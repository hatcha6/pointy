package control

import (
	"strconv"
	"strings"
)

// MinimumFleetVersion is the floor a contract migration has to clear.
//
// A schema change that *removes* something the previous release still writes
// cannot ship until every installation is past the release that stopped
// writing it — not most of them, and not the shop in front of you.
// `relay-remote-update` lets shops sit pinned, paused or on a canary, so the
// question "is anybody still on the old one" has a real answer and it is this
// one. Shipping a contract release while one pinned pharmacy is behind is how
// a shop loses its expiry tracking, and the rollout tooling exists precisely
// so that this is a query rather than a hope.
//
// Installations that have never reported a version are counted as **unknown**
// rather than as up to date. A box that has not phoned home is the one most
// likely to be running last year's build, and treating silence as consent is
// how the floor ends up measuring only the shops that were never the risk.
func MinimumFleetVersion(installations []Installation) (minimum string, unknown int) {
	for _, installation := range installations {
		current := strings.TrimSpace(installation.CurrentVersion)
		if current == "" {
			unknown++
			continue
		}
		if minimum == "" || CompareVersions(current, minimum) < 0 {
			minimum = current
		}
	}
	return minimum, unknown
}

// FleetIsPast reports whether every installation that has reported a version
// is at or beyond `floor`, and nothing is unknown.
func FleetIsPast(installations []Installation, floor string) bool {
	minimum, unknown := MinimumFleetVersion(installations)
	if unknown > 0 || minimum == "" {
		return false
	}
	return CompareVersions(minimum, floor) >= 0
}

// CompareVersions orders two dotted versions numerically, segment by segment.
//
// Deliberately not a full semver implementation: these are the shop build
// numbers this project ships ("1.4.0", "2.11.3"), and a pre-release suffix has
// never appeared in one. A segment that is not a number sorts *before* every
// number, which makes an unparseable version behave like an old one — the safe
// direction for a gate whose whole job is to refuse when it is unsure.
func CompareVersions(left, right string) int {
	leftParts := strings.Split(strings.TrimSpace(left), ".")
	rightParts := strings.Split(strings.TrimSpace(right), ".")
	length := len(leftParts)
	if len(rightParts) > length {
		length = len(rightParts)
	}
	for index := 0; index < length; index++ {
		leftValue, leftOK := segmentValue(leftParts, index)
		rightValue, rightOK := segmentValue(rightParts, index)
		if leftOK != rightOK {
			if !leftOK {
				return -1
			}
			return 1
		}
		if leftValue != rightValue {
			if leftValue < rightValue {
				return -1
			}
			return 1
		}
	}
	return 0
}

func segmentValue(parts []string, index int) (int, bool) {
	if index >= len(parts) {
		return 0, true
	}
	value, err := strconv.Atoi(strings.TrimSpace(parts[index]))
	if err != nil {
		return 0, false
	}
	return value, true
}
