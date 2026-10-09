package console

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"testing"

	"github.com/fxamacker/cbor/v2"
)

// softAuthenticator is a software passkey for tests: one P-256 key, "none"
// attestation, user verification always performed.
type softAuthenticator struct {
	t          *testing.T
	origin     string
	rpID       string
	key        *ecdsa.PrivateKey
	credID     []byte
	userHandle []byte
	counter    uint32
}

func newSoftAuthenticator(t *testing.T, origin, rpID string) *softAuthenticator {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	credID := make([]byte, 16)
	_, _ = rand.Read(credID)
	return &softAuthenticator{t: t, origin: origin, rpID: rpID, key: key, credID: credID}
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func (a *softAuthenticator) clientData(kind string, challenge string) []byte {
	data, _ := json.Marshal(map[string]any{
		"type":        kind,
		"challenge":   challenge,
		"origin":      a.origin,
		"crossOrigin": false,
	})
	return data
}

func (a *softAuthenticator) authData(attested bool) []byte {
	rpHash := sha256.Sum256([]byte(a.rpID))
	flags := byte(0x01 | 0x04) // user present, user verified
	if attested {
		flags |= 0x40
	}
	out := append([]byte{}, rpHash[:]...)
	out = append(out, flags)
	counter := make([]byte, 4)
	a.counter++
	binary.BigEndian.PutUint32(counter, a.counter)
	out = append(out, counter...)
	if attested {
		out = append(out, make([]byte, 16)...) // AAGUID
		length := make([]byte, 2)
		binary.BigEndian.PutUint16(length, uint16(len(a.credID)))
		out = append(out, length...)
		out = append(out, a.credID...)
		x := a.key.X.FillBytes(make([]byte, 32))
		y := a.key.Y.FillBytes(make([]byte, 32))
		cose, err := cbor.Marshal(map[int]any{1: 2, 3: -7, -1: 1, -2: x, -3: y})
		if err != nil {
			a.t.Fatal(err)
		}
		out = append(out, cose...)
	}
	return out
}

// register answers a creation options payload ({"publicKey": {...}}).
func (a *softAuthenticator) register(options json.RawMessage) json.RawMessage {
	var creation struct {
		PublicKey struct {
			Challenge string `json:"challenge"`
			User      struct {
				ID string `json:"id"`
			} `json:"user"`
		} `json:"publicKey"`
	}
	if err := json.Unmarshal(options, &creation); err != nil {
		a.t.Fatal(err)
	}
	handle, err := base64.RawURLEncoding.DecodeString(creation.PublicKey.User.ID)
	if err != nil {
		a.t.Fatal(err)
	}
	a.userHandle = handle
	attestation, err := cbor.Marshal(map[string]any{
		"fmt":      "none",
		"attStmt":  map[string]any{},
		"authData": a.authData(true),
	})
	if err != nil {
		a.t.Fatal(err)
	}
	response, _ := json.Marshal(map[string]any{
		"id":    b64(a.credID),
		"rawId": b64(a.credID),
		"type":  "public-key",
		"response": map[string]any{
			"clientDataJSON":    b64(a.clientData("webauthn.create", creation.PublicKey.Challenge)),
			"attestationObject": b64(attestation),
		},
	})
	return response
}

// assert answers a request options payload ({"publicKey": {...}}).
func (a *softAuthenticator) assert(options json.RawMessage) json.RawMessage {
	var request struct {
		PublicKey struct {
			Challenge string `json:"challenge"`
		} `json:"publicKey"`
	}
	if err := json.Unmarshal(options, &request); err != nil {
		a.t.Fatal(err)
	}
	authData := a.authData(false)
	clientData := a.clientData("webauthn.get", request.PublicKey.Challenge)
	clientHash := sha256.Sum256(clientData)
	digest := sha256.Sum256(append(append([]byte{}, authData...), clientHash[:]...))
	signature, err := ecdsa.SignASN1(rand.Reader, a.key, digest[:])
	if err != nil {
		a.t.Fatal(err)
	}
	response, _ := json.Marshal(map[string]any{
		"id":    b64(a.credID),
		"rawId": b64(a.credID),
		"type":  "public-key",
		"response": map[string]any{
			"clientDataJSON":    b64(clientData),
			"authenticatorData": b64(authData),
			"signature":         b64(signature),
			"userHandle":        b64(a.userHandle),
		},
	})
	return response
}
