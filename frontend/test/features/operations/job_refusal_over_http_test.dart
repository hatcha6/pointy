import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/job_refusal.dart';
import 'package:pointy_frontend/src/data/models/operations_job.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/operations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/operations/view_models/job_details_view_model.dart';
import 'package:pointy_frontend/src/features/operations/views/job_details_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// The repair counter's refusals, carried the way production carries them:
/// as an HTTP 400 through the real API client.
///
/// REGRESSION (Annaseem, 2026-09-30 23:30). The job screen hands an unpaid
/// job over by letting the server refuse it with `settlement_required`, then
/// offering to invoice. But every operations call checked its response with
/// `ensureSuccess`, which threw a bare Exception and dropped the body, so the
/// refusal was never recognised: the manager got "تعذر تنفيذ العملية" twice and
/// had to go back to the board. The same loss silently disabled opening the
/// drawer in place (`register_session_required`) and the over-quote question
/// (`over_approved_price`) on the board. Every earlier test fed the refusal in
/// through a fake repository, past the client where it was lost.
void main() {
  group('a job refusal that arrives over HTTP is recognised', () {
    test('settlement_required, from a hand-over', () async {
      final repository = _repositoryAnswering400({
        'detail':
            "Invoice and settle this job before handing the customer's "
            'property back.',
        'code': 'settlement_required',
      });

      final result = await repository.transitionJob(12, toStage: 7);

      expect(
        jobRefusalFromException(_exceptionOf(result))?.kind,
        JobRefusalKind.settlementRequired,
      );
    });

    test('register_session_required, from an invoice', () async {
      final repository = _repositoryAnswering400({
        'detail': 'No open register session for this request owner.',
        'code': 'register_session_required',
      });

      final result = await repository.invoiceJob(
        12,
        const JobInvoiceDraft(laborTotal: 50, payments: []),
      );

      expect(
        jobRefusalFromException(_exceptionOf(result))?.kind,
        JobRefusalKind.registerSessionRequired,
      );
    });

    test('over_approved_price, from an invoice', () async {
      final repository = _repositoryAnswering400({
        'detail': 'The invoice is above the approved price.',
        'code': 'over_approved_price',
        'approved_price': '100.00',
        'invoice_total': '150.00',
      });

      final result = await repository.invoiceJob(
        12,
        const JobInvoiceDraft(laborTotal: 150, payments: []),
      );

      expect(
        jobRefusalFromException(_exceptionOf(result))?.kind,
        JobRefusalKind.overApprovedPrice,
      );
    });
  });

  testWidgets(
    'the job screen explains an unpaid hand-over instead of a generic error',
    (tester) async {
      var transitions = 0;
      final service = PosApiService(
        client: MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'POST' &&
              path.endsWith('/jobs/12/transition/')) {
            transitions++;
            return _json({
              'detail':
                  "Invoice and settle this job before handing the customer's "
                  'property back.',
              'code': 'settlement_required',
            }, status: 400);
          }
          if (request.method == 'GET' && path.endsWith('/jobs/12/')) {
            return _json(_unpaidJobJson);
          }
          return http.Response('', 404);
        }),
      );
      final repository = OperationsRepository(service);
      final viewModel = JobDetailsViewModel(repository, jobId: 12);
      addTearDown(viewModel.dispose);
      const user = PosUser(
        id: 1,
        username: 'manager',
        displayName: 'مدير',
        role: UserRole.manager,
        isActive: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: PointyTheme.light(),
          home: JobDetailsScreen(
            viewModel: viewModel,
            capabilities: AuthorizationCapabilities.forUser(user),
            currentUser: user,
            catalogRepository: CatalogRepository(PosApiService()),
            operationsRepository: repository,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

      await tester.tap(find.text(l10n.jobHandoverButton).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.jobHandoverConfirm));
      await tester.pumpAndSettle();

      expect(transitions, 1);
      expect(find.text(l10n.jobHandoverBlockedTitle), findsOneWidget);
      expect(find.text(l10n.jobHandoverBlockedMessage), findsOneWidget);
      expect(find.text(l10n.operationsActionError), findsNothing);
    },
  );
}

OperationsRepository _repositoryAnswering400(Map<String, Object?> body) {
  return OperationsRepository(
    PosApiService(client: MockClient((_) async => _json(body, status: 400))),
  );
}

Object _exceptionOf<T>(Result<T> result) => switch (result) {
  Error<T>(:final exception) => exception,
  Ok<T>() => fail('expected the server to refuse, but it accepted'),
};

http.Response _json(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

const Map<String, Object?> _unpaidJobJson = {
  'id': 12,
  'job_number': 'REP-12',
  'job_type': 'repair',
  'status': 'open',
  'customer_name': 'زبون',
  'settlement_state': 'not_invoiced',
  'custody_state': 'with_shop',
  'materials_total': '150.00',
  'next_stage': {
    'id': 7,
    'code': 'delivered',
    'name': 'تم التسليم',
    'display_order': 6,
    'is_terminal': true,
    'requires_settlement': true,
    'releases_custody': true,
  },
};
