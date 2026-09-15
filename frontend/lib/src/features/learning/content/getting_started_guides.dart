import '../../../core/authorization.dart';
import '../../../shared/navigation/app_navigation.dart';
import '../models/learning_guide.dart';

/// The orientation track: what the software is, how the pieces fit, and the
/// words the rest of the library uses.
const gettingStartedGuides = <LearningGuide>[
  LearningGuide(
    id: 'start.how_pointy_works',
    title: 'كيف يعمل دفتر؟',
    summary:
        'صورة كاملة عن الخادم والأجهزة والدفتر الواحد قبل أن تلمس أي شاشة.',
    track: LearningTrack.gettingStarted,
    level: LearningLevel.beginner,
    kind: LearningKind.concept,
    minutes: 4,
    keywords: ['architecture', 'server', 'backend', 'خادم', 'سيرفر', 'شبكة'],
    related: ['setup.connection', 'setup.remote_access', 'start.glossary'],
    sections: [
      LearningSection(
        title: 'دفتر واحد، لا دفاتر متعددة',
        blocks: [
          LearningParagraph(
            'في المتجر جهاز واحد يحمل البيانات كلها — نسميه «الخادم». كل جهاز '
            'آخر (كاشير ثانٍ، هاتف المدير، جهاز فحص الأسعار) لا يحتفظ بنسخته '
            'الخاصة من المخزون أو المبيعات، بل يسأل الخادم ويعرض ما عنده.',
          ),
          LearningParagraph(
            'نتيجة ذلك بسيطة وهي أهم ما في البرنامج: إذا باع كاشير قطعة، تنقص '
            'الكمية فورًا على كل جهاز آخر. لا يوجد «مخزون على جهازي» و«مخزون على '
            'جهازك» يحتاجان مطابقة في آخر اليوم.',
          ),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'لماذا لا يعمل البرنامج بلا شبكة؟',
            message:
                'لأن الرقم الصحيح أهم من الاستمرار في البيع. جهاز يبيع وحده ثم '
                'يزامن لاحقًا يبيع قطعًا نفدت فعلًا، ويُنتج دفترين لا يتطابقان. '
                'إن انقطعت الشبكة، عالج الشبكة — البيانات لم تُفقد.',
          ),
        ],
      ),
      LearningSection(
        title: 'ما الذي يسجّله البرنامج فعلًا',
        blocks: [
          LearningBullets([
            'كل عملية بيع، ومن نفّذها، وفي أي وردية درج.',
            'كل حركة مخزون: بيع، شراء، إرجاع، جرد، تحويل، تلف.',
            'كل دينار: ما دخل الدرج، ما خرج منه، وما بقي دَينًا على العملاء أو لك عند الموردين.',
          ]),
          LearningParagraph(
            'لذلك لا يوجد في دفتر «حذف» لفاتورة. ما حدث حدث، ويُصحَّح بعملية '
            'معاكسة مُسجّلة (إرجاع، إلغاء، تعديل) يبقى أثرها ظاهرًا. هذه ليست '
            'صرامة بلا سبب: دفتر يمكن محوه لا يصلح للاحتجاج به على أحد.',
          ),
        ],
      ),
      LearningSection(
        title: 'من يرى ماذا',
        blocks: [
          LearningParagraph(
            'لكل مستخدم دور (كاشير، مشرف، مدير مخزون، محاسب…) والدور يحدّد ما '
            'يظهر له. إن كنت لا ترى شاشة يذكرها هذا الدليل، فالغالب أن دورك لا '
            'يشملها — وهذا إعداد يغيّره المدير، لا عطل.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'start.navigation',
    title: 'التنقّل بين الشاشات والبحث السريع',
    summary: 'القائمة الجانبية، وفتح أي شاشة باختصار واحد بدل البحث عنها.',
    track: LearningTrack.gettingStarted,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 2,
    keywords: ['navigation', 'menu', 'command palette', 'قائمة', 'اختصار'],
    related: ['start.how_pointy_works', 'selling.shortcuts'],
    sections: [
      LearningSection(
        title: 'القائمة',
        blocks: [
          LearningSteps([
            LearningStep(
              'اضغط زر القائمة في أعلى الشاشة لفتح قائمة الوجهات.',
              detail:
                  'على الشاشات العريضة تظهر القائمة كشريط جانبي دائم بلا ضغط.',
            ),
            LearningStep('اختر الشاشة التي تريدها من المجموعات.'),
          ]),
        ],
      ),
      LearningSection(
        title: 'الطريق الأسرع: لوحة الأوامر',
        blocks: [
          LearningParagraph(
            'اضغط Ctrl+K (أو ⌘K على الماك) من أي مكان، اكتب أول حروف ما تريد، '
            'ثم Enter. تبحث اللوحة في الشاشات وفي المنتجات والعملاء والفواتير '
            'أيضًا، فتصل إلى الشيء نفسه لا إلى الشاشة التي يسكنها فقط.',
          ),
          LearningNote(
            tone: LearningNoteTone.tip,
            title: 'اكتب بالعربية أو بالإنجليزية',
            message:
                'تقبل اللوحة الكلمتين: «مشتريات» و«purchasing» تصلان إلى الشاشة نفسها.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'start.first_day_cashier',
    title: 'يومك الأول على الصندوق',
    summary: 'الترتيب الصحيح ليوم كامل: افتح الوردية، بِع، أغلق، اطبع تقرير Z.',
    track: LearningTrack.gettingStarted,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.accessPos,
    keywords: ['cashier', 'first day', 'كاشير', 'وردية', 'يوم'],
    related: [
      'register.open',
      'selling.first_sale',
      'register.close',
      'register.zreport',
    ],
    opens: AppNavigationDestination.pos,
    sections: [
      LearningSection(
        title: 'ترتيب اليوم',
        blocks: [
          LearningSteps([
            LearningStep(
              'ادخل بحسابك أنت، لا بحساب زميلك.',
              detail:
                  'كل فاتورة تحمل اسم من أصدرها. الدخول بحساب غيرك ينسب بيعك — '
                  'وفرق درجك — إليه.',
            ),
            LearningStep(
              'افتح وردية الدرج وأدخل النقدية التي وجدتها فيه فعلًا.',
              detail: 'لا يمكن البيع قبل فتح وردية.',
            ),
            LearningStep('بِع طوال اليوم من شاشة البيع.'),
            LearningStep(
              'سجّل أي إضافة أو سحب نقدي وقت حدوثه، لا في آخر اليوم.',
            ),
            LearningStep(
              'أغلق الوردية بعدّ ما في الدرج فعلًا، ثم اطبع تقرير Z.',
            ),
          ]),
        ],
      ),
      LearningSection(
        title: 'ثلاث عادات تمنع أغلب المشاكل',
        blocks: [
          LearningBullets([
            'لا تترك الوردية مفتوحة لليوم التالي؛ الفرق النقدي يصبح بلا معنى.',
            'إن أخطأت في فاتورة، سجّل إرجاعًا — لا تحاول «إصلاحها» بفاتورة معاكسة يدوية.',
            'إن أعطيت بضاعة بلا دفع، سجّلها بيعًا آجلًا باسم العميل. الورقة في الجيب ليست دفترًا.',
          ]),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'start.glossary',
    title: 'قاموس المصطلحات',
    summary: 'معنى كل كلمة تتكرر في الشاشات: آجل، وردية، خيار، أمر شراء، فرق.',
    track: LearningTrack.gettingStarted,
    level: LearningLevel.beginner,
    kind: LearningKind.reference,
    minutes: 4,
    keywords: ['glossary', 'terms', 'قاموس', 'مصطلحات', 'معنى'],
    related: ['start.how_pointy_works'],
    sections: [
      LearningSection(
        title: 'البيع والنقد',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'وردية الدرج',
              'الفترة بين فتح الدرج وإغلاقه. كل بيع ينتمي إلى وردية واحدة وكاشير واحد.',
            ),
            LearningDefinition(
              'بيع عادي',
              'بيع دُفع كاملًا وقت إصداره، بأي طريقة أو بعدة طرق.',
            ),
            LearningDefinition(
              'بيع آجل',
              'بضاعة خرجت والمبلغ (أو جزء منه) دَين على عميل معروف بالاسم.',
            ),
            LearningDefinition(
              'عرض سعر',
              'ورقة سعر للعميل. لا دفع فيها ولا تُخصم من المخزون حتى تتحول إلى بيع.',
            ),
            LearningDefinition(
              'دفعة مقدّمة',
              'مبلغ يدفعه العميل وقت البيع الآجل، والباقي يبقى دَينًا عليه.',
            ),
            LearningDefinition(
              'تقسيم الدفع',
              'دفع فاتورة واحدة بأكثر من طريقة: جزء نقدًا وجزء بالبطاقة مثلًا.',
            ),
            LearningDefinition(
              'الفرق النقدي',
              'الفارق بين ما يتوقع النظام وجوده في الدرج وما عددته فعلًا عند الإغلاق.',
            ),
          ]),
        ],
      ),
      LearningSection(
        title: 'المنتجات والمخزون',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'المنتج',
              'العنوان العام: «تي شيرت قطن». لا يُباع بذاته ولا يُخزَّن بذاته.',
            ),
            LearningDefinition(
              'الخيار (Variant)',
              'الشيء الذي يُباع فعلًا: «تي شيرت قطن — أحمر — L». له سعره وباركوده ومخزونه.',
            ),
            LearningDefinition(
              'الوحدة الأساسية',
              'الوحدة التي يُحفظ بها المخزون. كل الوحدات الأخرى تُحوَّل إليها.',
            ),
            LearningDefinition(
              'الإضافات (Modifiers)',
              'اختيارات تُضاف وقت البيع وقد تغيّر السعر: «حجم كبير»، «بدون سكر».',
            ),
            LearningDefinition(
              'الجرد',
              'عدّ الموجود فعلًا ومقارنته بما يقوله النظام، ثم تصحيح الفرق.',
            ),
          ]),
        ],
      ),
      LearningSection(
        title: 'الشراء',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'أمر الشراء',
              'طلبك من المورد. يمرّ بمسودة ← مُرسل ← مستلم (كليًا أو جزئيًا).',
            ),
            LearningDefinition(
              'الاستلام',
              'تسجيل ما وصل فعلًا. هو وحده ما يزيد المخزون، لا إنشاء الأمر.',
            ),
            LearningDefinition(
              'تكاليف الوصول',
              'الشحن والجمارك والمناولة، تُوزَّع على الأصناف لتصبح التكلفة حقيقية.',
            ),
            LearningDefinition(
              'رصيد المورد',
              'مبلغ لك عند المورد ناتج عن إرجاع، يُستخدم في أوامر لاحقة.',
            ),
          ]),
        ],
      ),
    ],
  ),
];
