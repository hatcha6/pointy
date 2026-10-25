package relay

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"time"

	"pointy/relay/internal/clientaddr"
	"pointy/relay/internal/control"
	"pointy/relay/internal/dafa"
	"pointy/relay/internal/ratelimit"
	"pointy/relay/internal/resala"
)

// Sign-in for «دفتر كروت», the company's own card app
// (DAFTAR_CARDS_APP_PLAN.md). A customer proves a Libyan mobile number with a
// 6-digit code the relay texts through Resala, and gets a session for their
// device: a short access token and a rotating refresh token.
//
//	POST   /v1/customers/auth/otp        {phone}: text a code
//	POST   /v1/customers/auth/verify     {phone, code, device}: sign in
//	POST   /v1/customers/auth/refresh    {refresh_token}: a new token pair
//	POST   /v1/customers/auth/logout     sign this device out (Bearer)
//	GET    /v1/customers/me              the signed-in customer (Bearer)
//	DELETE /v1/customers/me              delete the account (Bearer)
//	GET    /v1/customers/me/sessions     the customer's devices (Bearer)
//	DELETE /v1/customers/me/sessions     sign every other device out (Bearer)
//	DELETE /v1/customers/me/sessions/{id}  sign one device out (Bearer)
//
// These routes take no installation token: the caller is a person's phone,
// not a shop. Every code is an SMS the company pays for, so codes are capped
// per phone in the store (durable) and per caller address in the limiter.

const (
	customerAccessTokenPrefix  = "pca1"
	customerRefreshTokenPrefix = "pcr1"
	customerOTPDigits          = 6
	maxCustomerRequestBytes    = 4 << 10
)

// CustomerOTPSender texts a sign-in code to a phone ("218…").
type CustomerOTPSender interface {
	SendCustomerOTP(ctx context.Context, phone, code string) error
}

// CustomerConfig turns customer sign-in on.
type CustomerConfig struct {
	// Sender texts the codes. Nil (and not TestMode) turns sign-in off: every
	// route answers 503 customers_unconfigured.
	Sender CustomerOTPSender
	// TestMode texts nothing and answers the code in the response
	// (test_code). For development only; the relay warns at startup.
	TestMode bool
	// TrustForwardedFor takes the caller's address from the load balancer's
	// last X-Forwarded-For hop.
	TrustForwardedFor bool
	CodeTTL           time.Duration
	ResendAfter       time.Duration
	// DailyCodesPerPhone caps the codes one number gets per Libyan day.
	DailyCodesPerPhone int
	// MaxAttempts is how many wrong guesses one code takes.
	MaxAttempts int
	AccessTTL   time.Duration
	// SessionTTL is how long a device stays signed in without opening the
	// app; each refresh renews it.
	SessionTTL time.Duration
	// OTPRateLimit and VerifyRateLimit are per caller address.
	OTPRateLimit    ratelimit.Policy
	VerifyRateLimit ratelimit.Policy
	// ReviewPhone signs in with ReviewCode and is never texted: the app store
	// reviewers' account, since they cannot receive a Libyan SMS.
	ReviewPhone string
	ReviewCode  string
	// ChannelCategories is what each app build may sell (see
	// ParseCustomerChannelCategories); nil keeps the defaults.
	ChannelCategories map[string][]string
	// OrderRateLimit is orders one customer may place.
	OrderRateLimit ratelimit.Policy
	// OrderTTL is how long an order waits for its payment.
	OrderTTL time.Duration
	// WebOrigins are the origins the card app's web build is served from
	// ("https://cards.dftr.ly"). A browser on one of them may call the
	// customer routes; no other origin is answered with CORS headers.
	WebOrigins []string
}

// allowsWebOrigin reports whether origin is one of WebOrigins.
func (c CustomerConfig) allowsWebOrigin(origin string) bool {
	for _, allowed := range c.WebOrigins {
		if strings.EqualFold(strings.TrimRight(allowed, "/"), origin) {
			return true
		}
	}
	return false
}

// customerCORS answers a browser on an allowed origin: the headers on every
// answer, and the preflight itself. The app authenticates with a Bearer
// token, never a cookie, so no credentials are allowed. True when the
// request was a preflight and is answered.
func (s HTTPServer) customerCORS(w http.ResponseWriter, r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" || !s.Customers.allowsWebOrigin(origin) {
		return false
	}
	header := w.Header()
	header.Set("Access-Control-Allow-Origin", origin)
	header.Add("Vary", "Origin")
	header.Set("Access-Control-Expose-Headers", "ETag, Retry-After")
	if r.Method != http.MethodOptions {
		return false
	}
	header.Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
	header.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, If-None-Match")
	header.Set("Access-Control-Max-Age", "600")
	w.WriteHeader(http.StatusNoContent)
	return true
}

func (c CustomerConfig) enabled() bool { return c.Sender != nil || c.TestMode }

func (c CustomerConfig) codeTTL() time.Duration {
	if c.CodeTTL > 0 {
		return c.CodeTTL
	}
	return 5 * time.Minute
}

func (c CustomerConfig) resendAfter() time.Duration {
	if c.ResendAfter > 0 {
		return c.ResendAfter
	}
	return 30 * time.Second
}

func (c CustomerConfig) dailyCodes() int {
	if c.DailyCodesPerPhone > 0 {
		return c.DailyCodesPerPhone
	}
	return 6
}

func (c CustomerConfig) maxAttempts() int {
	if c.MaxAttempts > 0 {
		return c.MaxAttempts
	}
	return 5
}

func (c CustomerConfig) accessTTL() time.Duration {
	if c.AccessTTL > 0 {
		return c.AccessTTL
	}
	return time.Hour
}

func (c CustomerConfig) sessionTTL() time.Duration {
	if c.SessionTTL > 0 {
		return c.SessionTTL
	}
	return 90 * 24 * time.Hour
}

// isReviewPhone reports whether phone is the configured review account.
func (c CustomerConfig) isReviewPhone(phone string) bool {
	if c.ReviewCode == "" {
		return false
	}
	review, ok := resala.NormalizeLibyanMobile(c.ReviewPhone)
	return ok && review == phone
}

// ResalaCustomerOTPSender texts codes with an approved Resala template. The
// template's $1 is the code; $2, when AndroidAppHash is set, is the app's SMS
// Retriever hash, so Android reads the code without the SMS permission. The
// iOS autofill line ("@<domain> #$1") is literal text in the template.
type ResalaCustomerOTPSender struct {
	Client         *resala.Client
	TemplateID     string
	AndroidAppHash string
	Test           bool
}

func (r ResalaCustomerOTPSender) SendCustomerOTP(ctx context.Context, phone, code string) error {
	values := []string{code}
	if hash := strings.TrimSpace(r.AndroidAppHash); hash != "" {
		values = append(values, hash)
	}
	result, err := r.Client.SendTemplate(ctx, r.TemplateID, []resala.Record{{Phone: phone, Values: values}}, r.Test)
	if err != nil {
		return err
	}
	if result.Failed > 0 && result.Succeeded == 0 {
		return errors.New("resala refused the number")
	}
	return nil
}

func (s HTTPServer) handleCustomerRoutes(w http.ResponseWriter, r *http.Request) {
	if !s.RouteMode.allowsPublic() {
		writeNotFound(w)
		return
	}
	if s.customerCORS(w, r) {
		return
	}
	store, ok := s.Store.(control.CustomerStore)
	if !ok {
		writeCustomerError(w, http.StatusServiceUnavailable, "customers_unconfigured", "this relay keeps no customers", nil)
		return
	}
	path := strings.TrimSuffix(r.URL.Path, "/")
	// Only a new sign-in needs the SMS sender. Everything else — the shelf,
	// signed-in customers, their orders and Dafa's webhook — keeps working
	// when codes cannot be texted, so a paid order is never stranded by an
	// SMS outage or a removed template.
	if (path == "/v1/customers/auth/otp" || path == "/v1/customers/auth/verify") && !s.Customers.enabled() {
		writeCustomerError(w, http.StatusServiceUnavailable, "customers_unconfigured", "customer sign-in is not configured", nil)
		return
	}
	switch {
	case path == "/v1/customers/catalog" && r.Method == http.MethodGet:
		s.handleCustomerCatalog(w, r)
	case strings.HasPrefix(path, "/v1/customers/images/") && r.Method == http.MethodGet:
		s.handleCustomerImage(w, r, strings.TrimPrefix(path, "/v1/customers/images/"))
	case path == "/v1/customers/payment-methods" && r.Method == http.MethodGet:
		s.handleCustomerPaymentMethods(w, r)
	case strings.HasPrefix(path, customerWebhookPrefix) && r.Method == http.MethodPost:
		s.handleCustomerDafaWebhook(w, r, strings.TrimPrefix(path, customerWebhookPrefix))
	case path == customerCardReturnPath && (r.Method == http.MethodGet || r.Method == http.MethodPost):
		handleCustomerCardReturn(w, r)
	case path == "/v1/customers/orders" && r.Method == http.MethodPost:
		s.withCustomer(w, r, store, func(customer control.Customer, _ control.CustomerSession) {
			s.handleCustomerOrderCreate(w, r, customer)
		})
	case path == "/v1/customers/orders" && r.Method == http.MethodGet:
		s.withCustomer(w, r, store, func(customer control.Customer, _ control.CustomerSession) {
			s.handleCustomerOrderList(w, r, customer)
		})
	case strings.HasPrefix(path, "/v1/customers/orders/"):
		s.routeCustomerOrder(w, r, store, strings.TrimPrefix(path, "/v1/customers/orders/"))
	case path == "/v1/customers/credit" && r.Method == http.MethodGet:
		s.withCustomer(w, r, store, func(customer control.Customer, _ control.CustomerSession) {
			s.handleCustomerCredit(w, r, customer)
		})
	case path == "/v1/customers/auth/otp" && r.Method == http.MethodPost:
		s.handleCustomerOTP(w, r, store)
	case path == "/v1/customers/auth/verify" && r.Method == http.MethodPost:
		s.handleCustomerVerify(w, r, store)
	case path == "/v1/customers/auth/refresh" && r.Method == http.MethodPost:
		s.handleCustomerRefresh(w, r, store)
	case path == "/v1/customers/auth/logout" && r.Method == http.MethodPost:
		s.withCustomer(w, r, store, func(customer control.Customer, session control.CustomerSession) {
			if _, err := store.DeleteCustomerSession(r.Context(), customer.ID, session.ID); err != nil {
				s.customerInternalError(w, "customer logout failed", err)
				return
			}
			w.WriteHeader(http.StatusNoContent)
		})
	case path == "/v1/customers/me" && r.Method == http.MethodGet:
		s.withCustomer(w, r, store, func(customer control.Customer, _ control.CustomerSession) {
			writeJSON(w, http.StatusOK, map[string]any{"customer": customerView(customer)})
		})
	case path == "/v1/customers/me" && r.Method == http.MethodDelete:
		s.withCustomer(w, r, store, func(customer control.Customer, _ control.CustomerSession) {
			if err := store.DeleteCustomer(r.Context(), customer.ID); err != nil {
				s.customerInternalError(w, "customer delete failed", err)
				return
			}
			s.logger().Info("customer deleted their account", "customer_id", customer.ID)
			w.WriteHeader(http.StatusNoContent)
		})
	case path == "/v1/customers/me/sessions" && r.Method == http.MethodGet:
		s.withCustomer(w, r, store, func(customer control.Customer, current control.CustomerSession) {
			sessions, err := store.CustomerSessions(r.Context(), customer.ID)
			if err != nil {
				s.customerInternalError(w, "customer sessions failed", err)
				return
			}
			views := make([]map[string]any, 0, len(sessions))
			for _, session := range sessions {
				views = append(views, customerSessionView(session, session.ID == current.ID))
			}
			writeJSON(w, http.StatusOK, map[string]any{"sessions": views})
		})
	case path == "/v1/customers/me/sessions" && r.Method == http.MethodDelete:
		s.withCustomer(w, r, store, func(customer control.Customer, current control.CustomerSession) {
			sessions, err := store.CustomerSessions(r.Context(), customer.ID)
			if err != nil {
				s.customerInternalError(w, "customer sessions failed", err)
				return
			}
			ended := 0
			for _, session := range sessions {
				if session.ID == current.ID {
					continue
				}
				deleted, err := store.DeleteCustomerSession(r.Context(), customer.ID, session.ID)
				if err != nil {
					s.customerInternalError(w, "customer sign-out failed", err)
					return
				}
				if deleted {
					ended++
				}
			}
			writeJSON(w, http.StatusOK, map[string]any{"signed_out": ended})
		})
	case strings.HasPrefix(path, "/v1/customers/me/sessions/") && r.Method == http.MethodDelete:
		id := strings.TrimPrefix(path, "/v1/customers/me/sessions/")
		s.withCustomer(w, r, store, func(customer control.Customer, _ control.CustomerSession) {
			deleted, err := store.DeleteCustomerSession(r.Context(), customer.ID, id)
			if err != nil {
				s.customerInternalError(w, "customer sign-out failed", err)
				return
			}
			if !deleted {
				writeCustomerError(w, http.StatusNotFound, "session_not_found", "no such session", nil)
				return
			}
			w.WriteHeader(http.StatusNoContent)
		})
	default:
		writeNotFound(w)
	}
}

// routeCustomerOrder serves /v1/customers/orders/{id}[/confirm|/cancel|/card|/card/complete].
func (s HTTPServer) routeCustomerOrder(w http.ResponseWriter, r *http.Request, store control.CustomerStore, rest string) {
	id, action, _ := strings.Cut(rest, "/")
	if id == "" {
		writeNotFound(w)
		return
	}
	switch {
	case action == "" && r.Method == http.MethodGet:
		s.withCustomer(w, r, store, func(customer control.Customer, _ control.CustomerSession) {
			s.handleCustomerOrderRead(w, r, customer, id)
		})
	case action == "confirm" && r.Method == http.MethodPost:
		s.withCustomer(w, r, store, func(customer control.Customer, _ control.CustomerSession) {
			s.handleCustomerOrderConfirm(w, r, customer, id)
		})
	case action == "cancel" && r.Method == http.MethodPost:
		s.withCustomer(w, r, store, func(customer control.Customer, _ control.CustomerSession) {
			s.handleCustomerOrderCancel(w, r, customer, id)
		})
	case action == "card" && r.Method == http.MethodPost:
		s.withCustomer(w, r, store, func(customer control.Customer, _ control.CustomerSession) {
			s.handleCustomerOrderCard(w, r, customer, id)
		})
	case action == "card/complete" && r.Method == http.MethodPost:
		s.withCustomer(w, r, store, func(customer control.Customer, _ control.CustomerSession) {
			s.handleCustomerOrderCardComplete(w, r, customer, id)
		})
	default:
		writeNotFound(w)
	}
}

type customerOTPRequest struct {
	Phone string `json:"phone"`
}

func (s HTTPServer) handleCustomerOTP(w http.ResponseWriter, r *http.Request, store control.CustomerStore) {
	var request customerOTPRequest
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	phone, ok := resala.NormalizeLibyanMobile(request.Phone)
	if !ok {
		writeCustomerError(w, http.StatusBadRequest, "invalid_phone", "a Libyan mobile number is required", nil)
		return
	}
	if s.limitCustomer(w, r, "otp", s.Customers.OTPRateLimit) {
		return
	}
	review := s.Customers.isReviewPhone(phone)
	code := s.Customers.ReviewCode
	if !review {
		generated, err := newCustomerOTPCode()
		if err != nil {
			s.customerInternalError(w, "customer otp generation failed", err)
			return
		}
		code = generated
	}
	codeHash := control.CustomerOTPCodeHash(phone, code)
	daily := s.Customers.dailyCodes()
	if review {
		daily = 0
	}
	challenge, err := store.IssueCustomerOTP(r.Context(), control.CustomerOTPRequest{
		Phone:       phone,
		CodeHash:    codeHash,
		TTL:         s.Customers.codeTTL(),
		ResendAfter: s.Customers.resendAfter(),
		DailyLimit:  daily,
	})
	var refusal *control.CustomerOTPRefusal
	if errors.As(err, &refusal) {
		w.Header().Set("Retry-After", retryAfterSeconds(refusal.RetryAt, s.clock().Now()))
		writeCustomerError(w, http.StatusTooManyRequests, refusal.Reason, "wait before asking for another code",
			map[string]any{"retry_at": refusal.RetryAt})
		return
	}
	if err != nil {
		s.customerInternalError(w, "customer otp store failed", err)
		return
	}
	if !review && !s.Customers.TestMode {
		if err := s.Customers.Sender.SendCustomerOTP(r.Context(), phone, code); err != nil {
			// Nothing reached the phone (or we cannot tell): give the send
			// back so the customer may ask again at once.
			if cancelErr := store.CancelCustomerOTP(r.Context(), phone, codeHash); cancelErr != nil {
				s.logger().Error("customer otp cancel failed", "error", cancelErr)
			}
			s.logger().Warn("customer otp send failed", "phone", maskCustomerPhone(phone), "error", err)
			writeCustomerError(w, http.StatusBadGateway, "send_failed", "the code could not be sent", nil)
			return
		}
	}
	s.logger().Info("customer otp sent", "phone", maskCustomerPhone(phone), "sends_today", challenge.SendsToday, "review", review)
	body := map[string]any{
		"phone":        phone,
		"phone_masked": maskCustomerPhone(phone),
		"code_length":  customerOTPDigits,
		"expires_at":   challenge.ExpiresAt,
		"resend_at":    challenge.ResendAt,
	}
	if s.Customers.TestMode && !review {
		body["test_code"] = code
	}
	writeJSON(w, http.StatusOK, body)
}

type customerDevice struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Platform string `json:"platform"`
}

type customerVerifyRequest struct {
	Phone  string         `json:"phone"`
	Code   string         `json:"code"`
	Device customerDevice `json:"device"`
}

func (s HTTPServer) handleCustomerVerify(w http.ResponseWriter, r *http.Request, store control.CustomerStore) {
	var request customerVerifyRequest
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	phone, ok := resala.NormalizeLibyanMobile(request.Phone)
	if !ok {
		writeCustomerError(w, http.StatusBadRequest, "invalid_phone", "a Libyan mobile number is required", nil)
		return
	}
	code, ok := normalizeCustomerOTPCode(request.Code)
	if !ok {
		writeCustomerError(w, http.StatusBadRequest, "invalid_code", "the code is 6 digits", nil)
		return
	}
	if s.limitCustomer(w, r, "verify", s.Customers.VerifyRateLimit) {
		return
	}
	customer, created, err := store.VerifyCustomerOTP(
		r.Context(), phone, control.CustomerOTPCodeHash(phone, code), s.Customers.maxAttempts())
	var wrong *control.CustomerOTPWrong
	switch {
	case errors.As(err, &wrong):
		writeCustomerError(w, http.StatusBadRequest, "wrong_code", "the code is wrong",
			map[string]any{"attempts_left": wrong.AttemptsLeft})
		return
	case errors.Is(err, control.ErrCustomerOTPExpired):
		writeCustomerError(w, http.StatusBadRequest, "code_expired", "the code expired; ask for a new one", nil)
		return
	case errors.Is(err, control.ErrCustomerOTPLocked):
		writeCustomerError(w, http.StatusTooManyRequests, "too_many_attempts", "too many wrong codes; ask for a new one", nil)
		return
	case err != nil:
		s.customerInternalError(w, "customer otp verify failed", err)
		return
	}
	pair, err := s.newCustomerTokens()
	if err != nil {
		s.customerInternalError(w, "customer token generation failed", err)
		return
	}
	session, err := store.CreateCustomerSession(r.Context(), control.CustomerSession{
		CustomerID:      customer.ID,
		AccessHash:      control.TokenHash(pair.access),
		RefreshHash:     control.TokenHash(pair.refresh),
		DeviceID:        request.Device.ID,
		DeviceName:      request.Device.Name,
		Platform:        request.Device.Platform,
		AccessExpiresAt: pair.hashes.AccessExpiresAt,
		ExpiresAt:       pair.hashes.ExpiresAt,
	})
	if err != nil {
		s.customerInternalError(w, "customer session create failed", err)
		return
	}
	s.logger().Info("customer signed in", "customer_id", customer.ID, "created", created, "platform", session.Platform)
	body := customerTokensView(pair, session)
	body["customer"] = customerView(customer)
	body["created"] = created
	writeJSON(w, http.StatusOK, body)
}

type customerRefreshRequest struct {
	RefreshToken string `json:"refresh_token"`
}

func (s HTTPServer) handleCustomerRefresh(w http.ResponseWriter, r *http.Request, store control.CustomerStore) {
	var request customerRefreshRequest
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	raw := strings.TrimSpace(request.RefreshToken)
	if !strings.HasPrefix(raw, customerRefreshTokenPrefix+".") {
		writeCustomerError(w, http.StatusUnauthorized, "invalid_refresh", "sign in again", nil)
		return
	}
	pair, err := s.newCustomerTokens()
	if err != nil {
		s.customerInternalError(w, "customer token generation failed", err)
		return
	}
	session, err := store.RefreshCustomerSession(r.Context(), control.TokenHash(raw), control.CustomerTokens{
		AccessHash:      control.TokenHash(pair.access),
		RefreshHash:     control.TokenHash(pair.refresh),
		AccessExpiresAt: pair.hashes.AccessExpiresAt,
		ExpiresAt:       pair.hashes.ExpiresAt,
	})
	switch {
	case errors.Is(err, control.ErrCustomerRefreshReused):
		s.logger().Warn("customer refresh token reused; session ended")
		writeCustomerError(w, http.StatusUnauthorized, "invalid_refresh", "sign in again", nil)
		return
	case errors.Is(err, control.ErrCustomerSessionNotFound):
		writeCustomerError(w, http.StatusUnauthorized, "invalid_refresh", "sign in again", nil)
		return
	case err != nil:
		s.customerInternalError(w, "customer refresh failed", err)
		return
	}
	writeJSON(w, http.StatusOK, customerTokensView(pair, session))
}

// withCustomer authenticates the Bearer access token.
func (s HTTPServer) withCustomer(
	w http.ResponseWriter,
	r *http.Request,
	store control.CustomerStore,
	next func(control.Customer, control.CustomerSession),
) {
	raw, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	raw = strings.TrimSpace(raw)
	if !ok || !strings.HasPrefix(raw, customerAccessTokenPrefix+".") {
		writeCustomerError(w, http.StatusUnauthorized, "unauthorized", "sign in first", nil)
		return
	}
	customer, session, err := store.CustomerByAccessToken(r.Context(), control.TokenHash(raw))
	if errors.Is(err, control.ErrCustomerSessionNotFound) {
		// The app refreshes on this answer, and signs in again if that fails.
		writeCustomerError(w, http.StatusUnauthorized, "token_expired", "refresh the session", nil)
		return
	}
	if err != nil {
		s.customerInternalError(w, "customer authentication failed", err)
		return
	}
	next(customer, session)
}

// limitCustomer spends one request from the caller address's budget. It fails
// open: the per-phone caps in the store still hold every SMS back.
func (s HTTPServer) limitCustomer(w http.ResponseWriter, r *http.Request, bucket string, policy ratelimit.Policy) bool {
	if !policy.Enabled() || s.RateLimiter == nil {
		return false
	}
	decision, err := s.RateLimiter.Allow(r.Context(), "customer-"+bucket+":"+s.customerClientIP(r), policy)
	if err != nil {
		s.metrics().RecordRateLimitFailed()
		s.logger().Error("customer rate limiter failed; allowing", "bucket", bucket, "error", err)
		return false
	}
	if decision.Allowed {
		return false
	}
	s.metrics().RecordRateLimitRejected()
	w.Header().Set("Retry-After", retryAfterSeconds(decision.ResetAt, s.clock().Now()))
	writeCustomerError(w, http.StatusTooManyRequests, "rate_limited", "too many requests", map[string]any{"retry_at": decision.ResetAt})
	return true
}

// customerClientIP is the caller's address. A proxy is believed when the
// operator says so (the paas load balancer) or when the TCP peer is local
// (a self-hosted NGINX in front): otherwise every customer would share the
// proxy's address and one busy hour would rate-limit the whole country.
func (s HTTPServer) customerClientIP(r *http.Request) string {
	return clientaddr.Of(r, s.Customers.TrustForwardedFor || clientaddr.PeerIsLocal(r))
}

type customerTokenPair struct {
	access  string
	refresh string
	hashes  control.CustomerTokens
}

func (s HTTPServer) newCustomerTokens() (customerTokenPair, error) {
	access, err := newCustomerToken(customerAccessTokenPrefix)
	if err != nil {
		return customerTokenPair{}, err
	}
	refresh, err := newCustomerToken(customerRefreshTokenPrefix)
	if err != nil {
		return customerTokenPair{}, err
	}
	now := s.clock().Now().UTC()
	return customerTokenPair{
		access:  access,
		refresh: refresh,
		hashes: control.CustomerTokens{
			AccessExpiresAt: now.Add(s.Customers.accessTTL()),
			ExpiresAt:       now.Add(s.Customers.sessionTTL()),
		},
	}, nil
}

func newCustomerToken(prefix string) (string, error) {
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return "", err
	}
	return prefix + "." + base64.RawURLEncoding.EncodeToString(secret), nil
}

// newCustomerOTPCode is a uniformly random 6-digit code.
func newCustomerOTPCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

// normalizeCustomerOTPCode accepts the code as typed or pasted: Arabic-Indic
// digits, spaces and direction marks included (dafa.Digits, plus the isolate
// marks a copied Arabic SMS wraps numbers in).
func normalizeCustomerOTPCode(raw string) (string, bool) {
	code, ok := dafa.Digits(strings.NewReplacer("\u2066", "", "\u2067", "", "\u2068", "", "\u2069", "").Replace(raw))
	return code, ok && !strings.HasPrefix(code, "+") && len(code) == customerOTPDigits
}

// maskCustomerPhone is how a number appears in logs and answers: "091•••678",
// the wallet's own payer mask on the national number.
func maskCustomerPhone(phone string) string {
	if masked := maskWalletPayer(dafa.PayerPhone, strings.TrimPrefix(phone, "218")); masked != "" {
		return masked
	}
	return "•••"
}

func customerView(customer control.Customer) map[string]any {
	return map[string]any{
		"id":              customer.ID,
		"phone":           customer.Phone,
		"phone_masked":    maskCustomerPhone(customer.Phone),
		"created_at":      customer.CreatedAt,
		"last_sign_in_at": customer.LastSignInAt,
	}
}

func customerSessionView(session control.CustomerSession, current bool) map[string]any {
	return map[string]any{
		"id":           session.ID,
		"device_name":  session.DeviceName,
		"platform":     session.Platform,
		"created_at":   session.CreatedAt,
		"last_seen_at": session.LastSeenAt,
		"current":      current,
	}
}

func customerTokensView(pair customerTokenPair, session control.CustomerSession) map[string]any {
	return map[string]any{
		"access_token":       pair.access,
		"access_expires_at":  session.AccessExpiresAt,
		"refresh_token":      pair.refresh,
		"refresh_expires_at": session.ExpiresAt,
		"session_id":         session.ID,
	}
}

func decodeCustomerBody(w http.ResponseWriter, r *http.Request, into any) bool {
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxCustomerRequestBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(into); err != nil {
		writeCustomerError(w, http.StatusBadRequest, "invalid_request", "the request body is not valid JSON", nil)
		return false
	}
	return true
}

func writeCustomerError(w http.ResponseWriter, status int, code, message string, extra map[string]any) {
	body := map[string]any{"error": message, "code": code}
	for key, value := range extra {
		body[key] = value
	}
	writeJSON(w, status, body)
}

func (s HTTPServer) customerInternalError(w http.ResponseWriter, message string, err error) {
	s.logger().Error(message, "error", err)
	writeCustomerError(w, http.StatusInternalServerError, "internal_error", "relay store failed", nil)
}
