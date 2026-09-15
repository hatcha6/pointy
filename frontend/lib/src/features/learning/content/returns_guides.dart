import '../../../core/authorization.dart';
import '../../../shared/navigation/app_navigation.dart';
import '../models/learning_guide.dart';

/// Undoing a sale correctly — the operations most likely to be done wrong, and
/// the ones a shop is most reluctant to let anyone practise on a live till.
const returnsGuides = <LearningGuide>[
  LearningGuide(
    id: 'returns.concept',
    title: 'الإرجاع والاستبدال: القاعدة العامة',
    summary: 'لماذا لا تُحذف فاتورة أبدًا، وكيف يُصحَّح الخطأ بدل ذلك.',
    track: LearningTrack.returns,
    level: LearningLevel.beginner,
    kind: LearningKind.concept,
    minutes: 2,
    capability: AppCapability.processReturnsByLookup,
    keywords: ['return', 'refund', 'إرجاع', 'استرجاع', 'إلغاء فاتورة'],
    related: ['returns.return_items', 'returns.exchange', 'returns.window'],
    sections: [
      LearningSection(
        title: 'لا حذف، بل عملية معاكسة',
        blocks: [
          LearningParagraph(
            'الفاتورة الصادرة حدث وقع. إصلاحه يكون بتسجيل إرجاع أو استبدال '
            'مرتبط بها، فتبقى الفاتورة الأصلية والمرتجع كلاهما ظاهرًا في السجل.',
          ),
          LearningParagraph(
            'الفائدة عملية لا نظرية: المخزون يعود بمقدار ما أُرجِع فعلًا، والمال '
            'يُرَدّ من حيث دخل، ويبقى بإمكانك أن تُري أي شخص ماذا جرى ومتى وبيد من.',
          ),
        ],
      ),
      LearningSection(
        title: 'أيّهما تختار',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'إرجاع',
              'ترجع البضاعة ويُرَدّ المال أو يُخصم من دَين العميل.',
            ),
            LearningDefinition(
              'استبدال',
              'ترجع بضاعة وتخرج أخرى، ويُسوَّى الفرق في الاتجاهين.',
            ),
          ]),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'returns.return_items',
    title: 'إرجاع أصناف من فاتورة',
    summary: 'ابحث عن الفاتورة برقمها، اختر الكميات، سجّل الإرجاع.',
    track: LearningTrack.returns,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.processReturnsByLookup,
    keywords: ['return', 'إرجاع', 'مرتجع', 'استرداد'],
    related: ['returns.exchange', 'returns.window', 'reports.invoices'],
    opens: AppNavigationDestination.returnsExchange,
    sections: [
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep(
              'افتح «المرتجعات والاستبدال» وأدخل رقم الفاتورة المطبوع على الإيصال.',
              detail:
                  'أو افتح الفاتورة من قائمة «الفواتير» إن كانت صلاحياتك تسمح، ثم اختر «إرجاع منتجات».',
            ),
            LearningStep('اضغط «بحث» لعرض الفاتورة وأصنافها.'),
            LearningStep(
              'أدخل كمية الإرجاع لكل صنف.',
              detail:
                  'يعرض كل سطر «الكمية القابلة للإرجاع» — ما لم يُرجَع منه سابقًا.',
            ),
            LearningStep('أكّد الإرجاع.'),
          ]),
        ],
      ),
      LearningSection(
        title: 'ماذا يحدث للمال',
        blocks: [
          LearningBullets([
            'فاتورة مدفوعة نقدًا: يُرَدّ المبلغ من درج الوردية المفتوحة.',
            'فاتورة آجلة لم تُسدَّد: يُخفَّض دَين العميل بقيمة المرتجع.',
            'فاتورة مقسّمة الدفع: يُرَدّ بما يوافق ما دُفع فعلًا.',
          ]),
          LearningNote(
            tone: LearningNoteTone.warning,
            title: 'الرد النقدي ينقص درجك',
            message:
                'المبلغ المردود يخرج من الدرج، فيقلّ النقد المتوقع عند الإغلاق '
                'بنفس القيمة. هذا صحيح ومقصود.',
          ),
        ],
      ),
      LearningSection(
        title: 'رسائل قد تراها',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'لا توجد فاتورة بهذا الرقم',
              'راجع الرقم على الإيصال؛ قد يكون رقم وردية أو رقم مرجع لا رقم فاتورة.',
            ),
            LearningDefinition(
              'تعذّر البحث عن الفاتورة',
              'مشكلة اتصال لا نتيجة بحث. الفاتورة قد تكون موجودة — أعد المحاولة.',
            ),
            LearningDefinition(
              'لا توجد كميات متاحة للإرجاع',
              'أُرجِعت أصناف الفاتورة كلها من قبل.',
            ),
          ]),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'returns.exchange',
    title: 'الاستبدال وتسوية الفرق',
    summary: 'بضاعة تدخل وأخرى تخرج في عملية واحدة، والفرق يُدفع أو يُرَدّ.',
    track: LearningTrack.returns,
    level: LearningLevel.intermediate,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.processReturnsByLookup,
    keywords: ['exchange', 'swap', 'استبدال', 'تبديل', 'مقاس'],
    related: ['returns.return_items', 'money.payment_methods'],
    opens: AppNavigationDestination.returnsExchange,
    sections: [
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep('ابحث عن الفاتورة برقمها.'),
            LearningStep('اختر «استبدال».'),
            LearningStep(
              'في «العناصر المُرتجعة» حدّد ما سيعيده العميل وكمياته.',
            ),
            LearningStep(
              'في «العناصر البديلة» ابحث عن الأصناف الجديدة وأضِفها بكمياتها.',
            ),
            LearningStep(
              'اقرأ سطر الفرق: «تبادل متكافئ» أو «على العميل دفع …» أو «يُرَدّ للعميل …».',
            ),
            LearningStep('اختر طريقة تسوية الفرق ثم أكّد.'),
          ]),
          LearningNote(
            tone: LearningNoteTone.tip,
            title: 'عملية واحدة لا اثنتان',
            message:
                'الاستبدال يُسجَّل كوحدة واحدة: إما أن ينجح الجزآن معًا أو لا '
                'يحدث شيء. هذا يمنع حالة «أرجعنا ولم نسلّم البديل».',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'returns.window',
    title: 'مدة صلاحية الإرجاع للكاشير',
    summary:
        'لماذا يستطيع الكاشير إرجاع فاتورة اليوم ولا يستطيع فاتورة الأسبوع الماضي.',
    track: LearningTrack.returns,
    level: LearningLevel.intermediate,
    kind: LearningKind.concept,
    minutes: 2,
    capability: AppCapability.accessPos,
    keywords: ['window', 'مدة', 'صلاحية الإرجاع', 'مهلة'],
    related: ['returns.return_items', 'people.roles'],
    sections: [
      LearningSection(
        title: 'كيف تعمل',
        blocks: [
          LearningParagraph(
            'يضبط المدير مدة (أيام وساعات) يستطيع خلالها الكاشير إرجاع فاتورة '
            'بنفسه. بعد انقضائها يبقى الإرجاع ممكنًا، لكن بصلاحية أعلى.',
          ),
          LearningParagraph(
            'كما أن الكاشير يرى عادةً فواتير ورديّاته هو. صلاحية «البحث عن '
            'فاتورة للإرجاع» تتيح إيجاد أي فاتورة برقمها لخدمة عميل جاء في '
            'وردية غير التي بِيع فيها، بلا أن تفتح له سجل مبيعات المتجر كله.',
          ),
        ],
      ),
    ],
  ),
];
