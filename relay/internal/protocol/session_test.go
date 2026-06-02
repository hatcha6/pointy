package protocol

import (
	"context"
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
