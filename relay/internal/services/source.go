package services

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"

	"pointy/relay/internal/reloadly"
)

// Raw is what the supplier says it sells, before the relay makes a directory of
// it: the countries it tops up, every operator it offers, every biller it pays.
type Raw struct {
	Countries []reloadly.TopupCountry
	Operators []reloadly.Operator
	Billers   []reloadly.Biller
}

// Source is where the directory's raw data comes from: Reloadly itself, or the
// fixture of test mode.
type Source interface {
	Load(ctx context.Context) (Raw, error)
}

//go:embed fixture/countries.json fixture/operators.json fixture/billers.json
var fixtureFiles embed.FS

// FixtureSource is a trimmed copy of Reloadly's own data (a few dozen countries,
// a few hundred operators and a few dozen billers, byte for byte as Reloadly
// writes them), so the shop's backend and the till can be developed without a
// Reloadly account. It goes through the very same normalization as the live data.
type FixtureSource struct{}

// Load implements Source.
func (FixtureSource) Load(context.Context) (Raw, error) {
	var raw Raw
	for name, target := range map[string]any{
		"fixture/countries.json": &raw.Countries,
		"fixture/operators.json": &raw.Operators,
		"fixture/billers.json":   &raw.Billers,
	} {
		data, err := fixtureFiles.ReadFile(name)
		if err != nil {
			return Raw{}, fmt.Errorf("services fixture %s: %w", name, err)
		}
		if err := json.Unmarshal(data, target); err != nil {
			return Raw{}, fmt.Errorf("services fixture %s: %w", name, err)
		}
	}
	return raw, nil
}
