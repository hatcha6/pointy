package vouchers

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"
)

// A brand whose cards are not codes but credit sent to an account: a game
// topped up by its player ID, Telegram Stars sent to a username, a Steam
// wallet topped up by its login, a Steam game sent as a gift to the account
// behind a friend invite link. Its Target says what the buyer types; the
// purchase carries what they typed (an Account) to the supplier, and succeeds
// with no code at all.

// Target kinds.
const (
	// TargetGameAccount is a game account by its player ID, with the server
	// or zone some games need.
	TargetGameAccount = "game_account"
	// TargetTelegram is a Telegram username.
	TargetTelegram = "telegram_username"
	// TargetSteam is a Steam login (the account name, not the profile name).
	TargetSteam = "steam_login"
	// TargetSteamInvite is a Steam friend invite link (https://s.team/p/…):
	// the supplier befriends the account and sends it the game as a gift.
	TargetSteamInvite = "steam_invite"
)

const (
	maxTargetFields      = 4
	maxTargetOptions     = 60
	maxTargetValueRunes  = 64
	maxTargetLabelRunes  = 60
	maxTargetHintRunes   = 300
	maxTargetCheckLength = 64
)

var (
	targetKeyPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,31}$`)
	// Telegram usernames are 5 to 32 letters, digits and underscores; a
	// leading @ is the buyer's habit and is dropped.
	telegramPattern = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]{3,31}$`)
	// Steam account names are letters, digits and underscores.
	steamLoginPattern = regexp.MustCompile(`^[A-Za-z0-9_]{2,64}$`)
	// A Steam quick invite link: the friend code ("gkcp-mvn") and the
	// invite's token ("CWQDTMJF"), the scheme optional.
	steamInvitePattern = regexp.MustCompile(`(?i)^(?:https?://)?s\.team/p/([a-z0-9]{2,16}(?:-[a-z0-9]{2,16})*)(?:/([a-z0-9]{2,32}))?/?$`)
)

// Target is what a brand's buyer types for the credit to be sent to.
type Target struct {
	Kind   string        `json:"kind"`
	Fields []TargetField `json:"fields"`
	// Check names the account check the supplier runs before an order (a
	// FazerCards game's validate-id category, "pubg_mobile"); empty when there
	// is none. A Steam login is always checkable; a Telegram username never.
	Check string `json:"check,omitempty"`
	// Hint tells the buyer where to find what they type, in Arabic.
	Hint string `json:"hint,omitempty"`
}

// TargetField is one thing the buyer types.
type TargetField struct {
	// Key is the supplier's own name for the field ("player_id", "zone_id").
	Key   string `json:"key"`
	Label string `json:"label"`
	// Type is "text" (the default) or "select", which takes one of Options.
	Type    string         `json:"type,omitempty"`
	Options []TargetOption `json:"options,omitempty"`
}

// TargetOption is one choice of a select field.
type TargetOption struct {
	Value string `json:"value"`
	Label string `json:"label"`
}

// Account is what the buyer typed, by field key: the whole of it, never masked.
type Account map[string]string

// Present reports whether there is anything in it.
func (a Account) Present() bool { return len(a) > 0 }

// validTargetKind reports whether kind is a Target kind.
func validTargetKind(kind string) bool {
	switch kind {
	case TargetGameAccount, TargetTelegram, TargetSteam, TargetSteamInvite:
		return true
	}
	return false
}

// validate reports what is wrong with a brand's target, path relative to it.
func (t Target) validate(add func(path, format string, args ...any), path string) {
	if !validTargetKind(t.Kind) {
		add(path+".kind", "must be %s, %s, %s or %s", TargetGameAccount, TargetTelegram, TargetSteam, TargetSteamInvite)
		return
	}
	switch {
	case len(t.Fields) == 0 || len(t.Fields) > maxTargetFields:
		add(path+".fields", "must list 1 to %d fields", maxTargetFields)
	case t.Kind != TargetGameAccount && len(t.Fields) != 1:
		add(path+".fields", "a %s target is one field", t.Kind)
	}
	seen := map[string]bool{}
	for i, field := range t.Fields {
		fieldPath := fmt.Sprintf("%s.fields[%d]", path, i)
		if !targetKeyPattern.MatchString(field.Key) {
			add(fieldPath+".key", "must be a lower-case name (letters, digits, _), at most 32 characters")
		} else if seen[field.Key] {
			add(fieldPath+".key", "%q is already a field", field.Key)
		}
		seen[field.Key] = true
		checkText(add, fieldPath+".label", field.Label, maxTargetLabelRunes, true)
		switch field.Type {
		case "", "text":
			if len(field.Options) > 0 {
				add(fieldPath+".options", "only a select field has options")
			}
		case "select":
			if len(field.Options) == 0 || len(field.Options) > maxTargetOptions {
				add(fieldPath+".options", "a select field lists 1 to %d options", maxTargetOptions)
			}
			values := map[string]bool{}
			for j, option := range field.Options {
				optionPath := fmt.Sprintf("%s.options[%d]", fieldPath, j)
				checkText(add, optionPath+".value", option.Value, maxTargetValueRunes, true)
				checkText(add, optionPath+".label", option.Label, maxTargetLabelRunes, true)
				if values[option.Value] {
					add(optionPath+".value", "%q is already an option", option.Value)
				}
				values[option.Value] = true
			}
		default:
			add(fieldPath+".type", `must be "text" or "select"`)
		}
	}
	if len(t.Check) > maxTargetCheckLength || strings.ContainsFunc(t.Check, unicode.IsSpace) {
		add(path+".check", "must be a supplier's check name, at most %d characters, no spaces", maxTargetCheckLength)
	}
	checkText(add, path+".hint", t.Hint, maxTargetHintRunes, false)
}

// normalized trims what the operator wrote.
func (t Target) normalized() Target {
	t.Kind = strings.TrimSpace(t.Kind)
	t.Check = strings.TrimSpace(t.Check)
	t.Hint = strings.TrimSpace(t.Hint)
	fields := make([]TargetField, len(t.Fields))
	for i, field := range t.Fields {
		field.Key = strings.TrimSpace(field.Key)
		field.Label = strings.TrimSpace(field.Label)
		field.Type = strings.ToLower(strings.TrimSpace(field.Type))
		if field.Type == "text" {
			field.Type = ""
		}
		options := make([]TargetOption, len(field.Options))
		for j, option := range field.Options {
			options[j] = TargetOption{Value: strings.TrimSpace(option.Value), Label: strings.TrimSpace(option.Label)}
		}
		if len(options) == 0 {
			options = nil
		}
		field.Options = options
		fields[i] = field
	}
	t.Fields = fields
	return t
}

// ErrAccountRequired is a purchase of a target brand's card without an account.
var ErrAccountRequired = errors.New("this card is sent to an account: the account is required")

// AccountProblem is what the buyer typed being wrong; Field names the field.
type AccountProblem struct {
	Field   string
	Message string
}

func (p *AccountProblem) Error() string {
	if p.Field == "" {
		return p.Message
	}
	return p.Field + ": " + p.Message
}

// ReadAccount checks what the buyer typed against the target and returns it
// cleaned: every field present (and no other), a select's value one of its
// options, a username or login in its own shape.
func (t Target) ReadAccount(values map[string]string) (Account, error) {
	if len(values) == 0 {
		return nil, ErrAccountRequired
	}
	known := map[string]bool{}
	account := Account{}
	for _, field := range t.Fields {
		known[field.Key] = true
		value := strings.TrimSpace(values[field.Key])
		if value == "" {
			return nil, &AccountProblem{Field: field.Key, Message: "is required"}
		}
		if utf8.RuneCountInString(value) > maxTargetValueRunes || strings.ContainsFunc(value, unicode.IsControl) {
			return nil, &AccountProblem{Field: field.Key, Message: fmt.Sprintf("must be at most %d characters, on one line", maxTargetValueRunes)}
		}
		if field.Type == "select" {
			found := false
			for _, option := range field.Options {
				if option.Value == value {
					found = true
					break
				}
			}
			if !found {
				return nil, &AccountProblem{Field: field.Key, Message: "is not one of the choices"}
			}
		}
		switch t.Kind {
		case TargetTelegram:
			value = strings.TrimPrefix(value, "@")
			if !telegramPattern.MatchString(value) {
				return nil, &AccountProblem{Field: field.Key, Message: "is not a Telegram username (5 to 32 letters, digits or _)"}
			}
		case TargetSteam:
			if !steamLoginPattern.MatchString(value) {
				return nil, &AccountProblem{Field: field.Key, Message: "is not a Steam login (letters, digits or _)"}
			}
		case TargetSteamInvite:
			link, ok := readSteamInvite(value)
			if !ok {
				return nil, &AccountProblem{Field: field.Key, Message: "is not a Steam friend invite link (https://s.team/p/…)"}
			}
			value = link
		case TargetGameAccount:
			if strings.ContainsFunc(value, unicode.IsSpace) {
				return nil, &AccountProblem{Field: field.Key, Message: "must not contain spaces"}
			}
		}
		account[field.Key] = value
	}
	for key := range values {
		if !known[key] && strings.TrimSpace(values[key]) != "" {
			return nil, &AccountProblem{Field: key, Message: "is not a field of this card"}
		}
	}
	return account, nil
}

// readSteamInvite is a friend invite link as the supplier takes it:
// https://s.team/p/<code>[/<token>], the code lower-case as Steam writes it
// and the token as typed.
func readSteamInvite(value string) (string, bool) {
	match := steamInvitePattern.FindStringSubmatch(value)
	if match == nil {
		return "", false
	}
	link := "https://s.team/p/" + strings.ToLower(match[1])
	if match[2] != "" {
		link += "/" + match[2]
	}
	return link, true
}

// Line is the account on one line, in the target's field order: what a slip
// prints ("5123456789 · 1001", "@name").
func (t Target) Line(account Account) string {
	parts := make([]string, 0, len(t.Fields))
	for _, field := range t.Fields {
		value := account[field.Key]
		if value == "" {
			continue
		}
		if t.Kind == TargetTelegram {
			value = "@" + value
		}
		parts = append(parts, value)
	}
	if len(parts) == 0 {
		// Not this target's fields: keep them all, in a stable order.
		keys := make([]string, 0, len(account))
		for key := range account {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			parts = append(parts, account[key])
		}
	}
	return strings.Join(parts, " · ")
}

// MaskAccount is the account as a purchase row keeps it: enough to recognise,
// not enough to reuse ("51•••••789", "@ab•••yz"). An invite link keeps only
// its friend code, masked ("s.team/p/gk••••vn"): the token is what lets
// anyone befriend the account.
func (t Target) MaskAccount(account Account) string {
	if t.Kind == TargetSteamInvite {
		if match := steamInvitePattern.FindStringSubmatch(t.Line(account)); match != nil {
			return "s.team/p/" + maskValue(strings.ToLower(match[1]))
		}
	}
	return maskLine(t.Line(account))
}

func maskLine(line string) string {
	parts := strings.Split(line, " · ")
	for i, part := range parts {
		parts[i] = maskValue(part)
	}
	return strings.Join(parts, " · ")
}

func maskValue(value string) string {
	runes := []rune(value)
	prefix := ""
	if len(runes) > 0 && runes[0] == '@' {
		prefix, runes = "@", runes[1:]
	}
	switch n := len(runes); {
	case n <= 2:
		return prefix + strings.Repeat("•", n)
	case n <= 5:
		return prefix + string(runes[:1]) + strings.Repeat("•", n-1)
	default:
		keep := 2
		if n >= 9 {
			keep = 3
		}
		return prefix + string(runes[:2]) + strings.Repeat("•", n-2-keep) + string(runes[n-keep:])
	}
}

// AccountCheck is what a supplier learned about an account before an order.
type AccountCheck struct {
	// Status is AccountValid, AccountInvalid, AccountUnconfirmed (the check
	// ran and could not tell) or AccountUnchecked (there is no check).
	Status string `json:"status"`
	// Name is the account's own name when the check gives it (a player's
	// nickname); Region its region when the game reports it.
	Name   string `json:"name,omitempty"`
	Region string `json:"region,omitempty"`
}

// AccountCheck statuses.
const (
	AccountValid       = "valid"
	AccountInvalid     = "invalid"
	AccountUnconfirmed = "unconfirmed"
	AccountUnchecked   = "unchecked"
)

// TargetBuyer is a supplier that sends credit to an account: a purchase of a
// target brand's card is placed with BuyFor, never Buy. A success carries no
// code. clientRef is the purchase's id, as for Buy.
type TargetBuyer interface {
	BuyFor(ctx context.Context, ref Ref, account Account, clientRef string) (Purchase, error)
}

// TargetChecker is a supplier that can look an account up before an order.
// check is the brand's Target.Check. It must never be a way to order anything.
type TargetChecker interface {
	CheckAccount(ctx context.Context, ref Ref, target Target, account Account) (AccountCheck, error)
}
