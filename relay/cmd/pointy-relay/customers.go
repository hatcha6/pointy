package main

import (
	"fmt"
	"net/url"
	"strings"
	"time"

	"pointy/relay/internal/ratelimit"
	relayserver "pointy/relay/internal/relay"
	"pointy/relay/internal/resala"
)

// customerSettings is the raw «دفتر كروت» sign-in configuration.
type customerSettings struct {
	// OTPTemplate is the approved Resala template the codes go out with.
	OTPTemplate    string
	AndroidAppHash string
	TestMode       bool
	CodeTTL        time.Duration
	ResendAfter    time.Duration
	DailyLimit     int
	MaxAttempts    int
	AccessTTL      time.Duration
	SessionTTL     time.Duration
	OTPRateLimit   string
	VerifyLimit    string
	ReviewPhone    string
	ReviewCode     string
	// ChannelCategories, OrderTTL and OrderRateLimit shape the orders.
	ChannelCategories string
	OrderTTL          time.Duration
	OrderRateLimit    string
	// WebOrigins is the comma-separated list of the web app's origins.
	WebOrigins string
	// SMS is the shops' Resala account, which the codes go out through.
	SMS relayserver.SMSConfig
}

// buildCustomerConfig validates the settings. A mistake is a startup error;
// a template with no Resala token only warns and leaves sign-in off.
func buildCustomerConfig(settings customerSettings) (relayserver.CustomerConfig, []string, error) {
	var warnings []string
	otpRate, err := ratelimit.ParsePolicy(settings.OTPRateLimit)
	if err != nil {
		return relayserver.CustomerConfig{}, nil, fmt.Errorf("POINTY_RELAY_CUSTOMER_OTP_RATE_LIMIT: %w", err)
	}
	orderRate, err := ratelimit.ParsePolicy(settings.OrderRateLimit)
	if err != nil {
		return relayserver.CustomerConfig{}, nil, fmt.Errorf("POINTY_RELAY_CUSTOMER_ORDER_RATE_LIMIT: %w", err)
	}
	channels, err := relayserver.ParseCustomerChannelCategories(settings.ChannelCategories)
	if err != nil {
		return relayserver.CustomerConfig{}, nil, fmt.Errorf("POINTY_RELAY_CUSTOMER_CHANNEL_CATEGORIES: %w", err)
	}
	verifyRate, err := ratelimit.ParsePolicy(settings.VerifyLimit)
	if err != nil {
		return relayserver.CustomerConfig{}, nil, fmt.Errorf("POINTY_RELAY_CUSTOMER_VERIFY_RATE_LIMIT: %w", err)
	}
	for name, value := range map[string]time.Duration{
		"POINTY_RELAY_CUSTOMER_OTP_TTL":          settings.CodeTTL,
		"POINTY_RELAY_CUSTOMER_OTP_RESEND_AFTER": settings.ResendAfter,
		"POINTY_RELAY_CUSTOMER_ACCESS_TTL":       settings.AccessTTL,
		"POINTY_RELAY_CUSTOMER_SESSION_TTL":      settings.SessionTTL,
		"POINTY_RELAY_CUSTOMER_ORDER_TTL":        settings.OrderTTL,
	} {
		if value < 0 {
			return relayserver.CustomerConfig{}, nil, fmt.Errorf("%s must be positive", name)
		}
	}
	if settings.DailyLimit < 0 || settings.MaxAttempts < 0 {
		return relayserver.CustomerConfig{}, nil, fmt.Errorf(
			"POINTY_RELAY_CUSTOMER_OTP_DAILY_LIMIT and POINTY_RELAY_CUSTOMER_OTP_MAX_ATTEMPTS must be positive")
	}
	hash := strings.TrimSpace(settings.AndroidAppHash)
	if hash != "" && len(hash) != 11 {
		return relayserver.CustomerConfig{}, nil, fmt.Errorf(
			"POINTY_RELAY_CUSTOMER_ANDROID_APP_HASH must be the 11-character SMS Retriever hash, got %d characters", len(hash))
	}
	reviewPhone := strings.TrimSpace(settings.ReviewPhone)
	reviewCode := strings.TrimSpace(settings.ReviewCode)
	if (reviewPhone == "") != (reviewCode == "") {
		return relayserver.CustomerConfig{}, nil, fmt.Errorf(
			"POINTY_RELAY_CUSTOMER_REVIEW_PHONE and POINTY_RELAY_CUSTOMER_REVIEW_CODE go together")
	}
	if reviewPhone != "" {
		if _, ok := resala.NormalizeLibyanMobile(reviewPhone); !ok {
			return relayserver.CustomerConfig{}, nil, fmt.Errorf("POINTY_RELAY_CUSTOMER_REVIEW_PHONE must be a Libyan mobile number")
		}
		if len(reviewCode) != 6 || strings.Trim(reviewCode, "0123456789") != "" {
			return relayserver.CustomerConfig{}, nil, fmt.Errorf("POINTY_RELAY_CUSTOMER_REVIEW_CODE must be 6 digits")
		}
	}
	config := relayserver.CustomerConfig{
		TestMode:           settings.TestMode,
		CodeTTL:            settings.CodeTTL,
		ResendAfter:        settings.ResendAfter,
		DailyCodesPerPhone: settings.DailyLimit,
		MaxAttempts:        settings.MaxAttempts,
		AccessTTL:          settings.AccessTTL,
		SessionTTL:         settings.SessionTTL,
		OTPRateLimit:       otpRate,
		VerifyRateLimit:    verifyRate,
		ReviewPhone:        reviewPhone,
		ReviewCode:         reviewCode,
		ChannelCategories:  channels,
		OrderTTL:           settings.OrderTTL,
		OrderRateLimit:     orderRate,
	}
	for _, origin := range strings.Split(settings.WebOrigins, ",") {
		origin = strings.TrimRight(strings.TrimSpace(origin), "/")
		if origin == "" {
			continue
		}
		if parsed, err := url.Parse(origin); err != nil || parsed.Scheme == "" || parsed.Host == "" || parsed.Path != "" {
			return relayserver.CustomerConfig{}, nil, fmt.Errorf(
				"POINTY_RELAY_CUSTOMER_WEB_ORIGINS: %q must be an origin such as https://cards.dftr.ly", origin)
		}
		config.WebOrigins = append(config.WebOrigins, origin)
	}
	template := strings.TrimSpace(settings.OTPTemplate)
	switch {
	case template == "":
	case strings.TrimSpace(settings.SMS.Token) == "":
		warnings = append(warnings, "a customer OTP template is set but POINTY_RELAY_RESALA_API_TOKEN is empty; customer sign-in stays off")
	default:
		timeout := settings.SMS.RequestTimeout
		if timeout <= 0 {
			timeout = 20 * time.Second
		}
		config.Sender = relayserver.ResalaCustomerOTPSender{
			Client: resala.New(resala.Config{
				BaseURL: settings.SMS.BaseURL,
				Token:   settings.SMS.Token,
				Timeout: timeout,
			}),
			TemplateID:     template,
			AndroidAppHash: hash,
			Test:           settings.SMS.TestMode,
		}
	}
	if config.TestMode {
		warnings = append(warnings, "customer OTP TEST MODE: no code is texted and every code is answered in the response; never run this in production")
	}
	return config, warnings, nil
}
