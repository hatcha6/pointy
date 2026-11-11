// Package esimdevices is the relay's own list of phones and tablets that take
// eSIMs, asked before Airalo's.
//
// Airalo's list knows a model by the name it is sold under and by few of the
// codes a phone actually reports: "iPhone17,1" (an iPhone 16 Pro) and most
// Android model codes are "not in the list" there. This list is keyed by those
// codes: Apple's hardware identifiers, and android.os.Build.MODEL as Google
// Play's device catalogue gives it for every model a seller's list names.
//
// devices.tsv is generated: see gen/generate.py and the lists beside it.
package esimdevices

import (
	"bufio"
	_ "embed"
	"regexp"
	"strconv"
	"strings"
)

// Device is what the list says of one model.
type Device struct {
	Brand string
	Name  string
	// Supported is whether the model takes eSIMs. False is a verdict too: an
	// iPhone 8, a Wi-Fi iPad, a Galaxy sold in mainland China.
	Supported bool
}

//go:embed devices.tsv
var table string

var (
	byModel = map[string]Device{}
	byName  = map[string]Device{}
)

// A sold-under name shorter than this is only matched with its brand: "X5" and
// "V30" are other makers' model codes too.
const shortestBareName = 6

func init() {
	scanner := bufio.NewScanner(strings.NewReader(table))
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) != 5 {
			panic("esimdevices: malformed line: " + line)
		}
		device := Device{Brand: fields[2], Name: fields[3], Supported: fields[4] == "1"}
		switch fields[0] {
		case "model":
			byModel[squash(fields[1])] = device
		case "name":
			bare, brand := nameKey(fields[1]), squash(fields[2])
			if len(bare) >= shortestBareName || strings.HasPrefix(bare, brand) {
				byName[bare] = device
			}
			if !strings.HasPrefix(bare, brand) {
				byName[brand+bare] = device
			}
		default:
			panic("esimdevices: unknown kind: " + line)
		}
	}
}

// Count is how many model codes and names the list holds.
func Count() (models, names int) { return len(byModel), len(byName) }

var iphoneModel = regexp.MustCompile(`^iPhone(\d+),\d+$`)

// Lookup answers for a model: the code a phone reports ("iPhone17,1",
// "SM-S918B", "Pixel 8 Pro") or the name it is sold under ("Galaxy S23 Ultra").
// ok is false when the list does not know it, which is no verdict.
func Lookup(model string) (device Device, ok bool) {
	model = strings.TrimSpace(model)
	if device, ok = byModel[squash(model)]; ok {
		return device, true
	}
	// An iPhone newer than the list: every one from the XS and XR
	// ("iPhone11,x") on takes eSIMs, and none before them does.
	if match := iphoneModel.FindStringSubmatch(model); match != nil {
		if generation, err := strconv.Atoi(match[1]); err == nil {
			return Device{Brand: "Apple", Name: "iPhone", Supported: generation >= 11}, true
		}
	}
	device, ok = byName[nameKey(model)]
	return device, ok
}

// squash drops case and everything but letters, digits, "," and "+" (as
// "plus"): "SM-S918B/DS" and "sm s918b ds" are the same code.
func squash(text string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(text) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == ',':
			b.WriteRune(r)
		case r == '+':
			b.WriteString("plus")
		}
	}
	return b.String()
}

// nameKey is a sold-under name, loosely: a "5G" does not tell two models apart.
func nameKey(name string) string {
	return strings.ReplaceAll(squash(name), "5g", "")
}
