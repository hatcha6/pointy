package artifacts

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"strings"
	"testing"
)

func TestStorePutGetOpen(t *testing.T) {
	store, err := New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	content := []byte("bundle-bytes-v1")
	meta, err := store.Put("1.4.0", bytes.NewReader(content))
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(content)
	if meta.SHA256 != hex.EncodeToString(sum[:]) {
		t.Fatalf("sha256 = %q, want %q", meta.SHA256, hex.EncodeToString(sum[:]))
	}
	if meta.Size != int64(len(content)) {
		t.Fatalf("size = %d, want %d", meta.Size, len(content))
	}
	if !store.Has("1.4.0") {
		t.Fatal("Has(1.4.0) should be true")
	}
	if store.Has("9.9.9") {
		t.Fatal("Has(9.9.9) should be false")
	}

	got, found, err := store.Get("1.4.0")
	if err != nil || !found || got.SHA256 != meta.SHA256 {
		t.Fatalf("Get = %+v found=%v err=%v", got, found, err)
	}

	file, openMeta, err := store.Open("1.4.0")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	read, err := io.ReadAll(file)
	if err != nil || !bytes.Equal(read, content) {
		t.Fatalf("Open content mismatch: %q err=%v", read, err)
	}
	if openMeta.Version != "1.4.0" {
		t.Fatalf("open meta version = %q", openMeta.Version)
	}

	// Overwrite replaces bytes + metadata.
	meta2, err := store.Put("1.4.0", strings.NewReader("newer"))
	if err != nil || meta2.Size != int64(len("newer")) {
		t.Fatalf("overwrite = %+v err=%v", meta2, err)
	}
	metas, err := store.List()
	if err != nil || len(metas) != 1 {
		t.Fatalf("List len = %d err=%v", len(metas), err)
	}
}

func TestStoreOpenMissing(t *testing.T) {
	store, err := New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.Open("nope"); err != ErrNotFound {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}
	if _, found, err := store.Get("nope"); err != nil || found {
		t.Fatalf("Get missing: found=%v err=%v", found, err)
	}
}

func TestSafeVersionRejectsTraversal(t *testing.T) {
	store, err := New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{"", "../etc", "a/b", "..", "v1/../../x", "a b"} {
		if _, err := store.Put(bad, strings.NewReader("x")); err == nil {
			t.Fatalf("expected rejection for version %q", bad)
		}
	}
}
