// Package artifacts is the relay's disk-backed store for on-prem update bundles.
// The relay is the sole source of update bits for the fleet (shops never need a
// registry or GitHub): an operator uploads a built bundle once, the relay keeps
// it on a persistent volume keyed by version, and the on-prem update agent pulls
// it back over an authenticated, range-resumable HTTPS endpoint.
package artifacts

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// ErrNotFound is returned when no artifact exists for a version.
var ErrNotFound = errors.New("artifact not found")

// Meta describes a stored bundle. The bytes live next to it on disk.
type Meta struct {
	Version   string    `json:"version"`
	SHA256    string    `json:"sha256"`
	Size      int64     `json:"size"`
	CreatedAt time.Time `json:"created_at"`
}

// Store keeps one bundle per version under <dir>/<version>/{bundle.zip,meta.json}.
type Store struct {
	dir string
}

// New opens (creating if needed) an artifact store rooted at dir.
func New(dir string) (*Store, error) {
	dir = strings.TrimSpace(dir)
	if dir == "" {
		return nil, errors.New("artifact store dir is required")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	return &Store{dir: dir}, nil
}

// Put streams content into the store under version, computing its sha256 and size,
// then atomically publishes it. An existing version is overwritten.
func (s *Store) Put(version string, content io.Reader) (Meta, error) {
	clean, err := safeVersion(version)
	if err != nil {
		return Meta{}, err
	}
	versionDir := filepath.Join(s.dir, clean)
	if err := os.MkdirAll(versionDir, 0o755); err != nil {
		return Meta{}, err
	}

	tmp, err := os.CreateTemp(versionDir, ".bundle-*.tmp")
	if err != nil {
		return Meta{}, err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)

	hasher := sha256.New()
	size, err := io.Copy(io.MultiWriter(tmp, hasher), content)
	if err != nil {
		tmp.Close()
		return Meta{}, err
	}
	if err := tmp.Close(); err != nil {
		return Meta{}, err
	}

	meta := Meta{
		Version:   clean,
		SHA256:    hex.EncodeToString(hasher.Sum(nil)),
		Size:      size,
		CreatedAt: time.Now().UTC(),
	}
	if err := os.Rename(tmpName, s.bundlePath(clean)); err != nil {
		return Meta{}, err
	}
	if err := s.writeMeta(clean, meta); err != nil {
		return Meta{}, err
	}
	return meta, nil
}

// Get returns the metadata for a version, or ok=false when absent.
func (s *Store) Get(version string) (Meta, bool, error) {
	clean, err := safeVersion(version)
	if err != nil {
		return Meta{}, false, err
	}
	meta, err := s.readMeta(clean)
	if errors.Is(err, os.ErrNotExist) {
		return Meta{}, false, nil
	}
	if err != nil {
		return Meta{}, false, err
	}
	return meta, true, nil
}

// Has reports whether a usable bundle exists for version.
func (s *Store) Has(version string) bool {
	_, ok, err := s.Get(version)
	return err == nil && ok
}

// Open returns the bundle file (an io.ReadSeekCloser, so the HTTP layer can serve
// Range requests) and its metadata.
func (s *Store) Open(version string) (*os.File, Meta, error) {
	clean, err := safeVersion(version)
	if err != nil {
		return nil, Meta{}, err
	}
	meta, err := s.readMeta(clean)
	if errors.Is(err, os.ErrNotExist) {
		return nil, Meta{}, ErrNotFound
	}
	if err != nil {
		return nil, Meta{}, err
	}
	file, err := os.Open(s.bundlePath(clean))
	if errors.Is(err, os.ErrNotExist) {
		return nil, Meta{}, ErrNotFound
	}
	if err != nil {
		return nil, Meta{}, err
	}
	return file, meta, nil
}

// List returns every stored artifact's metadata, newest first.
func (s *Store) List() ([]Meta, error) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return nil, err
	}
	var metas []Meta
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		meta, err := s.readMeta(entry.Name())
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		metas = append(metas, meta)
	}
	sort.Slice(metas, func(i, j int) bool {
		return metas[i].CreatedAt.After(metas[j].CreatedAt)
	})
	return metas, nil
}

func (s *Store) bundlePath(version string) string {
	return filepath.Join(s.dir, version, "bundle.zip")
}

func (s *Store) metaPath(version string) string {
	return filepath.Join(s.dir, version, "meta.json")
}

func (s *Store) writeMeta(version string, meta Meta) error {
	content, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.metaPath(version) + ".tmp"
	if err := os.WriteFile(tmp, append(content, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.metaPath(version))
}

func (s *Store) readMeta(version string) (Meta, error) {
	content, err := os.ReadFile(s.metaPath(version))
	if err != nil {
		return Meta{}, err
	}
	var meta Meta
	if err := json.Unmarshal(content, &meta); err != nil {
		return Meta{}, err
	}
	return meta, nil
}

// safeVersion rejects versions that aren't filesystem-safe so an uploaded version
// string can never escape the store directory.
func safeVersion(version string) (string, error) {
	version = strings.TrimSpace(version)
	if version == "" {
		return "", errors.New("version is required")
	}
	for _, r := range version {
		switch {
		case r >= 'a' && r <= 'z',
			r >= 'A' && r <= 'Z',
			r >= '0' && r <= '9',
			r == '.', r == '-', r == '_', r == '+':
		default:
			return "", fmt.Errorf("version %q contains unsupported characters", version)
		}
	}
	if version == "." || version == ".." || strings.Contains(version, "..") {
		return "", fmt.Errorf("invalid version %q", version)
	}
	return version, nil
}
