import '../../../core/authorization.dart';
import '../../../shared/navigation/app_navigation.dart';
import '../models/learning_guide.dart';

/// Work that is not a sale off a shelf: repairs, kitchen tickets, production,
/// and the customer property a shop is holding.
const operationsGuides = <LearningGuide>[
  LearningGuide(
    id: 'operations.intake',
    title: 'استلام جهاز للصيانة',
    summary: 'من لحظة دخول الجهاز حتى فتح مهمة عليه.',
    track: LearningTrack.operations,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.createJobs,
    keywords: ['repair', 'intake', 'صيانة', 'تصليح', 'استلام جهاز', 'ورشة'],
    related: ['operations.board', 'operations.settlement', 'operations.assets'],
    opens: AppNavigationDestination.operations,
    sections: [
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep('افتح «العمليات» وأنشئ مهمة جديدة.'),
            LearningStep('اختر العميل، أو أنشئه الآن.'),
            LearningStep(
              'حدّد الجهاز: نوعه ورقمه المميّز (IMEI، رقم تسلسلي، لوحة أو شاصي).',
              detail: 'هذا ما يميّز جهازًا عن آخر متطابق معه في الرف.',
            ),
            LearningStep(
              'اكتب العطل كما وصفه الزبون، وسجّل ما دخل مع الجهاز (شاحن، غطاء).',
            ),
            LearningStep('أدخل السعر المبدئي أو العربون إن وُجد.'),
          ]),
          LearningNote(
            tone: LearningNoteTone.tip,
            title: 'صوِّر الجهاز عند الاستلام',
            message: 'خدش موجود قبل الدخول يوفّر نقاشًا طويلًا عند التسليم.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'operations.board',
    title: 'لوحة الأعمال والمراحل',
    summary: 'أين وصل كل جهاز، ومن يعمل عليه.',
    track: LearningTrack.operations,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 2,
    capability: AppCapability.viewOperations,
    keywords: ['board', 'stages', 'لوحة', 'مراحل', 'أعمال'],
    related: ['operations.intake', 'operations.settlement', 'people.employees'],
    opens: AppNavigationDestination.operations,
    sections: [
      LearningSection(
        title: 'الاستعمال',
        blocks: [
          LearningParagraph(
            'تعرض اللوحة المهام موزّعة على المراحل (بانتظار الفحص، قيد الإصلاح، '
            'بانتظار قطعة، جاهز للتسليم). انقل المهمة بين المراحل مع ملاحظة عند '
            'الحاجة، فيبقى للجهاز تاريخ يمكن سرده للزبون.',
          ),
          LearningParagraph(
            'زر ⇄ على البطاقة، أو «تغيير المرحلة» في صفحة المهمة، ينقلها إلى أي '
            'مرحلة دفعة واحدة — للأمام إذا سبق العمل الشاشة، أو للخلف إذا فشل '
            'الاختبار. وإن تجاوزت النقلة موافقة الزبون يُسأل عن السعر الذي وافق عليه.',
          ),
          LearningParagraph(
            'إسناد المهمة لفنّي هو أيضًا أساس احتساب عمولته على ما أنجزه.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'operations.settlement',
    title: 'التسوية والتسليم',
    summary: 'لماذا لا يخرج الجهاز قبل أن يُسوّى حسابه.',
    track: LearningTrack.operations,
    level: LearningLevel.intermediate,
    kind: LearningKind.concept,
    minutes: 3,
    capability: AppCapability.viewOperations,
    keywords: ['handover', 'settlement', 'تسليم', 'تسوية', 'سداد'],
    related: ['operations.board', 'money.credit_sale'],
    sections: [
      LearningSection(
        title: 'حالتان مختلفتان',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'حالة المال',
              'لم تُفوتر / دفعة مقدمة / آجل / مدفوعة.',
            ),
            LearningDefinition(
              'حالة الحيازة',
              'الجهاز «عندنا» أم «تم التسليم».',
            ),
          ]),
          LearningParagraph(
            'الحالتان مستقلّتان: جهاز مدفوع قد يبقى عندنا حتى يأتي صاحبه، وجهاز '
            'سُلِّم قد يكون دَينًا. وخلطهما هو ما يجعل أجهزة تخرج بلا أثر مالي.',
          ),
        ],
      ),
      LearningSection(
        title: 'بوابة التسليم',
        blocks: [
          LearningParagraph(
            'لا يسمح البرنامج بتسليم جهاز بلا تسوية: «أصدر الفاتورة واستلم '
            'المبلغ، أو سجّلها آجل على الزبون، قبل تسليم الجهاز».',
          ),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'الآجل مقبول، والصمت ليس مقبولًا',
            message:
                'أن تقرّر ترك المبلغ دَينًا خيار سليم. أن يخرج الجهاز بلا قرار '
                'مسجَّل هو المشكلة.',
          ),
          LearningParagraph(
            'سجّل اسم من استلم الجهاز عند التسليم إن لم يكن صاحبه نفسه.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'operations.assets',
    title: 'سجل أصول العملاء',
    summary: 'الجهاز أو السيارة نفسها، لا صاحبها، هي محور التاريخ.',
    track: LearningTrack.operations,
    level: LearningLevel.intermediate,
    kind: LearningKind.concept,
    minutes: 2,
    capability: AppCapability.viewAssets,
    keywords: ['assets', 'vin', 'imei', 'أصول', 'أجهزة', 'مركبات', 'لوحة'],
    related: ['operations.intake', 'contacts.customer_file'],
    opens: AppNavigationDestination.assets,
    sections: [
      LearningSection(
        title: 'لماذا',
        blocks: [
          LearningParagraph(
            'السيارة تُباع ويتغيّر مالكها، والهاتف يُورَّث. لو عُلِّق التاريخ على '
            'المالك لضاع عند أول انتقال. فالسجل يقوم على الشيء نفسه: رقم '
            'الشاصي أو اللوحة أو IMEI، ويحتفظ بسلسلة المُلّاك.',
          ),
          LearningParagraph(
            'الفائدة: تفتح الأصل فترى كل ما فُعل به عندك مهما تغيّر صاحبه — وهذا '
            'ما يجعل «متى غيّرنا لها الزيت؟» سؤالًا له جواب.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'operations.kitchen',
    title: 'طلبات المطبخ وتوجيهها',
    summary: 'طباعة تذكرة الطلب في محطة التحضير الصحيحة.',
    track: LearningTrack.operations,
    level: LearningLevel.intermediate,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.viewPrepStations,
    keywords: ['kitchen', 'مطبخ', 'تذكرة', 'محطة تحضير', 'مطعم'],
    related: ['selling.modifiers', 'catalog.recipes', 'devices.printers'],
    sections: [
      LearningSection(
        title: 'كيف تعمل',
        blocks: [
          LearningParagraph(
            'تُعرَّف محطات التحضير (المشويات، المشروبات) وتُربط بالتصنيفات. عند '
            'إتمام البيع تُطبع تذكرة في كل محطة تخصّها أصنافها فقط — لا تصل '
            'أصناف المشروبات إلى الشوّاية.',
          ),
          LearningParagraph(
            'ملاحظات الأصناف («بدون بصل») تظهر على التذكرة، ولا تُطبع الأصناف '
            'غير المُعدّة أصلًا.',
          ),
        ],
      ),
    ],
  ),
];
