package relay

import (
	"context"
	"errors"
	"sync"

	"pointy/relay/internal/protocol"
)

var ErrConnectorOffline = errors.New("installation connector is offline")

type Hub struct {
	mu         sync.RWMutex
	connectors map[string]*protocol.Session
}

func NewHub() *Hub {
	return &Hub{connectors: map[string]*protocol.Session{}}
}

func (h *Hub) Register(installationID string, session *protocol.Session) func() {
	h.mu.Lock()
	if oldSession := h.connectors[installationID]; oldSession != nil && oldSession != session {
		_ = oldSession.Close()
	}
	h.connectors[installationID] = session
	h.mu.Unlock()

	var once sync.Once
	return func() {
		once.Do(func() {
			h.mu.Lock()
			if h.connectors[installationID] == session {
				delete(h.connectors, installationID)
			}
			h.mu.Unlock()
		})
	}
}

func (h *Hub) OpenStream(ctx context.Context, installationID string) (*protocol.Stream, error) {
	h.mu.RLock()
	session := h.connectors[installationID]
	h.mu.RUnlock()
	if session == nil {
		return nil, ErrConnectorOffline
	}
	return session.OpenStream(ctx)
}

func (h *Hub) IsOnline(installationID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.connectors[installationID] != nil
}
