import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/print_job.dart';
import '../../../data/models/register_cash_movement.dart';
import '../../../data/models/register_cash_movement_page.dart';
import '../../../data/models/register_session.dart';
import '../../../data/models/register_session_page.dart';
import '../../../data/models/register_session_summary.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/models/sale_order_page.dart';
import '../../../data/models/shop_settings.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/register_session_repository.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../pdf/z_report_pdf.dart';

class RegisterSessionHistoryViewModel extends ChangeNotifier {
  RegisterSessionHistoryViewModel(
    this._registerSessionRepository,
    this._saleRepository, {
    required PrintingRepository printingRepository,
    required ShopSettingsRepository shopSettingsRepository,
    RegisterZReportPdfService pdfService = const RegisterZReportPdfService(),
    AnalyticsEngine? analyticsEngine,
  }) : _printingRepository = printingRepository,
       _shopSettingsRepository = shopSettingsRepository,
       _pdfService = pdfService,
       _analyticsEngine = analyticsEngine {
    loadSessions();
  }

  final RegisterSessionRepository _registerSessionRepository;
  final SaleRepository _saleRepository;
  final PrintingRepository _printingRepository;
  final ShopSettingsRepository _shopSettingsRepository;
  final RegisterZReportPdfService _pdfService;
  final AnalyticsEngine? _analyticsEngine;
  bool _isPrintingZReport = false;

  /// Set when building or sending the Z-Report threw, so the screen can say so
  /// instead of silently doing nothing.
  bool _hasZReportError = false;
  bool get hasZReportError => _hasZReportError;

  List<RegisterSession> _sessions = [];

  /// A session reached by deep link (from an invoice's "جلسة الدرج" row) rather
  /// than by scrolling the history. It is kept at the head of the list through
  /// every reload, because it is usually older than the first page and would
  /// otherwise vanish — taking the selection with it — the moment the history
  /// refreshed underneath the reviewer.
  RegisterSession? _pinnedSession;
  List<SaleOrder> _orders = [];
  List<RegisterCashMovement> _cashMovements = [];
  RegisterSession? _selectedSession;
  RegisterSessionSummary? _selectedSummary;
  SaleOrderQuery _orderQuery = const SaleOrderQuery();
  bool _isLoadingSessions = false;
  bool _isLoadingMoreSessions = false;
  bool _isLoadingOrders = false;
  bool _isLoadingMoreOrders = false;
  bool _isLoadingCashMovements = false;
  bool _isLoadingMoreCashMovements = false;
  bool _isLoadingSummary = false;
  bool _hasSessionLoadError = false;
  bool _hasOrderLoadError = false;
  bool _hasCashMovementLoadError = false;
  bool _hasSummaryLoadError = false;
  bool _hasMoreSessions = true;
  bool _hasMoreOrders = false;
  bool _hasMoreCashMovements = false;
  // Keyset cursors, not page numbers: these three feeds are written to while
  // they are being read (a shift keeps selling, a drawer opens mid-scroll), and
  // an offset page would re-serve the boundary rows while silently dropping
  // everything recorded since the previous page. Null = start from the top.
  String? _nextSessionCursor;
  String? _nextOrderCursor;
  String? _nextCashMovementCursor;

  List<RegisterSession> get sessions => List.unmodifiable(_sessions);
  List<SaleOrder> get orders => List.unmodifiable(_orders);
  List<RegisterCashMovement> get cashMovements =>
      List.unmodifiable(_cashMovements);
  RegisterSession? get selectedSession => _selectedSession;
  RegisterSessionSummary? get selectedSummary => _selectedSummary;
  SaleOrderQuery get orderQuery => _orderQuery;
  bool get isLoadingSessions => _isLoadingSessions;
  bool get isLoadingMoreSessions => _isLoadingMoreSessions;
  bool get isLoadingOrders => _isLoadingOrders;
  bool get isLoadingMoreOrders => _isLoadingMoreOrders;
  bool get isLoadingCashMovements => _isLoadingCashMovements;
  bool get isLoadingMoreCashMovements => _isLoadingMoreCashMovements;
  bool get isLoadingSummary => _isLoadingSummary;
  bool get isPrintingZReport => _isPrintingZReport;
  bool get canPrintZReport => _selectedSummary != null && !_isPrintingZReport;
  bool get hasSessionLoadError => _hasSessionLoadError;
  bool get hasOrderLoadError => _hasOrderLoadError;
  bool get hasCashMovementLoadError => _hasCashMovementLoadError;
  bool get hasSummaryLoadError => _hasSummaryLoadError;
  bool get hasMoreSessions => _hasMoreSessions;
  bool get hasMoreOrders => _hasMoreOrders;
  bool get hasMoreCashMovements => _hasMoreCashMovements;

  Future<void> loadSessions() async {
    // Held so the trailing selection refresh below can tell "the shift on
    // screen when this refresh began" from "a shift selected while it was in
    // flight" — a deep link arriving mid-load has already fetched its own
    // detail, and refreshing it again costs three more requests.
    final selectedAtStart = _selectedSession;
    _isLoadingSessions = true;
    _hasSessionLoadError = false;
    _hasMoreSessions = true;
    _nextSessionCursor = null;
    notifyListeners();

    final result = await _registerSessionRepository.loadSessionHistory();
    switch (result) {
      case Ok<RegisterSessionPage>():
        _sessions = _withPinnedSession(result.value.sessions);
        _nextSessionCursor = result.value.nextCursor;
        // "More" means "there is a cursor to ask with". Trusting a bare `next`
        // would spin forever against a page that cannot be advanced.
        _hasMoreSessions = _nextSessionCursor != null;
        if (_selectedSession != null &&
            !_sessions.any((session) => session.id == _selectedSession!.id)) {
          _selectedSession = null;
          _selectedSummary = null;
          _orders = [];
          _cashMovements = [];
          _hasMoreOrders = false;
          _hasMoreCashMovements = false;
          _nextOrderCursor = null;
          _nextCashMovementCursor = null;
        }
      case Error<RegisterSessionPage>():
        _sessions = _withPinnedSession(const []);
        _selectedSession = null;
        _selectedSummary = null;
        _orders = [];
        _cashMovements = [];
        _hasMoreOrders = false;
        _hasMoreCashMovements = false;
        _nextOrderCursor = null;
        _nextCashMovementCursor = null;
        _hasSessionLoadError = true;
        _hasMoreSessions = false;
    }

    _isLoadingSessions = false;
    notifyListeners();

    // Refresh means refresh: the detail pane is showing the same shift the list
    // just re-read, and on an open drawer its sales and totals have moved on.
    // Only that shift, though — a selection made *during* this load (the
    // drawer-session deep link, which runs alongside the constructor's load)
    // has just fetched orders, movements and the summary for itself, and
    // re-fetching all three is pure waste on the slow link where the orderings
    // actually diverge.
    final selected = _selectedSession;
    if (selected != null && identical(selected, selectedAtStart)) {
      await _reloadSelectedSessionDetail(selected);
    }
  }

  Future<void> loadMoreSessions() async {
    if (_isLoadingSessions || _isLoadingMoreSessions || !_hasMoreSessions) {
      return;
    }

    _isLoadingMoreSessions = true;
    notifyListeners();

    final cursor = _nextSessionCursor;
    final result = await _registerSessionRepository.loadSessionHistory(
      cursor: cursor,
    );
    switch (result) {
      case Ok<RegisterSessionPage>():
        _sessions = _appendById(
          _sessions,
          result.value.sessions,
          (session) => session.id,
        );
        _nextSessionCursor = result.value.nextCursor;
        _hasMoreSessions = _nextSessionCursor != null;
      case Error<RegisterSessionPage>():
        _hasSessionLoadError = true;
        _hasMoreSessions = false;
    }

    _isLoadingMoreSessions = false;
    notifyListeners();
  }

  List<RegisterSession> _withPinnedSession(List<RegisterSession> sessions) {
    final pinned = _pinnedSession;
    if (pinned == null || sessions.any((session) => session.id == pinned.id)) {
      return sessions;
    }
    return [pinned, ...sessions];
  }

  /// Selects the session with [sessionId], fetching it when it is not in the
  /// history already. Returns false when it cannot be loaded (deleted, or out
  /// of this user's scope), so the caller can say so instead of opening an
  /// empty screen.
  Future<bool> focusSession(int sessionId) async {
    final loaded = _sessions.where((session) => session.id == sessionId);
    if (loaded.isNotEmpty) {
      _pinnedSession = loaded.first;
      await selectSession(loaded.first);
      return true;
    }

    final result = await _registerSessionRepository.loadSession(sessionId);
    switch (result) {
      case Ok<RegisterSession>(value: final session):
        // Pin before selecting: an in-flight `loadSessions` (the constructor
        // fires one) may land either side of this and would otherwise replace
        // the list with a first page that does not contain this shift.
        _pinnedSession = session;
        _sessions = _withPinnedSession(_sessions);
        await selectSession(session);
        return true;
      case Error<RegisterSession>():
        return false;
    }
  }

  Future<void> selectSession(RegisterSession session) async {
    // Re-tapping the session on screen REFETCHES it. An open drawer keeps
    // selling while it is being reviewed, so the sales, cash movements and
    // summary already on screen go stale within seconds — returning early here
    // left the reviewer looking at a shift that had moved on. The only thing
    // skipped is a tap that lands while the same session is already loading.
    if (_selectedSession?.id == session.id && _isLoadingOrders) {
      return;
    }

    _selectedSession = session;
    _selectedSummary = null;
    _trackSessionSelected(session);
    _orders = [];
    _cashMovements = [];
    _isLoadingOrders = true;
    _isLoadingMoreOrders = false;
    _isLoadingCashMovements = true;
    _isLoadingMoreCashMovements = false;
    _isLoadingSummary = true;
    _hasOrderLoadError = false;
    _hasCashMovementLoadError = false;
    _hasSummaryLoadError = false;
    _hasMoreOrders = true;
    _hasMoreCashMovements = true;
    _nextOrderCursor = null;
    _nextCashMovementCursor = null;
    notifyListeners();

    // Load the summary concurrently with orders/movements — it backs the first
    // (manager) tab, so we don't want it queued behind the paginated lists.
    final summaryFuture = _loadSummary(session.id);

    final result = await _saleRepository.loadOrdersForSession(
      session.id,
      query: _orderQuery,
    );
    switch (result) {
      case Ok<SaleOrderPage>():
        _orders = result.value.orders;
        _nextOrderCursor = result.value.nextCursor;
        _hasMoreOrders = _nextOrderCursor != null;
      case Error<SaleOrderPage>():
        _orders = [];
        _hasOrderLoadError = true;
        _hasMoreOrders = false;
    }

    _isLoadingOrders = false;
    notifyListeners();

    final movementResult = await _registerSessionRepository
        .loadCashMovementsForSession(session.id);
    switch (movementResult) {
      case Ok<RegisterCashMovementPage>():
        _cashMovements = movementResult.value.movements;
        _nextCashMovementCursor = movementResult.value.nextCursor;
        _hasMoreCashMovements = _nextCashMovementCursor != null;
      case Error<RegisterCashMovementPage>():
        _cashMovements = [];
        _hasCashMovementLoadError = true;
        _hasMoreCashMovements = false;
    }

    _isLoadingCashMovements = false;
    notifyListeners();

    await summaryFuture;
  }

  Future<void> _loadSummary(int sessionId) async {
    _isLoadingSummary = true;
    _hasSummaryLoadError = false;
    notifyListeners();

    final result = await _registerSessionRepository.loadSessionSummary(
      sessionId,
    );
    // The user may have switched sessions while this was in flight; ignore a
    // stale response so it never overwrites the now-selected session.
    if (_selectedSession?.id != sessionId) {
      return;
    }
    switch (result) {
      case Ok<RegisterSessionSummary>():
        _selectedSummary = result.value;
      case Error<RegisterSessionSummary>():
        _selectedSummary = null;
        _hasSummaryLoadError = true;
    }

    _isLoadingSummary = false;
    notifyListeners();
  }

  /// Re-fetch the summary for the selected session (after a refund, or to retry
  /// a failed load). No-op when nothing is selected.
  Future<void> refreshSelectedSummary() async {
    final session = _selectedSession;
    if (session == null) {
      return;
    }
    await _loadSummary(session.id);
  }

  /// Prints the thermal Z-Report (drawer copy) on the POS receipt printer.
  Future<bool> printZReportThermal() async {
    return _runZReport('thermal', (summary, shopSettings, logoBytes) async {
      final result = await _printingRepository.printRegisterZReport(
        summary: summary,
        shopSettings: shopSettings,
        shopLogoBytes: logoBytes,
      );
      return result.isSuccess;
    });
  }

  /// Opens the system print dialog for the A4 PDF Z-Report.
  Future<bool> printZReportPdf() async {
    return _runZReport('pdf_print', (summary, shopSettings, logoBytes) {
      return _pdfService.printZReport(
        summary: summary,
        shopSettings: shopSettings,
        shopLogoBytes: logoBytes,
      );
    });
  }

  /// Shares/saves the A4 PDF Z-Report through the OS share sheet.
  Future<bool> shareZReportPdf() async {
    return _runZReport('pdf_share', (summary, shopSettings, logoBytes) {
      return _pdfService.shareZReport(
        summary: summary,
        shopSettings: shopSettings,
        shopLogoBytes: logoBytes,
      );
    });
  }

  Future<bool> _runZReport(
    String format,
    Future<bool> Function(
      RegisterSessionSummary summary,
      ShopSettings? shopSettings,
      Uint8List? logoBytes,
    )
    action,
  ) async {
    final summary = _selectedSummary;
    if (summary == null || _isPrintingZReport) {
      return false;
    }
    _isPrintingZReport = true;
    _hasZReportError = false;
    notifyListeners();
    try {
      final shopSettings = await _loadShopSettings();
      final logoBytes = await _loadShopLogoBytes(shopSettings);
      final delivered = await action(summary, shopSettings, logoBytes);
      _trackZReportDelivered(summary, format: format, delivered: delivered);
      return delivered;
    } catch (error, stackTrace) {
      // PDF layout can throw on text the shaper cannot handle: the bidi
      // package raised a RangeError composing certain Arabic sequences, four
      // times in the field, and it escaped as an unhandled crash from a button
      // press. What the text was is not recorded anywhere, so this reports the
      // failure *with the session it came from* — enough to reproduce it —
      // and returns false so the cashier gets "it did not print" instead of a
      // crash.
      _hasZReportError = true;
      unawaited(
        _analyticsEngine?.captureError(
              error,
              stackTrace,
              name: AnalyticsEventName.appPlatformError,
              attributes: {
                'operation': 'z_report',
                'format': format,
                'session_id': summary.sessionId.toString(),
              },
            ) ??
            Future<void>.value(),
      );
      return false;
    } finally {
      _isPrintingZReport = false;
      notifyListeners();
    }
  }

  Future<ShopSettings?> _loadShopSettings() async {
    final result = await _shopSettingsRepository.loadSettings();
    return switch (result) {
      Ok<ShopSettings>(value: final settings) => settings,
      Error<ShopSettings>() => null,
    };
  }

  Future<Uint8List?> _loadShopLogoBytes(ShopSettings? settings) async {
    final result = await _shopSettingsRepository.loadLogoBytes(settings);
    return switch (result) {
      Ok<Uint8List?>(value: final bytes) => bytes,
      Error<Uint8List?>() => null,
    };
  }

  Future<void> loadMoreOrders() async {
    final session = _selectedSession;
    if (session == null ||
        _isLoadingOrders ||
        _isLoadingMoreOrders ||
        !_hasMoreOrders) {
      return;
    }

    _isLoadingMoreOrders = true;
    notifyListeners();

    final result = await _saleRepository.loadOrdersForSession(
      session.id,
      query: _orderQuery,
      cursor: _nextOrderCursor,
    );
    switch (result) {
      case Ok<SaleOrderPage>():
        _orders = _appendById(
          _orders,
          result.value.orders,
          (order) => order.id,
        );
        _nextOrderCursor = result.value.nextCursor;
        _hasMoreOrders = _nextOrderCursor != null;
      case Error<SaleOrderPage>():
        _hasOrderLoadError = true;
        _hasMoreOrders = false;
    }

    _isLoadingMoreOrders = false;
    notifyListeners();
  }

  Future<void> filterOrdersByCustomer(Customer? customer) async {
    final nextQuery = _orderQuery.withCustomer(
      id: customer?.id,
      name: customer?.fullName,
    );
    if (nextQuery.customerId == _orderQuery.customerId) {
      return;
    }
    _orderQuery = nextQuery;
    final session = _selectedSession;
    if (session == null) {
      notifyListeners();
      return;
    }
    await _reloadOrdersForSelectedSession(session);
  }

  /// Re-reads everything the detail pane renders for [session] — its sales, its
  /// cash movements and the summary the totals and Z-Report come from.
  Future<void> _reloadSelectedSessionDetail(RegisterSession session) async {
    _resetCashMovements();

    final summaryFuture = _loadSummary(session.id);
    await _reloadOrdersForSelectedSession(session);
    await _fetchCashMovementsForSelectedSession(session);

    await summaryFuture;
  }

  /// Re-fetch the selected session's sales (to retry a failed load). No-op when
  /// nothing is selected.
  Future<void> retrySelectedSessionOrders() async {
    final session = _selectedSession;
    if (session == null) {
      return;
    }
    await _reloadOrdersForSelectedSession(session);
  }

  /// Re-fetch the selected session's cash movements (to retry a failed load).
  /// No-op when nothing is selected.
  Future<void> retrySelectedSessionCashMovements() async {
    final session = _selectedSession;
    if (session == null) {
      return;
    }
    _resetCashMovements();
    notifyListeners();
    await _fetchCashMovementsForSelectedSession(session);
  }

  void _resetCashMovements() {
    _cashMovements = [];
    _isLoadingCashMovements = true;
    _isLoadingMoreCashMovements = false;
    _hasCashMovementLoadError = false;
    _hasMoreCashMovements = true;
    _nextCashMovementCursor = null;
  }

  Future<void> _fetchCashMovementsForSelectedSession(
    RegisterSession session,
  ) async {
    final movementResult = await _registerSessionRepository
        .loadCashMovementsForSession(session.id);
    // The reviewer may have moved to another shift while this was in flight;
    // drop the stale page rather than painting it over the new selection.
    if (_selectedSession?.id != session.id) {
      _isLoadingCashMovements = false;
      return;
    }
    switch (movementResult) {
      case Ok<RegisterCashMovementPage>():
        _cashMovements = movementResult.value.movements;
        _nextCashMovementCursor = movementResult.value.nextCursor;
        _hasMoreCashMovements = _nextCashMovementCursor != null;
      case Error<RegisterCashMovementPage>():
        _cashMovements = [];
        _hasCashMovementLoadError = true;
        _hasMoreCashMovements = false;
    }
    _isLoadingCashMovements = false;
    notifyListeners();
  }

  /// The full document behind a row in the session's sales strip. The strip
  /// serializes summaries (a line COUNT, no line items), so the details sheet
  /// has to fetch before it can show products or offer a return.
  Future<SaleOrder?> loadOrderDetail(int orderId) async {
    final result = await _saleRepository.loadOrder(orderId);
    return switch (result) {
      Ok<SaleOrder>(value: final order) => order,
      Error<SaleOrder>() => null,
    };
  }

  Future<void> _reloadOrdersForSelectedSession(RegisterSession session) async {
    _orders = [];
    _isLoadingOrders = true;
    _isLoadingMoreOrders = false;
    _hasOrderLoadError = false;
    _hasMoreOrders = true;
    _nextOrderCursor = null;
    notifyListeners();

    final result = await _saleRepository.loadOrdersForSession(
      session.id,
      query: _orderQuery,
    );
    switch (result) {
      case Ok<SaleOrderPage>():
        _orders = result.value.orders;
        _nextOrderCursor = result.value.nextCursor;
        _hasMoreOrders = _nextOrderCursor != null;
      case Error<SaleOrderPage>():
        _orders = [];
        _hasOrderLoadError = true;
        _hasMoreOrders = false;
    }

    _isLoadingOrders = false;
    notifyListeners();
  }

  Future<void> loadMoreCashMovements() async {
    final session = _selectedSession;
    if (session == null ||
        _isLoadingCashMovements ||
        _isLoadingMoreCashMovements ||
        !_hasMoreCashMovements) {
      return;
    }

    _isLoadingMoreCashMovements = true;
    notifyListeners();

    final result = await _registerSessionRepository.loadCashMovementsForSession(
      session.id,
      cursor: _nextCashMovementCursor,
    );
    switch (result) {
      case Ok<RegisterCashMovementPage>():
        _cashMovements = _appendById(
          _cashMovements,
          result.value.movements,
          (movement) => movement.id,
        );
        _nextCashMovementCursor = result.value.nextCursor;
        _hasMoreCashMovements = _nextCashMovementCursor != null;
      case Error<RegisterCashMovementPage>():
        _hasCashMovementLoadError = true;
        _hasMoreCashMovements = false;
    }

    _isLoadingMoreCashMovements = false;
    notifyListeners();
  }

  Future<bool> requestReprint(SaleOrder order) async {
    final result = await _saleRepository.requestReprint(order.id);
    switch (result) {
      case Ok<PrintJob>(value: final printJob):
        _trackReceiptReprintQueued(order, printJob);
        return true;
      case Error<PrintJob>():
        _trackReceiptReprintFailed(order);
        return false;
    }
  }

  Future<bool> voidOrder(SaleOrder order, {String reason = ''}) async {
    final result = await _saleRepository.voidOrder(
      saleOrderId: order.id,
      draft: SaleVoidDraft(reason: reason),
    );
    return _handleOrderAdjustmentResult(
      result,
      eventName: 'sales_history.order_void.completed',
      order: order,
      reason: reason,
    );
  }

  Future<bool> returnItems(
    SaleOrder order, {
    required List<SaleReturnLineDraft> lines,
    String reason = '',
    String? consignmentAction,
  }) async {
    final result = await _saleRepository.returnItems(
      saleOrderId: order.id,
      draft: SaleReturnDraft(
        lines: lines,
        reason: reason,
        consignmentAction: consignmentAction,
      ),
    );
    return _handleOrderAdjustmentResult(
      result,
      eventName: 'sales_history.order_return.completed',
      order: order,
      reason: reason,
      metrics: {
        'returned_quantity': lines.fold<double>(
          0,
          (sum, line) => sum + line.quantity,
        ),
        'returned_line_count': lines.length,
      },
    );
  }

  bool _handleOrderAdjustmentResult(
    Result<SaleOrder> result, {
    required String eventName,
    required SaleOrder order,
    required String reason,
    Map<String, num> metrics = const {},
  }) {
    switch (result) {
      case Ok<SaleOrder>(value: final updatedOrder):
        _replaceOrder(updatedOrder);
        // A void/return changes sales, refunds and the drawer — refresh the
        // summary so the panel and any reprint reflect the new numbers.
        unawaited(refreshSelectedSummary());
        _trackOrderAdjustmentCompleted(
          eventName: eventName,
          originalOrder: order,
          updatedOrder: updatedOrder,
          reason: reason,
          metrics: metrics,
        );
        notifyListeners();
        return true;
      case Error<SaleOrder>():
        return false;
    }
  }

  /// Appends a page, dropping anything already on screen. The cursor makes a
  /// repeat impossible server-side; this keeps a retried or replayed page from
  /// showing the same sale twice regardless.
  static List<T> _appendById<T>(
    List<T> existing,
    List<T> page,
    int Function(T) idOf,
  ) {
    final seen = existing.map(idOf).toSet();
    return [
      ...existing,
      for (final item in page)
        if (seen.add(idOf(item))) item,
    ];
  }

  void _replaceOrder(SaleOrder updatedOrder) {
    _orders = [
      for (final order in _orders)
        if (order.id == updatedOrder.id) updatedOrder else order,
    ];
  }

  void _trackSessionSelected(RegisterSession session) {
    trackAuditEvent(
      _analyticsEngine,
      name: 'sales_history.session.selected',
      sessionId: 'register:${session.id}',
      entityType: 'register_session',
      entityId: session.id,
      attributes: {
        'register_session_id': session.id,
        'session_number': session.sessionNumber,
        'status': session.status,
        'source': 'register_session_history',
      },
      metrics: {
        'opening_cash': session.openingCash,
        'expected_cash': session.expectedCash,
        'denomination_total': session.denominationTotal,
      },
    );
  }

  void _trackZReportDelivered(
    RegisterSessionSummary summary, {
    required String format,
    required bool delivered,
  }) {
    trackAuditEvent(
      _analyticsEngine,
      name: delivered
          ? 'register_session.z_report.delivered'
          : 'register_session.z_report.failed',
      severity: delivered
          ? AnalyticsEventSeverity.info
          : AnalyticsEventSeverity.warning,
      sessionId: 'register:${summary.sessionId}',
      entityType: 'register_session',
      entityId: summary.sessionId,
      attributes: {
        'register_session_id': summary.sessionId,
        'session_number': summary.sessionNumber,
        'format': format,
        'source': 'register_session_history',
      },
      metrics: {
        'net_sales': summary.sales.netSales,
        'payment_total': summary.paymentTotals.net,
      },
    );
  }

  void _trackReceiptReprintQueued(SaleOrder order, PrintJob printJob) {
    trackAuditEvent(
      _analyticsEngine,
      name: 'sales.receipt.reprint.queued',
      sessionId: _orderSessionId(order),
      entityType: 'sale_order',
      entityId: order.id,
      attributes: {
        ..._orderAttributes(order),
        'print_job_id': printJob.id,
        'print_job_status': printJob.status.name,
        'source': 'sale_order_details_sheet',
      },
      metrics: {'total': order.total, 'line_count': order.lineCount},
    );
  }

  void _trackReceiptReprintFailed(SaleOrder order) {
    trackAuditEvent(
      _analyticsEngine,
      name: 'sales.receipt.reprint.failed',
      severity: AnalyticsEventSeverity.warning,
      sessionId: _orderSessionId(order),
      entityType: 'sale_order',
      entityId: order.id,
      attributes: {
        ..._orderAttributes(order),
        'source': 'sale_order_details_sheet',
      },
      metrics: {'total': order.total, 'line_count': order.lineCount},
      flushImmediately: true,
    );
  }

  void _trackOrderAdjustmentCompleted({
    required String eventName,
    required SaleOrder originalOrder,
    required SaleOrder updatedOrder,
    required String reason,
    Map<String, num> metrics = const {},
  }) {
    trackAuditEvent(
      _analyticsEngine,
      name: eventName,
      sessionId: _orderSessionId(originalOrder),
      entityType: 'sale_order',
      entityId: originalOrder.id,
      attributes: {
        ..._orderAttributes(originalOrder),
        'updated_status': updatedOrder.status,
        'reason_present': reason.trim().isNotEmpty,
        'source': 'sale_order_details_sheet',
      },
      metrics: {
        'total': originalOrder.total,
        'line_count': originalOrder.lineCount,
        ...metrics,
      },
    );
  }

  Map<String, Object?> _orderAttributes(SaleOrder order) {
    return {
      'sale_order_id': order.id,
      if (order.receiptNumber?.isNotEmpty == true)
        'receipt_number': order.receiptNumber,
      if (order.registerSession != null)
        'register_session_id': order.registerSession,
      if (order.registerSessionNumber?.isNotEmpty == true)
        'session_number': order.registerSessionNumber,
      'status': order.status,
    };
  }

  String? _orderSessionId(SaleOrder order) {
    final registerSession = order.registerSession;
    return registerSession == null ? null : 'register:$registerSession';
  }
}
