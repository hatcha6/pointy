/// Buying: raising an order, and receiving what actually turned up.
library;

import '../../../core/authorization.dart';
import '../../../shared/tutor/anchors.dart';
import '../engine/lesson.dart';

/// The order itself — supplier, line, cost, send.
const purchasingCreatePoLesson = TutorLesson(
  id: 'purchasing.create_po',
  title: 'إنشاء أمر شراء',
  summary: 'سجّل بضاعة وصلت من مورّد: الصنف، التكلفة، المورّد، ثم الإرسال.',
  seed: SandboxSeed.groceryBackOffice,
  capability: AppCapability.createPurchaseOrder,
  guideId: 'purchasing.create_po',
  steps: [
    TutorStep(
      say: 'افتح «المشتريات» من القائمة الجانبية.',
      anchor: TutorAnchor.navigationDestination,
      anchorId: 'purchasing',
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.purchaseNewOrderButton),
      hint: 'القائمة على حافة الشاشة، وفيها كل الشاشات.',
    ),
    TutorStep(
      say: 'اضغط «أمر شراء جديد».',
      anchor: TutorAnchor.purchaseNewOrderButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.purchaseCatalogSearchField),
      hint: 'الزر العائم أسفل قائمة الأوامر.',
    ),
    TutorStep(
      say: 'ابحث عن «أرز» في كتالوج الشراء.',
      anchor: TutorAnchor.purchaseCatalogSearchField,
      act: TutorAct.type('أرز'),
      expect: TutorExpect.anchorCount(TutorAnchor.purchaseProductTile, 1),
      hint: 'خانة البحث أعلى بطاقات المنتجات.',
    ),
    TutorStep(
      say: 'اضغط على «أرز ٥ كغ» لإضافته إلى الأمر.',
      anchor: TutorAnchor.purchaseProductTile,
      anchorId: 'PCE3',
      act: TutorAct.tap(),
      expect: TutorExpect.visible(
        TutorAnchor.purchaseLineCostField,
        id: 'PCE3',
      ),
      hint: 'البطاقة الوحيدة الظاهرة بعد البحث.',
    ),
    TutorStep(
      say: 'اكتب تكلفة الشراء للوحدة: 18.',
      anchor: TutorAnchor.purchaseLineCostField,
      anchorId: 'PCE3',
      act: TutorAct.type('18'),
      expect: TutorExpect.fieldEquals(
        TutorAnchor.purchaseLineCostField,
        '18',
        id: 'PCE3',
      ),
      // The cost is what you pay, not what you sell at. Typing a selling price
      // here is the single most expensive typo in the whole program.
      hint: 'التكلفة هي ما تدفعه للمورّد، لا سعر البيع.',
    ),
    TutorStep(
      say:
          'انظر إلى «استلام فوري»: وهو مُفعَّل، فالبضاعة تدخل المخزون لحظة '
          'إرسال الأمر. اتركه مُفعَّلًا هنا — البضاعة على الطاولة أمامك. '
          'أطفئه حين تطلب بضاعة ستصل لاحقًا.',
      anchor: TutorAnchor.purchaseReceiveImmediatelyToggle,
      act: TutorAct.observe(),
      expect: TutorExpect.visible(TutorAnchor.purchaseReceiveImmediatelyToggle),
      hint: 'الفرق بين «طلبتها» و«استلمتها» هو الفرق بين مخزون صحيح وخاطئ.',
    ),
    TutorStep(
      say: 'افتح إعدادات الأمر لاختيار المورّد.',
      anchor: TutorAnchor.purchaseSettingsButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.contactSelectionTile),
      hint: 'زر الإعدادات أعلى مسودّة الأمر.',
    ),
    TutorStep(
      say: 'اضغط على خانة المورّد.',
      anchor: TutorAnchor.contactSelectionTile,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.contactPickerSearchField),
      hint: 'الخانة مكتوب فيها «لا مورّد».',
    ),
    TutorStep(
      say: 'اختر «مخازن الأمل».',
      anchor: TutorAnchor.contactPickerRow,
      anchorId: 'مخازن الأمل',
      act: TutorAct.tap(),
      expect: TutorExpect.anchorCount(TutorAnchor.contactPickerRow, 0),
      hint: 'اضغط على اسم المورّد في القائمة.',
    ),
    TutorStep(
      say: 'احفظ الإعدادات.',
      anchor: TutorAnchor.purchaseSettingsSaveButton,
      act: TutorAct.tap(),
      expect: TutorExpect.anchorCount(TutorAnchor.contactSelectionTile, 0),
      hint: 'زر «حفظ» أسفل النافذة.',
    ),
    TutorStep(
      say: 'اضغط زر الإرسال لتسجيل أمر الشراء.',
      anchor: TutorAnchor.purchaseSubmitButton,
      act: TutorAct.tap(),
      expect: TutorExpect.purchaseOrderCount(1),
      hint: 'لا يُرسَل أمر بلا مورّد — ولهذا اخترناه أولًا.',
    ),
  ],
  outcome: TutorExpect.all([
    TutorExpect.purchaseOrderCount(1),
    // Sent *and* received, because «استلام فوري» was left on: the goods were
    // on the counter. The stock rose by exactly the one unit ordered.
    TutorExpect.lastPurchaseOrderStatus('received'),
    TutorExpect.receivedQuantityOf('PCE3', 1),
    TutorExpect.stockOf('PCE3', 16),
  ]),
);

/// The delivery that came up short — the case worth practising, because
/// receiving what the paperwork says instead of what arrived is how a shop's
/// stock quietly stops matching its shelves.
const purchasingReceiveLesson = TutorLesson(
  id: 'purchasing.receive',
  title: 'استلام بضاعة ناقصة',
  summary: 'وصلت 8 من 10: استلم ما جاء فعلًا، لا ما هو مكتوب في الأمر.',
  seed: SandboxSeed.groceryBackOfficeWithOrder,
  capability: AppCapability.receivePurchaseOrder,
  guideId: 'purchasing.receive',
  requires: ['purchasing.create_po'],
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
        id: 'receive',
      ),
      hint: 'الأمر الوحيد في القائمة.',
    ),
    TutorStep(
      say: 'اضغط «استلام».',
      anchor: TutorAnchor.purchaseOrderAction,
      anchorId: 'receive',
      act: TutorAct.tap(),
      expect: TutorExpect.visible(
        TutorAnchor.purchaseReceiveQuantityField,
        id: 'PCE1',
      ),
      hint: 'الزر الأساسي أسفل صفحة الأمر.',
    ),
    TutorStep(
      say: 'وصلت 8 كراتين فقط من 10: اكتب 8.',
      anchor: TutorAnchor.purchaseReceiveQuantityField,
      anchorId: 'PCE1',
      act: TutorAct.type('8'),
      expect: TutorExpect.fieldEquals(
        TutorAnchor.purchaseReceiveQuantityField,
        '8',
        id: 'PCE1',
      ),
      hint: 'اكتب ما عددته بيدك، لا ما في الفاتورة.',
    ),
    TutorStep(
      say: 'اضغط «تأكيد» لتسجيل الاستلام.',
      anchor: TutorAnchor.purchaseReceiveConfirmButton,
      act: TutorAct.tap(),
      expect: TutorExpect.receivedQuantityOf('PCE1', 8),
      hint: 'يبقى الأمر مفتوحًا للكميتين الباقيتين.',
    ),
  ],
  outcome: TutorExpect.all([
    TutorExpect.receivedQuantityOf('PCE1', 8),
    // Eight arrived, so eight were added — not ten.
    TutorExpect.stockOf('PCE1', 32),
    // Still open: the supplier owes two, and the order says so.
    TutorExpect.lastPurchaseOrderStatus('partially_received'),
  ]),
);

const purchasingLessons = <TutorLesson>[
  purchasingCreatePoLesson,
  purchasingReceiveLesson,
];
