package protocol

import (
	"context"
	"errors"
	"io"
	"sync"
	"sync/atomic"
	"time"
)

var (
	ErrSessionClosed = errors.New("relay session is closed")
	ErrStreamClosed  = errors.New("relay stream is closed")
)

type Session struct {
	conn     *Conn
	incoming chan *Stream
	closed   chan struct{}

	nextStreamID uint64
	mu           sync.RWMutex
	streams      map[uint64]*Stream
	closeOnce    sync.Once

	// lastFrameAt is when the peer last sent anything (unix nanoseconds).
	lastFrameAt atomic.Int64
}

func NewSession(conn *Conn) *Session {
	session := &Session{
		conn:         conn,
		incoming:     make(chan *Stream, 256),
		closed:       make(chan struct{}),
		nextStreamID: 1,
		streams:      map[uint64]*Stream{},
	}
	session.lastFrameAt.Store(time.Now().UnixNano())
	return session
}

// Ping asks the peer for a pong. Any frame the peer sends back — the pong or
// ordinary traffic — refreshes SinceLastFrame, which is what a liveness check
// reads.
func (s *Session) Ping() error {
	return s.writeFrame(Frame{Type: FramePing})
}

// SinceLastFrame is how long ago the peer last sent a frame of any kind.
func (s *Session) SinceLastFrame() time.Duration {
	return time.Since(time.Unix(0, s.lastFrameAt.Load()))
}

// Done is closed once the session has ended.
func (s *Session) Done() <-chan struct{} {
	return s.closed
}

func (s *Session) Run() error {
	defer s.Close()
	for {
		frame, err := s.conn.ReadFrame()
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
		s.lastFrameAt.Store(time.Now().UnixNano())
		switch frame.Type {
		case FrameOpen:
			stream := newStream(frame.StreamID, s)
			if !s.addStream(stream) {
				stream.closeRead()
				return ErrSessionClosed
			}
			select {
			case s.incoming <- stream:
			case <-s.closed:
				stream.closeRead()
				return ErrSessionClosed
			}
		case FrameData:
			if stream := s.stream(frame.StreamID); stream != nil {
				stream.deliver(frame.Payload)
			}
		case FrameClose, FrameError:
			if stream := s.stream(frame.StreamID); stream != nil {
				stream.closeRead()
				s.removeStream(frame.StreamID)
			}
		case FramePing:
			_ = s.conn.WriteFrame(Frame{Type: FramePong})
		case FramePong:
		default:
			return UnexpectedFrameError(frame)
		}
	}
}

func (s *Session) OpenStream(ctx context.Context) (*Stream, error) {
	streamID := atomic.AddUint64(&s.nextStreamID, 2) - 2
	stream := newStream(streamID, s)
	if !s.addStream(stream) {
		return nil, ErrSessionClosed
	}
	if err := s.conn.WriteFrame(Frame{Type: FrameOpen, StreamID: streamID}); err != nil {
		s.removeStream(streamID)
		return nil, err
	}
	select {
	case <-ctx.Done():
		stream.Close()
		return nil, ctx.Err()
	default:
		return stream, nil
	}
}

func (s *Session) Accept(ctx context.Context) (*Stream, error) {
	select {
	case stream := <-s.incoming:
		if stream == nil {
			return nil, ErrSessionClosed
		}
		return stream, nil
	case <-s.closed:
		return nil, ErrSessionClosed
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (s *Session) Close() error {
	s.closeOnce.Do(func() {
		close(s.closed)
		_ = s.conn.Close()

		s.mu.Lock()
		for id, stream := range s.streams {
			stream.closeRead()
			delete(s.streams, id)
		}
		s.mu.Unlock()
	})
	return nil
}

func (s *Session) writeFrame(frame Frame) error {
	select {
	case <-s.closed:
		return ErrSessionClosed
	default:
		return s.conn.WriteFrame(frame)
	}
}

func (s *Session) addStream(stream *Stream) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	select {
	case <-s.closed:
		return false
	default:
		s.streams[stream.id] = stream
		return true
	}
}

func (s *Session) stream(id uint64) *Stream {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.streams[id]
}

func (s *Session) removeStream(id uint64) {
	s.mu.Lock()
	delete(s.streams, id)
	s.mu.Unlock()
}

type Stream struct {
	id      uint64
	session *Session

	readCh    chan []byte
	readDone  chan struct{}
	readOnce  sync.Once
	closeOnce sync.Once

	readMu  sync.Mutex
	pending []byte
}

func newStream(id uint64, session *Session) *Stream {
	return &Stream{
		id:       id,
		session:  session,
		readCh:   make(chan []byte, 128),
		readDone: make(chan struct{}),
	}
}

func (s *Stream) ID() uint64 {
	return s.id
}

// Done is closed once the stream is finished: the peer closed or reset it, it
// was closed locally, or the session ended. Whoever serves a stream can watch
// it to abandon work the other end no longer wants.
func (s *Stream) Done() <-chan struct{} {
	return s.readDone
}

func (s *Stream) Read(p []byte) (int, error) {
	s.readMu.Lock()
	defer s.readMu.Unlock()

	for len(s.pending) == 0 {
		select {
		case chunk := <-s.readCh:
			s.pending = chunk
			continue
		default:
		}
		select {
		case chunk := <-s.readCh:
			s.pending = chunk
		case <-s.readDone:
			select {
			case chunk := <-s.readCh:
				s.pending = chunk
				continue
			default:
			}
			return 0, io.EOF
		case <-s.session.closed:
			select {
			case chunk := <-s.readCh:
				s.pending = chunk
				continue
			default:
			}
			return 0, io.EOF
		}
	}

	n := copy(p, s.pending)
	s.pending = s.pending[n:]
	return n, nil
}

// Write sends p to the peer. It fails with ErrStreamClosed once the stream has
// been closed from EITHER end — the peer's FrameClose/FrameError, a local
// Close, or the session going down — and it checks before every chunk, so a
// long write stops mid-body.
//
// Without that check a writer never learned the reader had gone. The relay
// closes a stream when the device that asked hangs up, a request times out, or
// an operator's download is cut short; the connector went on reading the
// backend's response and pushing it up the shop's uplink to a relay that drops
// frames for unknown streams. For a response with an end — a diagnostics
// export — that ran the whole export on the shop's server for nobody; for one
// with no end — a camera's MJPEG stream, an AI turn — it never stopped, and
// every one of them held a backend thread and a share of the uplink.
func (s *Stream) Write(p []byte) (int, error) {
	written := 0
	for len(p) > 0 {
		if s.closed() {
			return written, ErrStreamClosed
		}
		chunkSize := len(p)
		if chunkSize > DataChunkSize {
			chunkSize = DataChunkSize
		}
		chunk := p[:chunkSize]
		payload := make([]byte, len(chunk))
		copy(payload, chunk)
		if err := s.session.writeFrame(Frame{
			Type:     FrameData,
			StreamID: s.id,
			Payload:  payload,
		}); err != nil {
			if written > 0 {
				return written, err
			}
			return 0, err
		}
		written += chunkSize
		p = p[chunkSize:]
	}
	return written, nil
}

func (s *Stream) Close() error {
	s.closeOnce.Do(func() {
		s.session.removeStream(s.id)
		s.closeRead()
		_ = s.session.writeFrame(Frame{Type: FrameClose, StreamID: s.id})
	})
	return nil
}

func (s *Stream) deliver(payload []byte) {
	if len(payload) == 0 {
		return
	}
	copied := make([]byte, len(payload))
	copy(copied, payload)
	select {
	case s.readCh <- copied:
	case <-s.readDone:
	case <-s.session.closed:
		s.closeRead()
	}
}

func (s *Stream) closeRead() {
	s.readOnce.Do(func() {
		close(s.readDone)
	})
}

// closed reports whether the stream is finished in both directions. The
// protocol has no half-close: readDone is closed by the peer's FrameClose or
// FrameError, by a local Close, and for every stream when the session ends, so
// it is the one signal that nothing more should be written either.
func (s *Stream) closed() bool {
	select {
	case <-s.readDone:
		return true
	case <-s.session.closed:
		return true
	default:
		return false
	}
}
