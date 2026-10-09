package services

import (
	"sort"
	"strings"
	"sync"
)

// Everything a cashier or a customer reads is Arabic (owner, 2026-10-08), but
// Reloadly spells operators, billers and plans in English and French. The
// relay's own tables (names_ar.go) give the Arabic; a Namer is how the directory
// reaches them, so a test can supply its own names.
type Namer interface {
	// Operator is the Arabic name of an airtime operator.
	Operator(name, countryISO, countryNameEN string) (string, bool)
	// Biller is the Arabic name of a bill provider.
	Biller(name, countryISO string) (string, bool)
	// Plan is the Arabic text of a fixed bill plan.
	Plan(description string) (string, bool)
}

// TableNamer names from the relay's embedded tables.
type TableNamer struct{}

func (TableNamer) Operator(name, countryISO, countryNameEN string) (string, bool) {
	return OperatorNameAR(name, countryISO, countryNameEN)
}

func (TableNamer) Biller(name, countryISO string) (string, bool) {
	return BillerNameAR(name, countryISO)
}

func (TableNamer) Plan(description string) (string, bool) {
	return PlanDescriptionAR(description)
}

// MissingName is a name the tables do not have: the directory shows Reloadly's
// Latin spelling for it until somebody adds the Arabic one.
type MissingName struct {
	// Kind is operator, biller or plan (a country with no Arabic name is not
	// shown in Latin: it is left out of the directory, see DroppedCountry).
	Kind string `json:"kind"`
	Name string `json:"name"`
	// Country is the ISO code the name belongs to; empty for a plan.
	Country string `json:"country,omitempty"`
}

// missingTracker collects the names a directory build could not translate.
type missingTracker struct {
	mu   sync.Mutex
	seen map[MissingName]bool
}

func (m *missingTracker) add(kind, name, country string) {
	name = strings.TrimSpace(name)
	if name == "" {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.seen == nil {
		m.seen = map[MissingName]bool{}
	}
	m.seen[MissingName{Kind: kind, Name: name, Country: country}] = true
}

func (m *missingTracker) list() []MissingName {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]MissingName, 0, len(m.seen))
	for name := range m.seen {
		out = append(out, name)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Kind != out[j].Kind {
			return out[i].Kind < out[j].Kind
		}
		if out[i].Country != out[j].Country {
			return out[i].Country < out[j].Country
		}
		return out[i].Name < out[j].Name
	})
	return out
}
