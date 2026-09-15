import '../../../core/authorization.dart';
import '../../../shared/navigation/app_navigation.dart';
import '../models/learning_guide.dart';

/// Reading the shop back: dashboards, reports, invoice history, and the audit
/// trail that answers "who did this".
const reportsGuides = <LearningGuide>[
  LearningGuide(
    id: 'reports.dashboard',
    title: 'لوحة المعلومات',
    summary: 'ما الذي تخبرك به الشاشة الأولى، وما الذي لا تخبرك به.',
    track: LearningTrack.reports,
    level: LearningLevel.beginner,
    kind: LearningKind.concept,
    minutes: 2,
    capability: AppCapability.viewDashboard,
    keywords: ['dashboard', 'لوحة', 'رئيسية', 'ملخص'],
    related: ['reports.reports', 'register.variance'],
    opens: AppNavigationDestination.dashboard,
    sections: [
      LearningSection(
        title: 'ما فيها',
        blocks: [
          LearningBullets([
            'مبيعات اليوم واتجاهها مقارنةً بما قبلها.',
            'تنبيهات تستحق فعلًا: فروقات نقدية، مستحقات موردين، أصناف على وشك النفاد.',
            'أرصدة الموردين والعملاء في لمحة.',
            'أسعار الصرف حين تكون مفعّلة.',
          ]),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'الكاشير لا يرى اللوحة عادةً',
            message:
                'إظهار إجمالي المبيعات لمن سيعدّ الدرج يُفسد العدّ الأعمى، فلا '
                'تُمنح مؤشرات اللوحة إلا بصلاحيات التقارير.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'reports.reports',
    title: 'التقارير: أيّها تفتح ومتى',
    summary: 'دليل سريع لاختيار التقرير الذي يجيب عن سؤالك.',
    track: LearningTrack.reports,
    level: LearningLevel.intermediate,
    kind: LearningKind.reference,
    minutes: 3,
    capability: AppCapability.viewReports,
    keywords: ['reports', 'تقارير', 'تقرير', 'محاسبة'],
    related: ['reports.dashboard', 'register.zreport', 'reports.export'],
    opens: AppNavigationDestination.reports,
    sections: [
      LearningSection(
        title: 'اختر بحسب السؤال',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'كم بعنا؟',
              'تقارير المبيعات، بالفترة وبالمنتج وبالكاشير.',
            ),
            LearningDefinition(
              'كم ربحنا؟',
              'تقارير الربحية، وتعتمد على طريقة تسعير المخزون.',
            ),
            LearningDefinition(
              'ماذا عندنا؟',
              'تقارير المخزون، ومنها رصيد بتاريخ سابق.',
            ),
            LearningDefinition(
              'من علينا ولنا؟',
              'تقارير أرصدة العملاء والموردين.',
            ),
            LearningDefinition('أين النقد؟', 'تقارير جلسات الدرج والمدفوعات.'),
          ]),
          LearningParagraph(
            'يمكن تصدير أي تقرير PDF أو CSV، وطباعته، وحفظ نسخة منه للمراجعة لاحقًا.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'reports.invoices',
    title: 'قائمة الفواتير: البحث والترشيح',
    summary: 'اعثر على أي فاتورة بالرقم أو العميل أو الكاشير أو التاريخ.',
    track: LearningTrack.reports,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.viewInvoices,
    keywords: ['invoices', 'فواتير', 'بحث', 'سجل المبيعات'],
    related: [
      'returns.return_items',
      'selling.receipt',
      'people.cashier_attribution',
    ],
    opens: AppNavigationDestination.invoices,
    sections: [
      LearningSection(
        title: 'الترشيح',
        blocks: [
          LearningBullets([
            'بنوع البيع: عادي، آجل، عرض سعر.',
            'بحالة السداد: مدفوعة أو عليها متبقٍّ.',
            'بالفترة الزمنية.',
            'بالكاشير أو بوردية الدرج (لمن يملك رؤية المتجر كله).',
          ]),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'الكاشير يرى فواتير ورديّاته',
            message:
                'هذا ليس إخفاءً بل نطاق: من يملك «رؤية المبيعات على مستوى '
                'المتجر» يرى الكل ويستطيع الترشيح بالكاشير.',
          ),
        ],
      ),
      LearningSection(
        title: 'من قائمة إلى مستند',
        blocks: [
          LearningParagraph(
            'صف القائمة ملخّص لا مستند: لا يحمل الأصناف. افتح الفاتورة لترى '
            'محتوياتها ودفعاتها ومرتجعاتها وإجراءاتها.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'reports.activity_log',
    title: 'سجل النشاط: من فعل ماذا ومتى',
    summary: 'أثر كل عملية حسّاسة، للمراجعة لا للمراقبة.',
    track: LearningTrack.reports,
    level: LearningLevel.intermediate,
    kind: LearningKind.reference,
    minutes: 2,
    capability: AppCapability.viewActivityLog,
    keywords: ['activity', 'audit', 'سجل', 'نشاط', 'تتبع'],
    related: ['register.variance', 'people.roles'],
    opens: AppNavigationDestination.activityLog,
    sections: [
      LearningSection(
        title: 'ما يُسجَّل',
        blocks: [
          LearningBullets([
            'فتح وإغلاق الورديات والحركات النقدية.',
            'إصدار الفواتير والمرتجعات وإعادة الطباعة.',
            'تعديل المنتجات والأسعار والخصومات.',
            'تغيير المستخدمين والصلاحيات والإعدادات.',
          ]),
          LearningParagraph(
            'رشِّح بالنوع أو بالمستخدم أو بالفترة. الغرض الأول تفسير رقم غريب، '
            'لا مطاردة موظف: أغلب ما يبدو تلاعبًا يتبيّن أنه خطوة نُسي تسجيلها.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'reports.export',
    title: 'تصدير البيانات',
    summary: 'أخرِج تقاريرك ملفات للمحاسب أو للحفظ.',
    track: LearningTrack.reports,
    level: LearningLevel.advanced,
    kind: LearningKind.walkthrough,
    minutes: 2,
    capability: AppCapability.viewReports,
    keywords: ['export', 'csv', 'تصدير', 'ملف', 'إكسل'],
    related: ['reports.reports'],
    sections: [
      LearningSection(
        title: 'الطرق',
        blocks: [
          LearningBullets([
            'PDF من أي تقرير — للطباعة أو الإرسال.',
            'CSV للجداول — لفتحه في برنامج جداول أو تسليمه للمحاسب.',
          ]),
          LearningNote(
            tone: LearningNoteTone.tip,
            title: 'التصدير الكبير يستغرق وقتًا',
            message:
                'يُجهَّز في الخلفية ويُخطرك عند جاهزيته؛ لا تُبقِ الشاشة منتظرة.',
          ),
        ],
      ),
    ],
  ),
];
