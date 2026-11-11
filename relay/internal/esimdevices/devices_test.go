package esimdevices

import "testing"

func TestLookup(t *testing.T) {
	cases := []struct {
		model     string
		known     bool
		supported bool
		name      string
	}{
		// The codes phones report.
		{"iPhone17,1", true, true, "iPhone 16 Pro"},
		{"iPhone11,8", true, true, "iPhone XR"},
		{"iPhone10,3", true, false, "iPhone X"},
		{"iPhone99,1", true, true, "iPhone"}, // newer than the list
		{"iPad13,17", true, true, "iPad Air 5th Gen (Wi-Fi + Cellular)"},
		{"iPad13,16", true, false, "iPad Air 5th Gen (Wi-Fi)"},
		{"iPad99,1", false, false, ""},
		{"SM-S918B", true, true, "Galaxy S23 Ultra"},
		{"sm-s918b", true, true, "Galaxy S23 Ultra"},
		{"SM-S9180", true, false, "Galaxy S23 Ultra"}, // mainland China, Hong Kong
		{"SM-G781B", true, false, "Galaxy S20 FE"},
		{"Pixel 8 Pro", true, true, "Pixel 8 Pro"},
		{"23078PND5G", true, true, "Xiaomi 13T Pro"},
		{"CPH2305", true, true, "Find X5 Pro"},
		{"ELS-NX9", true, true, "P40 Pro"},
		// The names they are sold under.
		{"iPhone 16 Pro", true, true, "iPhone 16 Pro"},
		{"Samsung Galaxy S23 Ultra 5G", true, true, "Galaxy S23 Ultra"},
		{"galaxy s20 fe", true, false, "Galaxy S20 FE"},
		{"OnePlus Open", true, true, "Open"},
		// No verdict.
		{"Open", false, false, ""}, // too short to be anyone's alone
		{"Nokia 3310", false, false, ""},
		{"SM-A155F", false, false, ""},
		{"", false, false, ""},
	}
	for _, c := range cases {
		device, ok := Lookup(c.model)
		if ok != c.known || device.Supported != c.supported || device.Name != c.name {
			t.Errorf("Lookup(%q) = %+v, %v; want %q supported=%v known=%v", c.model, device, ok, c.name, c.supported, c.known)
		}
	}
}

func TestTheListIsNotEmpty(t *testing.T) {
	if models, names := Count(); models < 1000 || names < 300 {
		t.Fatalf("the list shrank: %d model codes, %d names", models, names)
	}
}
