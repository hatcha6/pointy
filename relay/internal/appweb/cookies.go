package appweb

import (
	"net/http"
	"strings"
)

// Every shop's backend sets the same cookies (sessionid, csrftoken), and on
// this host they would all land in one browser jar: a manager signed in to
// shop A who then opens shop B would hand A's session to B's backend. So the
// app host keeps one jar per shop. A cookie a backend sets is renamed into
// its installation's namespace on the way out, and a request carries on only
// the cookies of the installation it is addressed to, under their own names.
//
// The installation is read from the request as the app sends it: the sign-in
// header, or the ticket (prefix.installation.secret). Neither is checked here
// — the relay judges both — and neither needs to be: a page cannot set them
// on a cross-site request, and naming another shop only picks which of the
// browser's own jars is sent, never another browser's.
const (
	ticketHeader       = "X-Pointy-Relay-Token"
	installationHeader = "X-Pointy-Relay-Installation"
	cookiePrefix       = "p_"
)

// requestInstallation is the installation an /api/ request is addressed to,
// or "" when it names none the cookie namespace can hold.
func requestInstallation(r *http.Request) string {
	id := ""
	if ticket := strings.TrimSpace(r.Header.Get(ticketHeader)); ticket != "" {
		if parts := strings.Split(ticket, "."); len(parts) == 3 {
			id = parts[1]
		}
	} else {
		id = r.Header.Get(installationHeader)
	}
	id = strings.ToLower(strings.TrimSpace(id))
	if id == "" || len(id) > 64 {
		return ""
	}
	for _, c := range id {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c == '-') {
			return ""
		}
	}
	return id
}

func cookieNamespace(installationID string) string {
	return cookiePrefix + installationID + "_"
}

// scopeRequestCookies keeps only installationID's cookies, under the names
// its backend gave them. It returns the names of cookies outside any shop's
// jar, set before jars existed, so the response can expire them.
func scopeRequestCookies(r *http.Request, installationID string) []string {
	cookies := r.Cookies()
	r.Header.Del("Cookie")
	namespace := cookieNamespace(installationID)
	var kept []string
	var unscoped []string
	for _, cookie := range cookies {
		switch {
		case installationID != "" && strings.HasPrefix(cookie.Name, namespace):
			name := strings.TrimPrefix(cookie.Name, namespace)
			if name != "" {
				kept = append(kept, name+"="+cookie.Value)
			}
		case !strings.HasPrefix(cookie.Name, cookiePrefix):
			unscoped = append(unscoped, cookie.Name)
		}
	}
	if len(kept) > 0 {
		r.Header.Set("Cookie", strings.Join(kept, "; "))
	}
	return unscoped
}

// scopeSetCookie renames one Set-Cookie line into namespace and drops any
// Domain, so the cookie stays on this host. A line with no name is dropped.
func scopeSetCookie(line, namespace string) string {
	parts := strings.Split(line, ";")
	name, _, found := strings.Cut(strings.TrimSpace(parts[0]), "=")
	if !found || strings.TrimSpace(name) == "" {
		return ""
	}
	scoped := []string{namespace + strings.TrimSpace(parts[0])}
	for _, attribute := range parts[1:] {
		key, _, _ := strings.Cut(strings.TrimSpace(attribute), "=")
		if strings.EqualFold(strings.TrimSpace(key), "Domain") {
			continue
		}
		scoped = append(scoped, attribute)
	}
	return strings.Join(scoped, ";")
}

// The relay streams the AI chat's events and checks for a Flusher to do it.
var _ http.Flusher = (*cookieScopingWriter)(nil)

// cookieScopingWriter rewrites a relayed answer's Set-Cookie lines into the
// shop's namespace before they reach the browser.
type cookieScopingWriter struct {
	http.ResponseWriter
	namespace string
	expire    []string
	written   bool
}

func (w *cookieScopingWriter) scope() {
	if w.written {
		return
	}
	w.written = true
	header := w.ResponseWriter.Header()
	lines := header.Values("Set-Cookie")
	header.Del("Set-Cookie")
	for _, line := range lines {
		if w.namespace == "" {
			continue
		}
		if scoped := scopeSetCookie(line, w.namespace); scoped != "" {
			header.Add("Set-Cookie", scoped)
		}
	}
	for _, name := range w.expire {
		header.Add("Set-Cookie", (&http.Cookie{Name: name, Path: "/", MaxAge: -1}).String())
	}
}

func (w *cookieScopingWriter) WriteHeader(status int) {
	if status >= http.StatusOK {
		w.scope()
	}
	w.ResponseWriter.WriteHeader(status)
}

func (w *cookieScopingWriter) Write(content []byte) (int, error) {
	w.scope()
	return w.ResponseWriter.Write(content)
}

// Flush keeps streamed answers (the AI chat's events) flowing.
func (w *cookieScopingWriter) Flush() {
	w.scope()
	if flusher, ok := w.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

// Unwrap lets http.ResponseController reach the connection underneath.
func (w *cookieScopingWriter) Unwrap() http.ResponseWriter {
	return w.ResponseWriter
}

// withShopCookies wraps a relayed /api/ request and its answer in the jar of
// the installation the request is addressed to.
func withShopCookies(w http.ResponseWriter, r *http.Request) (http.ResponseWriter, *http.Request) {
	installationID := requestInstallation(r)
	r = r.Clone(r.Context())
	expire := scopeRequestCookies(r, installationID)
	namespace := ""
	if installationID != "" {
		namespace = cookieNamespace(installationID)
	}
	return &cookieScopingWriter{ResponseWriter: w, namespace: namespace, expire: expire}, r
}
