package control

import (
	"context"
	"path/filepath"
	"testing"
	"time"
)

func TestAssignedUpdate(t *testing.T) {
	has := func(v string) bool { return v == "1.4.0" || v == "1.3.0" }
	inst := func(id, pinned string) Installation {
		return Installation{ID: id, UpdateChannel: "stable", PinnedVersion: pinned}
	}

	cases := []struct {
		name         string
		installation Installation
		target       ChannelTarget
		wantVersion  string
		wantApply    bool
	}{
		{
			name:         "rollout all applies",
			installation: inst("i1", ""),
			target:       ChannelTarget{TargetVersion: "1.4.0", RolloutPhase: RolloutAll},
			wantVersion:  "1.4.0",
			wantApply:    true,
		},
		{
			name:         "paused holds",
			installation: inst("i1", ""),
			target:       ChannelTarget{TargetVersion: "1.4.0", RolloutPhase: RolloutPaused},
			wantApply:    false,
		},
		{
			name:         "canary member applies",
			installation: inst("i1", ""),
			target:       ChannelTarget{TargetVersion: "1.4.0", RolloutPhase: RolloutCanary, CanaryIDs: []string{"i1"}},
			wantVersion:  "1.4.0",
			wantApply:    true,
		},
		{
			name:         "canary non-member holds",
			installation: inst("i2", ""),
			target:       ChannelTarget{TargetVersion: "1.4.0", RolloutPhase: RolloutCanary, CanaryIDs: []string{"i1"}},
			wantApply:    false,
		},
		{
			name:         "percent 100 applies",
			installation: inst("i1", ""),
			target:       ChannelTarget{TargetVersion: "1.4.0", RolloutPhase: RolloutPercent, RolloutPercent: 100},
			wantVersion:  "1.4.0",
			wantApply:    true,
		},
		{
			name:         "percent 0 holds",
			installation: inst("i1", ""),
			target:       ChannelTarget{TargetVersion: "1.4.0", RolloutPhase: RolloutPercent, RolloutPercent: 0},
			wantApply:    false,
		},
		{
			name:         "pin wins over paused channel",
			installation: inst("i1", "1.3.0"),
			target:       ChannelTarget{TargetVersion: "1.4.0", RolloutPhase: RolloutPaused},
			wantVersion:  "1.3.0",
			wantApply:    true,
		},
		{
			name:         "pin without artifact holds",
			installation: inst("i1", "9.9.9"),
			target:       ChannelTarget{TargetVersion: "1.4.0", RolloutPhase: RolloutAll},
			wantApply:    false,
		},
		{
			name:         "target without artifact holds",
			installation: inst("i1", ""),
			target:       ChannelTarget{TargetVersion: "9.9.9", RolloutPhase: RolloutAll},
			wantApply:    false,
		},
		{
			name:         "no target holds",
			installation: inst("i1", ""),
			target:       ChannelTarget{},
			wantApply:    false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			version, directive := AssignedUpdate(tc.installation, tc.target, has)
			wantDirective := "hold"
			if tc.wantApply {
				wantDirective = "apply"
			}
			if directive != wantDirective {
				t.Fatalf("directive = %q, want %q", directive, wantDirective)
			}
			if version != tc.wantVersion {
				t.Fatalf("version = %q, want %q", version, tc.wantVersion)
			}
		})
	}
}

func TestRolloutBucketIsDeterministicAndBounded(t *testing.T) {
	first := rolloutBucket("installation-123")
	if first != rolloutBucket("installation-123") {
		t.Fatal("bucket must be stable for the same id")
	}
	if first < 0 || first >= 100 {
		t.Fatalf("bucket %d out of range", first)
	}
}

func TestFileStoreUpdateStoreRoundTrip(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	path := filepath.Join(t.TempDir(), "installations.json")
	store, err := NewFileStore(path, fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()

	provisioned, err := store.ProvisionInstallation(ctx, ProvisionInstallationRequest{BusinessID: "b"})
	if err != nil {
		t.Fatal(err)
	}
	id := provisioned.Installation.ID
	if provisioned.Installation.UpdateChannel != "stable" || provisioned.Installation.UpdateStatus != "idle" {
		t.Fatalf("unexpected provision defaults: %+v", provisioned.Installation)
	}

	if inst, err := store.SetInstallationChannel(ctx, id, "beta"); err != nil || inst.UpdateChannel != "beta" {
		t.Fatalf("SetInstallationChannel = %+v, %v", inst, err)
	}
	if inst, err := store.PinInstallationVersion(ctx, id, "1.2.3"); err != nil || inst.PinnedVersion != "1.2.3" {
		t.Fatalf("PinInstallationVersion = %+v, %v", inst, err)
	}

	inst, err := store.ReportAgentStatus(ctx, id, AgentStatus{
		CurrentVersion: "1.2.3",
		AgentVersion:   "pointy-agent/1",
		UpdateStatus:   "succeeded",
	})
	if err != nil {
		t.Fatal(err)
	}
	if inst.CurrentVersion != "1.2.3" || inst.AgentVersion != "pointy-agent/1" || inst.UpdateStatus != "succeeded" {
		t.Fatalf("agent status not stored: %+v", inst)
	}
	if inst.LastUpdateAt == nil || inst.AgentLastSeenAt == nil {
		t.Fatal("expected LastUpdateAt and AgentLastSeenAt to be set on a terminal status")
	}

	if err := store.UpsertChannelTarget(ctx, ChannelTarget{
		Channel:       "stable",
		TargetVersion: "1.4.0",
		RolloutPhase:  RolloutAll,
	}); err != nil {
		t.Fatal(err)
	}
	target, ok, err := store.GetChannelTarget(ctx, "stable")
	if err != nil || !ok || target.TargetVersion != "1.4.0" || target.RolloutPhase != RolloutAll {
		t.Fatalf("GetChannelTarget = %+v, ok=%v, err=%v", target, ok, err)
	}

	// Survives a reload from disk.
	reloaded, err := NewFileStore(path, fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	again, ok, err := reloaded.GetChannelTarget(ctx, "stable")
	if err != nil || !ok || again.TargetVersion != "1.4.0" {
		t.Fatalf("channel target did not persist: %+v ok=%v err=%v", again, ok, err)
	}
	reloadedInst, err := reloaded.GetInstallation(ctx, id)
	if err != nil || reloadedInst.PinnedVersion != "1.2.3" || reloadedInst.CurrentVersion != "1.2.3" {
		t.Fatalf("installation update fields did not persist: %+v err=%v", reloadedInst, err)
	}
}
