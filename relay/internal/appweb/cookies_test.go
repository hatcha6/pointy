package appweb

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
)

const (
	shopA = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"
	shopB = "6ec0bd7f-11c0-43da-975e-2a8ad9ebae0b"
)

// newCookieHandler fronts a backend that records the Cookie it was sent and
// answers with a session of its own, as Django does at login.
func newCookieHandler(t *testing.T) (*Handler, *[]string) {
	t.Helper()
	var seen []string
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = append(seen, r.Header.Get("Cookie"))
		w.Header().Add("Set-Cookie", "sessionid=s-"+r.Header.Get("X-Shop")+"; HttpOnly; Path=/; SameSite=Lax; Secure")
		w.Header().Add("Set-Cookie", "csrftoken=c-"+r.Header.Get("X-Shop")+"; Domain=app.dftr.ly; Path=/")
		w.WriteHeader(http.StatusOK)
	})
	handler, err := Wrap(next, Config{
		Hosts: []string{"app.dftr.ly"},
		Files: fstest.MapFS{"index.html": {Data: []byte("<html>app</html>")}},
	})
	if err != nil {
		t.Fatal(err)
	}
	return handler, &seen
}

// browserJar is the one cookie jar every shop shares on the app host.
type browserJar map[string]string

func (jar browserJar) send(handler http.Handler, host, path string, edit func(*http.Request)) *http.Response {
	request := httptest.NewRequest(http.MethodPost, "https://"+host+path, nil)
	for name, value := range jar {
		request.AddCookie(&http.Cookie{Name: name, Value: value})
	}
	if edit != nil {
		edit(request)
	}
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	response := recorder.Result()
	for _, cookie := range response.Cookies() {
		if cookie.MaxAge < 0 {
			delete(jar, cookie.Name)
		} else {
			jar[cookie.Name] = cookie.Value
		}
	}
	return response
}

func signIn(installation string) func(*http.Request) {
	return func(r *http.Request) {
		r.Header.Set(installationHeader, installation)
		r.Header.Set("X-Shop", installation[:4])
	}
}

func TestOneShopsSessionNeverReachesAnother(t *testing.T) {
	handler, seen := newCookieHandler(t)
	jar := browserJar{}
	jar.send(handler, "app.dftr.ly", "/api/auth/login/", signIn(shopA))
	jar.send(handler, "app.dftr.ly", "/api/auth/me/", signIn(shopB))
	if got := (*seen)[1]; got != "" {
		t.Fatalf("shop B must get none of shop A's cookies, got %q", got)
	}
	jar.send(handler, "app.dftr.ly", "/api/auth/me/", signIn(shopA))
	if got := (*seen)[2]; got != "sessionid=s-1b9d; csrftoken=c-1b9d" &&
		got != "csrftoken=c-1b9d; sessionid=s-1b9d" {
		t.Fatalf("shop A gets its own session back under its own names, got %q", got)
	}
	for name := range jar {
		if !strings.HasPrefix(name, "p_") {
			t.Fatalf("every cookie on the app host belongs to a shop's jar, found %q", name)
		}
	}
}

func TestATicketPicksItsShopsJar(t *testing.T) {
	handler, seen := newCookieHandler(t)
	jar := browserJar{}
	// B first, so the shop signed in to last is not the one asked for.
	jar.send(handler, "app.dftr.ly", "/api/auth/login/", signIn(shopB))
	jar.send(handler, "app.dftr.ly", "/api/auth/login/", signIn(shopA))
	jar.send(handler, "app.dftr.ly", "/api/products/", func(r *http.Request) {
		r.Header.Set(ticketHeader, "ptt1."+shopB+".secret")
	})
	got := (*seen)[2]
	if !strings.Contains(got, "sessionid=s-6ec0") || strings.Contains(got, "1b9d") {
		t.Fatalf("a ticket for shop B carries B's session only, got %q", got)
	}
}

func TestScopedCookiesStayOnTheAppHost(t *testing.T) {
	handler, _ := newCookieHandler(t)
	response := browserJar{}.send(handler, "app.dftr.ly", "/api/auth/login/", signIn(shopA))
	for _, line := range response.Header.Values("Set-Cookie") {
		if strings.Contains(strings.ToLower(line), "domain=") {
			t.Fatalf("a shop's cookie must stay host-only, got %q", line)
		}
		if strings.HasPrefix(line, "p_"+shopA+"_sessionid=") &&
			(!strings.Contains(line, "HttpOnly") || !strings.Contains(line, "Secure")) {
			t.Fatalf("the session keeps its attributes, got %q", line)
		}
	}
}

func TestCookiesFromBeforeJarsAreDroppedAndExpired(t *testing.T) {
	handler, seen := newCookieHandler(t)
	jar := browserJar{"sessionid": "old-a", "csrftoken": "old-a"}
	jar.send(handler, "app.dftr.ly", "/api/auth/me/", signIn(shopB))
	if got := (*seen)[0]; got != "" {
		t.Fatalf("an unscoped cookie must not be passed on, got %q", got)
	}
	if _, ok := jar["sessionid"]; ok {
		t.Fatalf("the unscoped session should be expired, jar %v", jar)
	}
}

func TestARequestNamingNoShopCarriesNoCookies(t *testing.T) {
	handler, seen := newCookieHandler(t)
	jar := browserJar{}
	jar.send(handler, "app.dftr.ly", "/api/auth/login/", signIn(shopA))
	response := jar.send(handler, "app.dftr.ly", "/api/auth/me/", func(r *http.Request) {
		r.Header.Set(installationHeader, "../evil; x=1")
	})
	if got := (*seen)[1]; got != "" {
		t.Fatalf("expected no cookies, got %q", got)
	}
	if lines := response.Header.Values("Set-Cookie"); len(lines) != 0 {
		t.Fatalf("an answer for no shop sets nothing, got %v", lines)
	}
	jar.send(handler, "app.dftr.ly", "/v1/relay-ticket-refresh", nil)
	if got := (*seen)[2]; got != "" {
		t.Fatalf("the relay's own path gets no shop cookies, got %q", got)
	}
}

func TestOtherHostsKeepTheirCookiesAsTheyWere(t *testing.T) {
	handler, seen := newCookieHandler(t)
	response := browserJar{"sessionid": "lan"}.send(handler, "relay.dftr.ly", "/api/auth/me/", signIn(shopA))
	if got := (*seen)[0]; got != "sessionid=lan" {
		t.Fatalf("expected the cookie untouched off the app host, got %q", got)
	}
	if line := response.Header.Get("Set-Cookie"); !strings.HasPrefix(line, "sessionid=") {
		t.Fatalf("expected the backend's own cookie name off the app host, got %q", line)
	}
}
