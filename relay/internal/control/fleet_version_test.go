package control

import "testing"

func TestMinimumFleetVersionTakesTheLowestReportedVersion(t *testing.T) {
	minimum, unknown := MinimumFleetVersion([]Installation{
		{CurrentVersion: "2.11.0"},
		{CurrentVersion: "2.9.4"},
		{CurrentVersion: "2.10.1"},
	})
	if minimum != "2.9.4" {
		t.Fatalf("minimum = %q, want 2.9.4", minimum)
	}
	if unknown != 0 {
		t.Fatalf("unknown = %d, want 0", unknown)
	}
}

func TestSegmentsCompareNumericallyNotAsText(t *testing.T) {
	// The whole reason this is not a string comparison: "2.9.4" sorts after
	// "2.10.1" as text, and a gate that believed that would ship a contract
	// release over the top of the one shop that is actually behind.
	if CompareVersions("2.9.4", "2.10.1") >= 0 {
		t.Fatal("2.9.4 must sort before 2.10.1")
	}
}

func TestAnInstallationThatHasNeverReportedIsUnknownNotCurrent(t *testing.T) {
	minimum, unknown := MinimumFleetVersion([]Installation{
		{CurrentVersion: "2.11.0"},
		{CurrentVersion: ""},
	})
	if minimum != "2.11.0" {
		t.Fatalf("minimum = %q, want 2.11.0", minimum)
	}
	if unknown != 1 {
		t.Fatalf("unknown = %d, want 1", unknown)
	}
	if FleetIsPast([]Installation{{CurrentVersion: "2.11.0"}, {}}, "2.0.0") {
		t.Fatal("a silent box must hold the gate shut")
	}
}

func TestTheGateOpensOnlyWhenEverybodyIsPastTheFloor(t *testing.T) {
	fleet := []Installation{
		{CurrentVersion: "2.11.0"},
		{CurrentVersion: "2.10.0"},
	}
	if !FleetIsPast(fleet, "2.10.0") {
		t.Fatal("equal to the floor is past it")
	}
	if FleetIsPast(fleet, "2.10.1") {
		t.Fatal("one installation behind holds it shut")
	}
}

func TestAnUnparseableVersionBehavesLikeAnOldOne(t *testing.T) {
	if CompareVersions("dev", "1.0.0") >= 0 {
		t.Fatal("an unparseable version must sort before a real one")
	}
	if FleetIsPast([]Installation{{CurrentVersion: "dev"}}, "1.0.0") {
		t.Fatal("the gate must refuse when it cannot tell")
	}
}
