/// The catalogue: what the shop sells, and every code that scans to it.
///
/// Back-office lessons, so they run as the practice manager — a cashier cannot
/// open the catalogue at all, and seeding one would land the learner on a
/// permissions message.
library;

import '../../../core/authorization.dart';
import '../../../shared/tutor/anchors.dart';
import '../engine/lesson.dart';

/// A product from nothing: name, code, barcode, price.
const catalogCreateProductLesson = TutorLesson(
  id: 'catalog.create_product',
  title: 'إضافة منتج جديد',
  summary: 'أنشئ صنفًا باسمه ورمزه وباركوده وسعره.',
  seed: SandboxSeed.groceryBackOffice,
  capability: AppCapability.createProduct,
  guideId: 'catalog.product_basics',
  steps: [
    TutorStep(
      say: 'افتح «الأصناف» من القائمة الجانبية.',
      anchor: TutorAnchor.navigationDestination,
      anchorId: 'catalog',
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.catalogAddProductButton),
      hint: 'القائمة على حافة الشاشة، وفيها كل الشاشات.',
    ),
    TutorStep(
      say: 'اضغط «إضافة منتج» أعلى قائمة الأصناف.',
      anchor: TutorAnchor.catalogAddProductButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.productNameField),
      hint: 'الزر الأخضر بجانب خانة البحث.',
    ),
    TutorStep(
      say: 'اكتب اسم الصنف: «شاي أسود».',
      anchor: TutorAnchor.productNameField,
      act: TutorAct.type('شاي أسود'),
      expect: TutorExpect.fieldEquals(TutorAnchor.productNameField, 'شاي أسود'),
      hint: 'الاسم هو ما يبحث به الكاشير، فاكتبه كما ينطقه.',
    ),
    TutorStep(
      say: 'اضغط «التالي» للانتقال إلى بيانات البيع.',
      anchor: TutorAnchor.productFormPrimaryButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.productSkuField),
      hint: 'الصفحة الأولى للمنتج، والثانية للخيار الذي يُباع.',
    ),
    TutorStep(
      say: 'اكتب رمز الصنف (SKU): TEA1.',
      anchor: TutorAnchor.productSkuField,
      act: TutorAct.type('TEA1'),
      expect: TutorExpect.fieldEquals(TutorAnchor.productSkuField, 'TEA1'),
      hint: 'رمز داخلي قصير تعرفه أنت — غير الباركود.',
    ),
    TutorStep(
      say: 'اكتب الباركود المطبوع على العلبة: 6001000000998.',
      anchor: TutorAnchor.productBarcodeField,
      act: TutorAct.type('6001000000998'),
      expect: TutorExpect.fieldEquals(
        TutorAnchor.productBarcodeField,
        '6001000000998',
      ),
      hint: 'يمكنك مسحه بالقارئ بدل كتابته.',
    ),
    TutorStep(
      say: 'اكتب سعر البيع: 6.50.',
      anchor: TutorAnchor.productPriceField,
      act: TutorAct.type('6.50'),
      expect: TutorExpect.fieldEquals(TutorAnchor.productPriceField, '6.50'),
      hint: 'السعر يخصّ الخيار لا المنتج.',
    ),
    TutorStep(
      say: 'اضغط «إنشاء المنتج».',
      anchor: TutorAnchor.productFormPrimaryButton,
      act: TutorAct.tap(),
      expect: TutorExpect.productCount(13),
      hint: 'الصنف يظهر في الكتالوج فورًا.',
    ),
  ],
  outcome: TutorExpect.all([
    TutorExpect.productCount(13),
    TutorExpect.unitPriceOf('TEA1', 6.50),
    // Created with no stock. A shop that expects a new product to arrive stocked
    // is a shop that will oversell it — stock arrives through a purchase order.
    TutorExpect.stockOf('TEA1', 0),
  ]),
);

/// One product, several codes: the piece and the carton each scan to it.
const catalogCartonBarcodeLesson = TutorLesson(
  id: 'catalog.carton_barcode',
  title: 'باركود ثانٍ للكرتونة',
  summary: 'أعطِ الكرتونة باركودها الخاص إلى جانب باركود الحبة.',
  seed: SandboxSeed.groceryBackOffice,
  capability: AppCapability.createProduct,
  guideId: 'catalog.barcodes',
  requires: ['catalog.create_product'],
  steps: [
    TutorStep(
      say: 'افتح «الأصناف» من القائمة الجانبية.',
      anchor: TutorAnchor.navigationDestination,
      anchorId: 'catalog',
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.catalogAddProductButton),
      hint: 'القائمة على حافة الشاشة، وفيها كل الشاشات.',
    ),
    TutorStep(
      say: 'اضغط «إضافة منتج».',
      anchor: TutorAnchor.catalogAddProductButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.productNameField),
      hint: 'الزر الأخضر بجانب خانة البحث.',
    ),
    TutorStep(
      say: 'اكتب الاسم: «معكرونة».',
      anchor: TutorAnchor.productNameField,
      act: TutorAct.type('معكرونة'),
      expect: TutorExpect.fieldEquals(TutorAnchor.productNameField, 'معكرونة'),
      hint: 'الاسم كما ينطقه الكاشير.',
    ),
    TutorStep(
      say: 'أضِف وحدة تعبئة — الكرتونة — بالضغط على «إضافة وحدة».',
      anchor: TutorAnchor.productAddUnitButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.productUnitBarcodeField),
      hint: 'قسم «وحدات القياس» أسفل الصفحة الأولى.',
    ),
    TutorStep(
      say: 'اكتب باركود الكرتونة: 6001000000981.',
      anchor: TutorAnchor.productUnitBarcodeField,
      act: TutorAct.type('6001000000981'),
      expect: TutorExpect.fieldEquals(
        TutorAnchor.productUnitBarcodeField,
        '6001000000981',
      ),
      hint: 'الباركود المطبوع على الكرتونة نفسها، لا على الحبة.',
    ),
    TutorStep(
      say: 'اضغط زر الإضافة ليُسجَّل الباركود على الكرتونة.',
      anchor: TutorAnchor.productUnitAddBarcodeButton,
      act: TutorAct.tap(),
      // The field empties and the code becomes a chip: the same field is ready
      // for the next carton code, which is how a wedge scanner is used here.
      expect: TutorExpect.fieldEquals(TutorAnchor.productUnitBarcodeField, ''),
      hint: 'يمكن إضافة أكثر من باركود للوحدة الواحدة.',
    ),
    TutorStep(
      say: 'اضغط «التالي».',
      anchor: TutorAnchor.productFormPrimaryButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.productSkuField),
      hint: 'بقي أن نعطي الحبة رمزها وسعرها.',
    ),
    TutorStep(
      say: 'اكتب رمز الحبة: PASTA1.',
      anchor: TutorAnchor.productSkuField,
      act: TutorAct.type('PASTA1'),
      expect: TutorExpect.fieldEquals(TutorAnchor.productSkuField, 'PASTA1'),
      hint: 'رمز داخلي قصير.',
    ),
    TutorStep(
      say: 'اكتب باركود الحبة: 6001000000974.',
      anchor: TutorAnchor.productBarcodeField,
      act: TutorAct.type('6001000000974'),
      expect: TutorExpect.fieldEquals(
        TutorAnchor.productBarcodeField,
        '6001000000974',
      ),
      hint: 'باركود مختلف عن باركود الكرتونة.',
    ),
    TutorStep(
      say: 'اكتب سعر الحبة: 2.25.',
      anchor: TutorAnchor.productPriceField,
      act: TutorAct.type('2.25'),
      expect: TutorExpect.fieldEquals(TutorAnchor.productPriceField, '2.25'),
      hint: 'سعر الحبة الواحدة.',
    ),
    TutorStep(
      say: 'اضغط «إنشاء المنتج».',
      anchor: TutorAnchor.productFormPrimaryButton,
      act: TutorAct.tap(),
      expect: TutorExpect.productCount(13),
      hint: 'الآن يقرأ البرنامج الباركودين لنفس الصنف.',
    ),
  ],
  outcome: TutorExpect.all([
    TutorExpect.productCount(13),
    TutorExpect.unitPriceOf('PASTA1', 2.25),
    // Two codes on one product: the piece's own, and the carton's.
    TutorExpect.barcodeCountOf('PASTA1', 2),
  ]),
);

/// One product, three sizes — generated rather than typed three times.
///
/// The idea worth carrying away is in the outcome: this is *one* product with
/// three things that sell. Creating three separate products instead is the
/// mistake that makes a catalogue unreadable and every report wrong.
const catalogVariantsLesson = TutorLesson(
  id: 'catalog.create_variants',
  title: 'منتج بخيارات (مقاسات)',
  summary: 'عرّف المقاس مرة، ودع البرنامج يولّد الخيارات الثلاثة.',
  seed: SandboxSeed.groceryBackOffice,
  capability: AppCapability.createProductVariant,
  guideId: 'catalog.variants_create',
  requires: ['catalog.create_product'],
  steps: [
    TutorStep(
      say: 'افتح «الأصناف» من القائمة الجانبية.',
      anchor: TutorAnchor.navigationDestination,
      anchorId: 'catalog',
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.catalogAddProductButton),
      hint: 'القائمة على حافة الشاشة، وفيها كل الشاشات.',
    ),
    TutorStep(
      say: 'اضغط «إضافة منتج».',
      anchor: TutorAnchor.catalogAddProductButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.productNameField),
      hint: 'الزر الأخضر بجانب خانة البحث.',
    ),
    TutorStep(
      say: 'اكتب الاسم: «قفازات عمل».',
      anchor: TutorAnchor.productNameField,
      act: TutorAct.type('قفازات عمل'),
      expect: TutorExpect.fieldEquals(
        TutorAnchor.productNameField,
        'قفازات عمل',
      ),
      hint: 'اسم واحد لكل المقاسات — المقاس خيار، لا منتج مستقل.',
    ),
    TutorStep(
      say: 'افتح قائمة «خيارات المنتج».',
      anchor: TutorAnchor.productVariantOptionPicker,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(
        TutorAnchor.searchablePickerRow,
        id: 'المقاس',
      ),
      hint: 'ابحث في الخيارات المحفوظة قبل إنشاء خيار جديد.',
    ),
    TutorStep(
      say: 'اختر «المقاس» — خيار محفوظ بقيمه الثلاث.',
      anchor: TutorAnchor.searchablePickerRow,
      anchorId: 'المقاس',
      act: TutorAct.tap(),
      // Reusing one saved option across products is what keeps reports
      // groupable; a second "المقاس" typed by hand would not aggregate with it.
      expect: TutorExpect.anchorCount(TutorAnchor.searchablePickerRow, 0),
      hint: 'إعادة استعمال الخيار نفسه تُبقي التقارير قابلة للتجميع.',
    ),
    TutorStep(
      say: 'اضغط «التالي».',
      anchor: TutorAnchor.productFormPrimaryButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.productSkuPrefixField),
      hint: 'الصفحة الثانية تولّد التركيبات.',
    ),
    TutorStep(
      say: 'اكتب بادئة الرمز: GLOVE.',
      anchor: TutorAnchor.productSkuPrefixField,
      act: TutorAct.type('GLOVE'),
      expect: TutorExpect.fieldEquals(
        TutorAnchor.productSkuPrefixField,
        'GLOVE',
      ),
      hint: 'يُكمل البرنامج الرمز لكل مقاس من هذه البادئة.',
    ),
    TutorStep(
      say: 'اكتب السعر الموحّد: 8.',
      anchor: TutorAnchor.productGeneratedPriceField,
      act: TutorAct.type('8'),
      expect: TutorExpect.fieldEquals(
        TutorAnchor.productGeneratedPriceField,
        '8',
      ),
      hint: 'يمكن تعديل سعر أي مقاس على حدة بعد الحفظ.',
    ),
    TutorStep(
      say: 'اختر كل المقاسات الثلاثة دفعة واحدة.',
      anchor: TutorAnchor.productVariantOptionValuesSelectAll,
      anchorId: 'المقاس',
      act: TutorAct.tap(),
      // The shortcut offers only the values not yet taken, so it disappears
      // once they all are — which is the proof that they were.
      expect: TutorExpect.anchorCount(
        TutorAnchor.productVariantOptionValuesSelectAll,
        0,
      ),
      hint: 'خذ ما تبيعه فعلًا — لست مضطرًا لأخذ كل التركيبات.',
    ),
    TutorStep(
      say: 'اضغط «إنشاء المنتج».',
      anchor: TutorAnchor.productFormPrimaryButton,
      act: TutorAct.tap(),
      expect: TutorExpect.productCount(13),
      hint: 'ثلاثة مقاسات تحت صنف واحد.',
    ),
  ],
  outcome: TutorExpect.all([
    TutorExpect.productCount(13),
    // One product, three sellable things. Three separate products would give
    // productCount 15 and a catalogue nobody can read.
    TutorExpect.variantCountOf('قفازات عمل', 3),
    TutorExpect.unitPriceOf('GLOVE-S', 8),
  ]),
);

const catalogLessons = <TutorLesson>[
  catalogCreateProductLesson,
  catalogVariantsLesson,
  catalogCartonBarcodeLesson,
];
