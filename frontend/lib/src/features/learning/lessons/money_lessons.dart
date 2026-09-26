/// Money that moves without a sale: debts collected, suppliers paid.
///
/// These are the operations an owner most often does themselves and most often
/// forbids anyone else to touch, which is exactly why practising them matters.
library;

import '../../../core/authorization.dart';
import '../../../shared/tutor/anchors.dart';
import '../engine/lesson.dart';

/// فاطمة owes 120 from before today. Fifty of it comes back over the counter.
const moneyCollectDebtLesson = TutorLesson(
  id: 'money.collect_debt',
  title: 'تحصيل دين من زبون',
  summary: 'اقبض جزءًا من دين قديم، وشاهد الرصيد والدرج يتحركان معًا.',
  seed: SandboxSeed.groceryMorning,
  capability: AppCapability.collectCustomerDebt,
  guideId: 'money.collect_debt',
  requires: ['pos.credit_down_payment'],
  steps: [
    TutorStep(
      say: 'افتح الوردية بنقدية افتتاح 50.',
      anchor: TutorAnchor.registerOpeningCashField,
      act: TutorAct.type('50'),
      expect: TutorExpect.fieldEquals(
        TutorAnchor.registerOpeningCashField,
        '50',
      ),
      hint: 'اكتب 50 في خانة «نقدية الافتتاح».',
    ),
    TutorStep(
      say: 'اضغط «بدء الجلسة».',
      anchor: TutorAnchor.registerStartSessionButton,
      act: TutorAct.tap(),
      expect: TutorExpect.sessionOpen(),
      hint: 'الدين المُحصَّل يدخل الدرج، والدرج يحتاج وردية مفتوحة.',
    ),
    TutorStep(
      say: 'افتح قائمة الوردية.',
      anchor: TutorAnchor.registerSessionMenuButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(
        TutorAnchor.registerSessionAction,
        id: 'collect_debt',
      ),
      hint: 'الزر الذي يحمل رقم الوردية.',
    ),
    TutorStep(
      say: 'اختر «تحصيل دين».',
      anchor: TutorAnchor.registerSessionAction,
      anchorId: 'collect_debt',
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.collectDebtPickCustomerButton),
      hint: 'الخيار الخاص بديون الزبائن.',
    ),
    TutorStep(
      say: 'اضغط «اختيار زبون».',
      anchor: TutorAnchor.collectDebtPickCustomerButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.contactPickerSearchField),
      hint: 'الزر الوحيد في النافذة حتى الآن.',
    ),
    TutorStep(
      say: 'اختر «فاطمة الزهراء» — عليها 120 د.ل.',
      anchor: TutorAnchor.contactPickerRow,
      anchorId: 'فاطمة الزهراء',
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.collectDebtRecordPaymentButton),
      hint: 'الرصيد المستحق يظهر تحت اسمها.',
    ),
    TutorStep(
      say: 'اضغط «تسجيل دفعة».',
      anchor: TutorAnchor.collectDebtRecordPaymentButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.recordPaymentAmountField),
      hint: 'الزر يظهر فقط حين يكون على الزبون دين.',
    ),
    TutorStep(
      say: 'دفعت 50 د.ل. اليوم: اكتب 50.',
      anchor: TutorAnchor.recordPaymentAmountField,
      act: TutorAct.type('50'),
      expect: TutorExpect.fieldEquals(
        TutorAnchor.recordPaymentAmountField,
        '50',
      ),
      hint: 'الدفعة الجزئية مسموحة — لا يلزم سداد الدين كاملًا.',
    ),
    TutorStep(
      say: 'اضغط «تأكيد».',
      anchor: TutorAnchor.recordPaymentConfirmButton,
      act: TutorAct.tap(),
      expect: TutorExpect.customerBalanceOf('فاطمة الزهراء', 70),
      hint: 'الرصيد ينزل من 120 إلى 70.',
    ),
  ],
  outcome: TutorExpect.all([
    TutorExpect.customerBalanceOf('فاطمة الزهراء', 70),
    // Both halves of the same movement. A shop that records the debt payment
    // but not the cash finds a surplus at close it cannot explain.
    TutorExpect.drawerPaidIn(50),
    TutorExpect.drawerCash(100),
    TutorExpect.orderCount(0),
  ]),
);

/// Paying the supplier for goods already received.
const moneyPaySupplierLesson = TutorLesson(
  id: 'money.pay_supplier',
  title: 'دفع مستحقات مورّد',
  summary: 'سدّد أمر شراء وصلت بضاعته كاملة، وسجّل الدفعة على المورّد.',
  seed: SandboxSeed.groceryBackOfficeWithDelivery,
  // Not purchasing access: a buyer runs the order but, by default, does not
  // pay for it, and the button this lesson points at is not theirs.
  capability: AppCapability.recordSupplierPayment,
  guideId: 'purchasing.pay_supplier',
  requires: ['purchasing.receive'],
  steps: [
    TutorStep(
      say: 'افتح «المشتريات» من القائمة الجانبية.',
      anchor: TutorAnchor.navigationDestination,
      anchorId: 'purchasing',
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.purchaseOrderRow, id: 'PO-0001'),
      hint: 'القائمة على حافة الشاشة، وفيها كل الشاشات.',
    ),
    TutorStep(
      say: 'افتح أمر الشراء PO-0001.',
      anchor: TutorAnchor.purchaseOrderRow,
      anchorId: 'PO-0001',
      act: TutorAct.tap(),
      expect: TutorExpect.visible(
        TutorAnchor.purchaseOrderAction,
        id: 'record_payment',
      ),
      hint: 'الأمر الوحيد في القائمة.',
    ),
    TutorStep(
      say: 'اضغط «تسجيل دفعة للمورّد».',
      anchor: TutorAnchor.purchaseOrderAction,
      anchorId: 'record_payment',
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.recordPaymentAmountField),
      hint: 'المبلغ المستحق مكتوب أسفل الصفحة.',
    ),
    TutorStep(
      say: 'ادفع 21 د.ل. — قيمة الأمر كاملة.',
      anchor: TutorAnchor.recordPaymentAmountField,
      act: TutorAct.type('21'),
      expect: TutorExpect.fieldEquals(
        TutorAnchor.recordPaymentAmountField,
        '21',
      ),
      hint: '10 كراتين × 2.10 د.ل.',
    ),
    TutorStep(
      say: 'اضغط «تأكيد».',
      anchor: TutorAnchor.recordPaymentConfirmButton,
      act: TutorAct.tap(),
      expect: TutorExpect.supplierPaidTotal(21),
      hint: 'يُسجَّل الدفع على الأمر وعلى حساب المورّد.',
    ),
  ],
  outcome: TutorExpect.all([
    TutorExpect.supplierPaidTotal(21),
    // Receiving moved the stock; paying moves only the money. Two separate
    // steps, and a shop that confuses them pays twice for one delivery.
    TutorExpect.stockOf('PCE1', 34),
    TutorExpect.lastPurchaseOrderStatus('received'),
  ]),
);

const moneyLessons = <TutorLesson>[
  moneyCollectDebtLesson,
  moneyPaySupplierLesson,
];
