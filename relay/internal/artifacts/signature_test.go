package artifacts

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strings"
	"testing"
)

// releaseSignature signs content the way release.yml does: Ed25519 over the
// zip's sha256 hex, base64.
func releaseSignature(t *testing.T, key ed25519.PrivateKey, content []byte) string {
	t.Helper()
	sum := sha256.Sum256(content)
	return base64.StdEncoding.EncodeToString(ed25519.Sign(key, []byte(hex.EncodeToString(sum[:]))))
}

func newSigningKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	_, key, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	return key
}

func TestPutSignedKeepsTheSignatureAndReuploadDropsIt(t *testing.T) {
	store, _ := New(t.TempDir())
	key := newSigningKey(t)
	signature := releaseSignature(t, key, fakeBundle)

	// The .sig file as base64 -w0 writes it, plus the newline an editor adds.
	meta, err := store.PutSigned("1.4.0", strings.NewReader(string(fakeBundle)), signature+"\n")
	if err != nil {
		t.Fatal(err)
	}
	if meta.Signature != signature {
		t.Fatalf("signature = %q, want %q", meta.Signature, signature)
	}
	stored, _, _ := store.Get("1.4.0")
	if stored.Signature != signature {
		t.Fatalf("stored signature = %q", stored.Signature)
	}
	raw, _ := base64.StdEncoding.DecodeString(stored.Signature)
	if !ed25519.Verify(key.Public().(ed25519.PublicKey), []byte(stored.SHA256), raw) {
		t.Fatal("stored signature does not verify against the stored sha256")
	}

	// New bytes under the same version: the old signature cannot fit them.
	if _, err := store.Put("1.4.0", strings.NewReader("PK\x03\x04other")); err != nil {
		t.Fatal(err)
	}
	if stored, _, _ := store.Get("1.4.0"); stored.Signature != "" {
		t.Fatalf("re-upload kept a stale signature %q", stored.Signature)
	}
}

func TestPutSignedRefusesAMalformedSignatureAndKeepsTheOldBundle(t *testing.T) {
	store, _ := New(t.TempDir())
	good, err := store.Put("1.4.0", strings.NewReader(string(fakeBundle)))
	if err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{
		"not base64!",
		base64.StdEncoding.EncodeToString([]byte("too short")),
		// a sha256 hex file passed by mistake for the .sig
		strings.Repeat("ab", 32),
	} {
		_, err := store.PutSigned("1.4.0", strings.NewReader("PK\x03\x04replacement"), bad)
		if !errors.Is(err, ErrInvalidSignature) {
			t.Fatalf("PutSigned(%q) err = %v, want ErrInvalidSignature", bad, err)
		}
	}
	if stored, _, _ := store.Get("1.4.0"); stored.SHA256 != good.SHA256 {
		t.Fatal("a refused upload replaced the published bundle")
	}
}

func TestSetSignatureAttachesAndRemoves(t *testing.T) {
	store, _ := New(t.TempDir())
	if _, err := store.SetSignature("9.9.9", releaseSignature(t, newSigningKey(t), fakeBundle)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("signing a missing bundle: err = %v, want ErrNotFound", err)
	}
	put, err := store.Put("1.4.0", strings.NewReader(string(fakeBundle)))
	if err != nil {
		t.Fatal(err)
	}
	signature := releaseSignature(t, newSigningKey(t), fakeBundle)
	meta, err := store.SetSignature("1.4.0", signature)
	if err != nil {
		t.Fatal(err)
	}
	if meta.Signature != signature || meta.SHA256 != put.SHA256 || meta.Size != put.Size {
		t.Fatalf("meta after sign = %+v", meta)
	}
	if _, err := store.SetSignature("1.4.0", "garbage"); !errors.Is(err, ErrInvalidSignature) {
		t.Fatalf("err = %v, want ErrInvalidSignature", err)
	}
	if stored, _, _ := store.Get("1.4.0"); stored.Signature != signature {
		t.Fatal("a refused signature replaced the good one")
	}
	if meta, err := store.SetSignature("1.4.0", ""); err != nil || meta.Signature != "" {
		t.Fatalf("remove: meta = %+v err = %v", meta, err)
	}
}

func TestFetchPublishesTheSignatureAndRefusesABadOneUpFront(t *testing.T) {
	store, _ := New(t.TempDir())
	server := serveBytes(t, fakeBundle)
	headers := map[string]string{"Authorization": "Bearer asset-token"}

	if _, err := store.Fetch("1.4.0", FetchRequest{URL: server.URL + "/b.zip", Headers: headers, Signature: "nope"}); !errors.Is(err, ErrInvalidSignature) {
		t.Fatalf("err = %v, want ErrInvalidSignature", err)
	}
	if _, err := store.FetchStatus("1.4.0"); !errors.Is(err, ErrNoFetch) {
		t.Fatal("a refused signature still started a download")
	}

	signature := releaseSignature(t, newSigningKey(t), fakeBundle)
	if _, err := store.Fetch("1.4.0", FetchRequest{URL: server.URL + "/b.zip", Headers: headers, Signature: signature}); err != nil {
		t.Fatal(err)
	}
	status := waitFetch(t, store, "1.4.0")
	if status.State != FetchDone || status.Artifact == nil || status.Artifact.Signature != signature {
		t.Fatalf("status = %+v", status)
	}
	if stored, _, _ := store.Get("1.4.0"); stored.Signature != signature {
		t.Fatalf("stored signature = %q", stored.Signature)
	}
}
