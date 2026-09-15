import '../../../core/authorization.dart';
import '../../../shared/navigation/app_navigation.dart';
import '../models/learning_guide.dart';

/// Shop configuration, connectivity, and the one-off jobs an owner does once.
const setupGuides = <LearningGuide>[
  LearningGuide(
    id: 'setup.connection',
    title: 'كيف يعثر التطبيق على خادم المتجر',
    summary: 'الاكتشاف التلقائي على الشبكة، والاتصال اليدوي حين يفشل.',
    track: LearningTrack.setup,
    level: LearningLevel.intermediate,
    kind: LearningKind.concept,
    minutes: 3,
    keywords: ['connection', 'discovery', 'اتصال', 'شبكة', 'خادم', 'IP'],
    related: [
      'setup.remote_access',
      'start.how_pointy_works',
      'setup.troubleshooting',
    ],
    sections: [
      LearningSection(
        title: 'ما يحدث عند فتح التطبيق',
        blocks: [
          LearningParagraph(
            'يبحث التطبيق عن الخادم على الشبكة المحلية بثلاث طرق في وقت واحد: '
            'العنوان الذي نجح آخر مرة، ونداء عام على الشبكة، ومسح لعناوين '
            'الشبكة. أسرعها يفوز.',
          ),
          LearningParagraph(
            'لذلك لا يحتاج المتجر عنوانًا ثابتًا للخادم: لو غيّر الراوتر عنوانه '
            'بعد انقطاع الكهرباء، فالعنوان القديم مجرّد تخمين يخسر السباق، ولا '
            'يمنع الاتصال.',
          ),
        ],
      ),
      LearningSection(
        title: 'الاتصال اليدوي',
        blocks: [
          LearningParagraph(
            'إن لم يُعثر على الخادم تظهر شاشة «تعذّر العثور على الخادم '
            'تلقائيًا». أدخل عنوان الخادم (مثل 192.168.1.10) واضغط «اتصال»، أو '
            'دع «إعادة المحاولة تلقائيًا» تعمل — البحث في الخلفية لا يتوقف.',
          ),
          LearningBullets([
            'تأكّد أن الجهاز على شبكة المتجر نفسها لا على شبكة الضيوف.',
            'تأكّد أن جهاز الخادم يعمل ولم ينطفئ مع انقطاع الكهرباء.',
            'شبكات الهواتف (4G) لا تصل إلى شبكة المتجر المحلية — هذا ما يحلّه الوصول عن بُعد.',
          ]),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'setup.remote_access',
    title: 'الوصول عن بُعد: تشغيل التطبيق خارج المتجر',
    summary: 'اقترن بالجهاز داخل المتجر مرة واحدة، ثم افتح متجرك من أي مكان.',
    track: LearningTrack.setup,
    level: LearningLevel.intermediate,
    kind: LearningKind.concept,
    minutes: 5,
    keywords: [
      'remote',
      'remote access',
      'relay',
      'pairing',
      'وصول عن بعد',
      'عن بعد',
      'اقتران',
      'من البيت',
      'خارج المتجر',
      'انترنت',
    ],
    related: [
      'setup.connection',
      'setup.subscription',
      'setup.troubleshooting',
    ],
    sections: [
      LearningSection(
        title: 'الفكرة في جملة',
        blocks: [
          LearningParagraph(
            'جهازك يتعرّف على متجرك مرة واحدة وهو داخل المتجر، فيحتفظ بهوية '
            'موثّقة تتيح له لاحقًا الوصول إلى الخادم نفسه عبر الإنترنت — بلا '
            'عنوان ثابت، وبلا فتح أي منفذ في راوتر المتجر.',
          ),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'ليست نسخة ثانية من بياناتك',
            message:
                'أنت تفتح الخادم نفسه الذي في المتجر. ما تراه عن بُعد هو ما يراه '
                'الكاشير في اللحظة نفسها، وما تعدّله يُعدَّل هناك فورًا.',
          ),
        ],
      ),
      LearningSection(
        title: 'الخطوة الأولى: الاقتران داخل المتجر',
        blocks: [
          LearningSteps([
            LearningStep(
              'خذ الجهاز (هاتفك أو حاسوبك) إلى المتجر، وصِله بشبكة المتجر نفسها.',
              detail:
                  'لا بد أن يكون على الشبكة المحلية فعليًا، لا عبر بيانات الهاتف.',
            ),
            LearningStep(
              'افتح التطبيق ودعه يعثر على الخادم.',
              detail: 'يظهر اسم المتجر عند نجاح الاتصال.',
            ),
            LearningStep(
              'سجّل الدخول بحسابك.',
              detail:
                  'هنا يقع الاقتران تلقائيًا: لا يوجد زر «اقتران» تضغطه. دخول '
                  'ناجح على الشبكة المحلية هو الإثبات المطلوب.',
            ),
          ]),
          LearningNote(
            tone: LearningNoteTone.warning,
            title: 'لماذا يجب أن يكون الاقتران على الشبكة المحلية؟',
            message:
                'الوجود داخل المتجر هو الدليل على أنك لست غريبًا. لو أمكن '
                'الاقتران من الإنترنت لكان الوصول إلى متجرك مسألة تخمين كلمة مرور.',
          ),
        ],
      ),
      LearningSection(
        title: 'الخطوة الثانية: الاستعمال خارج المتجر',
        blocks: [
          LearningParagraph(
            'افتح التطبيق من أي مكان. يبحث أولًا عن الخادم على الشبكة المحلية، '
            'فلا يجده، فيتحوّل تلقائيًا إلى الوصول عن بُعد. لا تفعل شيئًا: التحوّل '
            'ليس خيارًا تختاره في كل مرة.',
          ),
          LearningParagraph(
            'وحين تعود إلى المتجر يعود الاتصال إلى الشبكة المحلية وحده، لأنها '
            'أسرع. يبقى التطبيق يبحث عنها في الخلفية حتى وهو يعمل عن بُعد.',
          ),
        ],
      ),
      LearningSection(
        title: 'ما يجب أن يتحقّق لينجح',
        blocks: [
          LearningBullets([
            'اشتراك «الوصول عن بُعد» مُفعّل لهذا المتجر.',
            'جهاز الخادم في المتجر يعمل ومتصل بالإنترنت — هو الطرف الذي يُسأل، وإن كان مطفأً فلا شيء يُجيب.',
            'جهازك أنت متصل بالإنترنت (بيانات الهاتف تكفي).',
            'الجهاز اقترن من قبل داخل المتجر ولم تنقضِ صلاحية اقترانه.',
          ]),
          LearningNote(
            tone: LearningNoteTone.danger,
            title: 'الخطأ الأشيع',
            message:
                'إنترنت في هاتفك وحده لا يكفي. إن انقطع الإنترنت عن المتجر أو '
                'انطفأ جهاز الخادم، فلا يوجد ما تتصل به مهما كان اتصالك جيدًا.',
          ),
        ],
      ),
      LearningSection(
        title: 'حين يتوقّف الوصول عن بُعد',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'انتهت صلاحية الاقتران وأنت بعيد',
              'الحل الوحيد أن تعود إلى شبكة المتجر وتسجّل الدخول مرة واحدة. لا يمكن تجديد الاقتران من بعيد بعد انقضائه — وهذا مقصود.',
            ),
            LearningDefinition(
              'الاشتراك غير مفعّل',
              'يظهر «الوصول عن بُعد غير مُفعّل» في إعدادات الاشتراك. البيع داخل المتجر لا يتأثّر إطلاقًا.',
            ),
            LearningDefinition(
              'جهاز جديد',
              'كل جهاز يقترن بنفسه. هاتف جديد لا يرث اقتران القديم.',
            ),
          ]),
        ],
      ),
      LearningSection(
        title: 'ماذا يفتح لك الوصول عن بُعد',
        blocks: [
          LearningParagraph(
            'التطبيق نفسه بصلاحياتك نفسها: المبيعات لحظة بلحظة، أرصدة العملاء، '
            'أوامر الشراء، التقارير، وتعديل الأسعار. صلاحياتك لا تتغيّر لأنك '
            'خارج المتجر.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'setup.subscription',
    title: 'حالة الاشتراك ورقم التثبيت',
    summary: 'أين ترى ما هو مفعّل لمتجرك، وأي رقم يطلبه الدعم منك.',
    track: LearningTrack.setup,
    level: LearningLevel.intermediate,
    kind: LearningKind.reference,
    minutes: 2,
    capability: AppCapability.manageShopSettings,
    keywords: ['subscription', 'اشتراك', 'رقم التثبيت', 'تفعيل'],
    related: ['setup.remote_access', 'setup.ai'],
    opens: AppNavigationDestination.settings,
    sections: [
      LearningSection(
        title: 'أين',
        blocks: [
          LearningParagraph(
            'من «إعدادات المتجر» افتح صفحة حالة الاشتراك. تعرض «رقم التثبيت» — '
            'وهو معرّف متجرك عندنا، انسخه حين يطلبه الدعم — وحالة كل ميزة '
            'مشتركة: الوصول عن بُعد، والمساعد الذكي.',
          ),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'ميزتان مستقلّتان',
            message:
                'يمكن أن يكون المساعد الذكي مفعّلًا والوصول عن بُعد غير مفعّل، '
                'أو العكس. ولا علاقة لأيّهما بقدرة المتجر على البيع.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'setup.wizard',
    title: 'معالج الإعداد الأول',
    summary: 'اختيار نوع النشاط يضبط عشرات الإعدادات دفعة واحدة.',
    track: LearningTrack.setup,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 2,
    capability: AppCapability.manageShopSettings,
    keywords: ['setup', 'wizard', 'إعداد', 'معالج', 'تهيئة', 'نوع النشاط'],
    related: ['setup.shop_settings', 'catalog.product_basics'],
    sections: [
      LearningSection(
        title: 'ماذا يفعل',
        blocks: [
          LearningParagraph(
            'يظهر المعالج مرة واحدة على متجر جديد. تختار فيه نوع النشاط (بقالة، '
            'مطعم، هواتف وصيانة، ملابس…) فتُضبط الميزات المناسبة له: عمليات '
            'المطبخ، عمليات الصيانة، السماح بالبيع بالسالب، رصيد الدرج '
            'الافتتاحي، وغيرها.',
          ),
          LearningParagraph(
            'كلها إعدادات يمكن تغييرها لاحقًا. النوع اختصار لنقطة بداية معقولة، '
            'لا قفل دائم.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'setup.shop_settings',
    title: 'إعدادات المتجر: ما تعنيه الخيارات المهمة',
    summary: 'الإعدادات التي تغيّر سلوك البيع فعليًا، لا شكله.',
    track: LearningTrack.setup,
    level: LearningLevel.advanced,
    kind: LearningKind.reference,
    minutes: 4,
    capability: AppCapability.manageShopSettings,
    keywords: ['settings', 'إعدادات', 'خيارات', 'ضبط'],
    related: ['selling.out_of_stock', 'money.credit_limits', 'selling.receipt'],
    opens: AppNavigationDestination.settings,
    sections: [
      LearningSection(
        title: 'البيع والدفع',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'طرق الدفع المفعّلة',
              'ما يظهر للكاشير في نافذة الدفع. أطفئ ما لا يستعمله متجرك.',
            ),
            LearningDefinition(
              'اشتراط إثبات إيصال البطاقة',
              'يمنع تأكيد دفعة بطاقة بلا مطابقة إيصالها.',
            ),
            LearningDefinition(
              'السماح بالبيع بالسالب',
              'هل يمكن بيع صنف نفد رصيده.',
            ),
            LearningDefinition(
              'منع البيع بخسارة',
              'يمنع بيعًا بسعر أقل من التكلفة.',
            ),
            LearningDefinition(
              'التنبيه لقلة المخزون قبل البيع',
              'تحذير للكاشير عند بيع صنف شارف على النفاد.',
            ),
          ]),
        ],
      ),
      LearningSection(
        title: 'العملاء والآجل',
        blocks: [
          LearningDefinitions([
            LearningDefinition('اشتراط عميل للبيع الآجل', 'لا دَين بلا اسم.'),
            LearningDefinition(
              'وصول الكاشير إلى العملاء',
              'هل يستطيع الكاشير البحث عن العملاء وإنشاءهم.',
            ),
            LearningDefinition(
              'تفعيل سقف الدين',
              'مغلق افتراضيًا؛ عند تفعيله يُرفض الآجل الذي يتجاوز السقف.',
            ),
          ]),
        ],
      ),
      LearningSection(
        title: 'الدرج والطباعة',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'طلب نقدية افتتاح الجلسة',
              'يُلزم الكاشير بعدّ الدرج عند الفتح.',
            ),
            LearningDefinition(
              'مدة صلاحية الإرجاع للكاشير',
              'كم يبقى بإمكان الكاشير إرجاع فاتورة بنفسه.',
            ),
            LearningDefinition(
              'الطباعة التلقائية للفواتير',
              'مع حدّ أدنى يمنع طباعة إيصال لصنف واحد زهيد.',
            ),
            LearningDefinition(
              'حد الشراء النقدي من شاشة البيع',
              'أقصى قيمة لشراء نقدي واحد من الدرج.',
            ),
          ]),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'setup.discount_rules',
    title: 'إنشاء قاعدة خصم',
    summary: 'خصم تلقائي أو كود، بشروط وفترة وجمهور محدّد.',
    track: LearningTrack.setup,
    level: LearningLevel.advanced,
    kind: LearningKind.walkthrough,
    minutes: 4,
    capability: AppCapability.createDiscountRule,
    keywords: ['discount rule', 'خصم', 'عرض', 'قاعدة', 'كوبون'],
    related: ['selling.discounts', 'contacts.segments'],
    opens: AppNavigationDestination.discounts,
    sections: [
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep('افتح «الخصومات» وأنشئ قاعدة.'),
            LearningStep('حدّد نوع القيمة: نسبة مئوية أو مبلغ ثابت.'),
            LearningStep(
              'حدّد النطاق: الفاتورة كلها، أو سطر بعينه، أو منتجات وتصنيفات محدّدة.',
            ),
            LearningStep(
              'اضبط الشروط: أقل مبلغ، أقل كمية، فئة عملاء، قناة البيع.',
            ),
            LearningStep('اضبط الفترة وأولوية القاعدة.'),
            LearningStep(
              'اقرأ الملخّص بالعربية أسفل النموذج قبل الحفظ.',
              detail: 'إن لم تكن الجملة تصف ما تريده، فالقاعدة ليست ما تريده.',
            ),
          ]),
        ],
      ),
      LearningSection(
        title: 'عروض الكميات',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'اشترِ كذا واحصل على كذا',
              'مجانًا أو بخصم على الوحدة الإضافية.',
            ),
            LearningDefinition(
              'سعر الكمية',
              'سعر أقل عند شراء عدد معيّن فأكثر.',
            ),
            LearningDefinition('شرائح', 'خصم يزيد كلما زادت الكمية.'),
          ]),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'setup.migration',
    title: 'استيراد بياناتك من نظام قديم',
    summary: 'ارفع ملف نظامك السابق، وراجع ما اكتُشف قبل الاستيراد.',
    track: LearningTrack.setup,
    level: LearningLevel.advanced,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.manageShopSettings,
    keywords: ['migration', 'import', 'استيراد', 'ترحيل', 'نظام قديم'],
    related: ['catalog.product_basics', 'contacts.customers'],
    sections: [
      LearningSection(
        title: 'كيف تعمل',
        blocks: [
          LearningSteps([
            LearningStep('ارفع ملف قاعدة بيانات نظامك القديم.'),
            LearningStep(
              'ينظر البرنامج في الملف ويعرض ما وجده: منتجات، عملاء، موردون، فواتير.',
            ),
            LearningStep('راجع الملخّص واختر ما تستورده.'),
            LearningStep('نفّذ الاستيراد، ثم يُحذف الملف المرفوع.'),
          ]),
          LearningNote(
            tone: LearningNoteTone.tip,
            title: 'ابدأ بالمنتجات والأرصدة',
            message:
                'المهم أن تبدأ البيع بأسماء وأسعار وأرصدة صحيحة. تاريخ الفواتير '
                'القديم مفيد لكنه ليس شرطًا للانطلاق.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'setup.updates',
    title: 'تحديث التطبيق على الأجهزة',
    summary: 'كل جهاز يحدّث نفسه من خادم المتجر، بلا متجر تطبيقات.',
    track: LearningTrack.setup,
    level: LearningLevel.intermediate,
    kind: LearningKind.walkthrough,
    minutes: 2,
    capability: AppCapability.manageDeviceSettings,
    keywords: ['update', 'تحديث', 'إصدار', 'نسخة'],
    related: ['setup.connection', 'devices.printers'],
    opens: AppNavigationDestination.deviceSettings,
    sections: [
      LearningSection(
        title: 'الطريقة',
        blocks: [
          LearningParagraph(
            'من «إعدادات الجهاز» يظهر التحديث المتاح من خادم المتجر. تحمّله '
            'وتثبّته من الشبكة المحلية مباشرة — لا حاجة إلى متجر تطبيقات ولا '
            'إلى إنترنت على الجهاز.',
          ),
          LearningParagraph(
            'لتثبيت التطبيق على جهاز جديد، افتح إعدادات الجهاز على جهاز يعمل '
            'وامسح رمز QR بالجهاز الجديد.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'setup.ai',
    title: 'المساعد الذكي',
    summary: 'اسأل عن بياناتك بالعربية، وصوّر فاتورة ليقرأها.',
    track: LearningTrack.setup,
    level: LearningLevel.intermediate,
    kind: LearningKind.concept,
    minutes: 3,
    capability: AppCapability.useAiAssistant,
    keywords: ['ai', 'assistant', 'ذكاء', 'مساعد', 'محادثة'],
    related: ['setup.subscription', 'reports.reports', 'purchasing.create_po'],
    opens: AppNavigationDestination.aiAssistant,
    sections: [
      LearningSection(
        title: 'ما يفعله',
        blocks: [
          LearningBullets([
            'يجيب عن أسئلة بيانات متجرك: «كم بعنا اليوم؟»، «من أكثر العملاء دَينًا؟».',
            'يرسم النتيجة جدولًا أو رسمًا حين يكون ذلك أوضح من الكلام.',
            'يفتح لك الشاشة المعنية مباشرة من داخل الإجابة.',
            'يقرأ صورة فاتورة مورد ويبني منها مسودة أمر شراء تراجعها أنت.',
            'يقبل رسالة صوتية بدل الكتابة.',
          ]),
          LearningNote(
            tone: LearningNoteTone.warning,
            title: 'راجع قبل أن تعتمد',
            message:
                'ما يبنيه المساعد مسودة تراجعها، لا قرارًا نُفِّذ. وهو ميزة '
                'باشتراك مستقل عن الوصول عن بُعد.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'setup.troubleshooting',
    title: 'حين لا يعمل شيء: أول خمس خطوات',
    summary: 'ترتيب الفحص قبل الاتصال بالدعم.',
    track: LearningTrack.setup,
    level: LearningLevel.beginner,
    kind: LearningKind.reference,
    minutes: 3,
    keywords: ['troubleshoot', 'مشكلة', 'عطل', 'لا يعمل', 'دعم'],
    related: ['setup.connection', 'setup.remote_access', 'devices.printers'],
    sections: [
      LearningSection(
        title: 'بالترتيب',
        blocks: [
          LearningSteps([
            LearningStep(
              'هل جهاز الخادم في المتجر يعمل؟ أكثر الأعطال انقطاع كهرباء عنه.',
            ),
            LearningStep(
              'هل جهازك على شبكة المتجر نفسها؟ تحقّق من اسم الشبكة.',
            ),
            LearningStep(
              'أغلق التطبيق وافتحه — يعيد البحث عن الخادم من الصفر.',
            ),
            LearningStep('جرّب الاتصال اليدوي بعنوان الخادم إن كنت تعرفه.'),
            LearningStep(
              'إن بقيت المشكلة، خذ رقم التثبيت من صفحة الاشتراك واتصل بالدعم.',
            ),
          ]),
        ],
      ),
      LearningSection(
        title: 'أعطال شائعة لها حلول بسيطة',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'الطابعة لا تطبع',
              'افحص الاتصال من إعدادات الطابعات، وتأكّد من الورق. البيع يستمر بلا طباعة.',
            ),
            LearningDefinition(
              'الماسح يكتب في المكان الخطأ',
              'اضغط داخل الكتالوج أولًا، ولا تمسح وخانة الكمية قيد التعديل.',
            ),
            LearningDefinition(
              'لا أرى شاشة يذكرها الدليل',
              'دورك لا يشملها. يغيّرها المدير من «المستخدمون».',
            ),
            LearningDefinition(
              'الأرقام مختلفة عن جهاز آخر',
              'أعد تحميل الشاشة. البيانات واحدة على الخادم، والشاشة القديمة صورة قديمة فحسب.',
            ),
          ]),
        ],
      ),
    ],
  ),
];
