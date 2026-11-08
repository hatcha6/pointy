package relay

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"pointy/relay/internal/alerts"
	"pointy/relay/internal/control"
	"pointy/relay/internal/fcm"
	"pointy/relay/internal/ratelimit"
)

// A customer reporting a problem with an order, and an operator answering it.
//
//	POST /v1/customers/orders/{id}/report               {reason, note} (Bearer)
//	GET  /v1/customers/admin/reports?status=&limit=
//	POST /v1/customers/admin/reports/{id}/resolve       {reply}
//
// An order the customer reads (GET /v1/customers/orders/{id}) carries its
// latest report. Filing one alerts the operators (ntfy); resolving one tells
// the customer's phones, with the reply on the order.

// customerReportReasonNames are the reasons as an operator's alert reads them.
var customerReportReasonNames = map[string]string{
	control.CustomerReportNotArrived:   "لم يصل",
	control.CustomerReportWrongAccount: "حساب خاطئ",
	control.CustomerReportWrongAmount:  "كمية خاطئة",
	control.CustomerReportOther:        "مشكلة أخرى",
}

type customerReportRequest struct {
	Reason string `json:"reason"`
	Note   string `json:"note"`
}

// handleCustomerOrderReport serves POST /v1/customers/orders/{id}/report. An
// order still waiting for its payment has nothing to report yet.
func (s HTTPServer) handleCustomerOrderReport(w http.ResponseWriter, r *http.Request, customer control.Customer, id string) {
	orders, ok := s.Store.(control.CustomerOrderStore)
	reports, hasReports := s.Store.(control.CustomerOrderReportStore)
	if !ok || !hasReports {
		writeCustomerError(w, http.StatusServiceUnavailable, "reports_unavailable", "this relay takes no reports", nil)
		return
	}
	var request customerReportRequest
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	order, ok := s.ownCustomerOrder(w, r, orders, customer, id)
	if !ok {
		return
	}
	if !control.CustomerReportReasons[strings.TrimSpace(request.Reason)] {
		writeCustomerError(w, http.StatusBadRequest, "invalid_reason", "choose what went wrong", nil)
		return
	}
	if order.Status == control.CustomerOrderAwaitingPayment || order.Status == control.CustomerOrderCancelled {
		writeCustomerError(w, http.StatusConflict, "nothing_to_report", "this order was never paid", nil)
		return
	}
	if s.limitCustomer(w, r, "report-"+customer.ID, customerReportRateLimit) {
		return
	}
	report, created, err := reports.ReportCustomerOrder(r.Context(), control.CustomerOrderReport{
		OrderID: order.ID, CustomerID: customer.ID, Reason: request.Reason, Note: request.Note,
	})
	if err != nil {
		s.customerInternalError(w, "filing a customer report failed", err)
		return
	}
	if created {
		s.logger().Info("customer reported an order", "order_id", order.ID, "report_id", report.ID, "reason", report.Reason)
		s.alertCustomerReport(order, report)
	}
	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	writeJSON(w, status, map[string]any{"report": customerReportView(report)})
}

// customerReportView is a report as its customer sees it: never who resolved it.
func customerReportView(report control.CustomerOrderReport) map[string]any {
	view := map[string]any{
		"id":         report.ID,
		"reason":     report.Reason,
		"note":       report.Note,
		"status":     report.Status,
		"created_at": report.CreatedAt,
	}
	if report.Status == control.CustomerReportResolved {
		view["reply"] = report.Reply
		view["resolved_at"] = report.ResolvedAt
	}
	return view
}

// latestCustomerReport is an order's newest report, or nil.
func (s HTTPServer) latestCustomerReport(ctx context.Context, orderID string) map[string]any {
	reports, ok := s.Store.(control.CustomerOrderReportStore)
	if !ok {
		return nil
	}
	list, err := reports.CustomerOrderReports(ctx, orderID)
	if err != nil || len(list) == 0 {
		return nil
	}
	return customerReportView(list[0])
}

// alertCustomerReport tells the operators a customer reported an order.
func (s HTTPServer) alertCustomerReport(order control.CustomerOrder, report control.CustomerOrderReport) {
	if s.Alerts == nil {
		return
	}
	body := order.ItemName
	if account := customerAccountLine(order.Account); account != "" {
		body += " → " + account
	}
	if report.Note != "" {
		body += "\n«" + report.Note + "»"
	}
	s.Alerts.Send(alerts.Message{
		Title:    "بلاغ من زبون: " + customerReportReasonNames[report.Reason],
		Body:     body,
		Priority: 4,
		Tags:     []string{"rotating_light"},
		Click:    "/cards/reports?report=" + report.ID,
	})
}

// customerReportRateLimit bounds one customer's reports: one per order is
// open at a time, and this stops a flood across many.
var customerReportRateLimit = ratelimit.Policy{Limit: 10, Window: time.Hour}

// --- the operator ---------------------------------------------------------

func (s HTTPServer) handleCustomerAdminReports(w http.ResponseWriter, r *http.Request, store customerAdminStore) {
	reports, ok := s.Store.(control.CustomerOrderReportStore)
	if !ok {
		writeJSON(w, http.StatusOK, map[string]any{"reports": []any{}})
		return
	}
	query := r.URL.Query()
	list, err := reports.ListCustomerOrderReports(r.Context(), control.CustomerOrderReportFilter{
		Status: query.Get("status"),
		Limit:  queryInt(query, "limit", 200, 500),
	})
	if err != nil {
		s.customerInternalError(w, "customer reports failed", err)
		return
	}
	views := make([]map[string]any, 0, len(list))
	for _, report := range list {
		views = append(views, s.customerReportAdminView(r.Context(), store, report))
	}
	writeJSON(w, http.StatusOK, map[string]any{"reports": views})
}

// customerReportAdminView is a report with its order beside it, so the
// operator sees what was bought, for which account, and how it ended.
func (s HTTPServer) customerReportAdminView(ctx context.Context, store customerAdminStore, report control.CustomerOrderReport) map[string]any {
	view := map[string]any{"report": report}
	if order, err := store.GetCustomerOrder(ctx, report.OrderID); err == nil {
		view["order"] = withPhones(ctx, store, []control.CustomerOrder{order})[0]
	}
	return view
}

type customerReportResolveRequest struct {
	Reply string `json:"reply"`
	Actor string `json:"actor"`
}

func (s HTTPServer) handleCustomerAdminResolveReport(w http.ResponseWriter, r *http.Request, store customerAdminStore, id string) {
	reports, ok := s.Store.(control.CustomerOrderReportStore)
	if !ok {
		writeNotFound(w)
		return
	}
	var request customerReportResolveRequest
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	report, resolved, err := reports.ResolveCustomerOrderReport(r.Context(), id, request.Reply, adminActor(r, request.Actor))
	if errors.Is(err, control.ErrCustomerOrderReportNotFound) {
		writeCustomerError(w, http.StatusNotFound, "report_not_found", "no such report", nil)
		return
	}
	if err != nil {
		s.customerInternalError(w, "resolving a customer report failed", err)
		return
	}
	if resolved {
		s.logger().Info("operator resolved a customer report", "report_id", report.ID, "order_id", report.OrderID,
			"actor", report.ResolvedBy)
		s.tellCustomerReportResolved(r.Context(), store, report)
	}
	writeJSON(w, http.StatusOK, s.customerReportAdminView(r.Context(), store, report))
}

// tellCustomerReportResolved lets the customer know their report was looked
// at; tapping it opens the order, where the reply is.
func (s HTTPServer) tellCustomerReportResolved(ctx context.Context, store customerAdminStore, report control.CustomerOrderReport) {
	if s.CustomerPush == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), customerOrderPushBudget)
	defer cancel()
	sessions, err := store.CustomerSessions(ctx, report.CustomerID)
	if err != nil {
		s.logger().Warn("telling a customer about their report: sessions unreadable", "report_id", report.ID, "error", err)
		return
	}
	body := "راجعنا بلاغك عن طلبك."
	if report.Reply != "" {
		body = report.Reply
	}
	var record control.CustomerNotification
	s.pushToDevices(ctx, store, sessions, fcm.Message{
		Title: "ردّنا على بلاغك",
		Body:  body,
		Link:  customerOrderLink(report.OrderID),
		Order: report.OrderID,
	}, &record)
}

// forgetCustomerReports removes a deleted customer's reports.
func (s HTTPServer) forgetCustomerReports(ctx context.Context, customerID string) {
	reports, ok := s.Store.(control.CustomerOrderReportStore)
	if !ok {
		return
	}
	if err := reports.ForgetCustomerOrderReports(ctx, customerID); err != nil {
		s.logger().Warn("forgetting a deleted customer's reports failed", "customer_id", customerID, "error", err)
	}
}
