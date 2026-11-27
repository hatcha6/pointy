package agentmcp

import (
	"html/template"
	"net/http"
	"net/url"
	"strings"
)

// The consent page is server-rendered with no script: the operator reads who
// asks and where the answer goes, and approves with a plain form. Approval
// needs the console's passkey session, whose SameSite=Strict cookie only
// arrives with a request sent from our own page — the form post.

var consentPage = template.Must(template.New("consent").Parse(`<!doctype html>
<html lang="ar" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>ربط Claude — دفتر</title>
<style>
:root{color-scheme:light dark;--bg:#f6f7f9;--card:#fff;--text:#17202a;--muted:#5b6673;--line:#dde2e8;--accent:#1f6feb;--warn:#9a6700}
@media (prefers-color-scheme:dark){:root{--bg:#0f1318;--card:#171c23;--text:#e8edf2;--muted:#9aa6b2;--line:#2a323c;--accent:#4c8dff;--warn:#e3b341}}
body{margin:0;background:var(--bg);color:var(--text);font:16px/1.6 system-ui,"Segoe UI",Tahoma,sans-serif}
main{max-width:520px;margin:40px auto;padding:0 16px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:24px}
h1{font-size:1.3rem;margin:0 0 12px}
dl{margin:16px 0;display:grid;grid-template-columns:max-content 1fr;gap:6px 12px}
dt{color:var(--muted)}dd{margin:0;word-break:break-all;direction:ltr;text-align:right}
ul{padding-inline-start:20px;color:var(--muted)}
.note{border-inline-start:3px solid var(--warn);padding:8px 12px;margin:16px 0;color:var(--warn)}
.actions{display:flex;gap:12px;margin-top:20px}
button{font:inherit;padding:10px 18px;border-radius:8px;border:1px solid var(--line);background:var(--card);color:var(--text);cursor:pointer}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff}
a{color:var(--accent)}
</style></head><body><main><div class="card">
<h1>{{.Title}}</h1>
{{if .Message}}<p>{{.Message}}</p>{{end}}
{{if .Form}}
<p>يطلب <strong>{{.Client}}</strong> الاطلاع على أعمال دفتر <strong>للقراءة فقط</strong>:</p>
<ul>
<li>المبيعات والمشتريات والأرباح، وأرصدة الموردين، وسعر الدولار، وإعدادات التسعير</li>
<li>شحن المحافظ، والملخص المالي، وحالة المتاجر والتنبيهات</li>
<li>تطبيق كروت دفتر: الزبائن (دون أرقام الهواتف) والطلبات والبلاغات والحملات</li>
<li>لا يرى أكواد البطاقات ولا الأرقام السرية ولا بيانات اتصال الزبائن، ولا يغيّر شيئاً</li>
</ul>
<dl><dt>الرجوع إلى</dt><dd>{{.Redirect}}</dd></dl>
<div class="note">وافق فقط إذا بدأت هذا الربط بنفسك الآن من حسابك في Claude. يمكنك إلغاؤه في أي وقت.</div>
{{if .SignIn}}<p><a href="/console/" target="_blank" rel="noopener">افتح لوحة التشغيل وسجّل الدخول</a></p>{{end}}
<form method="post" action="/oauth/authorize">
{{range $k, $v := .Fields}}<input type="hidden" name="{{$k}}" value="{{$v}}">{{end}}
<div class="actions">
<button class="primary" type="submit" name="decision" value="approve">موافقة</button>
<button type="submit" name="decision" value="deny">رفض</button>
</div></form>
{{end}}
</div></main></body></html>`))

type consentView struct {
	Title    string
	Message  string
	Form     bool
	SignIn   bool
	Client   string
	Redirect string
	Fields   map[string]string
}

// consentFields are the authorize parameters the form carries back.
var consentFields = []string{"response_type", "client_id", "redirect_uri", "state", "code_challenge",
	"code_challenge_method", "scope", "resource"}

func (s *Server) renderConsent(w http.ResponseWriter, values url.Values, request authorizeRequest, message string) {
	fields := map[string]string{}
	for _, name := range consentFields {
		if value := values.Get(name); value != "" {
			fields[name] = value
		}
	}
	redirect := request.RedirectURI
	if parsed, err := url.Parse(redirect); err == nil {
		redirect = parsed.Scheme + "://" + parsed.Host + parsed.Path
	}
	s.render(w, http.StatusOK, consentView{
		Title:    "ربط Claude بدفتر",
		Message:  message,
		Form:     true,
		SignIn:   message != "",
		Client:   request.Client.Name,
		Redirect: redirect,
		Fields:   fields,
	}, request.RedirectURI)
}

func (s *Server) renderMessage(w http.ResponseWriter, status int, title, message string) {
	s.render(w, status, consentView{Title: title, Message: message}, "")
}

func (s *Server) render(w http.ResponseWriter, status int, view consentView, redirect string) {
	formAction := "'self'"
	if parsed, err := url.Parse(redirect); err == nil && parsed.Host != "" {
		// Browsers apply form-action to the redirect after the post too.
		formAction += " " + parsed.Scheme + "://" + parsed.Host
		if isLoopbackHost(parsed.Hostname()) {
			formAction += " http://localhost:* http://127.0.0.1:*"
		}
	}
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Cache-Control", "no-store")
	h.Set("Content-Security-Policy", strings.Join([]string{
		"default-src 'none'", "style-src 'unsafe-inline'", "form-action " + formAction,
		"base-uri 'none'", "frame-ancestors 'none'",
	}, "; "))
	h.Set("X-Frame-Options", "DENY")
	h.Set("X-Content-Type-Options", "nosniff")
	// Not no-referrer: with it Chrome sends "Origin: null" on the consent
	// post, and the same-origin check refuses it.
	h.Set("Referrer-Policy", "same-origin")
	w.WriteHeader(status)
	_ = consentPage.Execute(w, view)
}
