import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/employee.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';
import 'package:pointy_frontend/src/features/employees/views/employee_loan_review_actions.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

const _loan = EmployeeLoan(
  id: 4,
  employeeId: 1,
  status: EmployeeLoanStatus.requested,
  amount: 300,
  monthlyDeduction: 50,
  outstandingBalance: 0,
  deductedAmount: 0,
  employeeName: 'سالم',
);

void main() {
  testWidgets('approving a loan asks first and names the monthly deduction', (
    tester,
  ) async {
    var approvals = 0;
    await _pumpActions(
      tester,
      onApprove: (_) async {
        approvals++;
        return null;
      },
    );

    await tester.tap(find.byKey(const ValueKey('loan_approve_4')));
    await tester.pumpAndSettle();

    // The decision has not been sent yet, and the question carries the two
    // numbers a manager needs to catch a wrong request.
    expect(approvals, 0);
    expect(find.text('الموافقة على السلفة؟'), findsOneWidget);
    expect(find.textContaining('سالم'), findsOneWidget);
    expect(find.textContaining('300'), findsOneWidget);
    expect(find.textContaining('50'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('loan_approve_confirm')));
    await tester.pumpAndSettle();
    expect(approvals, 1);
  });

  testWidgets('approving says where the money comes from', (tester) async {
    final sources = <LoanDisbursement>[];
    await _pumpActions(
      tester,
      onApprove: (disbursement) async {
        sources.add(disbursement);
        return null;
      },
    );

    await tester.tap(find.byKey(const ValueKey('loan_approve_4')));
    await tester.pumpAndSettle();
    // The cash box unless told otherwise.
    await tester.tap(find.byKey(const ValueKey('loan_source_drawer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('loan_approve_confirm')));
    await tester.pumpAndSettle();

    expect(sources.single.source, LoanDisbursementSource.drawer);
    expect(sources.single.toJson(), {
      'disbursement_method': 'cash',
      'pay_from_register': true,
    });
    // Closed once approved.
    expect(find.byKey(const ValueKey('loan_approve_confirm')), findsNothing);
  });

  testWidgets('a refusal is said in the dialog, which stays open', (
    tester,
  ) async {
    await _pumpActions(
      tester,
      onApprove: (_) async => PosApiException(
        message: 'refused',
        statusCode: 400,
        responseBody: '{"code": "register_session_required"}',
      ),
    );

    await tester.tap(find.byKey(const ValueKey('loan_approve_4')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('loan_source_drawer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('loan_approve_confirm')));
    await tester.pumpAndSettle();

    expect(
      find.text('افتح وردية أولًا، أو اصرف السلفة من الخزينة.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('loan_approve_confirm')), findsOneWidget);
  });

  testWidgets('dismissing the approval question sends nothing', (tester) async {
    var approvals = 0;
    await _pumpActions(
      tester,
      onApprove: (_) async {
        approvals++;
        return null;
      },
    );

    await tester.tap(find.byKey(const ValueKey('loan_approve_4')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إلغاء'));
    await tester.pumpAndSettle();

    expect(approvals, 0);
  });

  testWidgets('rejecting a loan asks first and says it cannot be undone', (
    tester,
  ) async {
    var rejections = 0;
    await _pumpActions(tester, onReject: () => rejections++);

    await tester.tap(find.byKey(const ValueKey('loan_reject_4')));
    await tester.pumpAndSettle();

    expect(rejections, 0);
    expect(find.text('رفض طلب السلفة؟'), findsOneWidget);
    expect(find.textContaining('لا يمكن التراجع'), findsOneWidget);

    await tester.tap(find.text('رفض').last);
    await tester.pumpAndSettle();
    expect(rejections, 1);
  });

  testWidgets('dismissing the rejection question sends nothing', (
    tester,
  ) async {
    var rejections = 0;
    await _pumpActions(tester, onReject: () => rejections++);

    await tester.tap(find.byKey(const ValueKey('loan_reject_4')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إلغاء'));
    await tester.pumpAndSettle();

    expect(rejections, 0);
  });

  testWidgets('both decisions are blocked while a payroll write is in flight', (
    tester,
  ) async {
    await _pumpActions(tester, isSaving: true);

    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('loan_approve_4')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('loan_reject_4')))
          .onPressed,
      isNull,
    );
  });
}

Future<void> _pumpActions(
  WidgetTester tester, {
  bool isSaving = false,
  Future<Exception?> Function(LoanDisbursement disbursement)? onApprove,
  VoidCallback? onReject,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Material(
          child: Center(
            child: EmployeeLoanReviewActions(
              loan: _loan,
              isSaving: isSaving,
              onApprove: onApprove ?? (_) async => null,
              onReject: onReject ?? () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
