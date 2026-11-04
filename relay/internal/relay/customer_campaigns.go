package relay

import (
	"context"
	"errors"
	"net/http"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/ratelimit"
)

// Where «دفتر كروت» customers come from (control.CustomerCampaignStore).
//
// The app's side:
//
//	GET  /v1/customers/campaigns/{code}       is a typed code a live campaign?
//	POST /v1/customers/campaigns/{code}/open  the installed app opened a campaign link {platform}
//	PUT  /v1/customers/me/attribution         {code, via, heard_from}
//
// and the same attribution may ride on /v1/customers/auth/verify, so a code
// the app was holding is never lost between sign-in and its next request.
//
// The console's (admin token):
//
//	GET   /v1/customers/admin/campaigns       every campaign with its results, and the answers
//	POST  /v1/customers/admin/campaigns       {code, name, display_name, kind, note, landing,
//	                                           reward, reward_limit, reward_until}
//	PATCH /v1/customers/admin/campaigns/{id}  the same but code and kind, and active

// campaignLookupRateLimit keeps a caller from guessing codes.
var campaignLookupRateLimit = ratelimit.Policy{Limit: 30, Window: time.Minute}

// customerAttributionRequest is what the app knows of where the customer came
// from. Every field is optional.
type customerAttributionRequest struct {
	Code      string `json:"code"`
	Via       string `json:"via"`
	HeardFrom string `json:"heard_from"`
}

func (s HTTPServer) customerCampaignStore(w http.ResponseWriter) (control.CustomerCampaignStore, bool) {
	store, ok := s.Store.(control.CustomerCampaignStore)
	if !ok {
		writeCustomerError(w, http.StatusServiceUnavailable, "customers_unconfigured", "this relay keeps no customers", nil)
	}
	return store, ok
}

// liveCampaign is the active campaign code names.
func liveCampaign(ctx context.Context, store control.CustomerCampaignStore, code string) (control.CustomerCampaign, bool, error) {
	campaign, err := store.CustomerCampaignByCode(ctx, code)
	if errors.Is(err, control.ErrCustomerCampaignNotFound) {
		return control.CustomerCampaign{}, false, nil
	}
	if err != nil {
		return control.CustomerCampaign{}, false, err
	}
	return campaign, campaign.Active, nil
}

// customerCampaignView is a campaign as the app sees it: never its notes or
// results. reward is what signing in with it gives now, "" for nothing.
func (s HTTPServer) customerCampaignView(campaign control.CustomerCampaign) map[string]any {
	view := map[string]any{
		"code": campaign.Code, "kind": campaign.Kind, "display_name": campaign.DisplayName,
		"landing": campaign.Landing, "reward": "",
	}
	if campaign.RewardDue(s.clock().Now()) {
		view["reward"] = campaign.Reward
	}
	return view
}

// handleCustomerCampaign answers whether a typed code is a live campaign;
// open counts the installed app opening its link.
func (s HTTPServer) handleCustomerCampaign(w http.ResponseWriter, r *http.Request, code string, open bool) {
	store, ok := s.customerCampaignStore(w)
	if !ok {
		return
	}
	if s.limitCustomer(w, r, "campaign", campaignLookupRateLimit) {
		return
	}
	campaign, live, err := liveCampaign(r.Context(), store, code)
	if err != nil {
		s.customerInternalError(w, "customer campaign read failed", err)
		return
	}
	if !live {
		writeCustomerError(w, http.StatusNotFound, "unknown_campaign", "no such code", nil)
		return
	}
	if open {
		if err := store.RecordCustomerCampaignClick(r.Context(), campaign.ID, "app"); err != nil {
			s.logger().Warn("campaign click not counted", "campaign", campaign.Code, "error", err)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"campaign": s.customerCampaignView(campaign)})
}

// attributeCustomer records what the app reported. A code that names no live
// campaign is dropped (code_accepted false) and the answer is still kept: the
// app must never be stuck re-sending something the relay will not take.
func (s HTTPServer) attributeCustomer(ctx context.Context, store control.CustomerCampaignStore, customerID string, request customerAttributionRequest) (control.CustomerAttributionResult, error) {
	result, err := store.AttributeCustomer(ctx, customerID, control.CustomerAttributionChange{
		CampaignCode: request.Code, CampaignVia: request.Via, HeardFrom: request.HeardFrom,
	})
	if err == nil && result.Reward != nil {
		s.logger().Info("campaign reward credited", "customer_id", customerID,
			"campaign", result.Reward.Code, "amount", result.Reward.Amount)
	}
	return result, err
}

func (s HTTPServer) handleCustomerAttribution(w http.ResponseWriter, r *http.Request, customer control.Customer) {
	store, ok := s.customerCampaignStore(w)
	if !ok {
		return
	}
	var request customerAttributionRequest
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	result, err := s.attributeCustomer(r.Context(), store, customer.ID, request)
	if err != nil {
		s.customerInternalError(w, "customer attribution failed", err)
		return
	}
	writeJSON(w, http.StatusOK, result)
}

// attributeSignedIn applies the attribution a sign-in carried. It never fails
// the sign-in: the app keeps what was not taken and sends it again.
func (s HTTPServer) attributeSignedIn(ctx context.Context, customerID string, request *customerAttributionRequest) *control.CustomerAttributionResult {
	if request == nil {
		return nil
	}
	store, ok := s.Store.(control.CustomerCampaignStore)
	if !ok {
		return nil
	}
	result, err := s.attributeCustomer(ctx, store, customerID, *request)
	if err != nil {
		s.logger().Warn("sign-in attribution not recorded", "customer_id", customerID, "error", err)
		return nil
	}
	return &result
}

// --- console -----------------------------------------------------------------

func (s HTTPServer) handleCustomerAdminCampaigns(w http.ResponseWriter, r *http.Request) {
	store, ok := s.customerCampaignStore(w)
	if !ok {
		return
	}
	report, err := store.CustomerCampaignReport(r.Context())
	if err != nil {
		s.customerInternalError(w, "customer campaign report failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"report": report})
}

// customerCampaignRequest is a campaign as the console writes it. A reward's
// end is a date or a time ("" on an update removes it).
type customerCampaignRequest struct {
	Code        string  `json:"code"`
	Name        *string `json:"name"`
	DisplayName *string `json:"display_name"`
	Kind        string  `json:"kind"`
	Note        *string `json:"note"`
	Landing     *string `json:"landing"`
	Active      *bool   `json:"active"`
	Reward      *string `json:"reward"`
	RewardLimit *int    `json:"reward_limit"`
	RewardUntil *string `json:"reward_until"`
	Actor       string  `json:"actor"`
}

// parseRewardUntil reads a reward's end: a date (its Libyan midnight, so the
// whole day still pays) or an RFC 3339 time.
func parseRewardUntil(raw string) (time.Time, bool) {
	if day, err := time.ParseInLocation(time.DateOnly, raw, libyanDay); err == nil {
		return day.AddDate(0, 0, 1).UTC(), true
	}
	at, err := time.Parse(time.RFC3339, raw)
	return at.UTC(), err == nil
}

var libyanDay = time.FixedZone("UTC+2", 2*60*60)

func deref[T any](value *T) T {
	var zero T
	if value == nil {
		return zero
	}
	return *value
}

func (s HTTPServer) handleCustomerAdminCreateCampaign(w http.ResponseWriter, r *http.Request) {
	store, ok := s.customerCampaignStore(w)
	if !ok {
		return
	}
	var request customerCampaignRequest
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	campaign := control.CustomerCampaign{
		Code: request.Code, Name: deref(request.Name), DisplayName: deref(request.DisplayName), Kind: request.Kind,
		Note: deref(request.Note), Landing: deref(request.Landing), Reward: deref(request.Reward),
		RewardLimit: deref(request.RewardLimit), CreatedBy: adminActor(r, request.Actor),
	}
	if raw := deref(request.RewardUntil); raw != "" {
		until, ok := parseRewardUntil(raw)
		if !ok {
			s.writeCampaignError(w, control.ErrCustomerCampaignInvalid)
			return
		}
		campaign.RewardUntil = &until
	}
	campaign, err := store.CreateCustomerCampaign(r.Context(), campaign)
	if !s.writeCampaignError(w, err) {
		return
	}
	s.logger().Info("operator created a campaign", "code", campaign.Code, "kind", campaign.Kind,
		"reward", campaign.Reward, "actor", campaign.CreatedBy)
	writeJSON(w, http.StatusCreated, map[string]any{"campaign": campaign})
}

func (s HTTPServer) handleCustomerAdminUpdateCampaign(w http.ResponseWriter, r *http.Request, id string) {
	store, ok := s.customerCampaignStore(w)
	if !ok {
		return
	}
	var request customerCampaignRequest
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	update := control.CustomerCampaignUpdate{
		Name: request.Name, DisplayName: request.DisplayName, Note: request.Note, Landing: request.Landing,
		Active: request.Active, Reward: request.Reward, RewardLimit: request.RewardLimit,
	}
	if request.RewardUntil != nil {
		if *request.RewardUntil == "" {
			update.ClearRewardUntil = true
		} else if until, ok := parseRewardUntil(*request.RewardUntil); ok {
			update.RewardUntil = &until
		} else {
			s.writeCampaignError(w, control.ErrCustomerCampaignInvalid)
			return
		}
	}
	campaign, err := store.UpdateCustomerCampaign(r.Context(), id, update)
	if !s.writeCampaignError(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"campaign": campaign})
}

// writeCampaignError answers a failed campaign write; true when err is nil.
func (s HTTPServer) writeCampaignError(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return true
	case errors.Is(err, control.ErrCustomerCampaignInvalid):
		writeCustomerError(w, http.StatusBadRequest, "invalid_campaign",
			"a campaign needs a code (3–24 of A–Z, 0–9, - and _), a name, a kind, a landing page path and a reward of 0 to 100", nil)
	case errors.Is(err, control.ErrCustomerCampaignCodeTaken):
		writeCustomerError(w, http.StatusConflict, "code_taken", "another campaign has this code", nil)
	case errors.Is(err, control.ErrCustomerCampaignNotFound):
		writeCustomerError(w, http.StatusNotFound, "campaign_not_found", "no such campaign", nil)
	default:
		s.customerInternalError(w, "customer campaign write failed", err)
	}
	return false
}

// --- the link ----------------------------------------------------------------

// OpenCampaignLink is the landing page of a live campaign's link, counting
// the open on platform unless count is false (a link preview's robot). It
// serves package cardsweb's cards.dftr.ly/go/{code}.
func (s HTTPServer) OpenCampaignLink(ctx context.Context, code, platform string, count bool) (control.CustomerCampaign, bool) {
	store, ok := s.Store.(control.CustomerCampaignStore)
	if !ok {
		return control.CustomerCampaign{}, false
	}
	campaign, live, err := liveCampaign(ctx, store, code)
	if err != nil {
		s.logger().Warn("campaign link read failed", "code", code, "error", err)
		return control.CustomerCampaign{}, false
	}
	if !live {
		return control.CustomerCampaign{}, false
	}
	if count {
		if err := store.RecordCustomerCampaignClick(ctx, campaign.ID, platform); err != nil {
			s.logger().Warn("campaign click not counted", "campaign", campaign.Code, "error", err)
		}
	}
	return campaign, true
}
