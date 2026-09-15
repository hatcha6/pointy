/// The drawer: money that arrives and leaves without a sale, and the close.
///
/// This is where a shop's numbers are most often lost, and it is exactly the
/// part nobody is trusted to practise on a live till.
library;

import '../../../core/authorization.dart';
import '../../../shared/tutor/anchors.dart';
import '../engine/lesson.dart';

const _openDrawer = [
  TutorStep(
    say: 'افتح الوردية بنقدية افتتاح 50.',
    anchor: TutorAnchor.registerOpeningCashField,
    act: TutorAct.type('50'),
    expect: TutorExpect.fieldEquals(TutorAnchor.registerOpeningCashField, '50'),
    hint: 'اكتب 50 في خانة «نقدية الافتتاح».',
  ),
  TutorStep(
    say: 'اضغط «بدء الجلسة».',
    anchor: TutorAnchor.registerStartSessionButton,
    act: TutorAct.tap(),
    expect: TutorExpect.sessionOpen(),
    hint: 'لا يمكن البيع قبل فتح وردية.',
  ),
];

/// Cash that leaves the drawer for something that is not a sale. Recording it
/// is the difference between a drawer that balances and a cashier accused of a
/// shortage.
const registerCashMovementLesson = TutorLesson(
  id: 'register.cash_movement',
  title: 'إخراج نقد من الدرج',
  summary: 'سجّل مبلغًا خرج من الدرج لغير البيع — وإلا ظهر نقصًا عند الإغلاق.',
  seed: SandboxSeed.groceryMorning,
  capability: AppCapability.createRegisterCashMovement,
  guideId: 'register.cash_movements',
  requires: ['pos.cash_sale'],
  steps: [
    ..._openDrawer,
    TutorStep(
      say: 'افتح قائمة الوردية من الشريط العلوي.',
      anchor: TutorAnchor.registerSessionMenuButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(
        TutorAnchor.registerSessionAction,
        id: 'pay_out',
      ),
      hint: 'الزر الذي يحمل رقم الوردية.',
    ),
    TutorStep(
      say: 'اختر «إخراج نقد».',
      anchor: TutorAnchor.registerSessionAction,
      anchorId: 'pay_out',
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.registerCashMovementAmountField),
      hint: 'الخيار الثاني في القائمة.',
    ),
    TutorStep(
      say: 'اكتب 20 — ثمن غاز اشتراه المحل من الدرج.',
      anchor: TutorAnchor.registerCashMovementAmountField,
      act: TutorAct.type('20'),
      expect: TutorExpect.fieldEquals(
        TutorAnchor.registerCashMovementAmountField,
        '20',
      ),
      hint: 'خانة المبلغ أعلى النافذة.',
    ),
    TutorStep(
      say: 'اكتب السبب: «شراء غاز».',
      anchor: TutorAnchor.registerCashMovementReasonField,
      act: TutorAct.type('شراء غاز'),
      expect: TutorExpect.fieldEquals(
        TutorAnchor.registerCashMovementReasonField,
        'شراء غاز',
      ),
      // Required by the form, and rightly so: the reason is what turns an
      // unexplained shortage at close into a recorded expense.
      hint: 'السبب مطلوب: هو ما يفسّر النقص لاحقًا.',
    ),
    TutorStep(
      say: 'اضغط «إخراج نقد» للتأكيد.',
      anchor: TutorAnchor.registerCashMovementConfirmButton,
      act: TutorAct.tap(),
      expect: TutorExpect.drawerPaidOut(20),
      hint: 'الزر الأخضر أسفل النافذة.',
    ),
  ],
  outcome: TutorExpect.all([
    TutorExpect.drawerPaidOut(20),
    // The expected drawer drops with it — which is the whole point: the money
    // left, and the till knows why.
    TutorExpect.drawerCash(30),
    TutorExpect.orderCount(0),
  ]),
);

/// Close the drawer by counting it — blind. The count is what the cashier
/// physically has; the software's expectation is none of their business until
/// after they have committed to a number.
const registerCloseLesson = TutorLesson(
  id: 'register.close',
  title: 'إغلاق الوردية',
  summary: 'بِع، ثم عُدّ الدرج وأغلق الوردية — واقرأ الفرق.',
  seed: SandboxSeed.groceryMorning,
  capability: AppCapability.closeRegisterSession,
  guideId: 'register.close',
  requires: ['pos.cash_sale'],
  steps: [
    ..._openDrawer,
    TutorStep(
      say: 'بِع رغيفًا أولًا: اضغط «خبز».',
      anchor: TutorAnchor.posProductTile,
      anchorId: 'PCE0',
      act: TutorAct.tap(),
      expect: TutorExpect.anchorCount(TutorAnchor.posCartLine, 1, id: 'PCE0'),
      hint: 'بطاقة «خبز» في الكتالوج.',
    ),
    TutorStep(
      say: 'اضغط زر الدفع.',
      anchor: TutorAnchor.posCheckoutButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.paymentSheet),
      hint: 'أو Ctrl+Enter.',
    ),
    TutorStep(
      say: 'أكِّد الدفع نقدًا.',
      anchor: TutorAnchor.paymentConfirmButton,
      act: TutorAct.tap(),
      expect: TutorExpect.orderCount(1),
      hint: 'المبلغ 0.50 د.ل.',
    ),
    TutorStep(
      say: 'افتح قائمة الوردية.',
      anchor: TutorAnchor.registerSessionMenuButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(
        TutorAnchor.registerSessionAction,
        id: 'close_session',
      ),
      hint: 'الزر الذي يحمل رقم الوردية.',
    ),
    TutorStep(
      say: 'اختر «إغلاق الوردية».',
      anchor: TutorAnchor.registerSessionAction,
      anchorId: 'close_session',
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.registerCloseCountedCashField),
      hint: 'آخر خيار في القائمة.',
    ),
    TutorStep(
      say: 'عُدّ ما في الدرج فعلًا واكتبه: 50.50.',
      anchor: TutorAnchor.registerCloseCountedCashField,
      act: TutorAct.type('50.50'),
      expect: TutorExpect.fieldEquals(
        TutorAnchor.registerCloseCountedCashField,
        '50.50',
      ),
      hint: 'الافتتاح 50 وبيعة نقدية 0.50.',
    ),
    TutorStep(
      say: 'اضغط «إغلاق الوردية».',
      anchor: TutorAnchor.registerCloseConfirmButton,
      act: TutorAct.tap(),
      expect: TutorExpect.sessionStatus('closed'),
      hint: 'بعدها لا يمكن البيع حتى تُفتح وردية جديدة.',
    ),
  ],
  outcome: TutorExpect.all([
    TutorExpect.sessionStatus('closed'),
    TutorExpect.orderCount(1),
    TutorExpect.stockOf('PCE0', 39),
  ]),
);

const registerLessons = <TutorLesson>[
  registerCashMovementLesson,
  registerCloseLesson,
];
