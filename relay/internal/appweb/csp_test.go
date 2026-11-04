package appweb

import (
	"crypto/sha256"
	"encoding/base64"
	"net/http"
	"os"
	"strings"
	"testing"
	"testing/fstest"
)

const builtPage = `<!DOCTYPE html><html><head>
  <script>
    (function () { hint("preload", "main.0123456789ab.dart.wasm"); })();
  </script>
</head><body>
  <script>
    window.addEventListener("flutter-first-frame", function () {});
  </script>
  <script src="flutter_bootstrap.0123456789ab.js" async></script>
</body></html>`

func sha(content string) string {
	sum := sha256.Sum256([]byte(content))
	return "'sha256-" + base64.StdEncoding.EncodeToString(sum[:]) + "'"
}

func cspHandler(t *testing.T, page string) *Handler {
	t.Helper()
	handler, err := Wrap(http.NotFoundHandler(), Config{
		Hosts: []string{"app.dftr.ly"},
		Files: fstest.MapFS{
			"index.html":                {Data: []byte(page)},
			"main.0123456789ab.dart.js": {Data: []byte("code")},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	return handler
}

func directive(policy, name string) string {
	for _, part := range strings.Split(policy, ";") {
		part = strings.TrimSpace(part)
		if strings.HasPrefix(part, name+" ") {
			return part
		}
	}
	return ""
}

func TestEveryPageOfTheAppCarriesThePolicy(t *testing.T) {
	handler := cspHandler(t, builtPage)
	for _, path := range []string{"/", "/sales/42", "/settings/user"} {
		response := get(handler, "app.dftr.ly", path, nil)
		policy := response.Header.Get("Content-Security-Policy")
		if response.StatusCode != http.StatusOK || policy == "" {
			t.Fatalf("%s: expected the page under a policy, got %d %q", path, response.StatusCode, policy)
		}
		if directive(policy, "frame-ancestors") != "frame-ancestors 'none'" ||
			directive(policy, "object-src") != "object-src 'none'" ||
			directive(policy, "base-uri") != "base-uri 'self'" {
			t.Fatalf("%s: missing a lockdown directive: %s", path, policy)
		}
	}
}

func TestOnlyTheBuildsOwnInlineScriptsMayRun(t *testing.T) {
	policy := get(cspHandler(t, builtPage), "app.dftr.ly", "/", nil).Header.Get("Content-Security-Policy")
	scripts := directive(policy, "script-src")
	hint := "\n    (function () { hint(\"preload\", \"main.0123456789ab.dart.wasm\"); })();\n  "
	splash := "\n    window.addEventListener(\"flutter-first-frame\", function () {});\n  "
	for _, want := range []string{"'self'", "'wasm-unsafe-eval'", "https://www.gstatic.com", sha(hint), sha(splash)} {
		if !strings.Contains(scripts, want) {
			t.Fatalf("script-src lacks %s: %s", want, scripts)
		}
	}
	for _, never := range []string{"'unsafe-inline'", "'unsafe-eval'", "https:", "*", "data:"} {
		for _, source := range strings.Fields(scripts) {
			if source == never {
				t.Fatalf("script-src must not allow %s: %s", never, scripts)
			}
		}
	}
	if n := strings.Count(scripts, "'sha256-"); n != 2 {
		t.Fatalf("a script with a src is not hashed: expected 2 hashes, got %d", n)
	}
}

func TestTheShippedPagesInlineScriptIsAllowed(t *testing.T) {
	page, err := os.ReadFile("../../../frontend/web/index.html")
	if err != nil {
		t.Skipf("no frontend checkout beside the relay: %v", err)
	}
	hashes := inlineScriptHashes(string(page))
	if len(hashes) == 0 {
		t.Fatal("the shipped index.html has an inline script the policy must hash")
	}
	policy := get(cspHandler(t, string(page)), "app.dftr.ly", "/", nil).Header.Get("Content-Security-Policy")
	for _, hash := range hashes {
		if !strings.Contains(directive(policy, "script-src"), "'"+hash+"'") {
			t.Fatalf("script-src lacks %s", hash)
		}
	}
}

func TestBuildFilesAndTheRelayCarryNoPagePolicy(t *testing.T) {
	handler := cspHandler(t, builtPage)
	for _, path := range []string{"/main.0123456789ab.dart.js", "/api/auth/me/"} {
		if policy := get(handler, "app.dftr.ly", path, nil).Header.Get("Content-Security-Policy"); policy != "" {
			t.Fatalf("%s: expected no page policy, got %q", path, policy)
		}
	}
}

func TestABuildWithoutAPageIsRefused(t *testing.T) {
	_, err := Wrap(http.NotFoundHandler(), Config{
		Hosts: []string{"app.dftr.ly"},
		Files: fstest.MapFS{"main.dart.js": {Data: []byte("code")}},
	})
	if err == nil {
		t.Fatal("expected an error for a build with no index.html")
	}
}

func TestOnlyWebKitBefore16GetsUnsafeEval(t *testing.T) {
	for _, browser := range []struct {
		name, userAgent string
		legacy          bool
	}{
		{"iOS 15 Safari", "Mozilla/5.0 (iPhone; CPU iPhone OS 15_8 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.6.6 Mobile/15E148 Safari/604.1", true},
		{"iOS 15 Chrome (WebKit)", "Mozilla/5.0 (iPhone; CPU iPhone OS 15_7_9 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/119.0.6045.169 Mobile/15E148 Safari/604.1", true},
		{"iOS 16 Safari", "Mozilla/5.0 (iPhone; CPU iPhone OS 16_7_10 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1", false},
		{"iOS 18 Safari", "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1", false},
		{"iPadOS 15", "Mozilla/5.0 (iPad; CPU OS 15_8 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.6 Mobile/15E148 Safari/604.1", true},
		{"macOS Safari 15", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.6.1 Safari/605.1.15", true},
		{"macOS Safari 17", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15", false},
		{"desktop Chrome", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36", false},
		{"Android Chrome", "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36", false},
		{"Android Samsung", "Mozilla/5.0 (Linux; Android 13; SM-A515F) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/23.0 Chrome/115.0.0.0 Mobile Safari/537.36", false},
		{"Firefox", "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:131.0) Gecko/20100101 Firefox/131.0", false},
		{"nothing", "", false},
	} {
		policy := get(cspHandler(t, builtPage), "app.dftr.ly", "/", func(r *http.Request) {
			r.Header.Set("User-Agent", browser.userAgent)
		}).Header.Get("Content-Security-Policy")
		scripts := strings.Fields(directive(policy, "script-src"))
		hasUnsafeEval := false
		for _, source := range scripts {
			hasUnsafeEval = hasUnsafeEval || source == "'unsafe-eval'"
		}
		if hasUnsafeEval != browser.legacy {
			t.Errorf("%s: 'unsafe-eval' = %v, want %v", browser.name, hasUnsafeEval, browser.legacy)
		}
		if directive(policy, "child-src") != "child-src 'self' blob:" {
			t.Errorf("%s: older WebKit reads child-src for workers: %s", browser.name, policy)
		}
	}
}

func TestThePolicyVariesByBrowser(t *testing.T) {
	response := get(cspHandler(t, builtPage), "app.dftr.ly", "/", nil)
	if !strings.Contains(response.Header.Get("Vary"), "User-Agent") {
		t.Fatalf("a cache must not hand one browser's policy to another: Vary=%q", response.Header.Get("Vary"))
	}
}
