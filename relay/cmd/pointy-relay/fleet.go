package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"text/tabwriter"
)

// runArtifacts manages the on-prem update bundles the relay serves to the fleet.
func runArtifacts(args []string) error {
	if len(args) == 0 {
		return usageError("missing artifacts command (upload)")
	}
	switch args[0] {
	case "upload":
		return runArtifactsUpload(args[1:])
	default:
		return usageError("unknown artifacts command %q", args[0])
	}
}

func runArtifactsUpload(args []string) error {
	flags := flag.NewFlagSet("artifacts upload", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	version := flags.String("version", "", "version this bundle is for, e.g. 1.4.0")
	bundle := flags.String("bundle", "", "path to the on-prem bundle zip to upload")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(*version) == "" {
		return usageError("--version is required")
	}
	if strings.TrimSpace(*bundle) == "" {
		return usageError("--bundle is required")
	}
	raw, err := admin.uploadFile(
		http.MethodPost,
		"/v1/artifacts/"+url.PathEscape(strings.TrimSpace(*version)),
		strings.TrimSpace(*bundle),
	)
	if err != nil {
		return err
	}
	fmt.Printf("Uploaded bundle for %s.\n\n", strings.TrimSpace(*version))
	return printRawJSON(raw)
}

// runFleet drives the remote-update control plane.
func runFleet(args []string) error {
	if len(args) == 0 {
		return usageError("missing fleet command (status, set-version, rollout, pause, pin, unpin, channel)")
	}
	switch args[0] {
	case "status":
		return runFleetStatus(args[1:])
	case "set-version":
		return runFleetSetVersion(args[1:])
	case "rollout":
		return runFleetRollout(args[1:])
	case "pause":
		return runFleetPause(args[1:])
	case "pin":
		return runFleetPin(args[1:])
	case "unpin":
		return runFleetUnpin(args[1:])
	case "channel":
		return runFleetChannel(args[1:])
	default:
		return usageError("unknown fleet command %q", args[0])
	}
}

type channelTargetRow struct {
	Channel        string `json:"channel"`
	TargetVersion  string `json:"target_version"`
	RolloutPhase   string `json:"rollout_phase"`
	RolloutPercent int    `json:"rollout_percent"`
}

type fleetInstallationRow struct {
	ID              string  `json:"id"`
	ShopName        string  `json:"shop_name"`
	Channel         string  `json:"channel"`
	CurrentVersion  string  `json:"current_version"`
	AssignedVersion string  `json:"assigned_version"`
	Directive       string  `json:"directive"`
	PinnedVersion   string  `json:"pinned_version"`
	UpdateStatus    string  `json:"update_status"`
	AgentLastSeenAt *string `json:"agent_last_seen_at"`
}

type fleetStatusResponse struct {
	Installations []fleetInstallationRow `json:"installations"`
	Channels      []channelTargetRow     `json:"channels"`
	Count         int                    `json:"count"`
}

func runFleetStatus(args []string) error {
	flags := flag.NewFlagSet("fleet status", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	query := flags.String("query", "", "case-insensitive substring over id, business id, and shop name")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	params := url.Values{}
	if q := strings.TrimSpace(*query); q != "" {
		params.Set("query", q)
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/fleet", params, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response fleetStatusResponse
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	return renderFleetStatus(response)
}

func renderFleetStatus(response fleetStatusResponse) error {
	if len(response.Channels) > 0 {
		fmt.Println("Channels:")
		writer := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
		fmt.Fprintln(writer, "  CHANNEL\tTARGET\tROLLOUT")
		for _, channel := range response.Channels {
			fmt.Fprintf(
				writer,
				"  %s\t%s\t%s\n",
				channel.Channel,
				dashIfEmpty(channel.TargetVersion),
				formatRollout(channel.RolloutPhase, channel.RolloutPercent),
			)
		}
		if err := writer.Flush(); err != nil {
			return err
		}
		fmt.Println()
	}

	if len(response.Installations) == 0 {
		fmt.Println("No installations found.")
		return nil
	}
	writer := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(writer, "ID\tSHOP\tCH\tCURRENT\tASSIGNED\tDIR\tSTATUS\tAGENT SEEN")
	for _, installation := range response.Installations {
		assigned := installation.AssignedVersion
		if installation.PinnedVersion != "" {
			assigned = installation.AssignedVersion + " (pinned)"
		}
		fmt.Fprintf(
			writer,
			"%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
			installation.ID,
			dashIfEmpty(installation.ShopName),
			dashIfEmpty(installation.Channel),
			dashIfEmpty(installation.CurrentVersion),
			dashIfEmpty(assigned),
			dashIfEmpty(installation.Directive),
			dashIfEmpty(installation.UpdateStatus),
			formatTimeField(installation.AgentLastSeenAt),
		)
	}
	if err := writer.Flush(); err != nil {
		return err
	}
	fmt.Printf("\n%d installation(s).\n", response.Count)
	return nil
}

func formatRollout(phase string, percent int) string {
	if phase == "percent" {
		return fmt.Sprintf("percent:%d%%", percent)
	}
	if phase == "" {
		return "paused"
	}
	return phase
}

func runFleetSetVersion(args []string) error {
	flags := flag.NewFlagSet("fleet set-version", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	channel := flags.String("channel", "stable", "update channel to target")
	rollout := flags.String("rollout", "canary", "rollout phase: all, paused, canary, or N%")
	canary := flags.String("canary", "", "comma-separated installation ids (with --rollout canary)")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	version, err := idAndFlags(args, flags)
	if err != nil {
		return err
	}
	phase, percent, canaryIDs, err := parseRollout(*rollout, *canary)
	if err != nil {
		return err
	}
	body := map[string]any{
		"target_version":  version,
		"rollout_phase":   phase,
		"rollout_percent": percent,
		"canary_ids":      canaryIDs,
	}
	return putChannelTarget(admin, strings.TrimSpace(*channel), body, *asJSON)
}

func runFleetRollout(args []string) error {
	flags := flag.NewFlagSet("fleet rollout", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	channel := flags.String("channel", "stable", "update channel to advance")
	canary := flags.String("canary", "", "comma-separated installation ids (with canary)")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	rolloutArg, err := idAndFlags(args, flags)
	if err != nil {
		return err
	}
	phase, percent, canaryIDs, err := parseRollout(rolloutArg, *canary)
	if err != nil {
		return err
	}
	version, err := currentChannelTargetVersion(admin, strings.TrimSpace(*channel))
	if err != nil {
		return err
	}
	if version == "" {
		return usageError("channel %q has no target version yet; use fleet set-version first", strings.TrimSpace(*channel))
	}
	body := map[string]any{
		"target_version":  version,
		"rollout_phase":   phase,
		"rollout_percent": percent,
		"canary_ids":      canaryIDs,
	}
	return putChannelTarget(admin, strings.TrimSpace(*channel), body, *asJSON)
}

func runFleetPause(args []string) error {
	flags := flag.NewFlagSet("fleet pause", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	channel := flags.String("channel", "stable", "update channel to pause (kill switch)")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	version, err := currentChannelTargetVersion(admin, strings.TrimSpace(*channel))
	if err != nil {
		return err
	}
	body := map[string]any{
		"target_version": version,
		"rollout_phase":  "paused",
	}
	return putChannelTarget(admin, strings.TrimSpace(*channel), body, *asJSON)
}

func runFleetPin(args []string) error {
	flags := flag.NewFlagSet("fleet pin", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	id, version, err := twoPositionals(args, flags, "installation id", "version")
	if err != nil {
		return err
	}
	return patchInstallationUpdate(admin, id, map[string]any{"pinned_version": version}, *asJSON)
}

func runFleetUnpin(args []string) error {
	flags := flag.NewFlagSet("fleet unpin", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	id, err := idAndFlags(args, flags)
	if err != nil {
		return err
	}
	return patchInstallationUpdate(admin, id, map[string]any{"pinned_version": ""}, *asJSON)
}

func runFleetChannel(args []string) error {
	flags := flag.NewFlagSet("fleet channel", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	id, channel, err := twoPositionals(args, flags, "installation id", "channel")
	if err != nil {
		return err
	}
	return patchInstallationUpdate(admin, id, map[string]any{"channel": channel}, *asJSON)
}

func putChannelTarget(admin *adminControlFlags, channel string, body map[string]any, asJSON bool) error {
	if channel == "" {
		return usageError("--channel must not be empty")
	}
	raw, err := admin.requestJSON(
		http.MethodPut,
		"/v1/fleet/channels/"+url.PathEscape(channel),
		nil,
		body,
	)
	if err != nil {
		return err
	}
	if asJSON {
		return printRawJSON(raw)
	}
	var target channelTargetRow
	if err := json.Unmarshal(raw, &target); err != nil {
		return err
	}
	fmt.Printf(
		"Channel %s → %s (%s).\n",
		target.Channel,
		dashIfEmpty(target.TargetVersion),
		formatRollout(target.RolloutPhase, target.RolloutPercent),
	)
	return nil
}

func patchInstallationUpdate(admin *adminControlFlags, id string, body map[string]any, asJSON bool) error {
	raw, err := admin.requestJSON(
		http.MethodPatch,
		"/v1/installations/"+url.PathEscape(id)+"/update",
		nil,
		body,
	)
	if err != nil {
		return err
	}
	if asJSON {
		return printRawJSON(raw)
	}
	fmt.Printf("Updated %s.\n", id)
	return printRawJSON(raw)
}

// currentChannelTargetVersion reads the channel's current target version so a
// rollout/pause change can keep the version while only moving the phase.
func currentChannelTargetVersion(admin *adminControlFlags, channel string) (string, error) {
	raw, err := admin.requestJSON(http.MethodGet, "/v1/fleet", nil, nil)
	if err != nil {
		return "", err
	}
	var response fleetStatusResponse
	if err := json.Unmarshal(raw, &response); err != nil {
		return "", err
	}
	want := channel
	if want == "" {
		want = "stable"
	}
	for _, target := range response.Channels {
		if target.Channel == want {
			return target.TargetVersion, nil
		}
	}
	return "", nil
}

func parseRollout(rollout, canary string) (phase string, percent int, canaryIDs []string, err error) {
	rollout = strings.TrimSpace(strings.ToLower(rollout))
	switch rollout {
	case "all":
		return "all", 0, nil, nil
	case "", "pause", "paused":
		return "paused", 0, nil, nil
	case "canary":
		ids := splitCSV(canary)
		if len(ids) == 0 {
			return "", 0, nil, usageError("--rollout canary requires --canary id1,id2")
		}
		return "canary", 0, ids, nil
	}
	n, convErr := strconv.Atoi(strings.TrimSuffix(rollout, "%"))
	if convErr != nil {
		return "", 0, nil, usageError("invalid rollout %q (use all, paused, canary, or N%%)", rollout)
	}
	if n < 0 || n > 100 {
		return "", 0, nil, usageError("rollout percent must be 0-100")
	}
	return "percent", n, nil, nil
}

func splitCSV(value string) []string {
	var out []string
	for _, part := range strings.Split(value, ",") {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

// twoPositionals reads two required positional arguments followed by flags, so a
// command reads as `... <a> <b> [flags]`.
func twoPositionals(args []string, flags *flag.FlagSet, aName, bName string) (string, string, error) {
	if len(args) < 1 || strings.HasPrefix(args[0], "-") {
		return "", "", usageError("missing %s as the first argument", aName)
	}
	if len(args) < 2 || strings.HasPrefix(args[1], "-") {
		return "", "", usageError("missing %s as the second argument", bName)
	}
	a := strings.TrimSpace(args[0])
	b := strings.TrimSpace(args[1])
	if a == "" || b == "" {
		return "", "", usageError("%s and %s must not be empty", aName, bName)
	}
	if err := flags.Parse(args[2:]); err != nil {
		return "", "", err
	}
	return a, b, nil
}

func (a *adminControlFlags) uploadFile(method, path, filePath string) (json.RawMessage, error) {
	if strings.TrimSpace(*a.adminToken) == "" {
		return nil, fmt.Errorf("admin token is required (set --admin-token or POINTY_RELAY_ADMIN_TOKEN)")
	}
	file, err := os.Open(filePath)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	endpoint, err := relayAdminEndpoint(*a.controlURL, path)
	if err != nil {
		return nil, err
	}
	client, err := newRelayAdminHTTPClient(relayAdminHTTPClientOptions{
		ControlURL:     *a.controlURL,
		AllowInsecure:  *a.allowInsecure,
		CAFile:         *a.caFile,
		ClientCertFile: *a.clientCertFile,
		ClientKeyFile:  *a.clientKeyFile,
		TLSServerName:  *a.tlsServerName,
	})
	if err != nil {
		return nil, err
	}
	request, err := http.NewRequest(method, endpoint.String(), file)
	if err != nil {
		return nil, err
	}
	request.ContentLength = info.Size()
	request.Header.Set("Content-Type", "application/zip")
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Authorization", "Bearer "+strings.TrimSpace(*a.adminToken))
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	payload, _ := io.ReadAll(io.LimitReader(response.Body, 4<<20))
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return nil, fmt.Errorf(
			"relay admin %s %s returned %d: %s",
			method, path, response.StatusCode, strings.TrimSpace(string(payload)),
		)
	}
	return json.RawMessage(payload), nil
}
