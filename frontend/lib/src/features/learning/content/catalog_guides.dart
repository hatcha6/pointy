import '../../../core/authorization.dart';
import '../../../shared/navigation/app_navigation.dart';
import '../models/learning_guide.dart';

/// Products, variants, units, barcodes, prices — everything that decides what
/// the sell screen can ring up and at what price.
const catalogGuides = <LearningGuide>[
  LearningGuide(
    id: 'catalog.product_basics',
    title: 'إنشاء منتج جديد',
    summary: 'أقل ما يحتاجه المنتج ليصبح قابلًا للبيع، وما يمكن تأجيله.',
    track: LearningTrack.catalog,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 4,
    capability: AppCapability.createProduct,
    keywords: ['product', 'create', 'منتج', 'صنف', 'إضافة منتج'],
    related: [
      'catalog.variants_concept',
      'catalog.units',
      'catalog.barcodes',
      'catalog.categories',
    ],
    opens: AppNavigationDestination.catalog,
    sections: [
      LearningSection(
        title: 'الحد الأدنى',
        blocks: [
          LearningSteps([
            LearningStep('افتح «المنتجات» ثم «منتج جديد».'),
            LearningStep('اكتب الاسم كما ينطقه الزبون، لا كما يكتبه المورد.'),
            LearningStep('حدّد الوحدة الأساسية (قطعة، كيلو، لتر…).'),
            LearningStep('أدخل سعر البيع، وأضِف الباركود إن وُجد.'),
            LearningStep('احفظ.'),
          ]),
          LearningParagraph(
            'التصنيف والصورة ومجموعات الإضافات والوحدات الإضافية كلها يمكن '
            'إضافتها لاحقًا. لا توقف إدخال البضاعة انتظارًا لها.',
          ),
        ],
      ),
      LearningSection(
        title: 'أنواع لها معاملة خاصة',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'خدمة',
              'لا مخزون لها ولا تنفد: قص شعر، تركيب، أجرة صيانة.',
            ),
            LearningDefinition(
              'يُحضَّر عند الطلب',
              'شطيرة أو عصير يُصنع وقت البيع. لا يُمنع بيعه لنفاد رصيد، والخصم يقع على مكوّنات الوصفة.',
            ),
            LearningDefinition(
              'يتابع تاريخ الانتهاء',
              'يُطلب تاريخ الانتهاء عند كل استلام.',
            ),
          ]),
        ],
      ),
      LearningSection(
        title: 'التكرار في الرمز أو الباركود',
        blocks: [
          LearningParagraph(
            'لا يقبل البرنامج رمزًا (SKU) أو باركودًا مستعملًا في خيار آخر، '
            'ويخبرك بالحقل المكرّر وبالمنتج الذي يحمله. باركود واحد لصنفين '
            'يعني ماسحًا لا يعرف ما يبيع.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'catalog.variants_concept',
    title: 'ما هي الخيارات (Variants) وما فائدتها',
    summary:
        'لماذا «تي شيرت» ليس صنفًا واحدًا، ولماذا هذا يوفّر عليك عملًا لا يضيفه.',
    track: LearningTrack.catalog,
    level: LearningLevel.beginner,
    kind: LearningKind.concept,
    minutes: 5,
    capability: AppCapability.viewCatalogManagement,
    keywords: [
      'variant',
      'variants',
      'options',
      'خيارات',
      'متغيرات',
      'مقاسات',
      'ألوان',
      'أحجام',
    ],
    related: [
      'catalog.variants_create',
      'catalog.product_basics',
      'catalog.units',
      'selling.add_items',
    ],
    sections: [
      LearningSection(
        title: 'الفكرة في سطرين',
        blocks: [
          LearningParagraph(
            'المنتج هو العنوان: «تي شيرت قطن». والخيار هو الشيء الذي يُباع '
            'فعلًا: «تي شيرت قطن — أحمر — L». الزبون يسأل عن العنوان، والدرج '
            'والمخزون يتعاملان مع الخيار.',
          ),
          LearningParagraph(
            'لذلك يعيش على الخيار كل ما يختلف بين قطعة وأخرى: السعر، الباركود، '
            'الرمز، الكمية المتاحة، وهل هو متاح للبيع. وتبقى على المنتج الأشياء '
            'المشتركة: الاسم، الوصف، التصنيف، الوحدة الأساسية، الصور.',
          ),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'كل منتج له خيار — حتى البسيط',
            message:
                'المنتج الذي لا اختلاف فيه (كيس ملح) له خيار واحد افتراضي، يُنشأ '
                'تلقائيًا ولا تراه أصلًا. فلا يوجد «منتج بلا خيارات» في الدفتر، '
                'ولهذا لا تختلف طريقة البيع بين الحالتين.',
          ),
        ],
      ),
      LearningSection(
        title: 'البديل الذي يستعمله كثيرون، ولماذا يتعب',
        blocks: [
          LearningParagraph(
            'الطريقة الشائعة هي إنشاء منتج مستقل لكل تركيبة: «تي شيرت أحمر L»، '
            '«تي شيرت أحمر M»، «تي شيرت أزرق L»… عشرون منتجًا لقميص واحد.',
          ),
          LearningBullets([
            'أي تعديل يتكرّر عشرين مرة: تغيير الاسم، الصورة، التصنيف، الوصف.',
            'لا يمكن الإجابة عن «كم بعنا من هذا القميص؟» إلا بجمع عشرين سطرًا يدويًا.',
            'الكاشير يبحث في قائمة ملأى بأسماء متشابهة، فيختار الخطأ.',
            'لا تعرف أي مقاس ينفد أولًا، لأن لا شيء يربط المقاسات ببعضها.',
          ]),
        ],
      ),
      LearningSection(
        title: 'ما تكسبه بالخيارات',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'كتالوج مقروء',
              'بطاقة واحدة على شاشة البيع بدل عشرين. يضغطها الكاشير فتُعرض عليه '
                  'الخيارات مع الكمية المتاحة لكل خيار.',
            ),
            LearningDefinition(
              'مخزون دقيق لكل تركيبة',
              'تعرف أن الأحمر L نفد بينما الأزرق M راكد — وهذا وحده يغيّر ما تشتريه المرة القادمة.',
            ),
            LearningDefinition(
              'تعديل مرة واحدة',
              'اسم أو صورة أو تصنيف يتغيّر على المنتج فيسري على كل خياراته.',
            ),
            LearningDefinition(
              'تسعير مرن',
              'المقاس الكبير بسعر أعلى، بلا اختلاق منتج ثانٍ.',
            ),
            LearningDefinition(
              'تقارير على المستويين',
              'إجمالي مبيعات المنتج، وتفصيل مبيعات كل خيار، من نفس البيانات.',
            ),
            LearningDefinition(
              'خصومات تصيب هدفها',
              'قاعدة خصم تُطبَّق على المنتج كله، أو على خيارات بعينها (المقاس الراكد مثلًا).',
            ),
          ]),
        ],
      ),
      LearningSection(
        title: 'متى لا تستعملها',
        blocks: [
          LearningParagraph(
            'الخيارات لأشياء يختلف فيها ما يُباع اختلافًا حقيقيًا (لون، مقاس، '
            'نكهة، سعة). لا تستعملها لأشياء أخرى تشبهها ظاهريًا:',
          ),
          LearningBullets([
            'اختلاف حجم العبوة (علبة/كرتونة) شأن «وحدات القياس»، لا الخيارات.',
            'إضافات وقت البيع (سكر زائد، بدون بصل) شأن «مجموعات الإضافات».',
            'اختلاف المورد أو سعر الشراء لا يصنع خيارًا — هو نفس الشيء اشتُري مرتين.',
          ]),
          LearningNote(
            tone: LearningNoteTone.tip,
            title: 'سؤال الحسم',
            message:
                'هل يريد الزبون شيئًا مختلفًا فعلًا، أم الشيء نفسه بكمية أو تجهيز مختلف؟ '
                'الأول خيار، والثاني وحدة أو إضافة.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'catalog.variants_create',
    title: 'إنشاء الخيارات وتوليدها',
    summary: 'عرّف اللون والمقاس مرة، ودع البرنامج يولّد كل التركيبات.',
    track: LearningTrack.catalog,
    level: LearningLevel.intermediate,
    kind: LearningKind.walkthrough,
    minutes: 5,
    capability: AppCapability.createProductVariant,
    keywords: [
      'generate variants',
      'توليد',
      'خيارات',
      'مقاس',
      'لون',
      'تركيبات',
    ],
    related: ['catalog.variants_concept', 'catalog.barcodes', 'catalog.prices'],
    opens: AppNavigationDestination.catalog,
    sections: [
      LearningSection(
        title: 'الطريقة السريعة: التوليد',
        blocks: [
          LearningSteps([
            LearningStep(
              'افتح المنتج ثم قسم «خيارات المنتج»، وأضِف خيارًا مثل «اللون».',
              detail:
                  'ابحث في الخيارات المحفوظة أولًا — إعادة استعمال «اللون» نفسه '
                  'عبر المنتجات يبقي التقارير قابلة للتجميع.',
            ),
            LearningStep('أدخل قيم الخيار: أحمر، أزرق، أسود.'),
            LearningStep(
              'أضِف خيارًا ثانيًا إن لزم، مثل «المقاس» بقيم S و M و L.',
            ),
            LearningStep(
              'اضغط «توليد الخيارات».',
              detail:
                  'تُعرض كل التركيبات الممكنة (٣ ألوان × ٣ مقاسات = ٩) مع '
                  'استبعاد ما هو موجود منها سلفًا.',
            ),
            LearningStep(
              'حدّد التركيبات التي تريدها فعلًا وأدخل سعرًا موحّدًا لها.',
              detail: 'لست مضطرًا لأخذ كل التركيبات؛ خذ ما تبيعه حقًا.',
            ),
            LearningStep(
              'احفظ، ثم عدّل سعر أو باركود أي خيار على حدة عند الحاجة.',
            ),
          ]),
          LearningNote(
            tone: LearningNoteTone.warning,
            title: 'عدد التركيبات يتضاعف بسرعة',
            message:
                'ثلاثة خيارات بعشر قيم لكل منها يعني ألف تركيبة. إن ظهرت رسالة '
                '«عدد الخيارات المولدة كبير جدًا» فقلّل القيم أو ولّد على دفعات.',
          ),
        ],
      ),
      LearningSection(
        title: 'الطريقة اليدوية',
        blocks: [
          LearningParagraph(
            'للمنتجات ذات الخيارات القليلة غير المنتظمة، أضِف كل خيار بنفسك من '
            '«إضافة خيار»: اسمه، سعره، رمزه، باركوده، وهل هو متاح للبيع.',
          ),
        ],
      ),
      LearningSection(
        title: 'إدارة الخيارات بعد الإنشاء',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'متاح للبيع',
              'إيقافه يخفي الخيار عن شاشة البيع بلا حذف تاريخه.',
            ),
            LearningDefinition(
              'الخيار الافتراضي',
              'ما يُختار تلقائيًا حين يُضاف المنتج بلا تحديد.',
            ),
            LearningDefinition(
              'المخزون',
              'لكل خيار رصيده؛ لا يوجد رصيد على مستوى المنتج إلا كمجموع.',
            ),
            LearningDefinition(
              'الباركود',
              'لكل خيار باركوده. ملصقات الباركود تُطبع لكل خيار على حدة.',
            ),
          ]),
          LearningNote(
            tone: LearningNoteTone.danger,
            title: 'لا تحذف خيارًا بِيع من قبل',
            message:
                'أوقفه عن البيع بدل حذفه. الفواتير القديمة تشير إليه، وحذفه يترك '
                'تاريخًا لا يمكن قراءته.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'catalog.units',
    title: 'وحدات القياس: قطعة وعلبة وكرتونة',
    summary: 'بيع واشترِ الصنف نفسه بوحدات مختلفة، والمخزون يبقى صحيحًا.',
    track: LearningTrack.catalog,
    level: LearningLevel.intermediate,
    kind: LearningKind.concept,
    minutes: 4,
    capability: AppCapability.viewCatalogManagement,
    keywords: [
      'unit',
      'uom',
      'pack',
      'وحدة',
      'كرتونة',
      'علبة',
      'كيلو',
      'تحويل',
    ],
    related: [
      'catalog.variants_concept',
      'selling.quantities_units',
      'purchasing.create_po',
    ],
    sections: [
      LearningSection(
        title: 'الفكرة',
        blocks: [
          LearningParagraph(
            'لكل منتج وحدة أساسية واحدة يُحفظ بها المخزون. الوحدات الأخرى تُعرَّف '
            'بمعامل تحويل إليها: الكرتونة = ١٢ علبة، والعلبة = ٦ قطع.',
          ),
          LearningParagraph(
            'تشتري بالكرتونة وتبيع بالقطعة، ويتولّى البرنامج التحويل. الرصيد '
            'يُعرض ويُحسب بالوحدة الأساسية دائمًا، فلا يختلف رقمان على شاشتين.',
          ),
        ],
      ),
      LearningSection(
        title: 'التسعير لكل وحدة',
        blocks: [
          LearningParagraph(
            'يمكن إعطاء كل وحدة سعرها: القطعة بدينار ونصف، والكرتونة بستة عشر '
            'دينارًا (لا بثمانية عشر). هذا هو سعر الجملة، ولا يحتاج منتجًا ثانيًا.',
          ),
          LearningParagraph(
            'يمكن أيضًا إعطاء كل وحدة باركودها الخاص، فمسح باركود الكرتونة يضيف '
            'كرتونة، ومسح باركود القطعة يضيف قطعة.',
          ),
          LearningNote(
            tone: LearningNoteTone.tip,
            title: 'اضبط الوحدة الافتراضية لكل جهة',
            message:
                'عيّن وحدة افتراضية للبيع وأخرى للشراء، فيفتح الكاشير على القطعة '
                'ويفتح المشتري على الكرتونة بلا تبديل يدوي كل مرة.',
          ),
        ],
      ),
      LearningSection(
        title: 'التكلفة والوحدات',
        blocks: [
          LearningParagraph(
            'تُسجَّل تكلفة الشراء بوحدة الشراء (تكلفة الكرتونة)، وتُقسَم على معامل '
            'التحويل لتصير تكلفة الوحدة الأساسية. لذلك لا بد أن يكون معامل '
            'التحويل صحيحًا — معامل خاطئ يُنتج ربحًا وهميًا أو خسارة وهمية على كل بيعة.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'catalog.barcodes',
    title: 'الباركود وملصقاته',
    summary: 'ربط الباركود بالخيار الصحيح، وطباعة ملصقات للأصناف بلا باركود.',
    track: LearningTrack.catalog,
    level: LearningLevel.intermediate,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.changeProduct,
    keywords: ['barcode', 'label', 'باركود', 'ملصق', 'طباعة ملصقات'],
    related: ['catalog.variants_create', 'devices.labels', 'selling.add_items'],
    sections: [
      LearningSection(
        title: 'أين يُسجَّل',
        blocks: [
          LearningParagraph(
            'الباركود يخصّ الخيار لا المنتج: لكل لون ومقاس باركوده. ويمكن أيضًا '
            'إعطاء وحدة معيّنة باركودها (باركود الكرتونة).',
          ),
          LearningParagraph(
            'لا يُقبل باركود مستعمل في مكان آخر؛ يعرض البرنامج الصنف الذي يحمله '
            'حتى تعرف أين التعارض.',
          ),
        ],
      ),
      LearningSection(
        title: 'أصناف بلا باركود',
        blocks: [
          LearningSteps([
            LearningStep('اترك حقل الباركود فارغًا واعتمد البحث بالاسم.'),
            LearningStep(
              'أو اطبع ملصق باركود من البرنامج وألصقه على الصنف.',
              detail: 'مفيد للبضاعة السائبة والمعبّأة محليًا.',
            ),
          ]),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'catalog.categories',
    title: 'التصنيفات والوصول السريع',
    summary: 'رتّب الكتالوج وثبّت أكثر التصنيفات استعمالًا فوق شاشة البيع.',
    track: LearningTrack.catalog,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 2,
    capability: AppCapability.manageCategories,
    keywords: ['category', 'تصنيف', 'قسم', 'مجموعة', 'وصول سريع'],
    related: ['selling.add_items', 'catalog.product_basics'],
    opens: AppNavigationDestination.categories,
    sections: [
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep(
              'افتح «التصنيفات» وأنشئ تصنيفًا، ويمكن جعله تحت تصنيف آخر.',
            ),
            LearningStep('اربط المنتجات بتصنيفاتها من بطاقة المنتج.'),
            LearningStep(
              'ثبّت التصنيفات الأكثر استعمالًا ورتّبها.',
              detail:
                  'تظهر كشرائح فوق كتالوج البيع، وضغطها يرشّح المعروض فورًا.',
            ),
          ]),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'الترشيح يشمل التصنيفات الفرعية',
            message: 'اختيار «مشروبات» يعرض «مشروبات غازية» و«عصائر» معه.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'catalog.prices',
    title: 'تغيير الأسعار',
    summary: 'سعر خيار واحد، أو أسعار منتج كامل، أو تعديل جماعي.',
    track: LearningTrack.catalog,
    level: LearningLevel.intermediate,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.changeProduct,
    keywords: ['price', 'pricing', 'سعر', 'تسعير', 'رفع الأسعار'],
    related: ['catalog.bulk', 'purchasing.cost_guard', 'setup.discount_rules'],
    sections: [
      LearningSection(
        title: 'ثلاث طرق',
        blocks: [
          LearningDefinitions([
            LearningDefinition('خيار واحد', 'من بطاقة الخيار مباشرة.'),
            LearningDefinition(
              'كل خيارات منتج',
              'من نافذة تسعير المنتج، وتعرض سعرًا لكل خيار ولكل وحدة.',
            ),
            LearningDefinition(
              'تعديل جماعي',
              'حدّد عدة منتجات من القائمة وطبّق تغييرًا واحدًا عليها.',
            ),
          ]),
          LearningNote(
            tone: LearningNoteTone.warning,
            title: 'سعر أقل من التكلفة',
            message:
                'ينبّهك البرنامج حين لا يغطّي سعر البيع تكلفة الشراء، ويمكن '
                'للمتجر منع البيع بخسارة تمامًا من الإعدادات.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'catalog.modifiers_setup',
    title: 'إعداد مجموعات الإضافات',
    summary: 'عرّف «الحجم» أو «الإضافات» مرة واربطها بالأصناف المعنية.',
    track: LearningTrack.catalog,
    level: LearningLevel.intermediate,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.manageShopSettings,
    keywords: ['modifier', 'addon', 'إضافات', 'حجم', 'كافيه', 'مطعم'],
    related: ['selling.modifiers', 'operations.kitchen'],
    sections: [
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep('من الإعدادات افتح «مجموعات الإضافات» وأنشئ مجموعة.'),
            LearningStep(
              'حدّد سلوكها: إلزامية أم اختيارية، اختيار واحد أم عدة، وأقصى عدد.',
            ),
            LearningStep(
              'أضِف الخيارات وسعر كل منها الإضافي، وعيّن الافتراضي.',
            ),
            LearningStep(
              'اربط المجموعة بالمنتجات التي تستعملها من بطاقة المنتج.',
            ),
          ]),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'catalog.archive',
    title: 'أرشفة منتج بدل حذفه',
    summary: 'أخرِج الصنف من الاستعمال مع إبقاء تاريخه سليمًا.',
    track: LearningTrack.catalog,
    level: LearningLevel.intermediate,
    kind: LearningKind.concept,
    minutes: 2,
    capability: AppCapability.changeProduct,
    keywords: ['archive', 'delete', 'أرشفة', 'حذف منتج', 'إيقاف'],
    related: ['catalog.variants_create', 'catalog.bulk'],
    sections: [
      LearningSection(
        title: 'الفرق بين ثلاث حالات',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'متاح للبيع (موقوف مؤقتًا)',
              'الصنف باقٍ لكنه لا يظهر في شاشة البيع — نفد موسمه مثلًا.',
            ),
            LearningDefinition(
              'مؤرشف',
              'خرج من الاستعمال نهائيًا: يختفي من القوائم الاعتيادية ويبقى في التقارير والفواتير القديمة. يمكن استرجاعه.',
            ),
            LearningDefinition(
              'محذوف',
              'غير متاح لمنتج له تاريخ. الأرشفة هي البديل الصحيح.',
            ),
          ]),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'catalog.bulk',
    title: 'العمليات الجماعية على المنتجات',
    summary: 'أرشِف أو سعّر أو صنّف عشرات المنتجات دفعة واحدة.',
    track: LearningTrack.catalog,
    level: LearningLevel.intermediate,
    kind: LearningKind.walkthrough,
    minutes: 2,
    capability: AppCapability.changeProduct,
    keywords: ['bulk', 'multi select', 'جماعي', 'تحديد متعدد', 'دفعة'],
    related: ['catalog.prices', 'catalog.archive', 'catalog.categories'],
    sections: [
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep('من قائمة المنتجات فعّل التحديد المتعدّد.'),
            LearningStep(
              'حدّد المنتجات — أو رشّح القائمة أولًا ثم حدّد المعروض.',
            ),
            LearningStep('اختر الإجراء: أرشفة، تغيير سعر، أو تغيير تصنيف.'),
          ]),
          LearningNote(
            tone: LearningNoteTone.tip,
            title: 'رشِّح قبل أن تحدّد',
            message:
                'ابحث عن «صيفي» أو رشّح بتصنيف، ثم طبّق الإجراء على النتيجة — أسرع وأقل خطأً من التحديد يدويًا.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'catalog.recipes',
    title: 'الوصفات والأصناف المُحضَّرة',
    summary: 'بيع شطيرة يخصم مكوّناتها من المخزون.',
    track: LearningTrack.catalog,
    level: LearningLevel.advanced,
    kind: LearningKind.concept,
    minutes: 3,
    capability: AppCapability.viewRecipes,
    keywords: ['recipe', 'وصفة', 'مكونات', 'تحضير', 'مطعم'],
    related: [
      'operations.kitchen',
      'catalog.product_basics',
      'inventory.stock_basics',
    ],
    sections: [
      LearningSection(
        title: 'كيف تعمل',
        blocks: [
          LearningParagraph(
            'الوصفة تربط صنفًا يُباع بمكوّناته: شطيرة = خبزة + ١٥٠غ لحم + جبن. '
            'عند البيع تُخصم المكوّنات بدل الصنف نفسه، لأن الشطيرة لم تكن موجودة '
            'في الرف أصلًا.',
          ),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'المُحضَّر لا يُمنع لنفاد رصيده',
            message:
                'الصنف المُحضَّر عند الطلب لا رصيد له، فحارس المخزون لا يوقف بيعه. '
                'ما يحدّ منه هو نفاد مكوّناته.',
          ),
        ],
      ),
    ],
  ),
];
