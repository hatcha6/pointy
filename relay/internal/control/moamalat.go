package control

import (
	"context"
	"errors"
	"sort"
	"strings"
	"time"
)

// MoamalatLink is the relay's copy of one shop's Moamalat merchant token: the
// second, independent keepalive behind the shop's own backend
// (tools/moamalat-capture/TOKEN_CUSTODY_DESIGN.md). One per installation — a
// shop holds one live token at a time.
//
// TokenID is the backend's name for the token, a random id minted at each
// link. It is the token's identity for every state change on either side: a
// death reported for a token is applied only while that token is still the
// one held, so a stale answer about a replaced token cannot flip a re-linked
// shop back to needing an OTP.
type MoamalatLink struct {
	InstallationID string `json:"installation_id"`
	MID            string `json:"mid"`
	TokenID        string `json:"token_id"`
	// SealedToken is the token sealed under the relay's Moamalat key; empty
	// once the token is dead. Persisted by the file store; the HTTP layer
	// never answers it (see moamalatLinkView).
	SealedToken string `json:"sealed_token,omitempty"`
	State       string `json:"state"`
	// LastOKAt is the relay's own last accepted poke; zero until the first.
	LastOKAt      time.Time `json:"last_ok_at,omitempty"`
	LastAttemptAt time.Time `json:"last_attempt_at,omitempty"`
	LastError     string    `json:"last_error,omitempty"`
	Failures      int       `json:"failures"`
	NextPokeAt    time.Time `json:"next_poke_at"`
	DiedAt        time.Time `json:"died_at,omitempty"`
	// DeathSource says who saw the death: "relay" or "backend".
	DeathSource string    `json:"death_source,omitempty"`
	LinkedAt    time.Time `json:"linked_at"`
	UpdatedAt   time.Time `json:"updated_at"`
}

const (
	MoamalatAlive       = "alive"
	MoamalatNeedsReauth = "needs_reauth"
)

// MoamalatIntegrationKey is the key the fleet kill switch uses for Moamalat.
const MoamalatIntegrationKey = "moamalat"

// MoamalatClaim is one poke an instance has claimed, with the age of the
// relay's last accepted poke measured on the store's clock.
type MoamalatClaim struct {
	Link MoamalatLink
	// Age is now − LastOKAt (or − LinkedAt when there is none), on the
	// store's clock: the only clock any comparison in the keepalive uses.
	Age time.Duration
}

// MoamalatPoke is what one poke learned, to be written back.
type MoamalatPoke struct {
	InstallationID string
	// TokenID is the token that was poked. A result for any other token is
	// dropped: the shop has re-linked since.
	TokenID string
	// Outcome is "alive", "transient" or "dead".
	Outcome string
	// NextIn is the delay to the next poke, from the store's now.
	NextIn time.Duration
	Error  string
}

// MoamalatStore is an optional store capability.
type MoamalatStore interface {
	// PutMoamalatLink stores (or replaces) a shop's token and makes it due
	// at once. The token arrives sealed.
	PutMoamalatLink(ctx context.Context, link MoamalatLink) (MoamalatLink, error)
	GetMoamalatLink(ctx context.Context, installationID string) (MoamalatLink, error)
	DeleteMoamalatLink(ctx context.Context, installationID string) (bool, error)
	// DeleteAllMoamalatLinks drops every copy: the fleet kill switch.
	DeleteAllMoamalatLinks(ctx context.Context) (int, error)
	ListMoamalatLinks(ctx context.Context) ([]MoamalatLink, error)
	// ClaimMoamalatPokes takes up to limit alive links that are due and
	// pushes each one's next_poke_at out by lease, so no other instance
	// takes it while this one pokes. An instance that dies mid-poke loses
	// the row back to the queue when the lease runs out.
	ClaimMoamalatPokes(ctx context.Context, limit int, lease time.Duration) ([]MoamalatClaim, error)
	// RecordMoamalatPoke writes a poke's result, only while TokenID is still
	// the shop's token and the link is alive. False: nothing was written.
	RecordMoamalatPoke(ctx context.Context, poke MoamalatPoke) (MoamalatLink, bool, error)
	// MarkMoamalatDead moves the link to needs_reauth and drops the sealed
	// token, only while TokenID is still the shop's token.
	MarkMoamalatDead(ctx context.Context, installationID, tokenID, source string) (MoamalatLink, bool, error)
}

// ErrInvalidMoamalatLink is a link missing its shop, merchant id, token id or
// sealed token.
var ErrInvalidMoamalatLink = errors.New("invalid moamalat link")

func normalizeMoamalatLink(link MoamalatLink) (MoamalatLink, error) {
	link.InstallationID = strings.TrimSpace(link.InstallationID)
	link.MID = strings.TrimSpace(link.MID)
	link.TokenID = strings.TrimSpace(link.TokenID)
	if link.InstallationID == "" || link.MID == "" || link.SealedToken == "" ||
		link.TokenID == "" || len(link.TokenID) > 64 || len(link.MID) > 64 {
		return MoamalatLink{}, ErrInvalidMoamalatLink
	}
	return link, nil
}

// --- file store ------------------------------------------------------------

func (s *FileStore) PutMoamalatLink(_ context.Context, link MoamalatLink) (MoamalatLink, error) {
	link, err := normalizeMoamalatLink(link)
	if err != nil {
		return MoamalatLink{}, err
	}
	now := s.clock.Now().UTC()
	link.State = MoamalatAlive
	link.LastOKAt = time.Time{}
	link.LastAttemptAt = time.Time{}
	link.LastError = ""
	link.Failures = 0
	link.NextPokeAt = now
	link.DiedAt = time.Time{}
	link.DeathSource = ""
	link.LinkedAt = now
	link.UpdatedAt = now

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.data.MoamalatLinks == nil {
		s.data.MoamalatLinks = map[string]MoamalatLink{}
	}
	previous, had := s.data.MoamalatLinks[link.InstallationID]
	s.data.MoamalatLinks[link.InstallationID] = link
	if err := s.saveLocked(); err != nil {
		if had {
			s.data.MoamalatLinks[link.InstallationID] = previous
		} else {
			delete(s.data.MoamalatLinks, link.InstallationID)
		}
		return MoamalatLink{}, err
	}
	return link, nil
}

func (s *FileStore) GetMoamalatLink(_ context.Context, installationID string) (MoamalatLink, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	link, ok := s.data.MoamalatLinks[installationID]
	if !ok {
		return MoamalatLink{}, ErrNotFound
	}
	return link, nil
}

func (s *FileStore) DeleteMoamalatLink(_ context.Context, installationID string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	previous, ok := s.data.MoamalatLinks[installationID]
	if !ok {
		return false, nil
	}
	delete(s.data.MoamalatLinks, installationID)
	if err := s.saveLocked(); err != nil {
		s.data.MoamalatLinks[installationID] = previous
		return false, err
	}
	return true, nil
}

func (s *FileStore) DeleteAllMoamalatLinks(_ context.Context) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	previous := s.data.MoamalatLinks
	count := len(previous)
	if count == 0 {
		return 0, nil
	}
	s.data.MoamalatLinks = map[string]MoamalatLink{}
	if err := s.saveLocked(); err != nil {
		s.data.MoamalatLinks = previous
		return 0, err
	}
	return count, nil
}

func (s *FileStore) ListMoamalatLinks(_ context.Context) ([]MoamalatLink, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	links := make([]MoamalatLink, 0, len(s.data.MoamalatLinks))
	for _, link := range s.data.MoamalatLinks {
		links = append(links, link)
	}
	sort.Slice(links, func(i, j int) bool { return links[i].InstallationID < links[j].InstallationID })
	return links, nil
}

func (s *FileStore) ClaimMoamalatPokes(_ context.Context, limit int, lease time.Duration) ([]MoamalatClaim, error) {
	now := s.clock.Now().UTC()
	s.mu.Lock()
	defer s.mu.Unlock()
	due := []MoamalatLink{}
	for _, link := range s.data.MoamalatLinks {
		if link.State == MoamalatAlive && link.SealedToken != "" && !link.NextPokeAt.After(now) {
			due = append(due, link)
		}
	}
	sort.Slice(due, func(i, j int) bool { return due[i].NextPokeAt.Before(due[j].NextPokeAt) })
	if limit > 0 && len(due) > limit {
		due = due[:limit]
	}
	claims := make([]MoamalatClaim, 0, len(due))
	for _, link := range due {
		link.NextPokeAt = now.Add(lease)
		s.data.MoamalatLinks[link.InstallationID] = link
		claims = append(claims, MoamalatClaim{Link: link, Age: moamalatAge(link, now)})
	}
	// The lease lives in memory only; a file store is one process, and a
	// lost lease costs one early poke.
	return claims, nil
}

func moamalatAge(link MoamalatLink, now time.Time) time.Duration {
	since := link.LastOKAt
	if since.IsZero() {
		since = link.LinkedAt
	}
	return now.Sub(since)
}

func (s *FileStore) RecordMoamalatPoke(_ context.Context, poke MoamalatPoke) (MoamalatLink, bool, error) {
	now := s.clock.Now().UTC()
	s.mu.Lock()
	defer s.mu.Unlock()
	link, ok := s.data.MoamalatLinks[poke.InstallationID]
	if !ok || link.TokenID != poke.TokenID || link.State != MoamalatAlive {
		return link, false, nil
	}
	previous := link
	link.LastAttemptAt = now
	link.NextPokeAt = now.Add(poke.NextIn)
	link.UpdatedAt = now
	switch poke.Outcome {
	case "alive":
		link.LastOKAt = now
		link.Failures = 0
		link.LastError = ""
	default:
		link.Failures++
		link.LastError = truncateRunes(poke.Error, 300)
	}
	s.data.MoamalatLinks[link.InstallationID] = link
	if err := s.saveLocked(); err != nil {
		s.data.MoamalatLinks[link.InstallationID] = previous
		return MoamalatLink{}, false, err
	}
	return link, true, nil
}

func (s *FileStore) MarkMoamalatDead(_ context.Context, installationID, tokenID, source string) (MoamalatLink, bool, error) {
	now := s.clock.Now().UTC()
	s.mu.Lock()
	defer s.mu.Unlock()
	link, ok := s.data.MoamalatLinks[installationID]
	if !ok || link.TokenID != tokenID || link.State != MoamalatAlive {
		return link, false, nil
	}
	previous := link
	link.State = MoamalatNeedsReauth
	link.SealedToken = ""
	link.DiedAt = now
	link.DeathSource = source
	link.UpdatedAt = now
	s.data.MoamalatLinks[installationID] = link
	if err := s.saveLocked(); err != nil {
		s.data.MoamalatLinks[installationID] = previous
		return MoamalatLink{}, false, err
	}
	return link, true, nil
}

// --- cache wrapper -----------------------------------------------------------

func (s *CachedInstallationStore) moamalatStore() (MoamalatStore, error) {
	store, ok := s.store.(MoamalatStore)
	if !ok {
		return nil, errors.New("moamalat store is unavailable")
	}
	return store, nil
}

func (s *CachedInstallationStore) PutMoamalatLink(ctx context.Context, link MoamalatLink) (MoamalatLink, error) {
	store, err := s.moamalatStore()
	if err != nil {
		return MoamalatLink{}, err
	}
	return store.PutMoamalatLink(ctx, link)
}

func (s *CachedInstallationStore) GetMoamalatLink(ctx context.Context, installationID string) (MoamalatLink, error) {
	store, err := s.moamalatStore()
	if err != nil {
		return MoamalatLink{}, err
	}
	return store.GetMoamalatLink(ctx, installationID)
}

func (s *CachedInstallationStore) DeleteMoamalatLink(ctx context.Context, installationID string) (bool, error) {
	store, err := s.moamalatStore()
	if err != nil {
		return false, err
	}
	return store.DeleteMoamalatLink(ctx, installationID)
}

func (s *CachedInstallationStore) DeleteAllMoamalatLinks(ctx context.Context) (int, error) {
	store, err := s.moamalatStore()
	if err != nil {
		return 0, err
	}
	return store.DeleteAllMoamalatLinks(ctx)
}

func (s *CachedInstallationStore) ListMoamalatLinks(ctx context.Context) ([]MoamalatLink, error) {
	store, err := s.moamalatStore()
	if err != nil {
		return nil, err
	}
	return store.ListMoamalatLinks(ctx)
}

func (s *CachedInstallationStore) ClaimMoamalatPokes(ctx context.Context, limit int, lease time.Duration) ([]MoamalatClaim, error) {
	store, err := s.moamalatStore()
	if err != nil {
		return nil, err
	}
	return store.ClaimMoamalatPokes(ctx, limit, lease)
}

func (s *CachedInstallationStore) RecordMoamalatPoke(ctx context.Context, poke MoamalatPoke) (MoamalatLink, bool, error) {
	store, err := s.moamalatStore()
	if err != nil {
		return MoamalatLink{}, false, err
	}
	return store.RecordMoamalatPoke(ctx, poke)
}

func (s *CachedInstallationStore) MarkMoamalatDead(ctx context.Context, installationID, tokenID, source string) (MoamalatLink, bool, error) {
	store, err := s.moamalatStore()
	if err != nil {
		return MoamalatLink{}, false, err
	}
	return store.MarkMoamalatDead(ctx, installationID, tokenID, source)
}
