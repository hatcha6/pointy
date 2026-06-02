package protocol

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

const (
	Version        byte = 1
	HeaderSize          = 16
	MaxPayloadSize      = 1 << 20
	DataChunkSize       = 64 << 10
)

type FrameType byte

const (
	FrameHello FrameType = iota + 1
	FrameHelloAck
	FrameOpen
	FrameData
	FrameClose
	FramePing
	FramePong
	FrameError
)

var (
	ErrBadVersion      = errors.New("bad relay protocol version")
	ErrPayloadTooLarge = errors.New("relay frame payload is too large")
)

type Frame struct {
	Type     FrameType
	StreamID uint64
	Payload  []byte
}

type Conn struct {
	conn    net.Conn
	writeMu sync.Mutex
}

func NewConn(conn net.Conn) *Conn {
	return &Conn{conn: conn}
}

func (c *Conn) ReadFrame() (Frame, error) {
	var header [HeaderSize]byte
	if _, err := io.ReadFull(c.conn, header[:]); err != nil {
		return Frame{}, err
	}
	if header[0] != Version {
		return Frame{}, ErrBadVersion
	}
	length := binary.BigEndian.Uint32(header[12:16])
	if length > MaxPayloadSize {
		return Frame{}, ErrPayloadTooLarge
	}
	payload := make([]byte, int(length))
	if length > 0 {
		if _, err := io.ReadFull(c.conn, payload); err != nil {
			return Frame{}, err
		}
	}
	return Frame{
		Type:     FrameType(header[1]),
		StreamID: binary.BigEndian.Uint64(header[4:12]),
		Payload:  payload,
	}, nil
}

func (c *Conn) WriteFrame(frame Frame) error {
	if len(frame.Payload) > MaxPayloadSize {
		return ErrPayloadTooLarge
	}
	var header [HeaderSize]byte
	header[0] = Version
	header[1] = byte(frame.Type)
	binary.BigEndian.PutUint64(header[4:12], frame.StreamID)
	binary.BigEndian.PutUint32(header[12:16], uint32(len(frame.Payload)))

	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if _, err := c.conn.Write(header[:]); err != nil {
		return err
	}
	if len(frame.Payload) == 0 {
		return nil
	}
	_, err := c.conn.Write(frame.Payload)
	return err
}

func (c *Conn) Close() error {
	return c.conn.Close()
}

func (c *Conn) SetDeadline(t time.Time) error {
	return c.conn.SetDeadline(t)
}

func (c *Conn) SetReadDeadline(t time.Time) error {
	return c.conn.SetReadDeadline(t)
}

func (c *Conn) SetWriteDeadline(t time.Time) error {
	return c.conn.SetWriteDeadline(t)
}

func WriteError(c *Conn, message string) error {
	return c.WriteFrame(Frame{Type: FrameError, Payload: []byte(message)})
}

func UnexpectedFrameError(frame Frame) error {
	return fmt.Errorf("unexpected relay frame type %d", frame.Type)
}
