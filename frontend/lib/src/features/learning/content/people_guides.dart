import '../../../core/authorization.dart';
import '../../../shared/navigation/app_navigation.dart';
import '../models/learning_guide.dart';

/// Users, roles, and paying the people who work in the shop.
const peopleGuides = <LearningGuide>[
  LearningGuide(
    id: 'people.roles',
    title: 'الأدوار والصلاحيات',
    summary: 'لماذا لا يرى الكاشير ما يراه المدير، وكيف يُستثنى شخص بعينه.',
    track: LearningTrack.people,
    level: LearningLevel.intermediate,
    kind: LearningKind.concept,
    minutes: 3,
    capability: AppCapability.manageUsers,
    keywords: ['roles', 'permissions', 'أدوار', 'صلاحيات', 'مستخدم'],
    related: ['people.users', 'returns.window', 'reports.activity_log'],
    opens: AppNavigationDestination.users,
    sections: [
      LearningSection(
        title: 'طبقتان',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'الدور',
              'حزمة جاهزة تناسب وظيفة: كاشير، مشرف، أمين مخزن، مشتريات، محاسب، مدير…',
            ),
            LearningDefinition(
              'صلاحيات إضافية',
              'استثناءات تُمنح لشخص بعينه فوق دوره — كأن يستطيع كاشير بعينه البحث عن فاتورة للإرجاع.',
            ),
          ]),
          LearningParagraph(
            'الإضافات تُضيف ولا تسحب: لا يمكن أن تُنقص صلاحية يعطيها الدور، ولا '
            'أن يمنح مستخدمٌ غيره ما لا يملكه هو.',
          ),
        ],
      ),
      LearningSection(
        title: 'مبدأ التوزيع',
        blocks: [
          LearningParagraph(
            'أعطِ أقل ما يكفي للعمل. ليس لأن الناس غير أمينين، بل لأن الصلاحية '
            'الزائدة تجعل الخطأ ممكنًا: من لا يملك «تطبيق الجرد» لا يستطيع '
            'تصحيح المخزون بالخطأ وهو يظن أنه يحفظ عدّة.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'people.users',
    title: 'إضافة مستخدم وضبط صلاحياته',
    summary: 'حساب لكل شخص — لا حساب مشترك على الصندوق.',
    track: LearningTrack.people,
    level: LearningLevel.intermediate,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.manageUsers,
    keywords: ['user', 'account', 'مستخدم', 'حساب', 'كلمة مرور'],
    related: ['people.roles', 'people.cashier_attribution'],
    opens: AppNavigationDestination.users,
    sections: [
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep('افتح «المستخدمون» وأضِف مستخدمًا.'),
            LearningStep('أدخل الاسم واسم الدخول وكلمة المرور.'),
            LearningStep('اختر الدور المناسب.'),
            LearningStep('أضِف صلاحيات استثنائية عند الحاجة فقط.'),
          ]),
          LearningNote(
            tone: LearningNoteTone.danger,
            title: 'الحساب المشترك يُبطل كل تتبّع',
            message:
                'إن دخل ثلاثة بحساب «كاشير»، فلا تعرف من أصدر أي فاتورة ولا من '
                'يخصّه أي فرق نقدي. حساب لكل شخص شرط لكل ما تبقّى.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'people.cashier_attribution',
    title: 'من باع ماذا',
    summary: 'كل فاتورة تحمل اسم كاشيرها ووردية درجه.',
    track: LearningTrack.people,
    level: LearningLevel.intermediate,
    kind: LearningKind.concept,
    minutes: 2,
    capability: AppCapability.viewRegisterSessions,
    keywords: ['attribution', 'cashier', 'من باع', 'مسؤولية', 'كاشير'],
    related: ['register.zreport', 'reports.invoices', 'people.users'],
    sections: [
      LearningSection(
        title: 'أين يظهر',
        blocks: [
          LearningBullets([
            'على الإيصال المطبوع وعلى فاتورة PDF.',
            'في تفاصيل الفاتورة، مع رابط إلى وردية الدرج.',
            'في قائمة الفواتير، حيث يمكن الترشيح بالكاشير.',
            'في تقارير المبيعات وجلسات الدرج.',
          ]),
          LearningParagraph(
            'الغرض ليس المراقبة بل الإسناد: عميل يسأل عن فاتورته يصل إلى من '
            'أصدرها، وفرق نقدي يخصّ وردية بعينها لا «الصندوق» عمومًا.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'people.employees',
    title: 'الموظفون والرواتب',
    summary: 'خطط الأجر، ومسير الرواتب، والسُّلَف.',
    track: LearningTrack.people,
    level: LearningLevel.advanced,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.viewPayroll,
    keywords: ['payroll', 'salary', 'رواتب', 'موظفين', 'أجر', 'سلفة'],
    related: ['people.attendance', 'operations.board', 'money.expenses'],
    opens: AppNavigationDestination.employees,
    sections: [
      LearningSection(
        title: 'خطط الأجر',
        blocks: [
          LearningDefinitions([
            LearningDefinition('راتب شهري ثابت', 'مبلغ ثابت كل شهر.'),
            LearningDefinition(
              'عمولة مبيعات',
              'نسبة من مبيعاته أو من أعمال أنجزها.',
            ),
            LearningDefinition('ثابت + عمولة', 'الاثنان معًا.'),
            LearningDefinition(
              'على أساس الوحدة',
              'أجر لكل وحدة إنتاج أو مهمة.',
            ),
          ]),
          LearningParagraph(
            'تفعيل خطة جديدة يوقف السابقة؛ لا يعمل لموظف خطّتان في وقت واحد.',
          ),
        ],
      ),
      LearningSection(
        title: 'مسير الرواتب',
        blocks: [
          LearningSteps([
            LearningStep('أنشئ مسير رواتب للفترة.'),
            LearningStep(
              'راجع المستحق لكل موظف: الأساسي والعمولات وخصم السُّلَف.',
            ),
            LearningStep('اعتمد المسير وسجّل الصرف.'),
          ]),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'تحتاج خطة أجر واحدة على الأقل',
            message: 'لا يمكن إنشاء مسير قبل أن يكون لموظف واحد خطة أجر.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'people.attendance',
    title: 'الحضور والانصراف',
    summary: 'ربط جهاز البصمة وتحويل السجلات إلى أيام عمل.',
    track: LearningTrack.people,
    level: LearningLevel.advanced,
    kind: LearningKind.concept,
    minutes: 3,
    capability: AppCapability.viewAttendance,
    keywords: ['attendance', 'biotime', 'حضور', 'بصمة', 'انصراف'],
    related: ['people.employees'],
    sections: [
      LearningSection(
        title: 'كيف يعمل',
        blocks: [
          LearningParagraph(
            'يتصل البرنامج بخادم جهاز البصمة في المتجر ويسحب سجلات البصمات، ثم '
            'يحوّلها إلى أيام عمل (حضور، انصراف، ساعات، تأخير) يمكن تطبيقها على '
            'مسير الرواتب.',
          ),
          LearningNote(
            tone: LearningNoteTone.warning,
            title: 'تحقّق من أول مزامنة',
            message:
                'المزامنة الأولى تسحب فترة محدودة. إن كان لديك تاريخ أقدم '
                'تحتاجه، تأكّد من اكتماله قبل اعتماد أي مسير عليه — نقص السجلات '
                'يقتطع من أجور فعلية.',
          ),
        ],
      ),
    ],
  ),
];
