package reloadly

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math/big"
	"regexp"
	"strings"
	"time"
)

// Num is a decimal number exactly as Reloadly wrote it ("505.00000000000",
// "0.19785", "3.8E-5"). Reloadly sends every amount, rate and percentage as a
// JSON number, and a float64 would silently round the ones this relay turns
// into money, so a Num keeps the literal and hands out exact big.Rat values.
//
// A Num never fails to decode a JSON number or a numeric string: a purchase
// whose answer cannot be read is an unknown outcome, so bad data is kept as
// written and Rat reports it instead. An absent or null value is the empty Num.
type Num string

// numPattern is the JSON number grammar, which is also what a Num may hold
// when it is sent to Reloadly.
var numPattern = regexp.MustCompile(`^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$`)

// maxExponentDigits keeps a hostile "1e999999999" from reaching big.Rat.
const maxExponentDigits = 4

// ParseNum validates a decimal number and returns it as a Num. It accepts the
// JSON number grammar plus a leading "+" or "." that people type ("+5", ".5").
func ParseNum(text string) (Num, error) {
	text = strings.TrimSpace(text)
	switch {
	case strings.HasPrefix(text, "+"):
		text = text[1:]
	case strings.HasPrefix(text, "-."):
		text = "-0" + text[1:]
	case strings.HasPrefix(text, "."):
		text = "0" + text
	}
	if !numPattern.MatchString(text) {
		return "", fmt.Errorf("reloadly: %q is not a decimal number", text)
	}
	return Num(text), nil
}

// NumFromRat renders r as a plain decimal with at most places digits after the
// point, rounding half away from zero and dropping trailing zeros: 3.96040 is
// "3.9604" and 5 is "5". It is how an exact amount is put on the wire.
func NumFromRat(r *big.Rat, places int) Num {
	if r == nil {
		return ""
	}
	if places < 0 {
		places = 0
	}
	text := roundRat(r, places).FloatString(places)
	if strings.Contains(text, ".") {
		text = strings.TrimRight(text, "0")
		text = strings.TrimSuffix(text, ".")
	}
	if text == "-0" || text == "" {
		text = "0"
	}
	return Num(text)
}

// String is the literal as written.
func (n Num) String() string { return string(n) }

// Empty is whether the value was absent or null.
func (n Num) Empty() bool { return n == "" }

// Rat is the exact value. ok is false for an empty Num and for text that is not
// a decimal number.
func (n Num) Rat() (*big.Rat, bool) {
	text := string(n)
	if text == "" || !numPattern.MatchString(text) {
		return nil, false
	}
	if i := strings.IndexAny(text, "eE"); i >= 0 {
		exponent := strings.TrimLeft(text[i+1:], "+-")
		if len(exponent) > maxExponentDigits {
			return nil, false
		}
	}
	value, ok := new(big.Rat).SetString(text)
	if !ok {
		return nil, false
	}
	return value, true
}

// UnmarshalJSON keeps a number or numeric string as written.
func (n *Num) UnmarshalJSON(data []byte) error {
	data = bytes.TrimSpace(data)
	switch {
	case len(data) == 0 || bytes.Equal(data, []byte("null")):
		*n = ""
	case data[0] == '"':
		var text string
		if err := json.Unmarshal(data, &text); err != nil {
			return err
		}
		*n = Num(strings.TrimSpace(text))
	case data[0] == '-' || (data[0] >= '0' && data[0] <= '9'):
		*n = Num(data)
	default:
		return fmt.Errorf("reloadly: %s is not a number", truncate(string(data), 40))
	}
	return nil
}

// MarshalJSON writes the literal as a JSON number, or null when empty.
func (n Num) MarshalJSON() ([]byte, error) {
	if n == "" {
		return []byte("null"), nil
	}
	if !numPattern.MatchString(string(n)) {
		return nil, fmt.Errorf("reloadly: %q is not a decimal number", string(n))
	}
	return []byte(n), nil
}

// Text is a value Reloadly writes as a string in one answer and as a number in
// another (PIN serials and codes, phone numbers, tokens). It keeps the literal
// as written, so a number with leading digits that look odd is never reformatted.
type Text string

// String is the text as written.
func (t Text) String() string { return string(t) }

// UnmarshalJSON accepts a string, a number or null.
func (t *Text) UnmarshalJSON(data []byte) error {
	data = bytes.TrimSpace(data)
	switch {
	case len(data) == 0 || bytes.Equal(data, []byte("null")):
		*t = ""
	case data[0] == '"':
		var text string
		if err := json.Unmarshal(data, &text); err != nil {
			return err
		}
		*t = Text(text)
	case data[0] == '-' || (data[0] >= '0' && data[0] <= '9'):
		*t = Text(data)
	case bytes.Equal(data, []byte("true")), bytes.Equal(data, []byte("false")):
		*t = Text(data)
	default:
		return fmt.Errorf("reloadly: %s is not text", truncate(string(data), 40))
	}
	return nil
}

// MarshalJSON writes the text as a JSON string, or null when empty.
func (t Text) MarshalJSON() ([]byte, error) {
	if t == "" {
		return []byte("null"), nil
	}
	return json.Marshal(string(t))
}

// Labels is a JSON object of text values ({"0.99": "55 Diamonds"}). It reads a
// value of any other type as its JSON text, so one odd description never fails
// the decoding of a whole catalog page.
type Labels map[string]string

// UnmarshalJSON reads an object of strings, tolerating other value types.
func (l *Labels) UnmarshalJSON(data []byte) error {
	data = bytes.TrimSpace(data)
	if len(data) == 0 || bytes.Equal(data, []byte("null")) {
		*l = nil
		return nil
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	out := make(Labels, len(raw))
	for key, value := range raw {
		var text string
		if err := json.Unmarshal(value, &text); err == nil {
			out[key] = text
			continue
		}
		out[key] = strings.TrimSpace(string(value))
	}
	*l = out
	return nil
}

// Time is a Reloadly timestamp. Reloadly writes "2006-01-02 15:04:05" in UTC in
// the fields this package exposes (transaction dates, submittedAt, completedAt,
// the error timeStamp), and a Time reads that as UTC. A value that cannot be
// read leaves the Time zero rather than failing the answer around it: the
// timestamps are informational, the money fields are not.
type Time struct{ time.Time }

// timeLayouts are the forms Reloadly is known to write, most common first.
var timeLayouts = []string{
	"2006-01-02 15:04:05",
	"2006-01-02 15:04:05.999999999",
	time.RFC3339Nano,
	"2006-01-02T15:04:05.999999999",
	"2006-01-02T15:04:05.999999999Z0700",
}

// ParseTime reads one of Reloadly's timestamp forms. A form without a zone is
// UTC. ok is false for anything else.
func ParseTime(text string) (time.Time, bool) {
	text = strings.TrimSpace(text)
	if text == "" {
		return time.Time{}, false
	}
	for _, layout := range timeLayouts {
		if parsed, err := time.ParseInLocation(layout, text, time.UTC); err == nil {
			return parsed.UTC(), true
		}
	}
	return time.Time{}, false
}

// FormatTime writes an instant the way Reloadly's query filters and answers do:
// "2006-01-02 15:04:05" in UTC.
func FormatTime(at time.Time) string { return at.UTC().Format("2006-01-02 15:04:05") }

// UnmarshalJSON reads a timestamp string; null, empty and unreadable values
// leave the zero time.
func (t *Time) UnmarshalJSON(data []byte) error {
	t.Time = time.Time{}
	data = bytes.TrimSpace(data)
	if len(data) == 0 || data[0] != '"' {
		return nil
	}
	var text string
	if err := json.Unmarshal(data, &text); err != nil {
		return nil
	}
	if parsed, ok := ParseTime(text); ok {
		t.Time = parsed
	}
	return nil
}

// MarshalJSON writes the timestamp in Reloadly's form, or null when zero.
func (t Time) MarshalJSON() ([]byte, error) {
	if t.IsZero() {
		return []byte("null"), nil
	}
	return json.Marshal(FormatTime(t.Time))
}

func truncate(value string, limit int) string {
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	return string(runes[:limit]) + "…"
}
