//go:build race

package e2e

// raceEnabled: the race detector slows some code far more than other code,
// so throughput comparisons mean nothing under it.
const raceEnabled = true
