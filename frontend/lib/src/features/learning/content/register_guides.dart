import '../../../core/authorization.dart';
import '../../../shared/navigation/app_navigation.dart';
import '../models/learning_guide.dart';

/// The drawer session: the container every sale, every dinar and every cashier
/// attribution hangs from.
const registerGuides = <LearningGuide>[
  LearningGuide(
    id: 'register.concept',
    title: 'ما هي وردية الدرج ولماذا',
    summary: 'لماذا لا يمكن البيع قبل فتح وردية، وما الذي تجمعه الوردية.',
    track: LearningTrack.register,
    level: LearningLevel.beginner,
    kind: LearningKind.concept,
    minutes: 2,
    capability: AppCapability.accessPos,
    keywords: ['session', 'shift', 'وردية', 'جلسة', 'درج', 'صندوق'],
    related: ['register.open', 'register.close', 'people.cashier_attribution'],
    sections: [
      LearningSection(
        title: 'الفكرة',
        blocks: [
          LearningParagraph(
            'الوردية هي الفترة بين فتح الدرج وإغلاقه. كل بيع، وكل إضافة أو سحب '
            'نقدي، وكل شراء نقدي من الدرج ينتمي إلى وردية واحدة ومستخدم واحد.',
          ),
          LearningParagraph(
            'هذا ما يجعل سؤال «كم كان يجب أن يكون في الدرج الآن؟» سؤالًا له '
            'إجابة واحدة: نقدية الافتتاح + النقد الداخل − النقد الخارج. وبلا '
            'وردية لا معنى لهذا الحساب أصلًا، ولذلك لا يسمح البرنامج بالبيع قبل فتحها.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'register.open',
    title: 'فتح وردية الدرج',
    summary: 'ابدأ يومك بعدّ ما في الدرج فعلًا، لا بما تتوقعه.',
    track: LearningTrack.register,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 2,
    capability: AppCapability.startRegisterSession,
    keywords: [
      'open session',
      'float',
      'فتح الوردية',
      'نقدية الافتتاح',
      'بداية',
    ],
    related: [
      'register.close',
      'selling.first_sale',
      'register.cash_movements',
    ],
    opens: AppNavigationDestination.pos,
    sections: [
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep(
              'افتح شاشة البيع؛ تظهر واجهة «جلسة الدرج» إن لم تكن هناك وردية مفتوحة.',
            ),
            LearningStep(
              'أدخل «نقدية الافتتاح»: عدّ ما في الدرج فعلًا الآن.',
              detail:
                  'قد يكون الحقل إلزاميًا حسب إعدادات المتجر. أدخل ما عددته، لا المبلغ المعتاد.',
            ),
            LearningStep('اضغط «بدء الجلسة».'),
          ]),
          LearningNote(
            tone: LearningNoteTone.danger,
            title: 'رقم افتتاح مُختلَق يُنتج فرقًا مُختلَقًا',
            message:
                'كل دينار تخطئ فيه هنا يظهر عجزًا أو زيادة عند الإغلاق، باسمك أنت.',
          ),
        ],
      ),
      LearningSection(
        title: 'حالات خاصة',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'وردية مفتوحة من قبل',
              'يعرض البرنامج «متابعة البيع» لاستئنافها. لا تفتح ثانية.',
            ),
            LearningDefinition(
              'تعذّر معرفة حالة الوردية',
              'رسالة تطلب إعادة المحاولة. لا تبدأ وردية جديدة قبل أن تنجح — فتح جلستين يفسد الحساب.',
            ),
            LearningDefinition(
              'المكان الذي يبيع منه الصندوق',
              'إن كان للمتجر أكثر من مخزن، يبيع هذا الصندوق من مكان محدّد. تغييره يحتاج صلاحية مدير.',
            ),
          ]),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'register.cash_movements',
    title: 'إضافة وسحب نقدية من الدرج',
    summary: 'كل دينار يدخل أو يخرج بلا بيع يجب أن يُسجَّل لحظتها.',
    track: LearningTrack.register,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 2,
    capability: AppCapability.createRegisterCashMovement,
    keywords: ['pay in', 'pay out', 'سحب', 'إيداع', 'حركة نقدية', 'فكة'],
    related: ['register.close', 'money.expenses', 'purchasing.cash_purchase'],
    sections: [
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep('من شاشة البيع افتح «إجراءات الجلسة».'),
            LearningStep('اختر «إضافة نقدية» أو «سحب نقدية».'),
            LearningStep(
              'أدخل المبلغ واكتب السبب.',
              detail: 'السبب إلزامي — حركة بلا سبب لا تُفسِّر فرقًا بعد أسبوع.',
            ),
          ]),
        ],
      ),
      LearningSection(
        title: 'أمثلة شائعة',
        blocks: [
          LearningBullets([
            'إضافة: فكّة جاءت من الخزنة، أو مبلغ أُعيد إلى الدرج.',
            'سحب: توريد إلى الخزنة، دفع مصروف، شراء عاجل من محل مجاور.',
          ]),
          LearningNote(
            tone: LearningNoteTone.warning,
            title: 'سجّلها وقتها',
            message:
                'الحركة التي تُؤجَّل إلى آخر اليوم تُنسى، ثم تظهر عجزًا لا يذكر أحد سببه.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'register.close',
    title: 'إغلاق الوردية وعدّ الدرج',
    summary: 'العدّ الأعمى: تعدّ أولًا ثم يخبرك النظام بالفرق.',
    track: LearningTrack.register,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.closeRegisterSession,
    keywords: ['close', 'count', 'إغلاق', 'عدّ', 'تقفيل', 'فرق'],
    related: [
      'register.zreport',
      'register.variance',
      'register.cash_movements',
    ],
    sections: [
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep('من «إجراءات الجلسة» اختر «إغلاق الجلسة».'),
            LearningStep(
              'عُدّ النقد في الدرج وأدخل الإجمالي.',
              detail:
                  'النظام لا يعرض لك المتوقَّع قبل أن تُدخل عدّك — وهذا مقصود.',
            ),
            LearningStep('اضغط «إغلاق الجلسة».'),
            LearningStep('اطبع تقرير Z عندما يُعرض عليك ذلك.'),
          ]),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'لماذا العدّ الأعمى؟',
            message:
                'لو عرف العادّ الرقم المتوقَّع، لصار العدّ تأكيدًا لا عدًّا. '
                'الإخفاء هو ما يجعل الفرق معلومة حقيقية.',
          ),
        ],
      ),
      LearningSection(
        title: 'ما يُقارَن بماذا',
        blocks: [
          LearningParagraph(
            'المتوقَّع = نقدية الافتتاح + المبيعات النقدية + التحصيلات النقدية '
            '+ إضافات الدرج − سحوبات الدرج − المشتريات النقدية من الدرج.',
          ),
          LearningParagraph(
            'المبيعات بالبطاقة والتحويل ليست جزءًا من هذا الحساب، ولا الفواتير '
            'الآجلة. إن كان مجموع مبيعاتك ٩٠٠ ومنها ٣٠٠ آجل و٢٠٠ بطاقة، فلا '
            'أحد يتوقّع ٩٠٠ في درجك.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'register.zreport',
    title: 'تقرير إغلاق الوردية (Z)',
    summary:
        'قراءة التقرير سطرًا سطرًا، والفرق بين «إجمالي المبيعات» و«المقبوض».',
    track: LearningTrack.register,
    level: LearningLevel.intermediate,
    kind: LearningKind.reference,
    minutes: 3,
    capability: AppCapability.closeRegisterSession,
    keywords: ['z report', 'تقرير', 'إغلاق', 'زد', 'ملخص الوردية'],
    related: ['register.close', 'register.variance', 'reports.reports'],
    sections: [
      LearningSection(
        title: 'أهم سطرين',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'إجمالي المبيعات',
              'قيمة كل ما بعته في الوردية، بأي طريقة وبأي نوع — بما فيه الآجل. '
                  'ويظهر تحته «صافي المبيعات» بعد خصم المرتجعات والخصومات.',
            ),
            LearningDefinition(
              'المقبوض',
              'ما قُبض فعلًا في الوردية، بما فيه تحصيل دَين عن فواتير قديمة.',
            ),
          ]),
          LearningParagraph(
            'لا يتساوى الرقمان عادةً، وتساويهما ليس هدفًا. الفرق بينهما هو ما '
            'بِيع دَينًا اليوم، ناقصًا ما حُصِّل اليوم عن ديون سابقة.',
          ),
        ],
      ),
      LearningSection(
        title: 'بقية الأسطر',
        blocks: [
          LearningDefinitions([
            LearningDefinition('نقدية الافتتاح', 'ما أدخلته عند فتح الوردية.'),
            LearningDefinition(
              'إضافات/سحوبات الدرج',
              'مجموع الحركات النقدية المسجَّلة.',
            ),
            LearningDefinition(
              'مشتريات من الدرج',
              'ما دُفع للموردين نقدًا من هذه الوردية.',
            ),
            LearningDefinition(
              'النقد المتوقع',
              'ما يجب أن يكون في الدرج حسب الدفتر.',
            ),
            LearningDefinition('النقد المعدود', 'ما أدخلته أنت عند الإغلاق.'),
            LearningDefinition('فرق النقد', 'الفارق بينهما.'),
          ]),
          LearningParagraph(
            'يمكن طباعة التقرير على الطابعة الحرارية أو تجهيزه PDF لمشاركته، '
            'كما يمكن فتح ملخص أي وردية سابقة من «جلسات الدرج».',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'register.variance',
    title: 'الفرق النقدي: كيف تقرأه وتعالجه',
    summary: 'العجز والزيادة ليسا اتهامًا — لكل منهما أسباب قليلة معروفة.',
    track: LearningTrack.register,
    level: LearningLevel.intermediate,
    kind: LearningKind.concept,
    minutes: 3,
    capability: AppCapability.viewRegisterSessions,
    keywords: ['variance', 'shortage', 'عجز', 'زيادة', 'فرق نقدي'],
    related: ['register.close', 'money.payment_methods', 'money.expenses'],
    opens: AppNavigationDestination.registerSessions,
    sections: [
      LearningSection(
        title: 'أسباب العجز',
        blocks: [
          LearningBullets([
            'نقد خرج من الدرج بلا تسجيل سحب (مصروف، فكّة، توريد للخزنة).',
            'باقٍ أُعطي أكثر من اللازم.',
            'بيع بالبطاقة سُجّل نقدًا.',
            'نقدية افتتاح أُدخلت أكبر مما كان فعلًا.',
          ]),
        ],
      ),
      LearningSection(
        title: 'أسباب الزيادة',
        blocks: [
          LearningBullets([
            'تحصيل دَين قُبض ولم يُسجَّل.',
            'بيع نقدي لم تُصدَر له فاتورة.',
            'نقد أُضيف للدرج بلا تسجيل إضافة.',
            'نقدية افتتاح أُدخلت أقل مما كان فعلًا.',
          ]),
        ],
      ),
      LearningSection(
        title: 'الطريقة الصحيحة للمعالجة',
        blocks: [
          LearningParagraph(
            'لا يُعالج الفرق بتغيير رقم. افتح ملخص الوردية وراجع حركاتها ومبيعاتها '
            'لتعرف أين نشأ، ثم سجّل ما لم يُسجَّل. الفرق نفسه يبقى في السجل — وهذا '
            'المطلوب: تاريخ الفروقات هو ما يكشف مشكلة متكرّرة.',
          ),
          LearningNote(
            tone: LearningNoteTone.tip,
            title: 'فرق يتكرّر بنفس القيمة',
            message:
                'عجز ثابت كل يوم بنفس المبلغ تقريبًا غالبًا عادة غير مسجَّلة '
                '(شاي، توصيل، فكّة) لا سرقة. سجّلها كمصروف وينتهي.',
          ),
        ],
      ),
    ],
  ),
];
