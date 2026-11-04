package appweb

import (
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"io/fs"
	"regexp"
	"strconv"
	"strings"
)

// The app's pages run only the build's own code. A ticket and its refresh
// token sit in the browser's storage, so a script that got onto this origin
// would carry the shop's remote access away with it; the policy below is what
// stops one from running.
//
// What the build needs, and so what the policy allows:
//   - Its own files, and the two inline scripts in index.html (the splash's
//     and the download hints flutter_web_postbuild.sh adds) by hash, read from
//     the build when the relay starts, so a new build needs no edit here.
//   - WebAssembly ('wasm-unsafe-eval'): the WasmGC build on Chromium, and
//     CanvasKit or skwasm everywhere. WebKit before 16 (Safari, and every
//     browser on an iPhone left on iOS 15) does not know that keyword and
//     would refuse to compile CanvasKit, so it alone is given 'unsafe-eval',
//     the only grant it reads for WebAssembly (legacyWebKit).
//   - Workers from the build or from blob: URLs, said again as child-src for
//     WebKit before 15.5, which reads no worker-src.
//   - The rendering engine from www.gstatic.com and fallback fonts (emoji,
//     scripts the bundled font lacks) from fonts.gstatic.com: the build is
//     made without --no-web-resources-cdn.
//   - Inline styles: the engine writes its own style elements and attributes.
//   - Images and fetches from any https host: a product's picture, and the
//     image search the catalog offers, come from wherever the web has them.
//     Fetching is not running, so this opens no door to script.
//
// Nothing may frame the app, and nothing it does not ship may run in it.

// cdnScripts are the hosts the Flutter loader takes the engine from.
const cdnScripts = "https://www.gstatic.com"

var inlineScriptPattern = regexp.MustCompile(`(?is)<script(\s[^>]*)?>(.*?)</script>`)

// pagePolicies are a build's page policy: for every browser, and for
// WebKit too old to read 'wasm-unsafe-eval'.
type pagePolicies struct {
	current, legacyWebKit string
}

// contentSecurityPolicy is the policy for the build's pages.
func contentSecurityPolicy(files fs.FS) (pagePolicies, error) {
	page, err := fs.ReadFile(files, "index.html")
	if err != nil {
		return pagePolicies{}, err
	}
	scripts := []string{"'self'", "'wasm-unsafe-eval'", cdnScripts}
	for _, hash := range inlineScriptHashes(string(page)) {
		scripts = append(scripts, "'"+hash+"'")
	}
	return pagePolicies{
		current:      policyWith(scripts),
		legacyWebKit: policyWith(append(scripts, "'unsafe-eval'")),
	}, nil
}

// For picks the policy for the browser that sent userAgent.
func (p pagePolicies) For(userAgent string) string {
	if legacyWebKit(userAgent) {
		return p.legacyWebKit
	}
	return p.current
}

var (
	iosVersionPattern    = regexp.MustCompile(`\bOS (\d+)_\d+(?:_\d+)? like Mac OS X`)
	safariVersionPattern = regexp.MustCompile(`\bVersion/(\d+)(?:\.\d+)*.*\bSafari/`)
)

// legacyWebKit reports a WebKit before 16, the first to read
// 'wasm-unsafe-eval': any browser on iOS 15 or older (all of them are
// WebKit), or Safari 15 or older on a Mac.
func legacyWebKit(userAgent string) bool {
	if match := iosVersionPattern.FindStringSubmatch(userAgent); match != nil {
		major, _ := strconv.Atoi(match[1])
		return major < 16
	}
	if strings.Contains(userAgent, "Chrome/") || strings.Contains(userAgent, "Chromium/") ||
		strings.Contains(userAgent, "Firefox/") || strings.Contains(userAgent, "Edg/") {
		return false
	}
	if match := safariVersionPattern.FindStringSubmatch(userAgent); match != nil {
		major, _ := strconv.Atoi(match[1])
		return major < 16
	}
	return false
}

func policyWith(scripts []string) string {
	directives := []string{
		"default-src 'self'",
		"script-src " + strings.Join(scripts, " "),
		"style-src 'self' 'unsafe-inline'",
		"img-src 'self' data: blob: https:",
		"font-src 'self' data: https://fonts.gstatic.com",
		"connect-src 'self' data: blob: https:",
		"media-src 'self' data: blob:",
		"worker-src 'self' blob:",
		"child-src 'self' blob:",
		"frame-src 'self' blob: data:",
		"manifest-src 'self'",
		"object-src 'none'",
		"base-uri 'self'",
		"form-action 'self'",
		"frame-ancestors 'none'",
	}
	return strings.Join(directives, "; ")
}

// inlineScriptHashes are the CSP hashes of page's inline scripts: every
// script element without a src, in the order they appear.
func inlineScriptHashes(page string) []string {
	var hashes []string
	for _, match := range inlineScriptPattern.FindAllStringSubmatch(page, -1) {
		if attributes := strings.ToLower(match[1]); strings.Contains(attributes, "src=") {
			continue
		}
		sum := sha256.Sum256([]byte(match[2]))
		hashes = append(hashes, fmt.Sprintf("sha256-%s", base64.StdEncoding.EncodeToString(sum[:])))
	}
	return hashes
}
