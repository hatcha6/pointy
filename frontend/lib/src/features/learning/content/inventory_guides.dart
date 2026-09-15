import '../../../core/authorization.dart';
import '../../../shared/navigation/app_navigation.dart';
import '../models/learning_guide.dart';

/// Stock: what moves it, how to count it, and what a unit actually costs.
const inventoryGuides = <LearningGuide>[
  LearningGuide(
    id: 'inventory.stock_basics',
    title: 'ما الذي يحرّك المخزون',
    summary: 'خمس عمليات فقط تغيّر الرصيد — وأي رقم غريب سببه واحدة منها.',
    track: LearningTrack.inventory,
    level: LearningLevel.beginner,
    kind: LearningKind.concept,
    minutes: 3,
    capability: AppCapability.viewStock,
    keywords: ['stock', 'inventory', 'مخزون', 'رصيد', 'كمية'],
    related: [
      'inventory.stock_count',
      'inventory.adjustments',
      'purchasing.receive',
    ],
    sections: [
      LearningSection(
        title: 'العمليات التي تحرّك الرصيد',
        blocks: [
          LearningDefinitions([
            LearningDefinition('بيع', 'ينقص بمقدار المبيع، لحظة تأكيد الدفع.'),
            LearningDefinition(
              'استلام أمر شراء',
              'يزيد بما استُلم سليمًا فقط.',
            ),
            LearningDefinition(
              'إرجاع',
              'إرجاع عميل يزيد الرصيد، وإرجاع إلى مورد ينقصه.',
            ),
            LearningDefinition('تطبيق جرد', 'يصحّح الرصيد إلى ما عُدَّ فعلًا.'),
            LearningDefinition(
              'حركة يدوية',
              'تلف، هدية، استعمال داخلي — بسبب مكتوب.',
            ),
          ]),
          LearningParagraph(
            'والتحويل بين الأماكن ينقل الرصيد من مكان إلى آخر بلا تغيير في المجموع.',
          ),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'الرصيد نتيجة لا مدخَل',
            message:
                'لا توجد خانة تكتب فيها «الرصيد الصحيح». إن كان الرقم خاطئًا '
                'فالسبب حركة لم تُسجَّل، والعلاج تسجيلها أو تطبيق جرد.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'inventory.stock_count',
    title: 'الجرد: العدّ وتطبيق الفروقات',
    summary: 'عُدّ أعمى، راجع الفروقات، ثم يطبّقها المدير.',
    track: LearningTrack.inventory,
    level: LearningLevel.intermediate,
    kind: LearningKind.walkthrough,
    minutes: 4,
    capability: AppCapability.countStock,
    keywords: ['stock count', 'جرد', 'عد', 'فروقات', 'مطابقة'],
    related: [
      'inventory.stock_basics',
      'inventory.adjustments',
      'register.variance',
    ],
    opens: AppNavigationDestination.stockCount,
    sections: [
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep(
              'ابدأ جردًا جديدًا واختر نطاقه: كل المنتجات أو تصنيفًا محدّدًا.',
              detail: 'جرد تصنيف واحد أسبوعيًا أنفع من جرد شامل مرة في السنة.',
            ),
            LearningStep(
              'امسح باركود الصنف أو ابحث عنه، ثم أدخل الكمية المعدودة واحفظ.',
              detail:
                  'لا يعرض البرنامج رصيد النظام أثناء العدّ — وهذا مقصود، كالعدّ الأعمى للدرج.',
            ),
            LearningStep(
              'إن عددت صنفًا مرتين، اختر: أضِف إلى العدّة أم استبدلها.',
              detail: 'أضِف حين تعدّ رفًا ثانيًا، واستبدل حين تصحّح خطأ.',
            ),
            LearningStep('اضغط «إنهاء ومراجعة» لعرض الفروقات.'),
            LearningStep(
              'يراجع المدير ويضغط «تطبيق التعديلات».',
              detail:
                  'هنا وحده يتغيّر المخزون. العدّ نفسه لا يغيّر شيئًا ولا يمكن التراجع عن التطبيق.',
            ),
          ]),
        ],
      ),
      LearningSection(
        title: 'قراءة شاشة الفروقات',
        blocks: [
          LearningDefinitions([
            LearningDefinition('النظام', 'ما يقوله الدفتر.'),
            LearningDefinition('المعدود', 'ما أدخلته أنت.'),
            LearningDefinition(
              'نقص',
              'الموجود أقل: بيع بلا فاتورة، تلف غير مسجّل، أو خطأ عدّ.',
            ),
            LearningDefinition(
              'زيادة',
              'الموجود أكثر: استلام غير مسجّل، أو إرجاع لم يُدخَل.',
            ),
          ]),
          LearningNote(
            tone: LearningNoteTone.tip,
            title: 'أعد العدّ قبل التطبيق',
            message:
                'الفروقات الكبيرة تستحق عدّة ثانية. التطبيق يكتب التاريخ، ولا يُمحى.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'inventory.adjustments',
    title: 'حركات المخزون اليدوية',
    summary: 'تلف أو هدية أو استعمال داخلي — سجّلها بسببها.',
    track: LearningTrack.inventory,
    level: LearningLevel.intermediate,
    kind: LearningKind.walkthrough,
    minutes: 2,
    capability: AppCapability.createStockMovement,
    keywords: ['adjustment', 'damage', 'تلف', 'هدر', 'حركة مخزون'],
    related: ['inventory.stock_basics', 'inventory.stock_count'],
    sections: [
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep('افتح بطاقة المنتج ثم حركات المخزون.'),
            LearningStep('أضِف حركة: زيادة أو نقص، بالكمية والسبب.'),
          ]),
          LearningParagraph(
            'اكتب سببًا يفهمه غيرك بعد شهر: «كسر أثناء التفريغ» لا «تعديل».',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'inventory.expiry',
    title: 'تواريخ الانتهاء',
    summary: 'تتبّع الصلاحية من الاستلام حتى التنبيه.',
    track: LearningTrack.inventory,
    level: LearningLevel.intermediate,
    kind: LearningKind.concept,
    minutes: 2,
    capability: AppCapability.viewStock,
    keywords: ['expiry', 'صلاحية', 'انتهاء', 'تاريخ'],
    related: ['purchasing.receive', 'catalog.product_basics'],
    sections: [
      LearningSection(
        title: 'كيف تعمل',
        blocks: [
          LearningParagraph(
            'فعّل «يتابع تاريخ الانتهاء» على المنتج، فيصبح إدخال التاريخ إلزاميًا '
            'عند كل استلام — لا يمكن حفظ أمر شراء بدونه.',
          ),
          LearningParagraph(
            'يفيد ذلك في تنبيهك لما قارب الانتهاء قبل أن يصير خسارة، وفي اختيار '
            'الأقدم أولًا عند الصرف.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'inventory.warehouses',
    title: 'الأماكن والتحويلات بينها',
    summary: 'محل ومخزن وفرع: من أين يبيع كل صندوق وكيف تنقل البضاعة.',
    track: LearningTrack.inventory,
    level: LearningLevel.advanced,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.viewStock,
    keywords: ['warehouse', 'transfer', 'مخزن', 'تحويل', 'فرع', 'مكان'],
    related: ['inventory.stock_basics', 'register.open'],
    sections: [
      LearningSection(
        title: 'الأماكن',
        blocks: [
          LearningParagraph(
            'يمكن للمتجر أن يكون له أكثر من مكان، ولكل صندوق مكان يبيع منه. '
            'مبيعاته تُخصم من رصيد ذلك المكان، والجرد والتقارير تتبعه. تغيير '
            'مكان صندوق يحتاج صلاحية مدير.',
          ),
        ],
      ),
      LearningSection(
        title: 'التحويل',
        blocks: [
          LearningSteps([
            LearningStep('أنشئ تحويلًا جديدًا وحدّد «من» و«إلى».'),
            LearningStep(
              'أضِف الأصناف وكمياتها؛ يمنعك البرنامج من إرسال أكثر مما في المصدر.',
            ),
            LearningStep(
              'أرسل — تصبح البضاعة «في الطريق»، خارج المصدر ولم تصل بعد.',
            ),
            LearningStep(
              'عند الوصول سجّل الاستلام: «وصل كل شيء»، أو عدّل الكميات إن وصل جزء.',
            ),
          ]),
          LearningNote(
            tone: LearningNoteTone.info,
            title: '«في الطريق» حالة حقيقية',
            message:
                'البضاعة المرسَلة ليست في المخزنين معًا ولا في لا مكان: هي في '
                'الطريق، ولذلك يظهر الفرق حين لا يصل كل ما أُرسل.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'inventory.valuation',
    title: 'طريقة تسعير المخزون (تكلفة البيع)',
    summary:
        'المتوسط المتحرك أو FIFO أو LIFO: ما تعنيه ولماذا تُختار مرة واحدة.',
    track: LearningTrack.inventory,
    level: LearningLevel.advanced,
    kind: LearningKind.concept,
    minutes: 4,
    capability: AppCapability.manageShopSettings,
    keywords: ['valuation', 'cogs', 'تكلفة', 'تسعير المخزون', 'fifo', 'متوسط'],
    related: [
      'purchasing.landed_costs',
      'reports.reports',
      'purchasing.cost_guard',
    ],
    sections: [
      LearningSection(
        title: 'السؤال الذي تجيب عنه',
        blocks: [
          LearningParagraph(
            'اشتريت الصنف مرة بعشرة ومرة باثني عشر، ثم بعت واحدة بخمسة عشر. '
            'بكم تكلّفتك هذه الواحدة؟ الجواب يحدّد ربح البيعة، وهو ما تقرّره '
            'طريقة تسعير المخزون.',
          ),
        ],
      ),
      LearningSection(
        title: 'الطرق الثلاث',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'المتوسط المتحرك',
              'تكلفة واحدة موزّعة على كل الكمية، تتغيّر مع كل شراء. الأنسب لمعظم المحلات.',
            ),
            LearningDefinition(
              'الوارد أولًا يصرف أولًا (FIFO)',
              'يُحتسب البيع على تكلفة أقدم بضاعة. الأنسب لذوات الصلاحية.',
            ),
            LearningDefinition(
              'الوارد أخيرًا يصرف أولًا (LIFO)',
              'يُحتسب على تكلفة أحدث بضاعة؛ يرفع التكلفة ويقلّل الربح المُعلن عند ارتفاع الأسعار.',
            ),
          ]),
          LearningNote(
            tone: LearningNoteTone.danger,
            title: 'اخترها مرة واحدة',
            message:
                'تغييرها بعد بدء البيع يجعل أرقام التكلفة والأرباح الجديدة محسوبة '
                'بطريقة مختلفة عن تقارير اعتمدت عليها من قبل — وربما عن عمولات '
                'صُرفت فعلًا. إن اضطررت، فليكن في بداية فترة محاسبية جديدة وبعد '
                'استخراج تقارير السابقة.',
          ),
        ],
      ),
    ],
  ),
];
