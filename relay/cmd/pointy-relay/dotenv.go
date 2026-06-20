package main

import (
	"bufio"
	"os"
	"strings"
)

// dotEnvPath returns the .env file to load. Defaults to ".env" in the working
// directory (which is the relay/ dir under `make relay-run` and a direct
// `go run ./cmd/pointy-relay`). Override with POINTY_RELAY_ENV_FILE.
func dotEnvPath() string {
	if path := strings.TrimSpace(os.Getenv("POINTY_RELAY_ENV_FILE")); path != "" {
		return path
	}
	return ".env"
}

// loadDotEnv loads KEY=VALUE pairs from a .env file into the process
// environment for local development. It only fills variables that are currently
// empty or unset, so real environment variables and Makefile-provided values
// always win. This mirrors the relay's envString semantics, which already treat
// an empty value as "use the default", so an empty value passed by the Makefile
// is transparently filled from .env. A missing file is ignored, so production
// deployments without a .env are unaffected.
func loadDotEnv(path string) {
	file, err := os.Open(path)
	if err != nil {
		return
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")

		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		if key == "" {
			continue
		}
		if strings.TrimSpace(os.Getenv(key)) != "" {
			continue
		}
		_ = os.Setenv(key, trimMatchingQuotes(strings.TrimSpace(value)))
	}
}

func trimMatchingQuotes(value string) string {
	if len(value) >= 2 {
		first := value[0]
		last := value[len(value)-1]
		if (first == '"' && last == '"') || (first == '\'' && last == '\'') {
			return value[1 : len(value)-1]
		}
	}
	return value
}
