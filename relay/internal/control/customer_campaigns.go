package control

import (
	"context"
	"errors"
	"math/big"
	"sort"
	"strings"
	"time"
)

// Where «دفتر كروت» customers come from. An operator makes a campaign in the
// console (an ad, a creator, a billboard, a flyer, a friend's code), each with
// a code. The code reaches the app three ways: its link
// (cards.dftr.ly/go/CODE, counted per platform), the install referrer Google
// Play hands an app installed from it, or the customer typing it. A customer
// is credited to at most one campaign, the first one named, and only while
// they are new: an old customer tapping a link was not won by it.
//
// A campaign may give its new customers credit (its reward), to as many as
// its limit and until its reward ends. The campaign itself never ends on its
// own: a flyer still on a wall in three years still names who it brought,
// it just stops paying them.
//
// Every customer is also asked once where they heard of the app. The answer
// is what measures what a link cannot: a billboard, a friend, a shop.

// Campaign kinds: what the operator is paying for.
const (
	CampaignKindAd        = "ad"
	CampaignKindCreator   = "creator"
	CampaignKindBillboard = "billboard"
	CampaignKindFlyer     = "flyer"
	CampaignKindReferral  = "referral"
	CampaignKindOther     = "other"
)

var customerCampaignKinds = map[string]bool{
	CampaignKindAd: true, CampaignKindCreator: true, CampaignKindBillboard: true,
	CampaignKindFlyer: true, CampaignKindReferral: true, CampaignKindOther: true,
}

// CustomerCreditCampaign is a campaign's reward to a customer it brought:
// one per customer and campaign (reference "campaign:<id>").
const CustomerCreditCampaign = "campaign"

// CustomerHeardFromAnswers are the answers the app offers to «من أين سمعت عن
// دفتر كروت؟».
var CustomerHeardFromAnswers = []string{
	"facebook", "instagram", "tiktok", "whatsapp", "friend", "shop", "billboard", "store_search", "other",
}

// How a campaign's code reached the customer.
var customerAttributionVias = map[string]bool{"link": true, "code": true, "referrer": true, "web": true}

// Where a campaign link was opened: the relay's redirect tells phones from
// the rest; "app" is a link the installed app opened itself.
var customerCampaignClickPlatforms = map[string]bool{"ios": true, "android": true, "web": true, "app": true}

// CustomerCampaignNewFor is how long after their first sign-in a customer can
// still be credited to a campaign.
const CustomerCampaignNewFor = 7 * 24 * time.Hour

const (
	maxCampaignCode  = 24
	minCampaignCode  = 3
	maxCampaignText  = 200
	maxCampaignNotes = 1000
	maxCampaignShown = 60
)

// maxCampaignReward caps one customer's reward, against a slipped digit.
var maxCampaignReward = big.NewRat(100, 1)

var (
	ErrCustomerCampaignInvalid   = errors.New("customer campaign invalid")
	ErrCustomerCampaignCodeTaken = errors.New("customer campaign code taken")
	ErrCustomerCampaignNotFound  = errors.New("customer campaign not found")
)

// CustomerCampaign is one thing the operator does to bring customers.
type CustomerCampaign struct {
	ID string `json:"id"`
	// Code is what the link carries and the customer types: A–Z, 0–9, - and
	// _, stored upper case.
	Code string `json:"code"`
	// Name is the operator's; DisplayName, when set, is what customers read
	// («أحمد», «ملصق جامعة مصراتة»).
	Name        string `json:"name"`
	DisplayName string `json:"display_name,omitempty"`
	Kind        string `json:"kind"`
	Note        string `json:"note,omitempty"`
	// Landing is the app page the link opens ("/", "/brand/pubg").
	Landing string `json:"landing"`
	// Active campaigns are the ones links and typed codes still credit.
	Active bool `json:"active"`
	// Reward is the credit (dinars) each new customer it brings gets;
	// "0.000" gives none. RewardLimit caps how many get it (0: no cap), and
	// none do from RewardUntil on (nil: no end).
	Reward      string     `json:"reward"`
	RewardLimit int        `json:"reward_limit"`
	RewardUntil *time.Time `json:"reward_until,omitempty"`
	// Rewarded counts the customers who got it, read with the campaign.
	Rewarded  int       `json:"rewarded"`
	CreatedBy string    `json:"created_by,omitempty"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

// RewardDue reports whether a customer the campaign brings now still gets
// its reward.
func (c CustomerCampaign) RewardDue(now time.Time) bool {
	reward, err := ParseWalletAmount(c.Reward)
	return err == nil && reward.Sign() > 0 && c.Active &&
		(c.RewardUntil == nil || now.Before(*c.RewardUntil)) &&
		(c.RewardLimit == 0 || c.Rewarded < c.RewardLimit)
}

// CustomerCampaignUpdate changes a campaign; nil leaves a field as it is. The
// code never changes: links and posters already carry it.
type CustomerCampaignUpdate struct {
	Name        *string
	DisplayName *string
	Note        *string
	Landing     *string
	Active      *bool
	Reward      *string
	RewardLimit *int
	// RewardUntil sets the end; ClearRewardUntil removes it.
	RewardUntil      *time.Time
	ClearRewardUntil bool
}

// CustomerAcquisition counts the customers of one campaign or one answer,
// and what they brought.
type CustomerAcquisition struct {
	// Customers signed in; Buyers got at least one card; Spent sums their
	// delivered orders paid with real money (not test, not review).
	Customers int    `json:"customers"`
	Buyers    int    `json:"buyers"`
	Spent     string `json:"spent"`
}

// CustomerCampaignStats is a campaign with its results.
type CustomerCampaignStats struct {
	CustomerCampaign
	CustomerAcquisition
	// Clicks counts link opens by platform (ios, android, web, app).
	Clicks map[string]int `json:"clicks"`
	// RewardsGiven sums the credit it gave.
	RewardsGiven string `json:"rewards_given"`
}

// CustomerHeardFromStats is one answer to «من أين سمعت عنا؟» with its results.
type CustomerHeardFromStats struct {
	Answer string `json:"answer"`
	CustomerAcquisition
}

// CustomerCampaignReport is the console's acquisition page.
type CustomerCampaignReport struct {
	Campaigns []CustomerCampaignStats `json:"campaigns"`
	// NoCampaign are the customers no campaign brought.
	NoCampaign CustomerAcquisition `json:"no_campaign"`
	// HeardFrom lists every answer (zeros included); Unanswered are the
	// customers who never answered.
	HeardFrom   []CustomerHeardFromStats `json:"heard_from"`
	Unanswered  CustomerAcquisition      `json:"unanswered"`
	GeneratedAt time.Time                `json:"generated_at"`
}

// CustomerAttribution is where one customer came from.
type CustomerAttribution struct {
	CampaignCode string     `json:"campaign_code,omitempty"`
	CampaignVia  string     `json:"campaign_via,omitempty"`
	CampaignAt   *time.Time `json:"campaign_at,omitempty"`
	HeardFrom    string     `json:"heard_from,omitempty"`
	HeardFromAt  *time.Time `json:"heard_from_at,omitempty"`
}

// CustomerAttributionChange is what the app reports; empty fields say
// nothing. A code that names no active campaign is dropped.
type CustomerAttributionChange struct {
	CampaignCode string
	CampaignVia  string
	HeardFrom    string
}

// CustomerCampaignReward is the credit a campaign just gave a customer, and
// why, for the app to say so.
type CustomerCampaignReward struct {
	Amount      string `json:"amount"`
	Code        string `json:"code"`
	Kind        string `json:"kind"`
	DisplayName string `json:"display_name,omitempty"`
	Via         string `json:"via"`
}

// CustomerAttributionResult is what [CustomerCampaignStore.AttributeCustomer]
// did: Accepted when the change's code is now the customer's campaign,
// Reward when that gave them credit.
type CustomerAttributionResult struct {
	Attribution CustomerAttribution     `json:"attribution"`
	Accepted    bool                    `json:"code_accepted"`
	Reward      *CustomerCampaignReward `json:"reward,omitempty"`
}

// CustomerCampaignStore is an optional store capability (type-asserted).
type CustomerCampaignStore interface {
	CreateCustomerCampaign(ctx context.Context, campaign CustomerCampaign) (CustomerCampaign, error)
	UpdateCustomerCampaign(ctx context.Context, id string, update CustomerCampaignUpdate) (CustomerCampaign, error)
	// CustomerCampaignByCode finds a campaign, active or not, by its code
	// as typed (any case).
	CustomerCampaignByCode(ctx context.Context, code string) (CustomerCampaign, error)
	CustomerCampaignReport(ctx context.Context) (CustomerCampaignReport, error)
	// RecordCustomerCampaignClick counts one open of a campaign's link.
	RecordCustomerCampaignClick(ctx context.Context, campaignID, platform string) error
	CustomerAttribution(ctx context.Context, customerID string) (CustomerAttribution, error)
	// AttributeCustomer keeps the first campaign and the first answer a
	// customer reports; later ones change nothing. A campaign reaching a
	// customer past [CustomerCampaignNewFor] is ignored. Naming a campaign
	// gives its reward, if still due, in the same write.
	AttributeCustomer(ctx context.Context, customerID string, change CustomerAttributionChange) (CustomerAttributionResult, error)
}

var (
	_ CustomerCampaignStore = (*FileStore)(nil)
	_ CustomerCampaignStore = (*PostgresStore)(nil)
	_ CustomerCampaignStore = (*CachedInstallationStore)(nil)
)

// NormalizeCampaignCode reads a code as typed: trimmed, upper case. ok is
// false for anything a code cannot be.
func NormalizeCampaignCode(code string) (string, bool) {
	code = strings.ToUpper(strings.TrimSpace(code))
	if len(code) < minCampaignCode || len(code) > maxCampaignCode {
		return "", false
	}
	for _, r := range code {
		if (r < 'A' || r > 'Z') && (r < '0' || r > '9') && r != '-' && r != '_' {
			return "", false
		}
	}
	return code, true
}

// IsCustomerHeardFromAnswer reports whether answer is one the app offers.
func IsCustomerHeardFromAnswer(answer string) bool {
	for _, known := range CustomerHeardFromAnswers {
		if known == answer {
			return true
		}
	}
	return false
}

// NormalizeCampaignLanding reads an app page: a path on cards.dftr.ly, "/" when
// empty.
func NormalizeCampaignLanding(landing string) (string, bool) {
	landing = strings.TrimSpace(landing)
	if landing == "" {
		return "/", true
	}
	if !strings.HasPrefix(landing, "/") || strings.HasPrefix(landing, "//") ||
		strings.ContainsAny(landing, " \\#") || len(landing) > maxCampaignText ||
		strings.HasPrefix(landing, "/go/") {
		return "", false
	}
	return landing, true
}

// normalizeCampaignReward reads a reward: "" is none, else 0 to 100 dinars.
func normalizeCampaignReward(reward string) (string, bool) {
	if strings.TrimSpace(reward) == "" {
		return FormatWalletAmount(new(big.Rat)), true
	}
	amount, err := ParseWalletAmount(reward)
	if err != nil || amount.Sign() < 0 || amount.Cmp(maxCampaignReward) > 0 {
		return "", false
	}
	return FormatWalletAmount(amount), true
}

func normalizeNewCampaign(campaign CustomerCampaign, now time.Time) (CustomerCampaign, error) {
	code, ok := NormalizeCampaignCode(campaign.Code)
	if !ok {
		return CustomerCampaign{}, ErrCustomerCampaignInvalid
	}
	campaign.Code = code
	campaign.Name = truncateRunes(strings.TrimSpace(campaign.Name), maxCampaignText)
	if campaign.Name == "" || !customerCampaignKinds[campaign.Kind] {
		return CustomerCampaign{}, ErrCustomerCampaignInvalid
	}
	campaign.DisplayName = truncateRunes(strings.TrimSpace(campaign.DisplayName), maxCampaignShown)
	campaign.Note = truncateRunes(strings.TrimSpace(campaign.Note), maxCampaignNotes)
	landing, ok := NormalizeCampaignLanding(campaign.Landing)
	if !ok {
		return CustomerCampaign{}, ErrCustomerCampaignInvalid
	}
	campaign.Landing = landing
	reward, ok := normalizeCampaignReward(campaign.Reward)
	if !ok || campaign.RewardLimit < 0 {
		return CustomerCampaign{}, ErrCustomerCampaignInvalid
	}
	campaign.Reward = reward
	if campaign.RewardUntil != nil {
		until := campaign.RewardUntil.UTC()
		campaign.RewardUntil = &until
	}
	campaign.CreatedBy = truncateRunes(strings.TrimSpace(campaign.CreatedBy), maxIntegrationSwitchText)
	if campaign.ID == "" {
		id, err := NewInstallationID()
		if err != nil {
			return CustomerCampaign{}, err
		}
		campaign.ID = id
	}
	campaign.Active = true
	campaign.Rewarded = 0
	campaign.CreatedAt = now
	campaign.UpdatedAt = now
	return campaign, nil
}

func applyCampaignUpdate(campaign CustomerCampaign, update CustomerCampaignUpdate, now time.Time) (CustomerCampaign, error) {
	if update.Name != nil {
		name := truncateRunes(strings.TrimSpace(*update.Name), maxCampaignText)
		if name == "" {
			return CustomerCampaign{}, ErrCustomerCampaignInvalid
		}
		campaign.Name = name
	}
	if update.DisplayName != nil {
		campaign.DisplayName = truncateRunes(strings.TrimSpace(*update.DisplayName), maxCampaignShown)
	}
	if update.Note != nil {
		campaign.Note = truncateRunes(strings.TrimSpace(*update.Note), maxCampaignNotes)
	}
	if update.Landing != nil {
		landing, ok := NormalizeCampaignLanding(*update.Landing)
		if !ok {
			return CustomerCampaign{}, ErrCustomerCampaignInvalid
		}
		campaign.Landing = landing
	}
	if update.Active != nil {
		campaign.Active = *update.Active
	}
	if update.Reward != nil {
		reward, ok := normalizeCampaignReward(*update.Reward)
		if !ok {
			return CustomerCampaign{}, ErrCustomerCampaignInvalid
		}
		campaign.Reward = reward
	}
	if update.RewardLimit != nil {
		if *update.RewardLimit < 0 {
			return CustomerCampaign{}, ErrCustomerCampaignInvalid
		}
		campaign.RewardLimit = *update.RewardLimit
	}
	switch {
	case update.ClearRewardUntil:
		campaign.RewardUntil = nil
	case update.RewardUntil != nil:
		until := update.RewardUntil.UTC()
		campaign.RewardUntil = &until
	}
	campaign.UpdatedAt = now
	return campaign, nil
}

// normalizeAttributionChange drops what the app may not report.
func normalizeAttributionChange(change CustomerAttributionChange) CustomerAttributionChange {
	code, ok := NormalizeCampaignCode(change.CampaignCode)
	if !ok {
		code = ""
	}
	change.CampaignCode = code
	if !customerAttributionVias[change.CampaignVia] {
		change.CampaignVia = "code"
	}
	if code == "" {
		change.CampaignVia = ""
	}
	if !IsCustomerHeardFromAnswer(change.HeardFrom) {
		change.HeardFrom = ""
	}
	return change
}

// takesCampaign reports whether a customer created at created, with current
// attribution, can be won by a campaign now.
func takesCampaign(current CustomerAttribution, created, now time.Time) bool {
	return current.CampaignCode == "" && now.Sub(created) <= CustomerCampaignNewFor
}

// attribute applies change to what a customer already has, the first answer
// of each kind winning. campaign is the active campaign the change's code
// names, or nil.
func attribute(current CustomerAttribution, change CustomerAttributionChange, campaign *CustomerCampaign, created, now time.Time) CustomerAttribution {
	if campaign != nil && takesCampaign(current, created, now) {
		current.CampaignCode = campaign.Code
		current.CampaignVia = change.CampaignVia
		current.CampaignAt = &now
	}
	if change.HeardFrom != "" && current.HeardFrom == "" {
		current.HeardFrom = change.HeardFrom
		current.HeardFromAt = &now
	}
	return current
}

// campaignRewardEntry is the credit campaign gives customerID, or nil when
// its reward is not due.
func campaignRewardEntry(campaign CustomerCampaign, customerID string, now time.Time) *CustomerCreditEntry {
	if !campaign.RewardDue(now) {
		return nil
	}
	return &CustomerCreditEntry{
		CustomerID: customerID,
		Kind:       CustomerCreditCampaign,
		Amount:     campaign.Reward,
		Note:       campaign.Code,
		Reference:  campaignRewardReference(campaign.ID),
		CreatedAt:  now,
	}
}

func campaignRewardReference(campaignID string) string {
	return CustomerCreditCampaign + ":" + campaignID
}

func campaignReward(campaign CustomerCampaign, via string) *CustomerCampaignReward {
	return &CustomerCampaignReward{
		Amount: campaign.Reward, Code: campaign.Code, Kind: campaign.Kind,
		DisplayName: campaign.DisplayName, Via: via,
	}
}

// acquisitionTally adds customers up into a [CustomerAcquisition].
type acquisitionTally struct {
	customers, buyers int
	spent             *big.Rat
}

func (t *acquisitionTally) add(delivered bool, spent string) {
	t.customers++
	if delivered {
		t.buyers++
	}
	if value, ok := new(big.Rat).SetString(spent); ok {
		t.spent.Add(t.spent, value)
	}
}

// result is the tally as reported; a nil tally (nobody) is zeros.
func (t *acquisitionTally) result() CustomerAcquisition {
	if t == nil {
		return CustomerAcquisition{Spent: FormatWalletAmount(new(big.Rat))}
	}
	return CustomerAcquisition{Customers: t.customers, Buyers: t.buyers, Spent: FormatWalletAmount(t.spent)}
}

func tallyInto(tallies map[string]*acquisitionTally, key string, delivered bool, spent string) {
	tally := tallies[key]
	if tally == nil {
		tally = &acquisitionTally{spent: new(big.Rat)}
		tallies[key] = tally
	}
	tally.add(delivered, spent)
}

// campaignRewards is what each campaign's reward gave: by campaign id.
type campaignRewards map[string]struct {
	count int
	total *big.Rat
}

func (r campaignRewards) add(reference, amount string) {
	id, ok := strings.CutPrefix(reference, CustomerCreditCampaign+":")
	if !ok {
		return
	}
	value, ok := new(big.Rat).SetString(amount)
	if !ok {
		return
	}
	given := r[id]
	if given.total == nil {
		given.total = new(big.Rat)
	}
	given.count++
	given.total.Add(given.total, value)
	r[id] = given
}

// buildCampaignReport puts campaigns, their clicks, rewards and the tallies
// (keyed by campaign code and by answer, "" for none) together, newest
// campaign first.
func buildCampaignReport(
	campaigns []CustomerCampaign, clicks map[string]map[string]int, rewards campaignRewards,
	byCode, byAnswer map[string]*acquisitionTally, now time.Time,
) CustomerCampaignReport {
	report := CustomerCampaignReport{GeneratedAt: now, Campaigns: []CustomerCampaignStats{}}
	sort.Slice(campaigns, func(i, j int) bool { return campaigns[i].CreatedAt.After(campaigns[j].CreatedAt) })
	for _, campaign := range campaigns {
		counted := clicks[campaign.ID]
		if counted == nil {
			counted = map[string]int{}
		}
		given := rewards[campaign.ID]
		total := given.total
		if total == nil {
			total = new(big.Rat)
		}
		campaign.Rewarded = given.count
		report.Campaigns = append(report.Campaigns, CustomerCampaignStats{
			CustomerCampaign:    campaign,
			CustomerAcquisition: byCode[campaign.Code].result(),
			Clicks:              counted,
			RewardsGiven:        FormatWalletAmount(total),
		})
	}
	report.NoCampaign = byCode[""].result()
	for _, answer := range CustomerHeardFromAnswers {
		report.HeardFrom = append(report.HeardFrom, CustomerHeardFromStats{
			Answer: answer, CustomerAcquisition: byAnswer[answer].result(),
		})
	}
	report.Unanswered = byAnswer[""].result()
	return report
}

// --- file store ------------------------------------------------------------

type fileCustomerCampaignData struct {
	Campaigns map[string]CustomerCampaign `json:"campaigns,omitempty"`
	// Clicks are counted per campaign id, then platform.
	Clicks       map[string]map[string]int      `json:"clicks,omitempty"`
	Attributions map[string]CustomerAttribution `json:"attributions,omitempty"`
}

func (s *FileStore) campaignsLocked() *fileCustomerCampaignData {
	if s.data.CustomerCampaigns == nil {
		s.data.CustomerCampaigns = &fileCustomerCampaignData{}
	}
	c := s.data.CustomerCampaigns
	if c.Campaigns == nil {
		c.Campaigns = map[string]CustomerCampaign{}
	}
	if c.Clicks == nil {
		c.Clicks = map[string]map[string]int{}
	}
	if c.Attributions == nil {
		c.Attributions = map[string]CustomerAttribution{}
	}
	return c
}

// rewardsLocked is what every campaign's reward gave.
func (s *FileStore) rewardsLocked() campaignRewards {
	rewards := campaignRewards{}
	if s.data.CustomerOrders != nil {
		for _, entry := range s.data.CustomerOrders.Credits {
			if entry.Kind == CustomerCreditCampaign {
				rewards.add(entry.Reference, entry.Amount)
			}
		}
	}
	return rewards
}

// campaignLocked is the stored campaign with its reward count.
func (s *FileStore) campaignLocked(campaign CustomerCampaign) CustomerCampaign {
	campaign.Rewarded = s.rewardsLocked()[campaign.ID].count
	return campaign
}

func (s *FileStore) CreateCustomerCampaign(_ context.Context, campaign CustomerCampaign) (CustomerCampaign, error) {
	campaign, err := normalizeNewCampaign(campaign, s.clock.Now().UTC())
	if err != nil {
		return CustomerCampaign{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	data := s.campaignsLocked()
	for _, existing := range data.Campaigns {
		if existing.Code == campaign.Code {
			return CustomerCampaign{}, ErrCustomerCampaignCodeTaken
		}
	}
	data.Campaigns[campaign.ID] = campaign
	if err := s.saveLocked(); err != nil {
		delete(data.Campaigns, campaign.ID)
		return CustomerCampaign{}, err
	}
	return campaign, nil
}

func (s *FileStore) UpdateCustomerCampaign(_ context.Context, id string, update CustomerCampaignUpdate) (CustomerCampaign, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	data := s.campaignsLocked()
	previous, ok := data.Campaigns[id]
	if !ok {
		return CustomerCampaign{}, ErrCustomerCampaignNotFound
	}
	campaign, err := applyCampaignUpdate(previous, update, s.clock.Now().UTC())
	if err != nil {
		return CustomerCampaign{}, err
	}
	data.Campaigns[id] = campaign
	if err := s.saveLocked(); err != nil {
		data.Campaigns[id] = previous
		return CustomerCampaign{}, err
	}
	return s.campaignLocked(campaign), nil
}

func (s *FileStore) campaignByCodeLocked(code string) (CustomerCampaign, bool) {
	if s.data.CustomerCampaigns != nil {
		for _, campaign := range s.data.CustomerCampaigns.Campaigns {
			if campaign.Code == code {
				return s.campaignLocked(campaign), true
			}
		}
	}
	return CustomerCampaign{}, false
}

func (s *FileStore) CustomerCampaignByCode(_ context.Context, code string) (CustomerCampaign, error) {
	code, ok := NormalizeCampaignCode(code)
	if !ok {
		return CustomerCampaign{}, ErrCustomerCampaignNotFound
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	campaign, ok := s.campaignByCodeLocked(code)
	if !ok {
		return CustomerCampaign{}, ErrCustomerCampaignNotFound
	}
	return campaign, nil
}

func (s *FileStore) RecordCustomerCampaignClick(_ context.Context, campaignID, platform string) error {
	if !customerCampaignClickPlatforms[platform] {
		platform = "web"
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	data := s.campaignsLocked()
	if _, ok := data.Campaigns[campaignID]; !ok {
		return ErrCustomerCampaignNotFound
	}
	if data.Clicks[campaignID] == nil {
		data.Clicks[campaignID] = map[string]int{}
	}
	data.Clicks[campaignID][platform]++
	if err := s.saveLocked(); err != nil {
		data.Clicks[campaignID][platform]--
		return err
	}
	return nil
}

func (s *FileStore) CustomerAttribution(_ context.Context, customerID string) (CustomerAttribution, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.data.Customers == nil {
		return CustomerAttribution{}, ErrCustomerNotFound
	}
	if _, ok := s.data.Customers.Customers[customerID]; !ok {
		return CustomerAttribution{}, ErrCustomerNotFound
	}
	if s.data.CustomerCampaigns == nil {
		return CustomerAttribution{}, nil
	}
	return s.data.CustomerCampaigns.Attributions[customerID], nil
}

func (s *FileStore) AttributeCustomer(_ context.Context, customerID string, change CustomerAttributionChange) (CustomerAttributionResult, error) {
	change = normalizeAttributionChange(change)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.data.Customers == nil {
		return CustomerAttributionResult{}, ErrCustomerNotFound
	}
	customer, ok := s.data.Customers.Customers[customerID]
	if !ok || customer.DeletedAt != nil {
		return CustomerAttributionResult{}, ErrCustomerNotFound
	}
	now := s.clock.Now().UTC()
	data := s.campaignsLocked()
	previous, had := data.Attributions[customerID]
	var campaign *CustomerCampaign
	if found, ok := s.campaignByCodeLocked(change.CampaignCode); ok && found.Active && change.CampaignCode != "" {
		campaign = &found
	}
	next := attribute(previous, change, campaign, customer.CreatedAt, now)
	result := CustomerAttributionResult{Attribution: next}
	if next == previous {
		return result, nil
	}
	won := campaign != nil && next.CampaignCode != previous.CampaignCode
	result.Accepted = won
	data.Attributions[customerID] = next
	credits := 0
	if s.data.CustomerOrders != nil {
		credits = len(s.data.CustomerOrders.Credits)
	}
	if won {
		if entry := campaignRewardEntry(*campaign, customerID, now); entry != nil {
			if err := s.appendCustomerCreditLocked(entry); err != nil {
				return CustomerAttributionResult{}, err
			}
			result.Reward = campaignReward(*campaign, next.CampaignVia)
		}
	}
	if err := s.saveLocked(); err != nil {
		if had {
			data.Attributions[customerID] = previous
		} else {
			delete(data.Attributions, customerID)
		}
		if s.data.CustomerOrders != nil {
			s.data.CustomerOrders.Credits = s.data.CustomerOrders.Credits[:credits]
		}
		return CustomerAttributionResult{}, err
	}
	return result, nil
}

func (s *FileStore) CustomerCampaignReport(_ context.Context) (CustomerCampaignReport, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	now := s.clock.Now().UTC()
	var campaigns []CustomerCampaign
	clicks := map[string]map[string]int{}
	attributions := map[string]CustomerAttribution{}
	if data := s.data.CustomerCampaigns; data != nil {
		for _, campaign := range data.Campaigns {
			campaigns = append(campaigns, campaign)
		}
		for id, counted := range data.Clicks {
			copied := make(map[string]int, len(counted))
			for platform, n := range counted {
				copied[platform] = n
			}
			clicks[id] = copied
		}
		attributions = data.Attributions
	}
	byCode, byAnswer := map[string]*acquisitionTally{}, map[string]*acquisitionTally{}
	if s.data.Customers != nil {
		for _, customer := range s.data.Customers.Customers {
			summary := s.customerSummaryLocked(customer, now)
			attribution := attributions[customer.ID]
			tallyInto(byCode, attribution.CampaignCode, summary.Delivered > 0, summary.Spent)
			tallyInto(byAnswer, attribution.HeardFrom, summary.Delivered > 0, summary.Spent)
		}
	}
	return buildCampaignReport(campaigns, clicks, s.rewardsLocked(), byCode, byAnswer, now), nil
}

// --- cached store ------------------------------------------------------------

func (s *CachedInstallationStore) customerCampaignStore() (CustomerCampaignStore, error) {
	store, ok := s.store.(CustomerCampaignStore)
	if !ok {
		return nil, errCustomersUnsupported
	}
	return store, nil
}

func (s *CachedInstallationStore) CreateCustomerCampaign(ctx context.Context, campaign CustomerCampaign) (CustomerCampaign, error) {
	store, err := s.customerCampaignStore()
	if err != nil {
		return CustomerCampaign{}, err
	}
	return store.CreateCustomerCampaign(ctx, campaign)
}

func (s *CachedInstallationStore) UpdateCustomerCampaign(ctx context.Context, id string, update CustomerCampaignUpdate) (CustomerCampaign, error) {
	store, err := s.customerCampaignStore()
	if err != nil {
		return CustomerCampaign{}, err
	}
	return store.UpdateCustomerCampaign(ctx, id, update)
}

func (s *CachedInstallationStore) CustomerCampaignByCode(ctx context.Context, code string) (CustomerCampaign, error) {
	store, err := s.customerCampaignStore()
	if err != nil {
		return CustomerCampaign{}, err
	}
	return store.CustomerCampaignByCode(ctx, code)
}

func (s *CachedInstallationStore) CustomerCampaignReport(ctx context.Context) (CustomerCampaignReport, error) {
	store, err := s.customerCampaignStore()
	if err != nil {
		return CustomerCampaignReport{}, err
	}
	return store.CustomerCampaignReport(ctx)
}

func (s *CachedInstallationStore) RecordCustomerCampaignClick(ctx context.Context, campaignID, platform string) error {
	store, err := s.customerCampaignStore()
	if err != nil {
		return err
	}
	return store.RecordCustomerCampaignClick(ctx, campaignID, platform)
}

func (s *CachedInstallationStore) CustomerAttribution(ctx context.Context, customerID string) (CustomerAttribution, error) {
	store, err := s.customerCampaignStore()
	if err != nil {
		return CustomerAttribution{}, err
	}
	return store.CustomerAttribution(ctx, customerID)
}

func (s *CachedInstallationStore) AttributeCustomer(ctx context.Context, customerID string, change CustomerAttributionChange) (CustomerAttributionResult, error) {
	store, err := s.customerCampaignStore()
	if err != nil {
		return CustomerAttributionResult{}, err
	}
	return store.AttributeCustomer(ctx, customerID, change)
}
