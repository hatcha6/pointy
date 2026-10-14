package relay

import (
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"html/template"
	"math/big"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode"
)

// The customer-facing invoice page: what a shop's shared invoice link shows.
// The relay fetches the invoice from the shop's backend and renders it here,
// so this page has to read the same as the slip printed at the counter.

//go:embed assets/brand_mark.png
var brandMarkPNG []byte

// brandMarkSrc is دفتر's app icon (in colour, from assets/branding/logo.png)
// for the closing tagline, inlined so the page
// needs nothing but itself (its CSP allows data: images only).
var brandMarkSrc = template.URL(
	"data:image/png;base64," + base64.StdEncoding.EncodeToString(brandMarkPNG),
)

var publicInvoiceTemplate = template.Must(template.New("public-invoice").Parse(`<!doctype html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{.ShopName}} - {{.ReceiptNumber}}</title>
  <style>
    :root { color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Tahoma, Arial, sans-serif; }
    body { margin: 0; background: #f5f7fa; color: #111827; }
    main { max-width: 760px; margin: 0 auto; padding: 28px 16px 44px; }
    .invoice { background: #fff; border: 1px solid #d8dee9; border-radius: 8px; overflow: hidden; }
    header { padding: 24px; border-bottom: 1px solid #e5e7eb; display: flex; align-items: center; gap: 16px; }
    header .heading { flex: 1; }
    /* The shop's own logo, unframed so its shape is its own; a wide wordmark
       keeps its width instead of being squeezed into a square. */
    .logo { height: 80px; width: auto; max-width: 200px; object-fit: contain; }
    h1 { margin: 0; font-size: 26px; }
    .muted { color: #5f6b7a; }
    .meta { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; padding: 18px 24px; border-bottom: 1px solid #e5e7eb; }
    .meta div { display: grid; gap: 4px; justify-items: start; }
    .label { color: #6b7280; font-size: 12px; font-weight: 700; }
    .value { font-weight: 700; }
    table { width: 100%; border-collapse: collapse; }
    th, td { padding: 12px 16px; border-bottom: 1px solid #eef1f5; text-align: right; vertical-align: top; }
    th { color: #4b5563; font-size: 12px; }
    .num { text-align: left; direction: ltr; white-space: nowrap; }
    .qty { text-align: left; white-space: nowrap; }
    .unit { color: #5f6b7a; font-size: 13px; }
    .pill { display: inline-block; padding: 2px 10px; border-radius: 999px; font-size: 13px; font-weight: 700; background: #eef1f5; color: #374151; }
    .pill.ok { background: #e3f4ec; color: #0e6b4e; }
    .pill.warn { background: #fdf0dc; color: #8a5a14; }
    .pill.void { background: #fde8e6; color: #b42318; }
    /* Phone-only pieces: the total up front, and a line's quantity under its name. */
    .hero, .mqty { display: none; }
    .sub { margin-top: 4px; color: #5f6b7a; font-size: 13px; }
    .code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; color: #111827; }
    .totals { display: grid; gap: 10px; padding: 18px 24px; margin-inline-start: auto; max-width: 340px; }
    .total-row { display: flex; justify-content: space-between; gap: 16px; }
    .grand { font-size: 20px; font-weight: 800; }
    footer { padding: 18px 24px 24px; border-top: 1px solid #e5e7eb; }
    .actions { display: flex; justify-content: flex-end; margin-top: 18px; }
    button { border: 0; border-radius: 6px; padding: 12px 18px; font: inherit; font-weight: 800; background: #0b6b64; color: #fff; cursor: pointer; }
    .tagline { display: flex; align-items: center; justify-content: center; gap: 6px; color: #6b7280; font-size: 13px; margin-top: 20px; }
    .tagline img { height: 18px; width: auto; }
    /* One colour for both words: the mark is the only colour in the line. */
    .tagline strong { color: inherit; }
    @media (max-width: 560px) {
      main { padding: 12px 12px 32px; }
      .invoice { border-radius: 14px; }
      header { flex-direction: column; text-align: center; gap: 10px; padding: 24px 16px 18px; border-bottom: 0; }
      header .heading { flex: none; }
      h1 { font-size: 22px; }
      header p { margin: 6px 0 0; font-size: 14px; }
      .logo { height: 64px; max-width: 160px; }
      .hero { display: grid; justify-items: center; gap: 6px; margin: 0 16px 16px; padding: 16px; border-radius: 12px; background: #f3f8f7; }
      .hero-total { font-size: 32px; font-weight: 800; direction: ltr; }
      .meta { gap: 14px 12px; padding: 16px; border-top: 1px solid #e5e7eb; }
      .meta .status { display: none; }
      .value { font-size: 15px; }
      /* Items read as a list, not a four-column table: the name and the line
         total, then "6 قطعة × 1.25" and whatever identifies the article. */
      thead, td.qty, td.price { display: none; }
      tbody tr { display: flex; gap: 12px; padding: 12px 16px; border-bottom: 1px solid #eef1f5; }
      tbody td { display: block; padding: 0; border: 0; }
      tbody td:first-child { flex: 1; min-width: 0; }
      .name { font-weight: 600; }
      .mqty { display: block; margin-top: 3px; color: #5f6b7a; font-size: 13px; }
      .sub { font-size: 12px; }
      td.total { font-weight: 700; }
      .totals { max-width: none; margin: 0; padding: 14px 16px 16px; background: #fafbfc; }
      .grand { border-top: 1px solid #e5e7eb; padding-top: 10px; margin-top: 2px; }
      footer { padding: 16px; text-align: center; font-size: 14px; }
      .actions { margin-top: 14px; }
      button { width: 100%; padding: 14px; border-radius: 10px; }
    }
    @media print {
      body { background: #fff; }
      main { padding: 0; max-width: none; }
      .invoice { border: 0; border-radius: 0; }
      .actions { display: none; }
    }
  </style>
</head>
<body>
<main>
  <section class="invoice">
    <header>
      {{if .ShopLogoSrc}}<img class="logo" src="{{.ShopLogoSrc}}" alt="">{{end}}
      <div class="heading">
        <h1>{{.ShopName}}</h1>
        {{if .HeaderText}}<p class="muted">{{.HeaderText}}</p>{{end}}
      </div>
    </header>
    <section class="hero">
      <span class="label">الإجمالي</span>
      <span class="hero-total">{{.Total}}</span>
      <span class="pill {{.StatusTone}}">{{.StatusLabel}}</span>
    </section>
    <section class="meta">
      <div><span class="label">رقم الفاتورة</span><span class="value">{{.ReceiptNumber}}</span></div>
      <div class="status"><span class="label">الحالة</span><span class="pill {{.StatusTone}}">{{.StatusLabel}}</span></div>
      <div><span class="label">تاريخ الإصدار</span><span class="value"><bdi dir="ltr">{{.CreatedAtLabel}}</bdi></span></div>
      {{if .CustomerName}}<div><span class="label">العميل</span><span class="value">{{.CustomerName}}</span></div>{{end}}
    </section>
    <table>
      <thead>
        <tr>
          <th>الصنف</th>
          <th class="qty">الكمية</th>
          <th class="num price">السعر</th>
          <th class="num">الإجمالي</th>
        </tr>
      </thead>
      <tbody>
        {{range .Lines}}
          <tr>
            <td>
              <div class="name">{{.DisplayName}}</div>
              <div class="mqty"><bdi dir="ltr">{{.QuantityLabel}}</bdi>{{if .UnitLabel}} {{.UnitLabel}}{{end}} × <bdi dir="ltr">{{.UnitPrice}}</bdi></div>
              {{if .ModifiersLabel}}<div class="sub">{{.ModifiersLabel}}</div>{{end}}
              {{range .IdentifierRows}}<div class="sub">{{if .Prefix}}{{.Prefix}} {{end}}{{if .Code}}<bdi dir="ltr" class="code">{{.Code}}</bdi>{{end}}{{if .Suffix}} — {{.Suffix}}{{end}}</div>{{end}}
            </td>
            <td class="qty"><bdi dir="ltr">{{.QuantityLabel}}</bdi>{{if .UnitLabel}} <span class="unit">{{.UnitLabel}}</span>{{end}}</td>
            <td class="num price">{{.UnitPrice}}</td>
            <td class="num total">{{.LineTotal}}</td>
          </tr>
        {{end}}
      </tbody>
    </table>
    <section class="totals">
      <div class="total-row"><span>المجموع الفرعي</span><span class="num">{{.Subtotal}}</span></div>
      {{if .RulesDiscount}}<div class="total-row"><span>الخصم</span><span class="num">{{.RulesDiscount}}</span></div>{{end}}
      {{if .ExtraDiscount}}<div class="total-row"><span>خصم إضافي</span><span class="num">{{.ExtraDiscount}}</span></div>{{end}}
      <div class="total-row grand"><span>الإجمالي</span><span class="num">{{.Total}}</span></div>
    </section>
    {{if .FooterText}}<footer class="muted">{{.FooterText}}</footer>{{end}}
  </section>
  <div class="actions">
    <button type="button" id="save-pdf">حفظ كملف PDF</button>
  </div>
  <p class="tagline"><span>دُوّن في</span><img src="{{.BrandMarkSrc}}" alt=""><strong>دفتر</strong></p>
</main>
<script>
document.getElementById('save-pdf').addEventListener('click', function () { window.print(); });
</script>
</body>
</html>`))

var publicInvoiceErrorTemplate = template.Must(template.New("public-invoice-error").Parse(`<!doctype html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>الفاتورة غير متاحة</title>
  <style>
    :root { color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Tahoma, Arial, sans-serif; }
    body { margin: 0; background: #f5f7fa; color: #111827; }
    main { max-width: 560px; margin: 0 auto; padding: 48px 16px; }
    section { background: #fff; border: 1px solid #d8dee9; border-radius: 8px; padding: 24px; }
    h1 { margin: 0 0 10px; font-size: 24px; }
    p { margin: 0; color: #5f6b7a; }
  </style>
</head>
<body>
<main>
  <section>
    <h1>الفاتورة غير متاحة</h1>
    <p>{{.Message}}</p>
  </section>
</main>
</body>
</html>`))

type publicInvoicePayload struct {
	ShopName        string                     `json:"shop_name"`
	ReceiptHeader   string                     `json:"receipt_header"`
	ReceiptFooter   string                     `json:"receipt_footer"`
	ShopLogoDataURI string                     `json:"shop_logo_data_uri"`
	ReceiptNumber   string                     `json:"receipt_number"`
	Status          string                     `json:"status"`
	CustomerName    string                     `json:"customer_name"`
	Lines           []publicInvoiceLinePayload `json:"lines"`
	Subtotal        string                     `json:"subtotal"`
	DiscountTotal   string                     `json:"discount_total"`
	// The cashier's one-off discount. It is already spread over the lines,
	// so it is part of DiscountTotal, not on top of it.
	ExtraDiscountAmount string `json:"extra_discount_amount"`
	Total               string `json:"total"`
	CreatedAt           string `json:"created_at"`
}

type publicInvoiceLinePayload struct {
	ProductName string `json:"product_name"`
	VariantName string `json:"variant_name"`
	// A decimal: the backend sends 2.0 for two pieces and 1.25 for a weighed
	// line, which an int refuses — and one refused line failed the whole page.
	Quantity      json.Number                      `json:"quantity"`
	UnitLabel     string                           `json:"unit_label"`
	UnitPrice     string                           `json:"unit_price"`
	LineSubtotal  string                           `json:"line_subtotal"`
	DiscountTotal string                           `json:"discount_total"`
	LineTotal     string                           `json:"line_total"`
	Modifiers     []publicInvoiceModifierPayload   `json:"modifiers"`
	Identifiers   []publicInvoiceIdentifierPayload `json:"identifiers"`
}

type publicInvoiceModifierPayload struct {
	Name       string `json:"name"`
	Quantity   int    `json:"quantity"`
	PriceDelta string `json:"price_delta"`
}

type publicInvoiceIdentifierPayload struct {
	Kind              string `json:"kind"`
	Code              string `json:"code"`
	ExpiryDate        string `json:"expiry_date"`
	WarrantyExpiresOn string `json:"warranty_expires_on"`
}

type publicInvoiceViewData struct {
	publicInvoicePayload
	StatusLabel    string
	StatusTone     string
	CreatedAtLabel string
	HeaderText     string
	FooterText     string
	RulesDiscount  string
	ExtraDiscount  string
	Lines          []publicInvoiceLineViewData
	// Typed template.URL so html/template renders the validated data URI
	// instead of sanitizing it.
	ShopLogoSrc  template.URL
	BrandMarkSrc template.URL
}

type publicInvoiceLineViewData struct {
	publicInvoiceLinePayload
	DisplayName    string
	QuantityLabel  string
	ModifiersLabel string
	IdentifierRows []publicInvoiceIdentifierRow
}

// publicInvoiceIdentifierRow is one printed identity line under a sale line,
// split so the Latin code renders isolated from the Arabic around it.
type publicInvoiceIdentifierRow struct {
	Prefix string
	Code   string
	Suffix string
}

type publicInvoiceErrorData struct {
	Message string
}

// publicInvoiceLogoSrc only trusts embedded raster image data URIs; anything
// else renders no logo at all.
func publicInvoiceLogoSrc(dataURI string) template.URL {
	if strings.HasPrefix(dataURI, "data:image/png;base64,") ||
		strings.HasPrefix(dataURI, "data:image/jpeg;base64,") ||
		strings.HasPrefix(dataURI, "data:image/webp;base64,") {
		return template.URL(dataURI)
	}
	return ""
}

func (s HTTPServer) renderPublicInvoice(
	w http.ResponseWriter,
	payload publicInvoicePayload,
) {
	rulesDiscount, extraDiscount := publicInvoiceDiscounts(
		payload.DiscountTotal,
		payload.ExtraDiscountAmount,
	)
	data := publicInvoiceViewData{
		publicInvoicePayload: payload,
		StatusLabel:          publicInvoiceStatusLabel(payload.Status),
		StatusTone:           publicInvoiceStatusTone(payload.Status),
		HeaderText:           keepNumbersWhole(payload.ReceiptHeader),
		FooterText:           keepNumbersWhole(payload.ReceiptFooter),
		CreatedAtLabel:       publicInvoiceDateTime(payload.CreatedAt),
		RulesDiscount:        rulesDiscount,
		ExtraDiscount:        extraDiscount,
		Lines:                publicInvoiceLineViewDataList(payload.Lines),
		ShopLogoSrc:          publicInvoiceLogoSrc(payload.ShopLogoDataURI),
		BrandMarkSrc:         brandMarkSrc,
	}
	setPublicInvoiceHeaders(w.Header(), true)
	w.WriteHeader(http.StatusOK)
	_ = publicInvoiceTemplate.Execute(w, data)
}

func (s HTTPServer) renderPublicInvoiceError(
	w http.ResponseWriter,
	statusCode int,
	message string,
) {
	setPublicInvoiceHeaders(w.Header(), false)
	w.WriteHeader(statusCode)
	_ = publicInvoiceErrorTemplate.Execute(w, publicInvoiceErrorData{
		Message: message,
	})
}

func setPublicInvoiceHeaders(header http.Header, allowScript bool) {
	header.Set("Content-Type", "text/html; charset=utf-8")
	header.Set("Cache-Control", "no-store")
	header.Set("X-Content-Type-Options", "nosniff")
	csp := "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'"
	if allowScript {
		// img-src data: lets the inlined shop logo and brand mark show; with
		// default-src 'none' alone the browser dropped both.
		csp = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; base-uri 'none'; frame-ancestors 'none'"
	}
	header.Set("Content-Security-Policy", csp)
}

func publicInvoiceStatusLabel(status string) string {
	switch strings.TrimSpace(status) {
	case "paid":
		return "مدفوعة"
	case "void":
		return "ملغاة"
	case "open":
		return "مفتوحة"
	default:
		return status
	}
}

// publicInvoiceStatusTone colours the status badge: settled, still open, or
// void.
func publicInvoiceStatusTone(status string) string {
	switch strings.TrimSpace(status) {
	case "paid":
		return "ok"
	case "open":
		return "warn"
	case "void":
		return "void"
	default:
		return ""
	}
}

// keepNumbersWhole swaps a hyphen between two digits for a non-breaking one,
// so a phone number in the shop's header ("091-1234567") never splits across
// lines on a narrow screen.
func keepNumbersWhole(text string) string {
	runes := []rune(text)
	for i := 1; i+1 < len(runes); i++ {
		if runes[i] == '-' && unicode.IsDigit(runes[i-1]) && unicode.IsDigit(runes[i+1]) {
			runes[i] = '\u2011'
		}
	}
	return string(runes)
}

// publicInvoiceDateTime prints the issue time as the receipt does
// ("2026/10/12 14:32"), in the offset the shop sent — its own wall clock.
func publicInvoiceDateTime(raw string) string {
	raw = strings.TrimSpace(raw)
	parsed, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil {
		return raw
	}
	return parsed.Format("2006/01/02 15:04")
}

// publicInvoiceQuantity prints "6" for the 6.0 the backend sends and "1.25"
// as it is.
func publicInvoiceQuantity(quantity json.Number) string {
	text := strings.TrimSpace(quantity.String())
	if text == "" {
		return "1"
	}
	if strings.Contains(text, ".") && !strings.ContainsAny(text, "eE") {
		text = strings.TrimRight(strings.TrimRight(text, "0"), ".")
	}
	return text
}

// publicInvoiceDiscounts splits the order's discount into the rules' and
// coupons' part and the cashier's extra discount, each "" when there is none.
func publicInvoiceDiscounts(discountTotal string, extraAmount string) (string, string) {
	total, ok := new(big.Rat).SetString(strings.TrimSpace(discountTotal))
	if !ok {
		total = new(big.Rat)
	}
	extra, ok := new(big.Rat).SetString(strings.TrimSpace(extraAmount))
	if !ok || extra.Sign() < 0 {
		extra = new(big.Rat)
	}
	if extra.Cmp(total) > 0 {
		extra = new(big.Rat).Set(total)
	}
	rules := new(big.Rat).Sub(total, extra)
	return publicInvoiceMoney(rules), publicInvoiceMoney(extra)
}

func publicInvoiceMoney(amount *big.Rat) string {
	if amount.Sign() <= 0 {
		return ""
	}
	return amount.FloatString(2)
}

func publicInvoiceLineViewDataList(
	lines []publicInvoiceLinePayload,
) []publicInvoiceLineViewData {
	rendered := make([]publicInvoiceLineViewData, 0, len(lines))
	for _, line := range lines {
		name := strings.TrimSpace(line.VariantName)
		if name == "" {
			name = strings.TrimSpace(line.ProductName)
		}
		rendered = append(rendered, publicInvoiceLineViewData{
			publicInvoiceLinePayload: line,
			DisplayName:              name,
			QuantityLabel:            publicInvoiceQuantity(line.Quantity),
			ModifiersLabel:           publicInvoiceModifiersLabel(line.Modifiers),
			IdentifierRows:           publicInvoiceIdentifierRows(line.Identifiers),
		})
	}
	return rendered
}

// publicInvoiceModifiersLabel reads "إضافات: جبنة ×2 (2.00)، بدون بصل".
func publicInvoiceModifiersLabel(modifiers []publicInvoiceModifierPayload) string {
	parts := make([]string, 0, len(modifiers))
	for _, modifier := range modifiers {
		name := strings.TrimSpace(modifier.Name)
		if name == "" {
			continue
		}
		if modifier.Quantity > 1 {
			name += " ×" + strconv.Itoa(modifier.Quantity)
		}
		if delta, ok := new(big.Rat).SetString(strings.TrimSpace(modifier.PriceDelta)); ok && delta.Sign() != 0 {
			// No "+": under an «إضافات» heading the amount is plainly added,
			// and a sign beside Latin digits flips side in an RTL line.
			amount := new(big.Rat).Abs(delta).FloatString(2)
			if delta.Sign() < 0 {
				amount = "خصم " + amount
			}
			name += " (" + amount + ")"
		}
		parts = append(parts, name)
	}
	if len(parts) == 0 {
		return ""
	}
	return "إضافات: " + strings.Join(parts, "، ")
}

// publicInvoiceIdentifierRows mirrors the printed receipt: a handset's serial
// and its warranty date, a lot's code and expiry month.
func publicInvoiceIdentifierRows(
	identifiers []publicInvoiceIdentifierPayload,
) []publicInvoiceIdentifierRow {
	rows := make([]publicInvoiceIdentifierRow, 0, len(identifiers))
	for _, identifier := range identifiers {
		code := strings.TrimSpace(identifier.Code)
		expiry := strings.TrimSpace(identifier.ExpiryDate)
		if code == "" && expiry == "" {
			continue
		}
		isUnit := identifier.Kind == "unit"
		row := publicInvoiceIdentifierRow{Code: code}
		if !isUnit && code != "" {
			row.Prefix = "دفعة:"
		}
		if expiry != "" {
			row.Suffix = "صلاحية حتى " + publicInvoiceExpiryMonth(expiry)
		}
		rows = append(rows, row)
		if warranty := strings.TrimSpace(identifier.WarrantyExpiresOn); isUnit && warranty != "" {
			rows = append(rows, publicInvoiceIdentifierRow{
				Prefix: "ضمان حتى",
				Code:   strings.ReplaceAll(publicInvoiceDay(warranty), "-", "/"),
			})
		}
	}
	return rows
}

func publicInvoiceDay(isoDate string) string {
	if len(isoDate) >= 10 {
		return isoDate[:10]
	}
	return isoDate
}

// publicInvoiceExpiryMonth prints 2027-08-31 as 08/2027, as the foil does.
func publicInvoiceExpiryMonth(isoDate string) string {
	parts := strings.Split(publicInvoiceDay(isoDate), "-")
	if len(parts) < 2 {
		return isoDate
	}
	return parts[1] + "/" + parts[0]
}
