import '../../../core/authorization.dart';
import '../../../shared/navigation/app_navigation.dart';
import '../models/learning_guide.dart';

/// Everything that happens on the sell screen before the payment sheet opens.
/// Money — split payments, credit, quotations — lives in the money track.
const sellingGuides = <LearningGuide>[
  LearningGuide(
    id: 'selling.first_sale',
    title: 'بيع نقدي من البداية إلى الإيصال',
    summary: 'أبسط عملية كاملة: أضِف صنفًا، اقبض نقدًا، اطبع.',
    track: LearningTrack.selling,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.checkoutSale,
    keywords: ['sale', 'sell', 'cash', 'بيع', 'كاش', 'نقدي', 'فاتورة'],
    related: [
      'selling.add_items',
      'money.split_tender',
      'register.open',
      'selling.receipt',
    ],
    opens: AppNavigationDestination.pos,
    sections: [
      LearningSection(
        title: 'قبل أن تبدأ',
        blocks: [
          LearningParagraph(
            'تحتاج وردية درج مفتوحة. إن ظهرت لك رسالة «لا توجد جلسة درج '
            'مفتوحة»، افتح الوردية أولًا ثم عد إلى هنا.',
          ),
        ],
      ),
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep(
              'أضِف الصنف: امسح الباركود، أو اكتب في خانة البحث، أو اضغط بطاقة المنتج.',
              detail:
                  'إن كان للمنتج أكثر من خيار (لون/مقاس) ستُطلب منك اختيار الخيار قبل الإضافة.',
            ),
            LearningStep(
              'راجع السلة على اليمين: الكمية والسعر والإجمالي.',
              detail:
                  'لتغيير كمية، اضغط على رقم الكمية واكتب الرقم الجديد ثم Enter.',
            ),
            LearningStep('اضغط «إتمام البيع» (أو Ctrl+Enter).'),
            LearningStep(
              'في نافذة «إتمام الدفع» اترك النوع «عادي»، واختر «نقد».',
            ),
            LearningStep(
              'أدخل المبلغ الذي ناولك إياه العميل، أو اضغط أحد أزرار «مبالغ سريعة».',
              detail:
                  'أول زر هو المبلغ المضبوط، والباقي تقريب لأعلى لأقرب ورقة نقدية معتادة.',
            ),
            LearningStep('تحقّق من «الباقي للعميل» ثم اضغط «تأكيد الدفع».'),
          ]),
          LearningNote(
            tone: LearningNoteTone.tip,
            title: 'الباقي لا يُحسب إلا من النقد',
            message:
                'إن دفع العميل أكثر من المطلوب ببطاقة أو تحويل فلا باقٍ له — '
                'البرنامج يرفض ذلك لأن رد فرق البطاقة نقدًا من الدرج يخلق عجزًا لا مصدر له.',
          ),
        ],
      ),
      LearningSection(
        title: 'ماذا حدث عند التأكيد',
        blocks: [
          LearningBullets([
            'صدرت فاتورة برقم، وتحمل اسمك ورقم ورديتك.',
            'نقصت كميات الأصناف من المخزون فورًا على كل الأجهزة.',
            'دخل المبلغ النقدي إلى درج ورديتك، فصار جزءًا من النقد المتوقع عند الإغلاق.',
          ]),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'selling.add_items',
    title: 'إضافة الأصناف: المسح والبحث والتصنيفات',
    summary: 'أربع طرق لإيصال الصنف إلى السلة، ومتى تستعمل كل واحدة.',
    track: LearningTrack.selling,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.accessPos,
    keywords: ['barcode', 'scan', 'search', 'باركود', 'مسح', 'بحث', 'تصنيف'],
    related: [
      'selling.first_sale',
      'catalog.variants_concept',
      'catalog.categories',
    ],
    opens: AppNavigationDestination.pos,
    sections: [
      LearningSection(
        title: 'الطرق الأربع',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'الماسح الضوئي',
              'الأسرع. وجّه الماسح واقرأ — يُضاف الصنف مباشرة بلا ضغط زر. لا حاجة لوضع المؤشر في خانة البحث.',
            ),
            LearningDefinition(
              'البحث بالكتابة',
              'اكتب جزءًا من الاسم أو الرمز أو الباركود. الخانة تستعيد التركيز تلقائيًا بعد كل إضافة، فيمكنك الكتابة مباشرة للصنف التالي.',
            ),
            LearningDefinition(
              'بطاقات الكتالوج',
              'اضغط على صورة المنتج. مناسب للأصناف التي لا باركود لها (خضار، مشروبات معدّة).',
            ),
            LearningDefinition(
              'شرائح الوصول السريع',
              'التصنيفات المثبّتة أعلى الكتالوج تُرشّح المعروض فورًا، بما في ذلك التصنيفات الفرعية.',
            ),
          ]),
        ],
      ),
      LearningSection(
        title: 'حين لا يُضاف الصنف',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'لم يُعثر على الباركود',
              'الباركود غير مسجّل على أي خيار. سجّله في بطاقة المنتج، أو ابحث بالاسم وأضِف يدويًا الآن.',
            ),
            LearningDefinition(
              'لا توجد خيارات نشطة',
              'المنتج موجود لكن كل خياراته موقوفة عن البيع. يحلّها المدير من الكتالوج.',
            ),
            LearningDefinition(
              'الصنف غير ظاهر أصلًا',
              'إن كان المتجر يمنع البيع بالسالب، فالأصناف التي نفدت لا تظهر في الكتالوج. الخدمات والأصناف المُعدّة تظهر دائمًا.',
            ),
          ]),
        ],
      ),
      LearningSection(
        title: 'سرعة الماسح',
        blocks: [
          LearningNote(
            tone: LearningNoteTone.warning,
            title: 'لا تمسح والمؤشر داخل خانة الكمية',
            message:
                'الماسح يكتب أرقامًا بسرعة عالية. البرنامج يحمي من ذلك، لكن العادة '
                'الآمنة أن تؤكّد الكمية بـ Enter قبل المسح التالي.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'selling.quantities_units',
    title: 'الكمية والوحدة والوزن',
    summary: 'بيع ثلاث علب أو كرتونة أو ٧٥٠ غرامًا من الصنف نفسه.',
    track: LearningTrack.selling,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.accessPos,
    keywords: [
      'quantity',
      'unit',
      'weight',
      'كمية',
      'وحدة',
      'وزن',
      'كرتونة',
      'كيلو',
    ],
    related: ['catalog.units', 'devices.scales'],
    opens: AppNavigationDestination.pos,
    sections: [
      LearningSection(
        title: 'تغيير الكمية',
        blocks: [
          LearningSteps([
            LearningStep('اضغط على رقم الكمية في سطر السلة.'),
            LearningStep('اكتب الكمية الجديدة ثم اضغط Enter لتأكيدها.'),
          ]),
          LearningParagraph(
            'أو استخدم زرَّي + و − على السطر للزيادة والنقصان خطوة خطوة. '
            'لحذف السطر بالكامل اضغط F4 وهو محدَّد.',
          ),
        ],
      ),
      LearningSection(
        title: 'البيع بوحدة أخرى',
        blocks: [
          LearningParagraph(
            'إن كان للمنتج أكثر من وحدة (قطعة، علبة، كرتونة) اختر الوحدة من '
            'السطر، أو اضغط F2 لتدوير الوحدات على السطر المحدَّد.',
          ),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'المخزون يبقى بالوحدة الأساسية',
            message:
                'بيع كرتونة فيها ١٢ علبة ينقص ١٢ من المخزون. السعر يتبع الوحدة '
                'المختارة، والمخزون يتبع الوحدة الأساسية دائمًا.',
          ),
        ],
      ),
      LearningSection(
        title: 'البيع بالوزن',
        blocks: [
          LearningParagraph(
            'للأصناف الموزونة تظهر نافذة «أدخل الوزن». اكتب الوزن كما يظهر على '
            'الميزان. وإن كان الميزان يطبع ملصقًا بباركود، فمسحه يضيف الصنف '
            'بوزنه وسعره دفعة واحدة.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'selling.held_invoices',
    title: 'الفواتير المعلّقة: زبونان في وقت واحد',
    summary: 'علِّق فاتورة وابدأ أخرى، ثم عُد إلى الأولى بلا فقدان شيء.',
    track: LearningTrack.selling,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 2,
    capability: AppCapability.accessPos,
    keywords: ['hold', 'park', 'معلقة', 'تعليق', 'فاتورة ثانية'],
    related: ['selling.first_sale', 'selling.shortcuts'],
    opens: AppNavigationDestination.pos,
    sections: [
      LearningSection(
        title: 'متى تحتاجها',
        blocks: [
          LearningParagraph(
            'عميل نسي شيئًا وذهب ليأتي به، أو يريد أن يتصل ليسأل. بدل إلغاء '
            'السلة أو إيقاف الطابور، علِّق الفاتورة وابدأ واحدة جديدة.',
          ),
        ],
      ),
      LearningSection(
        title: 'الاستعمال',
        blocks: [
          LearningSteps([
            LearningStep(
              'اضغط «فاتورة جديدة» (أو F1). تُحفظ الحالية معلّقة وتفتح فاتورة فارغة.',
            ),
            LearningStep(
              'للتنقّل بين الفواتير المفتوحة استخدم Page Down و Page Up، أو افتح قائمة «الفواتير المفتوحة».',
            ),
            LearningStep(
              'أكمل أي فاتورة بالدفع كالمعتاد؛ تختفي من القائمة عند إصدارها.',
            ),
          ]),
          LearningNote(
            tone: LearningNoteTone.warning,
            title: 'المعلّقة ليست بيعًا',
            message:
                'الفاتورة المعلّقة لا تخصم مخزونًا ولا تدخل تقريرًا. إن خرجت '
                'البضاعة مع العميل فهي بيع — عادي أو آجل — لا فاتورة معلّقة.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'selling.customer',
    title: 'ربط عميل بالفاتورة',
    summary: 'متى يكون العميل اختياريًا ومتى يصبح شرطًا لإتمام البيع.',
    track: LearningTrack.selling,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 2,
    capability: AppCapability.accessPos,
    keywords: ['customer', 'عميل', 'زبون', 'حساب'],
    related: [
      'money.credit_sale',
      'contacts.customer_file',
      'money.credit_limits',
    ],
    sections: [
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep('اضغط زر العميل أعلى السلة.'),
            LearningStep(
              'ابحث بالاسم أو رقم الهاتف، أو أنشئ عميلًا جديدًا من النافذة نفسها.',
            ),
          ]),
        ],
      ),
      LearningSection(
        title: 'متى يكون إلزاميًا',
        blocks: [
          LearningBullets([
            'البيع الآجل: لا دَين بلا اسم يُطالَب به.',
            'عرض السعر: العرض موجّه لجهة معيّنة.',
          ]),
          LearningParagraph(
            'في البيع العادي هو اختياري، لكن ربطه يبني تاريخ شراء العميل — '
            'وهو ما تقوم عليه المرتجعات السهلة، والعروض الموجّهة، وتصنيف العملاء.',
          ),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'إن لم تجد زر العميل',
            message:
                'صلاحية وصول الكاشير إلى العملاء يضبطها المدير من إعدادات المتجر.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'selling.modifiers',
    title: 'الإضافات المسعّرة على الصنف',
    summary: 'قهوة كبيرة بحليب إضافي: كيف تُختار الإضافات وكيف تُحسب.',
    track: LearningTrack.selling,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 2,
    capability: AppCapability.accessPos,
    keywords: ['modifiers', 'options', 'إضافات', 'قهوة', 'مطعم', 'كافيه'],
    related: ['catalog.modifiers_setup', 'operations.kitchen'],
    sections: [
      LearningSection(
        title: 'كيف تعمل',
        blocks: [
          LearningParagraph(
            'إن كان للصنف مجموعات إضافات، تفتح نافذة الاختيار عند إضافته. '
            'المجموعة قد تكون إلزامية (لا بد من اختيار) أو اختيارية، وقد تسمح '
            'باختيار واحد أو عدة اختيارات بحد أقصى.',
          ),
          LearningParagraph(
            'يظهر السعر الإضافي بجانب كل خيار، ويتحدّث إجمالي السطر فورًا. '
            'السعر النهائي يُحسب على الخادم لا على الجهاز، فلا يمكن لجهاز '
            'مضبوط خطأ أن يبيع بسعر مختلف.',
          ),
          LearningNote(
            tone: LearningNoteTone.tip,
            title: 'تعديل الاختيارات بعد الإضافة',
            message: 'اضغط على السطر في السلة ثم «تعديل الخيارات».',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'selling.discounts',
    title: 'الخصومات على شاشة البيع',
    summary: 'الفرق بين الخصم التلقائي وكود الخصم، ولماذا لا يظهر خصم توقّعته.',
    track: LearningTrack.selling,
    level: LearningLevel.intermediate,
    kind: LearningKind.concept,
    minutes: 3,
    capability: AppCapability.accessPos,
    keywords: ['discount', 'coupon', 'خصم', 'كوبون', 'عرض', 'تخفيض'],
    related: ['setup.discount_rules', 'money.split_tender'],
    sections: [
      LearningSection(
        title: 'نوعان فقط',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'خصم تلقائي',
              'قاعدة يضبطها المدير وتنطبق وحدها متى تحقّقت شروطها. لا يفعل الكاشير شيئًا.',
            ),
            LearningDefinition(
              'كود خصم',
              'لا ينطبق حتى يُدخَل الكود في السلة.',
            ),
          ]),
        ],
      ),
      LearningSection(
        title: 'لماذا لم يظهر الخصم؟',
        blocks: [
          LearningBullets([
            'لم تتحقق شروط القاعدة: أقل مبلغ، أقل كمية، تصنيف محدّد، أو فئة عملاء.',
            'القاعدة خارج فترتها أو خارج أوقات عملها.',
            'القاعدة مخصّصة لقناة بيع أخرى.',
            'القاعدة موقوفة.',
          ]),
          LearningParagraph(
            'يحسم الخادم كل ذلك ويعيد للسلة الخصم المطبَّق مسمّى باسمه، فما تراه '
            'في السلة هو ما سيُسجَّل في الفاتورة.',
          ),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'إن تعذّر حساب الخصم',
            message:
                'عند تعذّر الوصول لمحرّك الخصم يطلب البرنامج تأكيدك قبل المتابعة '
                'بالسعر بلا خصم، بدل أن يوقف الطابور.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'selling.receipt',
    title: 'الطباعة والمشاركة وإعادة الطباعة',
    summary:
        'ما يُطبع تلقائيًا، وكيف ترسل الفاتورة على واتساب، وكيف تعيد طباعتها.',
    track: LearningTrack.selling,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.accessPos,
    keywords: [
      'print',
      'receipt',
      'pdf',
      'whatsapp',
      'طباعة',
      'إيصال',
      'مشاركة',
    ],
    related: ['devices.printers', 'reports.invoices'],
    sections: [
      LearningSection(
        title: 'وقت الدفع',
        blocks: [
          LearningParagraph(
            'في نافذة الدفع مفتاحان: «طباعة الفاتورة بعد الدفع» و«مشاركة PDF '
            'بعد الدفع». الأول يرسل للطابعة الحرارية، والثاني يجهّز ملفًا '
            'ترسله على واتساب أو تحفظه.',
          ),
          LearningNote(
            tone: LearningNoteTone.tip,
            title: 'الطباعة لا توقف البيع',
            message:
                'إن تعثّرت الطابعة، تُسجَّل الفاتورة على كل حال وتظهر رسالة. '
                'البيع لا ينتظر ورقة.',
          ),
        ],
      ),
      LearningSection(
        title: 'الطباعة التلقائية',
        blocks: [
          LearningParagraph(
            'يمكن للمتجر تفعيل الطباعة التلقائية مع حدّ أدنى: لا تُطبع فاتورة '
            'رغيف خبز واحد، وتُطبع فاتورة تسوق كاملة. الفواتير الآجلة وعروض '
            'الأسعار تُطبع دائمًا لأنها مستند يحتاجه العميل.',
          ),
        ],
      ),
      LearningSection(
        title: 'إعادة الطباعة لاحقًا',
        blocks: [
          LearningSteps([
            LearningStep('افتح «الفواتير» وابحث عن الفاتورة برقمها.'),
            LearningStep('من إجراءات الفاتورة اختر الطباعة أو مشاركة PDF.'),
          ]),
          LearningParagraph(
            'تُسجَّل كل إعادة طباعة في سجل النشاط — إعادة طباعة إيصال ليست '
            'إصدار فاتورة جديدة، والسجل يثبت ذلك.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'selling.shortcuts',
    title: 'اختصارات لوحة المفاتيح على شاشة البيع',
    summary: 'كل الاختصارات في جدول واحد — تعمل من أي مكان في الشاشة.',
    track: LearningTrack.selling,
    level: LearningLevel.intermediate,
    kind: LearningKind.reference,
    minutes: 2,
    capability: AppCapability.accessPos,
    keywords: [
      'shortcuts',
      'keyboard',
      'اختصارات',
      'لوحة المفاتيح',
      'F1',
      'F2',
    ],
    related: ['selling.held_invoices', 'money.split_tender'],
    opens: AppNavigationDestination.pos,
    sections: [
      LearningSection(
        title: 'على شاشة البيع',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'F1',
              'تعليق الفاتورة الحالية وفتح واحدة جديدة.',
            ),
            LearningDefinition(
              'Page Down / Page Up',
              'التنقّل بين الفواتير المفتوحة.',
            ),
            LearningDefinition('F2', 'تبديل وحدة القياس للسطر المحدَّد.'),
            LearningDefinition('F4', 'حذف السطر المحدَّد.'),
            LearningDefinition('Ctrl+Enter (أو ⌘+Enter)', 'فتح نافذة الدفع.'),
            LearningDefinition(
              'Ctrl+K (أو ⌘K)',
              'لوحة الأوامر: انتقل لأي شاشة أو ابحث عن أي شيء.',
            ),
          ]),
        ],
      ),
      LearningSection(
        title: 'داخل نافذة الدفع',
        blocks: [
          LearningDefinitions([
            LearningDefinition('Ctrl+1 (أو ⌘1)', 'اختيار النقد.'),
            LearningDefinition('Ctrl+2 (أو ⌘2)', 'اختيار البطاقة.'),
            LearningDefinition('Ctrl+3 (أو ⌘3)', 'اختيار التحويل.'),
            LearningDefinition('Enter', 'تأكيد الدفع إن كان مكتملًا.'),
            LearningDefinition('Esc', 'إلغاء والعودة إلى السلة.'),
          ]),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'لماذا Ctrl مع الأرقام',
            message:
                'الأرقام وحدها كانت تختار طريقة الدفع حتى والمؤشر في خانة المبلغ، '
                'فلا يمكن كتابة مبلغ الدفعة في الدفع المقسوم. مع Ctrl صار الرقم '
                'وحده يُكتب في الخانة، والاختصار يعمل من أي مكان في النافذة.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'selling.out_of_stock',
    title: 'البيع عند نفاد الكمية',
    summary: 'لماذا يختفي صنف من الكتالوج، وماذا يعني السماح بالبيع بالسالب.',
    track: LearningTrack.selling,
    level: LearningLevel.intermediate,
    kind: LearningKind.concept,
    minutes: 2,
    capability: AppCapability.accessPos,
    keywords: ['stock', 'oversell', 'نفد', 'مخزون', 'سالب'],
    related: ['inventory.stock_basics', 'setup.shop_settings'],
    sections: [
      LearningSection(
        title: 'الوضعان',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'منع البيع بالسالب',
              'الأصناف التي نفدت لا تظهر في كتالوج البيع أصلًا، فلا يمكن بيع ما ليس موجودًا.',
            ),
            LearningDefinition(
              'السماح بالبيع بالسالب',
              'تظهر كل الأصناف ويمكن البيع، ويصبح المخزون سالبًا حتى يصل التوريد.',
            ),
          ]),
          LearningParagraph(
            'الخدمات والأصناف المُعدّة عند الطلب تظهر دائمًا في الحالتين — لا '
            'معنى لرصيد مخزون لقص شعر أو لشطيرة تُحضَّر وقت الطلب.',
          ),
          LearningNote(
            tone: LearningNoteTone.warning,
            title: 'المخزون السالب ليس عطلًا',
            message:
                'هو إخبار بأن البيع سبق التسجيل: إما أن توريدًا لم يُسجَّل، أو أن '
                'جردًا ناقصًا لم يُطبَّق. عالجه بالتسجيل، لا بتعديل الرقم يدويًا.',
          ),
        ],
      ),
    ],
  ),
];
