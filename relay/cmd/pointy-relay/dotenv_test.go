package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadDotEnvFillsEmptyAndPreservesSet(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".env")
	content := `# a comment line

POINTY_RELAY_TEST_FILLED=from-dotenv
export POINTY_RELAY_TEST_EXPORTED=exported-value
POINTY_RELAY_TEST_QUOTED="quoted value"
POINTY_RELAY_TEST_URL=postgres://u:p@h:5432/db?sslmode=disable
POINTY_RELAY_TEST_PRESET=ignored
`
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}

	// A var already set to a non-empty value must be preserved.
	t.Setenv("POINTY_RELAY_TEST_PRESET", "kept")
	for _, key := range []string{
		"POINTY_RELAY_TEST_FILLED",
		"POINTY_RELAY_TEST_EXPORTED",
		"POINTY_RELAY_TEST_QUOTED",
		"POINTY_RELAY_TEST_URL",
	} {
		_ = os.Unsetenv(key)
		t.Cleanup(func() { _ = os.Unsetenv(key) })
	}

	loadDotEnv(path)

	cases := map[string]string{
		"POINTY_RELAY_TEST_FILLED":   "from-dotenv",
		"POINTY_RELAY_TEST_EXPORTED": "exported-value",
		"POINTY_RELAY_TEST_QUOTED":   "quoted value",
		"POINTY_RELAY_TEST_URL":      "postgres://u:p@h:5432/db?sslmode=disable",
		"POINTY_RELAY_TEST_PRESET":   "kept",
	}
	for key, want := range cases {
		if got := os.Getenv(key); got != want {
			t.Fatalf("%s = %q, want %q", key, got, want)
		}
	}
}

func TestLoadDotEnvMissingFileIsNoop(t *testing.T) {
	// Must not panic or error when the file is absent (production has no .env).
	loadDotEnv(filepath.Join(t.TempDir(), "does-not-exist.env"))
}
