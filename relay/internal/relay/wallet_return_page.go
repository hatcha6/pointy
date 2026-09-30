package relay

import (
	"html/template"
	"net/http"
	"strings"

	"pointy/relay/internal/control"
)

// The page the payer's browser lands on after the gateway. The shop owner
// reads it in Arabic, on a phone or a till, so it says in one line what
// happened to their money and what to do next — and it never shows more than
// the amount and the invoice number, because its URL carries the signature.

var walletReturnTemplate = template.Must(template.New("wallet-return").Parse(`<!doctype html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex">
  <title>{{.Title}} · دفتر</title>
  <style>
    :root { color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Tahoma, Arial, sans-serif; }
    body { margin: 0; background: #f5f7fa; color: #111827; }
    main { max-width: 520px; margin: 0 auto; padding: 48px 16px; }
    section { background: #fff; border: 1px solid #d8dee9; border-radius: 12px; padding: 32px 24px; text-align: center; }
    .mark { width: 64px; height: 64px; border-radius: 50%; margin: 0 auto 16px; display: flex; align-items: center; justify-content: center; font-size: 34px; font-weight: 800; }
    .success .mark { background: #e7f8ef; color: #11613a; }
    .neutral .mark { background: #eef1f5; color: #4b5563; }
    .warning .mark { background: #fff4e5; color: #9a5b00; }
    .danger .mark { background: #fdecec; color: #9f1c1c; }
    h1 { margin: 0 0 10px; font-size: 22px; }
    p { margin: 0 0 8px; color: #4b5563; line-height: 1.7; }
    .amount { font-size: 30px; font-weight: 800; margin: 18px 0 6px; color: #0b6b64; }
    .facts { margin-top: 20px; padding-top: 16px; border-top: 1px solid #eef1f5; color: #6b7280; font-size: 13px; }
    .ref { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; color: #111827; }
    .test { display: inline-block; margin-top: 14px; padding: 4px 10px; border-radius: 999px; background: #fff4e5; color: #9a5b00; font-size: 12px; font-weight: 700; }
    .brand { text-align: center; color: #6b7280; font-size: 12px; margin-top: 20px; }
    .brand strong { color: #0b6b64; }
  </style>
</head>
<body>
<main>
  <section class="{{.Tone}}">
    <div class="mark" aria-hidden="true">{{.Mark}}</div>
    <h1>{{.Title}}</h1>
    {{if .Amount}}<div class="amount"><bdi dir="ltr">{{.Amount}}</bdi> د.ل</div>{{end}}
    <p>{{.Message}}</p>
    {{if .Advice}}<p>{{.Advice}}</p>{{end}}
    {{if .InvoiceNo}}<div class="facts">رقم العملية: <bdi class="ref" dir="ltr">{{.InvoiceNo}}</bdi></div>{{end}}
    {{if .TestMode}}<div class="test">وضع تجريبي — لم تُحوَّل أموال حقيقية</div>{{end}}
  </section>
  <p class="brand">محفظة <strong>دفتر</strong></p>
</main>
</body>
</html>`))

type walletReturnPage struct {
	Tone      string
	Mark      string
	Title     string
	Amount    string
	Message   string
	Advice    string
	InvoiceNo string
	TestMode  bool
}

const walletReturnCloseAdvice = "يمكنك إغلاق هذه الصفحة والعودة إلى دفتر."

// walletReturnFor draws the page from what the relay has recorded, never from
// the query string: a replayed or edited URL shows the stored truth.
func walletReturnFor(topUp control.WalletTopUp) walletReturnPage {
	page := walletReturnPage{
		InvoiceNo: topUp.InvoiceNo,
		TestMode:  topUp.TestMode,
		Amount:    walletDisplayAmount(topUp.Amount),
	}
	switch topUp.Status {
	case control.WalletTopUpPaid:
		page.Tone, page.Mark = "success", "✓"
		page.Title = "تم شحن محفظتك"
		page.Message = "أُضيف المبلغ إلى رصيد محفظتك في دفتر."
		page.Advice = walletReturnCloseAdvice
	case control.WalletTopUpCanceled:
		page.Tone, page.Mark = "neutral", "×"
		page.Title = "أُلغيت عملية الدفع"
		page.Message = "لم يُخصم أي مبلغ. يمكنك بدء عملية شحن جديدة من دفتر متى شئت."
	case control.WalletTopUpFailed:
		if topUp.ErrorCode == walletCodeAmountMismatch {
			page.Tone, page.Mark = "warning", "!"
			page.Title = "نراجع عملية الدفع"
			page.Message = "إن خُصم المبلغ من بطاقتك فسيُضاف إلى محفظتك بعد المراجعة."
			page.Advice = "احتفظ برقم العملية وتواصل مع الدعم إن احتجت."
			break
		}
		page.Tone, page.Mark = "danger", "×"
		page.Title = "لم تكتمل عملية الدفع"
		page.Message = "لم تُقبل عملية الدفع. يمكنك المحاولة مجدداً من دفتر."
	case control.WalletTopUpExpired:
		page.Tone, page.Mark = "neutral", "!"
		page.Title = "انتهت مهلة عملية الشحن"
		page.Message = "إن خُصم المبلغ من بطاقتك فتواصل مع الدعم واذكر رقم العملية."
	default:
		page.Tone, page.Mark = "neutral", "…"
		page.Title = "عملية الدفع قيد المعالجة"
		page.Message = "سيظهر المبلغ في محفظتك فور تأكيده."
		page.Advice = walletReturnCloseAdvice
	}
	return page
}

func walletReturnUnverified(invoiceNo string) walletReturnPage {
	return walletReturnPage{
		Tone:      "warning",
		Mark:      "!",
		Title:     "تعذّر التحقق من عملية الدفع",
		Message:   "لم نتمكن من التحقق من نتيجة الدفع، فلم نغيّر شيئاً في محفظتك.",
		Advice:    "إن خُصم المبلغ من بطاقتك فتواصل مع الدعم واذكر رقم العملية.",
		InvoiceNo: walletReturnInvoice(invoiceNo),
	}
}

func walletReturnRetry(invoiceNo string) walletReturnPage {
	return walletReturnPage{
		Tone:      "warning",
		Mark:      "!",
		Title:     "تعذّر تسجيل نتيجة الدفع الآن",
		Message:   "أعد تحميل هذه الصفحة بعد لحظات. لن يُحتسب الدفع مرتين.",
		InvoiceNo: walletReturnInvoice(invoiceNo),
	}
}

func walletReturnUnavailable() walletReturnPage {
	return walletReturnPage{
		Tone:    "neutral",
		Mark:    "!",
		Title:   "خدمة شحن المحفظة غير متاحة",
		Message: "تواصل مع الدعم إن كنت قد أتممت عملية دفع.",
	}
}

// walletReturnInvoice shows an invoice number from an unverified request only
// if it looks like one of ours, so the page cannot be made to print arbitrary
// text.
func walletReturnInvoice(invoiceNo string) string {
	invoiceNo = strings.TrimSpace(invoiceNo)
	if len(invoiceNo) > 32 || !strings.HasPrefix(invoiceNo, "DFW-") {
		return ""
	}
	for _, c := range invoiceNo[4:] {
		if !((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
			return ""
		}
	}
	return invoiceNo
}

// walletDisplayAmount writes a stored amount the way a receipt does: two
// places, three only when the dirhams need them.
func walletDisplayAmount(amount string) string {
	amount = strings.TrimSpace(amount)
	whole, fraction, found := strings.Cut(amount, ".")
	if !found {
		return amount + ".00"
	}
	for len(fraction) > 2 && strings.HasSuffix(fraction, "0") {
		fraction = strings.TrimSuffix(fraction, "0")
	}
	for len(fraction) < 2 {
		fraction += "0"
	}
	return whole + "." + fraction
}

func writeWalletReturnPage(w http.ResponseWriter, status int, page walletReturnPage) {
	header := w.Header()
	header.Set("Content-Type", "text/html; charset=utf-8")
	// The URL carries the gateway's signature and transaction id: nothing
	// caches it and nothing it links to learns it.
	header.Set("Cache-Control", "no-store")
	header.Set("Referrer-Policy", "no-referrer")
	header.Set("X-Content-Type-Options", "nosniff")
	header.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'")
	w.WriteHeader(status)
	_ = walletReturnTemplate.Execute(w, page)
}
