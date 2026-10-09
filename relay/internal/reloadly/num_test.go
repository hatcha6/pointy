package reloadly

import (
	"encoding/json"
	"math/big"
	"strings"
	"testing"
	"time"
)

func TestNumKeepsTheLiteralAndIsExact(t *testing.T) {
	var parsed struct {
		A Num   `json:"a"`
		B Num   `json:"b"`
		C Num   `json:"c"`
		D Num   `json:"d"`
		E Num   `json:"e"`
		F []Num `json:"f"`
	}
	raw := `{"a":505.00000000000,"b":"0.19785","c":null,"d":3.8E-5,"e":-0.1,"f":[1,2.50,"3"]}`
	if err := json.Unmarshal([]byte(raw), &parsed); err != nil {
		t.Fatal(err)
	}
	if parsed.A != "505.00000000000" || parsed.B != "0.19785" || !parsed.C.Empty() || parsed.D != "3.8E-5" || parsed.E != "-0.1" ||
		parsed.F[1] != "2.50" || parsed.F[2] != "3" {
		t.Fatalf("parsed = %+v", parsed)
	}
	for literal, want := range map[string]string{
		"505.00000000000": "505",
		"0.19785":         "3957/20000",
		"3.8E-5":          "19/500000",
		"-0.1":            "-1/10",
		"1e3":             "1000",
		"0":               "0",
	} {
		got, ok := Num(literal).Rat()
		if !ok || got.RatString() != want {
			t.Errorf("Rat(%q) = %v, %t, want %s", literal, got, ok, want)
		}
	}
	// 0.1 + 0.2 is exactly 0.3 in rationals, which is why money never touches a float.
	a, _ := Num("0.1").Rat()
	b, _ := Num("0.2").Rat()
	c, _ := Num("0.3").Rat()
	if new(big.Rat).Add(a, b).Cmp(c) != 0 {
		t.Fatal("0.1 + 0.2 != 0.3")
	}
}

func TestNumRefusesWhatIsNotANumber(t *testing.T) {
	for _, literal := range []string{"", "abc", "1/3", "0x10", "1e99999", "NaN", "Inf", " 1", "1.", ".5", "--1"} {
		if _, ok := Num(literal).Rat(); ok {
			t.Errorf("Rat(%q) must fail", literal)
		}
	}
	var n Num
	if err := json.Unmarshal([]byte(`{"x":1}`), &n); err == nil {
		t.Error("an object is not a number")
	}
	if err := json.Unmarshal([]byte(`true`), &n); err == nil {
		t.Error("a boolean is not a number")
	}
	// Bad text in a string is kept, not an error: an unreadable amount must not
	// turn a bought card into an unreadable answer.
	if err := json.Unmarshal([]byte(`"n/a"`), &n); err != nil || n != "n/a" {
		t.Errorf("n = %q, err = %v", n, err)
	}
	if _, ok := n.Rat(); ok {
		t.Error("n/a is not a number")
	}
}

func TestNumMarshals(t *testing.T) {
	out, err := json.Marshal(struct {
		A Num  `json:"a"`
		B Num  `json:"b,omitempty"`
		C Num  `json:"c"`
		D *Num `json:"d,omitempty"`
	}{A: "5.250", C: ""})
	if err != nil || string(out) != `{"a":5.250,"c":null}` {
		t.Fatalf("out = %s, err = %v", out, err)
	}
	if _, err := json.Marshal(Num("five")); err == nil {
		t.Fatal("a Num that is not a number must not be written")
	}
}

func TestParseNumAndNumFromRat(t *testing.T) {
	for in, want := range map[string]Num{"5": "5", " 5.50 ": "5.50", "+5": "5", ".5": "0.5", "-.5": "-0.5", "1e3": "1e3"} {
		if got, err := ParseNum(in); err != nil || got != want {
			t.Errorf("ParseNum(%q) = %q, %v", in, got, err)
		}
	}
	for _, bad := range []string{"", "a", "1,5", "1 2", "0x1"} {
		if _, err := ParseNum(bad); err == nil {
			t.Errorf("ParseNum(%q) must fail", bad)
		}
	}
	for _, test := range []struct {
		rat    string
		places int
		want   Num
	}{
		{"1/3", 5, "0.33333"},
		{"2/3", 5, "0.66667"},
		{"396039604/100000000", 5, "3.9604"},
		{"5", 2, "5"},
		{"1/2", 0, "1"},
		{"-1/2", 0, "-1"},
		{"-1/1000000", 2, "0"},
		{"1050/100", 1, "10.5"},
	} {
		r, _ := new(big.Rat).SetString(test.rat)
		if got := NumFromRat(r, test.places); got != test.want {
			t.Errorf("NumFromRat(%s, %d) = %q, want %q", test.rat, test.places, got, test.want)
		}
	}
	if NumFromRat(nil, 2) != "" {
		t.Error("nil is the empty Num")
	}
}

func TestRoundingIsHalfAwayFromZero(t *testing.T) {
	for _, test := range []struct{ in, want string }{
		{"0.000005", "0.00001"},
		{"0.000004999", "0.00000"},
		{"3.960396039604", "3.96040"},
		{"-0.000005", "-0.00001"},
		{"0.123455", "0.12346"},
		{"7", "7.00000"},
		{"0.987655", "0.98766"},
	} {
		r, _ := new(big.Rat).SetString(test.in)
		if got := RoundCost(r).FloatString(5); got != test.want {
			t.Errorf("RoundCost(%s) = %s, want %s", test.in, got, test.want)
		}
	}
}

func TestTextAcceptsStringsAndNumbers(t *testing.T) {
	var v struct {
		A Text `json:"a"`
		B Text `json:"b"`
		C Text `json:"c"`
		D Text `json:"d"`
	}
	if err := json.Unmarshal([]byte(`{"a":"x","b":773709732277102,"c":null,"d":true}`), &v); err != nil {
		t.Fatal(err)
	}
	if v.A != "x" || v.B != "773709732277102" || v.C != "" || v.D != "true" {
		t.Fatalf("v = %+v", v)
	}
	if err := json.Unmarshal([]byte(`{"a":{}}`), &v); err == nil {
		t.Fatal("an object is not text")
	}
	out, _ := json.Marshal(struct {
		A Text `json:"a"`
		B Text `json:"b"`
	}{A: "k"})
	if string(out) != `{"a":"k","b":null}` {
		t.Fatalf("out = %s", out)
	}
}

func TestTimeIsUTCAndLenient(t *testing.T) {
	var v struct {
		A Time `json:"a"`
		B Time `json:"b"`
		C Time `json:"c"`
		D Time `json:"d"`
		E Time `json:"e"`
		F Time `json:"f"`
	}
	raw := `{"a":"2026-10-08 01:45:35","b":"2026-10-08T01:45:35.693+00:00","c":"2026-10-08T03:45:35+02:00","d":null,"e":"garbage","f":12}`
	if err := json.Unmarshal([]byte(raw), &v); err != nil {
		t.Fatal(err)
	}
	want := time.Date(2026, 10, 8, 1, 45, 35, 0, time.UTC)
	if !v.A.Time.Equal(want) || v.A.Location() != time.UTC || !v.B.Time.Equal(want.Add(693*time.Millisecond)) || !v.C.Time.Equal(want) {
		t.Fatalf("v = %+v", v)
	}
	if !v.D.IsZero() || !v.E.IsZero() || !v.F.IsZero() {
		t.Fatal("null and unreadable timestamps must stay zero without failing the answer")
	}
	out, _ := json.Marshal(struct {
		A Time `json:"a"`
		B Time `json:"b"`
	}{A: v.A})
	if string(out) != `{"a":"2026-10-08 01:45:35","b":null}` {
		t.Fatalf("out = %s", out)
	}
	if FormatTime(time.Date(2026, 10, 8, 5, 0, 0, 0, time.FixedZone("x", 4*3600))) != "2026-10-08 01:00:00" {
		t.Fatal("FormatTime must write UTC")
	}
	if _, ok := ParseTime("2026-10-08"); ok {
		t.Fatal("a bare date is not a Reloadly timestamp")
	}
}

func TestLabelsToleratesOtherTypes(t *testing.T) {
	var labels Labels
	if err := json.Unmarshal([]byte(`{"a":"x","b":2,"c":null,"d":{"e":1}}`), &labels); err != nil {
		t.Fatal(err)
	}
	if labels["a"] != "x" || labels["b"] != "2" || labels["c"] != "" || !strings.Contains(labels["d"], `"e"`) {
		t.Fatalf("labels = %v", labels)
	}
	if err := json.Unmarshal([]byte(`null`), &labels); err != nil || labels != nil {
		t.Fatalf("null = %v, %v", labels, err)
	}
	if err := json.Unmarshal([]byte(`[1]`), &labels); err == nil {
		t.Fatal("an array is not a label map")
	}
}

func TestStatusIsNormalisedAndClassified(t *testing.T) {
	var v struct {
		S Status `json:"s"`
	}
	if err := json.Unmarshal([]byte(`{"s":" Successful "}`), &v); err != nil || v.S != StatusSuccessful {
		t.Fatalf("status = %q, %v", v.S, err)
	}
	for status, want := range map[Status][4]bool{
		// final, succeeded, unsuccessful, in progress
		StatusSuccessful: {true, true, false, false},
		StatusRefunded:   {true, false, true, false},
		StatusFailed:     {true, false, true, false},
		StatusProcessing: {false, false, false, true},
		StatusPending:    {false, false, false, true},
		Status(""):       {false, false, false, true},
		Status("NEW"):    {false, false, false, true},
	} {
		got := [4]bool{status.Final(), status.Succeeded(), status.Unsuccessful(), status.InProgress()}
		if got != want {
			t.Errorf("%q: final/succeeded/unsuccessful/inProgress = %v, want %v", status, got, want)
		}
	}
}

func TestPinDetailEmpty(t *testing.T) {
	if !(PinDetail{}).Empty() || (PinDetail{Code: "1"}).Empty() {
		t.Fatal("Empty")
	}
}
