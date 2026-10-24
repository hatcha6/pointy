package clientaddr

import (
	"net/http/httptest"
	"testing"
)

func TestOf(t *testing.T) {
	request := httptest.NewRequest("GET", "/", nil)
	request.RemoteAddr = "10.0.0.5:4000"
	request.Header.Add("X-Forwarded-For", "6.6.6.6, 203.0.113.9")
	if got := Of(request, true); got != "203.0.113.9" {
		t.Fatalf("trusted = %s", got)
	}
	if got := Of(request, false); got != "10.0.0.5" {
		t.Fatalf("untrusted = %s", got)
	}
	request.Header.Set("X-Forwarded-For", "not-an-ip")
	if got := Of(request, true); got != "10.0.0.5" {
		t.Fatalf("garbage hop = %s", got)
	}
}

func TestPeerIsLocal(t *testing.T) {
	for addr, want := range map[string]bool{
		"127.0.0.1:1": true, "[::1]:1": true, "10.1.2.3:1": true, "192.168.1.9:1": true, "172.16.0.2:1": true,
		"203.0.113.9:1": false, "8.8.8.8:1": false,
	} {
		request := httptest.NewRequest("GET", "/", nil)
		request.RemoteAddr = addr
		if got := PeerIsLocal(request); got != want {
			t.Errorf("%s: %v", addr, got)
		}
	}
}
