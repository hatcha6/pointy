// Package artifacts is the relay's disk-backed store for on-prem update bundles.
// The relay is the sole source of update bits for the fleet (shops never need a
// registry or GitHub): an operator uploads a built bundle once (or points the
// relay at a URL to download it from, see Fetch), the relay keeps
// it on a persistent volume keyed by version, and the on-prem update agent pulls
// it back over an authenticated, range-resumable HTTPS endpoint.
package artifacts

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// ErrNotFound is returned when no artifact exists for a version.
var ErrNotFound = errors.New("artifact not found")

// ErrInvalidSignature means a release signature is not an Ed25519 signature
// in base64 (the content of the release's <zip>.sig file).
var ErrInvalidSignature = errors.New("invalid release signature")

// Meta describes a stored bundle. The bytes live next to it on disk.
type Meta struct {
	Version   string    `json:"version"`
	SHA256    string    `json:"sha256"`
	Size      int64     `json:"size"`
	CreatedAt time.Time `json:"created_at"`
	// Signature is the release key's Ed25519 signature over the SHA256 hex
	// (base64, as the release workflow writes it to <zip>.sig). The relay only
	// carries it: it holds no key, and the update agent is what verifies it.
	Signature string `json:"signature,omitempty"`
}

// Store keeps one bundle per version under <dir>/<version>/{bundle.zip,meta.json}.
type Store struct {
	dir string

	// FetchClient downloads bundles for Fetch; nil uses a client with sane
	// connect/header timeouts and no overall deadline (bundles are large).
	FetchClient *http.Client

	mu      sync.Mutex
	fetches map[string]*fetchJob
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
	return s.PutSigned(version, content, "")
}

// PutSigned is Put with the bundle's release signature (see Meta.Signature);
// an empty signature publishes the bundle unsigned. Overwriting a version
// always replaces its signature, because a signature only fits the bytes it
// was made for.
func (s *Store) PutSigned(version string, content io.Reader, signature string) (Meta, error) {
	return s.put(version, content, "", signature)
}

// put is PutSigned with an optional expected sha256: on a mismatch nothing is
// published, so a corrupt download never replaces a good bundle.
func (s *Store) put(version string, content io.Reader, expectedSHA256, signature string) (Meta, error) {
	return s.write(version, expectedSHA256, signature, func(tmp *os.File, hasher hash.Hash) (int64, error) {
		return io.Copy(io.MultiWriter(tmp, hasher), content)
	})
}

// SetSignature attaches (or, with "", removes) the release signature of a
// bundle already in the store — for a bundle uploaded before its .sig was at
// hand.
func (s *Store) SetSignature(version, signature string) (Meta, error) {
	clean, err := safeVersion(version)
	if err != nil {
		return Meta{}, err
	}
	normalized, err := NormalizeSignature(signature)
	if err != nil {
		return Meta{}, err
	}
	meta, err := s.readMeta(clean)
	if errors.Is(err, os.ErrNotExist) {
		return Meta{}, ErrNotFound
	}
	if err != nil {
		return Meta{}, err
	}
	meta.Signature = normalized
	if err := s.writeMeta(clean, meta); err != nil {
		return Meta{}, err
	}
	return meta, nil
}

// NormalizeSignature checks a release signature is base64 of an Ed25519
// signature and returns it in canonical form ("" stays ""). It cannot check
// the signature is RIGHT — that needs the public key, which only shops hold —
// but it turns a pasted wrong file into an error here instead of a refused
// update on every shop.
func NormalizeSignature(signature string) (string, error) {
	signature = strings.TrimSpace(signature)
	if signature == "" {
		return "", nil
	}
	raw, err := base64.StdEncoding.DecodeString(signature)
	if err != nil {
		return "", fmt.Errorf("%w: not base64", ErrInvalidSignature)
	}
	if len(raw) != ed25519.SignatureSize {
		return "", fmt.Errorf("%w: %d bytes, an Ed25519 signature is %d", ErrInvalidSignature, len(raw), ed25519.SignatureSize)
	}
	return base64.StdEncoding.EncodeToString(raw), nil
}

// write publishes whatever fill streams into the temp file and hasher. fill
// owns both, so a resumable download can append across connections or start
// over (truncate + Reset) without the store knowing.
func (s *Store) write(
	version, expectedSHA256, signature string,
	fill func(tmp *os.File, hasher hash.Hash) (int64, error),
) (_ Meta, err error) {
	clean, err := safeVersion(version)
	if err != nil {
		return Meta{}, err
	}
	signature, err = NormalizeSignature(signature)
	if err != nil {
		return Meta{}, err
	}
	versionDir := filepath.Join(s.dir, clean)
	if err := os.MkdirAll(versionDir, 0o755); err != nil {
		return Meta{}, err
	}
	defer func() {
		if err != nil {
			os.Remove(versionDir) // only succeeds when empty: never drops a good bundle
		}
	}()

	tmp, err := os.CreateTemp(versionDir, ".bundle-*.tmp")
	if err != nil {
		return Meta{}, err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)

	hasher := sha256.New()
	size, err := fill(tmp, hasher)
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
		Signature: signature,
	}
	if expectedSHA256 != "" && meta.SHA256 != expectedSHA256 {
		return Meta{}, fmt.Errorf("%w: got %s, want %s", ErrChecksumMismatch, meta.SHA256, expectedSHA256)
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
