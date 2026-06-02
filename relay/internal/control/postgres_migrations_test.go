package control

import "testing"

func TestPostgresMigrationsHaveUniqueIncreasingVersions(t *testing.T) {
	seen := map[int]bool{}
	lastVersion := 0
	for _, migration := range postgresMigrations {
		if migration.version <= lastVersion {
			t.Fatalf("migration version %d is not greater than %d", migration.version, lastVersion)
		}
		if seen[migration.version] {
			t.Fatalf("duplicate migration version %d", migration.version)
		}
		if migration.name == "" || migration.sql == "" {
			t.Fatalf("migration %d must include name and SQL", migration.version)
		}
		seen[migration.version] = true
		lastVersion = migration.version
	}
}
