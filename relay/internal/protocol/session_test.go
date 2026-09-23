package protocol

import (
	"context"
	"errors"
	"io"
	"net"
	"testing"
	"time"
)

func TestSessionMultiplexesStreams(t *testing.T) {
	leftRaw, rightRaw := net.Pipe()
	left := NewSession(NewConn(leftRaw))
	right := NewSession(NewConn(rightRaw))
	defer left.Close()
	defer right.Close()

	errs := make(chan error, 2)
	go func() { errs <- left.Run() }()
	go func() { errs <- right.Run() }()

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	leftStream, err := left.OpenStream(ctx)
	if err != nil {
		t.Fatal(err)
	}
	rightStream, err := right.Accept(ctx)
	if err != nil {
		t.Fatal(err)
	}

	go func() {
		defer rightStream.Close()
		buf := make([]byte, len("ping"))
		if _, err := io.ReadFull(rightStream, buf); err != nil {
			t.Errorf("right stream read failed: %v", err)
			return
		}
		if string(buf) != "ping" {
			t.Errorf("expected ping, got %q", string(buf))
			return
		}
		if _, err := rightStream.Write([]byte("pong")); err != nil {
			t.Errorf("right stream write failed: %v", err)
		}
	}()

	if _, err := leftStream.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	response, err := io.ReadAll(leftStream)
	if err != nil {
		t.Fatal(err)
	}
	if string(response) != "pong" {
		t.Fatalf("expected pong, got %q", string(response))
	}

	left.Close()
	right.Close()
	for i := 0; i < 2; i++ {
		select {
		case <-errs:
		case <-time.After(time.Second):
			t.Fatal("session run did not exit")
		}
	}
}

// The relay closes a stream when the device that asked has gone. Before this
// check the serving side kept writing — the connector pumped the rest of a
// camera stream or an export up the shop's uplink into a relay that drops
// frames for streams it no longer knows.
func TestWriteFailsOnceThePeerClosesTheStream(t *testing.T) {
	leftRaw, rightRaw := net.Pipe()
	left := NewSession(NewConn(leftRaw))
	right := NewSession(NewConn(rightRaw))
	defer left.Close()
	defer right.Close()
	go func() { _ = left.Run() }()
	go func() { _ = right.Run() }()

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	opener, err := left.OpenStream(ctx)
	if err != nil {
		t.Fatal(err)
	}
	server, err := right.Accept(ctx)
	if err != nil {
		t.Fatal(err)
	}

	// The opener reads a little, then hangs up — a device closing a camera
	// view, or a relay whose request deadline passed.
	go func() {
		buf := make([]byte, 16)
		_, _ = opener.Read(buf)
		_ = opener.Close()
	}()

	writeErr := make(chan error, 1)
	go func() {
		chunk := make([]byte, 1024)
		for {
			if _, err := server.Write(chunk); err != nil {
				writeErr <- err
				return
			}
		}
	}()

	select {
	case err := <-writeErr:
		if !errors.Is(err, ErrStreamClosed) {
			t.Fatalf("expected ErrStreamClosed, got %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("writer kept writing after the peer closed the stream")
	}
	select {
	case <-server.Done():
	default:
		t.Fatal("Done must be closed once the peer has closed the stream")
	}
}

func TestWriteFailsAfterALocalClose(t *testing.T) {
	leftRaw, rightRaw := net.Pipe()
	left := NewSession(NewConn(leftRaw))
	right := NewSession(NewConn(rightRaw))
	defer left.Close()
	defer right.Close()
	go func() { _ = left.Run() }()
	go func() { _ = right.Run() }()

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	stream, err := left.OpenStream(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := right.Accept(ctx); err != nil {
		t.Fatal(err)
	}
	_ = stream.Close()
	if _, err := stream.Write([]byte("late")); !errors.Is(err, ErrStreamClosed) {
		t.Fatalf("expected ErrStreamClosed after Close, got %v", err)
	}
}
