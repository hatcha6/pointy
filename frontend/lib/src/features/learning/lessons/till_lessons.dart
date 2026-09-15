/// Selling: the till, start to finish.
///
/// Every number below is checkable by hand against `groceryMorningSeed()` —
/// خبز is 0.50 with 40 on hand, أرز is 22.50 with 15, بيض is 12.00 with 10 —
/// and the drawer always opens with 50.00. A lesson whose arithmetic you cannot
/// do in your head is a lesson nobody can review.
library;

import '../../../core/authorization.dart';
import '../../../shared/tutor/anchors.dart';
import '../engine/lesson.dart';

const _openDrawer = [
  TutorStep(
    say: 'أدخل النقدية الموجودة في الدرج الآن: اكتب 50.',
    anchor: TutorAnchor.registerOpeningCashField,
    act: TutorAct.type('50'),
    expect: TutorExpect.fieldEquals(TutorAnchor.registerOpeningCashField, '50'),
    hint: 'اكتب المبلغ في خانة «نقدية الافتتاح».',
  ),
  TutorStep(
    say: 'اضغط «بدء الجلسة» لفتح وردية الدرج.',
    anchor: TutorAnchor.registerStartSessionButton,
    act: TutorAct.tap(),
    expect: TutorExpect.sessionOpen(),
    hint: 'لا يمكن البيع قبل فتح وردية.',
  ),
];

/// Phase 0's proof: one real task, start to finish, against a shop that moves.
const posCashSaleLesson = TutorLesson(
  id: 'pos.cash_sale',
  title: 'بيع نقدي كامل',
  summary:
      'افتح الوردية، أضِف صنفًا، اقبض نقدًا — على متجر تدريب لا يمسّ محلك.',
  seed: SandboxSeed.groceryMorning,
  capability: AppCapability.checkoutSale,
  guideId: 'selling.first_sale',
  steps: [
    ..._openDrawer,
    TutorStep(
      say: 'اضغط على «خبز» في الكتالوج لإضافته إلى السلة.',
      anchor: TutorAnchor.posProductTile,
      anchorId: 'PCE0',
      act: TutorAct.tap(),
      // Names the same product the narration does. Accepting any cart line
      // would let the step complete on a product the learner was not told to
      // tap, and the lesson would stop describing what is on screen.
      expect: TutorExpect.anchorCount(TutorAnchor.posCartLine, 1, id: 'PCE0'),
      hint: 'بطاقات المنتجات على يمين الشاشة.',
    ),
    TutorStep(
      say: 'اضغط زر الدفع لفتح نافذة إتمام الدفع.',
      anchor: TutorAnchor.posCheckoutButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.paymentSheet),
      hint: 'يمكنك أيضًا الضغط على Ctrl+Enter.',
    ),
    TutorStep(
      say: 'اضغط «تأكيد الدفع» لإتمام البيع نقدًا.',
      anchor: TutorAnchor.paymentConfirmButton,
      act: TutorAct.tap(),
      expect: TutorExpect.orderCount(1),
      hint: 'المبلغ مدفوع بالكامل، فالزر جاهز.',
    ),
  ],
  // The screen can lie; the ledger cannot. All three must move together.
  outcome: TutorExpect.all([
    TutorExpect.orderCount(1),
    TutorExpect.stockOf('PCE0', 39),
    TutorExpect.drawerCash(50.50),
  ]),
);

/// Two different products, one of them found by typing its name.
///
/// The search step matters more than it looks: a cashier who only knows the
/// tiles is lost the moment the shop has more products than fit on a screen.
const posMultiItemSaleLesson = TutorLesson(
  id: 'pos.multi_item_sale',
  title: 'فاتورة بأكثر من صنف',
  summary: 'أضِف صنفين — واحدًا من البطاقات وواحدًا بالبحث بالاسم.',
  seed: SandboxSeed.groceryMorning,
  capability: AppCapability.checkoutSale,
  guideId: 'selling.add_items',
  requires: ['pos.cash_sale'],
  steps: [
    ..._openDrawer,
    TutorStep(
      say: 'أضِف «بيض ٣٠ حبة» من البطاقات.',
      anchor: TutorAnchor.posProductTile,
      anchorId: 'PCE2',
      act: TutorAct.tap(),
      expect: TutorExpect.anchorCount(TutorAnchor.posCartLine, 1, id: 'PCE2'),
      hint: 'ابحث عن البطاقة التي تحمل اسم «بيض ٣٠ حبة».',
    ),
    TutorStep(
      say: 'اكتب «سكر» في خانة البحث لتصفية الكتالوج.',
      anchor: TutorAnchor.posCatalogSearchField,
      act: TutorAct.type('سكر'),
      // The catalogue narrowing to one tile is the thing the learner is meant
      // to notice, and it is also what proves the search reached the server.
      expect: TutorExpect.anchorCount(TutorAnchor.posProductTile, 1),
      hint: 'خانة البحث فوق بطاقات المنتجات.',
    ),
    TutorStep(
      say: 'اضغط على «سكر ١ كغ» لإضافته.',
      anchor: TutorAnchor.posProductTile,
      anchorId: 'PCE5',
      act: TutorAct.tap(),
      expect: TutorExpect.anchorCount(TutorAnchor.posCartLine, 1, id: 'PCE5'),
      hint: 'البطاقة الوحيدة الظاهرة بعد البحث.',
    ),
    TutorStep(
      say: 'اضغط زر الدفع.',
      anchor: TutorAnchor.posCheckoutButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.paymentSheet),
      hint: 'المجموع الآن 16.25 د.ل.',
    ),
    TutorStep(
      say: 'اضغط «تأكيد الدفع».',
      anchor: TutorAnchor.paymentConfirmButton,
      act: TutorAct.tap(),
      expect: TutorExpect.orderCount(1),
      hint: 'المبلغ مدفوع بالكامل.',
    ),
  ],
  outcome: TutorExpect.all([
    TutorExpect.orderCount(1),
    TutorExpect.stockOf('PCE2', 9),
    TutorExpect.stockOf('PCE5', 29),
    TutorExpect.lastOrderTotal(16.25),
    TutorExpect.drawerCash(66.25),
  ]),
);

/// One invoice, two tenders. The half everyone gets wrong is that the second
/// line fills itself with the remainder — so the cashier types the amount they
/// actually took on the card, not the amount left over.
const posSplitTenderLesson = TutorLesson(
  id: 'pos.split_tender',
  title: 'دفع مقسوم: نقد وبطاقة',
  summary: 'فاتورة واحدة بدفعتين — جزء نقدًا والباقي بالبطاقة.',
  seed: SandboxSeed.groceryMorning,
  capability: AppCapability.checkoutSale,
  guideId: 'money.split_tender',
  requires: ['pos.cash_sale'],
  steps: [
    ..._openDrawer,
    TutorStep(
      say: 'أضِف «أرز ٥ كغ» إلى السلة — سعره 22.50 د.ل.',
      anchor: TutorAnchor.posProductTile,
      anchorId: 'PCE3',
      act: TutorAct.tap(),
      expect: TutorExpect.anchorCount(TutorAnchor.posCartLine, 1, id: 'PCE3'),
      hint: 'ابحث عن بطاقة «أرز ٥ كغ».',
    ),
    TutorStep(
      say: 'اضغط زر الدفع.',
      anchor: TutorAnchor.posCheckoutButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.paymentSheet),
      hint: 'أو Ctrl+Enter.',
    ),
    TutorStep(
      say: 'الزبون دفع 10 نقدًا فقط: اكتب 10 في خانة المبلغ.',
      anchor: TutorAnchor.paymentTenderAmountField,
      anchorId: '0',
      act: TutorAct.type('10'),
      expect: TutorExpect.fieldEquals(
        TutorAnchor.paymentTenderAmountField,
        '10',
        id: '0',
      ),
      hint: 'الخانة مملوءة بالمجموع كاملًا — امسحه واكتب 10.',
    ),
    TutorStep(
      say: 'اضغط «إضافة دفعة» ليأخذ السطر الثاني الباقي.',
      anchor: TutorAnchor.paymentAddTenderButton,
      act: TutorAct.tap(),
      // The second line fills itself with the remainder and picks the next
      // unused method — so the cashier types what was handed over, never what
      // is left over.
      expect: TutorExpect.fieldEquals(
        TutorAnchor.paymentTenderAmountField,
        '12.50',
        id: '1',
      ),
      hint: 'البرنامج يحسب الباقي وحده: 12.50 على البطاقة.',
    ),
    TutorStep(
      say: 'اضغط «تأكيد الدفع».',
      anchor: TutorAnchor.paymentConfirmButton,
      act: TutorAct.tap(),
      expect: TutorExpect.orderCount(1),
      hint: 'مجموع الدفعتين يساوي الفاتورة، فالزر جاهز.',
    ),
  ],
  outcome: TutorExpect.all([
    TutorExpect.orderCount(1),
    TutorExpect.stockOf('PCE3', 14),
    TutorExpect.paymentCountOf('cash', 1),
    TutorExpect.paymentCountOf('card', 1),
    // Only the cash half reaches the drawer. A till that counts the card half
    // as cash is a till whose close never balances.
    TutorExpect.drawerCash(60),
  ]),
);

/// آجل with a down-payment: the sale that most often goes wrong on paper.
const posCreditDownPaymentLesson = TutorLesson(
  id: 'pos.credit_down_payment',
  title: 'فاتورة آجل بدفعة مقدّمة',
  summary: 'اربط الفاتورة بزبون، خذ دفعة مقدّمة، وحدّد موعد سداد الباقي.',
  seed: SandboxSeed.groceryMorning,
  capability: AppCapability.checkoutSale,
  guideId: 'money.credit_down_payment',
  requires: ['pos.cash_sale'],
  steps: [
    ..._openDrawer,
    TutorStep(
      say: 'أضِف «بيض ٣٠ حبة» — سعره 12.00 د.ل.',
      anchor: TutorAnchor.posProductTile,
      anchorId: 'PCE2',
      act: TutorAct.tap(),
      expect: TutorExpect.anchorCount(TutorAnchor.posCartLine, 1, id: 'PCE2'),
      hint: 'بطاقة «بيض ٣٠ حبة».',
    ),
    TutorStep(
      say: 'الفاتورة الآجلة لا بد لها من زبون. افتح إعدادات الفاتورة.',
      anchor: TutorAnchor.posSaleSettingsButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.contactSelectionTile),
      hint: 'زر الإعدادات أعلى السلة.',
    ),
    TutorStep(
      say: 'اضغط على خانة الزبون لفتح قائمة الزبائن.',
      anchor: TutorAnchor.contactSelectionTile,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.contactPickerSearchField),
      hint: 'الخانة مكتوب فيها «زبون عابر».',
    ),
    TutorStep(
      say: 'اختر «أحمد المبروك».',
      anchor: TutorAnchor.contactPickerRow,
      anchorId: 'أحمد المبروك',
      act: TutorAct.tap(),
      expect: TutorExpect.anchorCount(TutorAnchor.contactPickerRow, 0),
      hint: 'اضغط على اسمه في القائمة.',
    ),
    TutorStep(
      say: 'احفظ الإعدادات لتُربط الفاتورة باسمه.',
      anchor: TutorAnchor.posSaleSettingsSaveButton,
      act: TutorAct.tap(),
      // Not "a dialog closed" — the cart must now name the customer the
      // narration named. Any other customer would close the dialog too.
      expect: TutorExpect.visible(
        TutorAnchor.posCartCustomer,
        id: 'أحمد المبروك',
      ),
      hint: 'زر «حفظ» أسفل النافذة.',
    ),
    TutorStep(
      say: 'اضغط زر الدفع.',
      anchor: TutorAnchor.posCheckoutButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.paymentSheet),
      hint: 'أو Ctrl+Enter.',
    ),
    TutorStep(
      say: 'اختر نوع البيع «آجل».',
      anchor: TutorAnchor.paymentSaleTypeSegment,
      anchorId: 'credit',
      act: TutorAct.tap(),
      // Credit clears the prefilled full payment: what stays unpaid becomes the
      // debt, so the sheet starts from "nothing paid yet".
      expect: TutorExpect.visible(
        TutorAnchor.paymentCreditDueDatePreset,
        id: '30',
      ),
      hint: 'أزرار نوع البيع أعلى النافذة.',
    ),
    TutorStep(
      say: 'الزبون دفع 5 د.ل. الآن: أضِف دفعة مقدّمة.',
      anchor: TutorAnchor.paymentAddTenderButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(
        TutorAnchor.paymentTenderAmountField,
        id: '0',
      ),
      hint: 'زر «إضافة دفعة مقدّمة» أسفل وسائل الدفع.',
    ),
    TutorStep(
      say: 'اكتب 5 في خانة الدفعة المقدّمة.',
      anchor: TutorAnchor.paymentTenderAmountField,
      anchorId: '0',
      act: TutorAct.type('5'),
      expect: TutorExpect.fieldEquals(
        TutorAnchor.paymentTenderAmountField,
        '5',
        id: '0',
      ),
      hint: 'الخانة تبدأ فارغة في البيع الآجل.',
    ),
    TutorStep(
      say: 'حدّد موعد سداد الباقي بعد 30 يومًا.',
      anchor: TutorAnchor.paymentCreditDueDatePreset,
      anchorId: '30',
      act: TutorAct.tap(),
      // The clear button only exists once a date is set: proof the chip took,
      // rather than proof that a button which is always there is still there.
      expect: TutorExpect.visible(TutorAnchor.paymentCreditDueDateClear),
      hint: 'رسائل تحصيل الدين تنتظر هذا التاريخ.',
    ),
    TutorStep(
      say: 'اضغط «تأكيد الدفع» لتسجيل الفاتورة الآجلة.',
      anchor: TutorAnchor.paymentConfirmButton,
      act: TutorAct.tap(),
      expect: TutorExpect.orderCount(1),
      hint: 'الباقي — 7 د.ل. — يُقيَّد على حساب الزبون.',
    ),
  ],
  outcome: TutorExpect.all([
    TutorExpect.orderCount(1),
    TutorExpect.lastOrderSaleType('credit'),
    TutorExpect.stockOf('PCE2', 9),
    TutorExpect.lastOrderPaidTotal(5),
    // The whole point of آجل: the unpaid remainder became a debt, and only the
    // 5 that was actually handed over reached the drawer.
    TutorExpect.customerBalanceOf('أحمد المبروك', 7),
    TutorExpect.drawerCash(55),
  ]),
);

/// A quotation is an offer, not a sale: no money, and — the part that surprises
/// people — no stock movement either.
const posQuotationLesson = TutorLesson(
  id: 'pos.quotation',
  title: 'عرض سعر',
  summary: 'اكتب عرض سعر لزبون دون أن يتحرّك مخزون أو نقد.',
  seed: SandboxSeed.groceryMorning,
  capability: AppCapability.checkoutSale,
  guideId: 'money.quotation',
  requires: ['pos.credit_down_payment'],
  steps: [
    ..._openDrawer,
    TutorStep(
      say: 'أضِف «زيت ذرة ١ لتر» — سعره 9.75 د.ل.',
      anchor: TutorAnchor.posProductTile,
      anchorId: 'PCE4',
      act: TutorAct.tap(),
      expect: TutorExpect.anchorCount(TutorAnchor.posCartLine, 1, id: 'PCE4'),
      hint: 'بطاقة «زيت ذرة ١ لتر».',
    ),
    TutorStep(
      say: 'افتح إعدادات الفاتورة لاختيار الزبون.',
      anchor: TutorAnchor.posSaleSettingsButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.contactSelectionTile),
      hint: 'زر الإعدادات أعلى السلة.',
    ),
    TutorStep(
      say: 'اضغط على خانة الزبون.',
      anchor: TutorAnchor.contactSelectionTile,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.contactPickerSearchField),
      hint: 'الخانة مكتوب فيها «زبون عابر».',
    ),
    TutorStep(
      say: 'اختر «مقهى الواحة».',
      anchor: TutorAnchor.contactPickerRow,
      anchorId: 'مقهى الواحة',
      act: TutorAct.tap(),
      expect: TutorExpect.anchorCount(TutorAnchor.contactPickerRow, 0),
      hint: 'اضغط على الاسم في القائمة.',
    ),
    TutorStep(
      say: 'احفظ الإعدادات.',
      anchor: TutorAnchor.posSaleSettingsSaveButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(
        TutorAnchor.posCartCustomer,
        id: 'مقهى الواحة',
      ),
      hint: 'زر «حفظ» أسفل النافذة.',
    ),
    TutorStep(
      say: 'اضغط زر الدفع.',
      anchor: TutorAnchor.posCheckoutButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.paymentSheet),
      hint: 'أو Ctrl+Enter.',
    ),
    TutorStep(
      say: 'اختر «عرض سعر».',
      anchor: TutorAnchor.paymentSaleTypeSegment,
      anchorId: 'quotation',
      act: TutorAct.tap(),
      // The tender lines disappear entirely: a quotation takes no money, so
      // there is nothing to type.
      expect: TutorExpect.anchorCount(TutorAnchor.paymentTenderAmountField, 0),
      hint: 'أزرار نوع البيع أعلى النافذة.',
    ),
    TutorStep(
      say: 'اضغط «تأكيد» لحفظ العرض.',
      anchor: TutorAnchor.paymentConfirmButton,
      act: TutorAct.tap(),
      expect: TutorExpect.orderCount(1),
      hint: 'لن يُقبض شيء ولن ينقص المخزون.',
    ),
  ],
  outcome: TutorExpect.all([
    TutorExpect.orderCount(1),
    TutorExpect.lastOrderSaleType('quotation'),
    // Unchanged: an offer that moved stock is the classic way this flow is
    // taught wrong.
    TutorExpect.stockOf('PCE4', 18),
    TutorExpect.drawerCash(50),
  ]),
);

/// Card, not cash — and the drawer does not move.
///
/// Worth its own lesson because the mistake it prevents is expensive: a shop
/// that counts card takings as cash finds a shortage every single evening.
const posCardSaleLesson = TutorLesson(
  id: 'pos.card_sale',
  title: 'بيع بالبطاقة',
  summary: 'اقبض بالبطاقة، وانظر كيف لا يتغيّر ما في الدرج.',
  seed: SandboxSeed.groceryMorning,
  capability: AppCapability.checkoutSale,
  guideId: 'money.payment_methods',
  requires: ['pos.cash_sale'],
  steps: [
    ..._openDrawer,
    TutorStep(
      say: 'أضِف «حليب طازج ١ لتر» — سعره 3.00 د.ل.',
      anchor: TutorAnchor.posProductTile,
      anchorId: 'PCE1',
      act: TutorAct.tap(),
      expect: TutorExpect.anchorCount(TutorAnchor.posCartLine, 1, id: 'PCE1'),
      hint: 'بطاقة «حليب طازج ١ لتر».',
    ),
    TutorStep(
      say: 'اضغط زر الدفع.',
      anchor: TutorAnchor.posCheckoutButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.paymentSheet),
      hint: 'أو Ctrl+Enter.',
    ),
    TutorStep(
      say: 'اختر «بطاقة».',
      anchor: TutorAnchor.paymentMethodSegment,
      anchorId: 'card',
      act: TutorAct.tap(),
      // Choosing the card brings out the slip controls — the shop can require
      // the terminal receipt before the sale is allowed through.
      expect: TutorExpect.visible(TutorAnchor.paymentCardReceiptButton),
      hint: 'أزرار وسائل الدفع أعلى النافذة.',
    ),
    TutorStep(
      say: 'اضغط «تأكيد الدفع».',
      anchor: TutorAnchor.paymentConfirmButton,
      act: TutorAct.tap(),
      expect: TutorExpect.orderCount(1),
      hint: 'المبلغ كامل على البطاقة.',
    ),
  ],
  outcome: TutorExpect.all([
    TutorExpect.orderCount(1),
    TutorExpect.paymentCountOf('card', 1),
    TutorExpect.stockOf('PCE1', 23),
    // The sale happened and the drawer did not move. This is the whole lesson.
    TutorExpect.drawerCash(50),
  ]),
);

const tillLessons = <TutorLesson>[
  posCashSaleLesson,
  posMultiItemSaleLesson,
  posCardSaleLesson,
  posSplitTenderLesson,
  posCreditDownPaymentLesson,
  posQuotationLesson,
];
