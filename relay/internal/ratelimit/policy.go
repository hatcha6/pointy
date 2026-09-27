package ratelimit

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// ParsePolicy reads a human rate such as "60/minute", "5/second", "1000/hour",
// "20000/day" or "30/90s" (any Go duration after the slash). "", "0" and "off"
// disable the policy. It exists so a limit and its window travel as ONE setting:
// two separate env vars let an operator change the count and forget the window
// it is counted over.
func ParsePolicy(spec string) (Policy, error) {
	spec = strings.ToLower(strings.TrimSpace(spec))
	if spec == "" || spec == "0" || spec == "off" {
		return Policy{}, nil
	}
	rawLimit, rawWindow, ok := strings.Cut(spec, "/")
	if !ok {
		return Policy{}, fmt.Errorf("rate %q must look like 60/minute", spec)
	}
	limit, err := strconv.Atoi(strings.TrimSpace(rawLimit))
	if err != nil || limit < 0 {
		return Policy{}, fmt.Errorf("rate %q must start with a whole number", spec)
	}
	window, err := parseWindow(strings.TrimSpace(rawWindow))
	if err != nil {
		return Policy{}, fmt.Errorf("rate %q: %w", spec, err)
	}
	if limit == 0 {
		return Policy{}, nil
	}
	return Policy{Limit: limit, Window: window}, nil
}

func parseWindow(raw string) (time.Duration, error) {
	switch raw {
	case "s", "sec", "second", "seconds":
		return time.Second, nil
	case "m", "min", "minute", "minutes":
		return time.Minute, nil
	case "h", "hr", "hour", "hours":
		return time.Hour, nil
	case "d", "day", "days":
		return 24 * time.Hour, nil
	}
	window, err := time.ParseDuration(raw)
	if err != nil || window <= 0 {
		return 0, fmt.Errorf("window %q must be second, minute, hour, day or a positive duration", raw)
	}
	return window, nil
}

// String renders the policy the way ParsePolicy reads it ("60/minute"), or
// "off" when it is disabled.
func (p Policy) String() string {
	if !p.Enabled() {
		return "off"
	}
	unit := p.Window.String()
	switch p.Window {
	case time.Second:
		unit = "second"
	case time.Minute:
		unit = "minute"
	case time.Hour:
		unit = "hour"
	case 24 * time.Hour:
		unit = "day"
	}
	return strconv.Itoa(p.Limit) + "/" + unit
}
