package relay

import (
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"
)

const (
	smsConsentTransactional = "transactional"
	smsConsentMarketing     = "marketing"
)

// smsKind is a message kind the relay knows. Django owns the canonical text and
// renders its own copy; the relay keeps only what it enforces — how many
// positional variables the kind takes and the consent class it goes out under —
// and the Arabic title the kind's charge prints on the shop's SMS statement
// (Django's SMSTemplateSpec.title). The approved text itself lives in the
// Resala dashboard and comes back on every send.
type smsKind struct {
	Kind         string
	ConsentClass string
	Variables    int
	Title        string
}

// smsKindCatalog mirrors the kinds table of the SMS contract (and the relay
// README). A kind configured in POINTY_RELAY_SMS_TEMPLATES but missing here is
// still sendable — operators can add one without a deploy — it just skips the
// variable-count check.
var smsKindCatalog = []smsKind{
	{Kind: "test", ConsentClass: smsConsentTransactional, Variables: 1, Title: "رسالة تجريبية"},
	{Kind: "invoice", ConsentClass: smsConsentTransactional, Variables: 3, Title: "فاتورة بيع"},
	{Kind: "invoice_link", ConsentClass: smsConsentTransactional, Variables: 4, Title: "فاتورة بيع مع رابط"},
	{Kind: "debt_reminder", ConsentClass: smsConsentTransactional, Variables: 3, Title: "تذكير بدين"},
	{Kind: "debt_reminder_link", ConsentClass: smsConsentTransactional, Variables: 4, Title: "تذكير بدين مع رابط"},
	{Kind: "consignment_sale", ConsentClass: smsConsentTransactional, Variables: 5, Title: "بيع أمانة"},
	{Kind: "consignment_payout", ConsentClass: smsConsentTransactional, Variables: 4, Title: "تسليم مستحقات أمانة"},
	{Kind: "consignment_claim", ConsentClass: smsConsentTransactional, Variables: 5, Title: "تسوية حادث أمانة"},
	{Kind: "batch_recall", ConsentClass: smsConsentTransactional, Variables: 4, Title: "استدعاء دفعة"},
	{Kind: "month_end_report", ConsentClass: smsConsentTransactional, Variables: 7, Title: "ملخص إقفال الشهر"},
	{Kind: "direct", ConsentClass: smsConsentTransactional, Variables: 2, Title: "رسالة مباشرة"},
	{Kind: "marketing", ConsentClass: smsConsentMarketing, Variables: 2, Title: "عرض ترويجي"},
	{Kind: "quotation", ConsentClass: smsConsentTransactional, Variables: 4, Title: "عرض سعر"},
	{Kind: "quotation_link", ConsentClass: smsConsentTransactional, Variables: 5, Title: "عرض سعر مع رابط"},
	{Kind: "refund_issued", ConsentClass: smsConsentTransactional, Variables: 3, Title: "تسجيل مرتجع"},
	{Kind: "warranty_registered", ConsentClass: smsConsentTransactional, Variables: 4, Title: "تسجيل ضمان"},
	{Kind: "credit_invoice", ConsentClass: smsConsentTransactional, Variables: 4, Title: "فاتورة آجلة"},
	{Kind: "payment_received", ConsentClass: smsConsentTransactional, Variables: 3, Title: "استلام دفعة"},
	{Kind: "account_balance", ConsentClass: smsConsentTransactional, Variables: 3, Title: "رصيد الحساب"},
	{Kind: "due_date_changed", ConsentClass: smsConsentTransactional, Variables: 4, Title: "تغيير موعد الاستحقاق"},
	{Kind: "job_received", ConsentClass: smsConsentTransactional, Variables: 3, Title: "استلام طلب"},
	{Kind: "job_estimate", ConsentClass: smsConsentTransactional, Variables: 3, Title: "تكلفة الطلب بانتظار الموافقة"},
	{Kind: "job_ready", ConsentClass: smsConsentTransactional, Variables: 2, Title: "جاهز للاستلام"},
	{Kind: "job_ready_due", ConsentClass: smsConsentTransactional, Variables: 3, Title: "جاهز للاستلام مع المتبقي"},
	{Kind: "job_returned", ConsentClass: smsConsentTransactional, Variables: 2, Title: "جاهز للاستلام دون إصلاح"},
	{Kind: "job_pickup_reminder", ConsentClass: smsConsentTransactional, Variables: 3, Title: "تذكير بالاستلام"},
	{Kind: "job_delivered", ConsentClass: smsConsentTransactional, Variables: 3, Title: "التسليم والضمان"},
	{Kind: "payroll_paid", ConsentClass: smsConsentTransactional, Variables: 3, Title: "صرف الراتب"},
}

func lookupSMSKind(kind string) (smsKind, bool) {
	for _, known := range smsKindCatalog {
		if known.Kind == kind {
			return known, true
		}
	}
	return smsKind{}, false
}

var smsKindPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)

// ParseSMSTemplates reads POINTY_RELAY_SMS_TEMPLATES: a JSON object mapping a
// message kind to the id of its APPROVED Resala template, e.g.
// {"invoice":"0b6a…","test":"5c1e…"}. Empty configures no kinds.
//
// Malformed JSON is an error, so a typo stops the relay at startup instead of
// quietly failing every send. The warnings are for things that start fine but
// deserve a line in the log: a kind the relay does not know, or one left blank.
func ParseSMSTemplates(raw string) (map[string]string, []string, error) {
	templates := map[string]string{}
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return templates, nil, nil
	}
	var decoded map[string]string
	if err := json.Unmarshal([]byte(raw), &decoded); err != nil {
		return nil, nil, fmt.Errorf(
			"POINTY_RELAY_SMS_TEMPLATES must be a JSON object of kind -> Resala template id "+
				`(e.g. {"invoice":"<uuid>"}): %w`,
			err,
		)
	}
	var warnings []string
	kinds := make([]string, 0, len(decoded))
	for kind := range decoded {
		kinds = append(kinds, kind)
	}
	sort.Strings(kinds)
	for _, rawKind := range kinds {
		kind := strings.ToLower(strings.TrimSpace(rawKind))
		if !smsKindPattern.MatchString(kind) {
			return nil, nil, fmt.Errorf("POINTY_RELAY_SMS_TEMPLATES: %q is not a valid message kind", rawKind)
		}
		if _, duplicate := templates[kind]; duplicate {
			return nil, nil, fmt.Errorf("POINTY_RELAY_SMS_TEMPLATES: kind %q is configured twice", kind)
		}
		templateID := strings.TrimSpace(decoded[rawKind])
		if templateID == "" {
			warnings = append(warnings, fmt.Sprintf(
				"kind %q has an empty template id; its sends fail with template_not_configured", kind,
			))
			continue
		}
		if _, known := lookupSMSKind(kind); !known {
			warnings = append(warnings, fmt.Sprintf(
				"kind %q is not in the relay catalog; its variable count is not checked", kind,
			))
		}
		templates[kind] = templateID
	}
	return templates, warnings, nil
}
