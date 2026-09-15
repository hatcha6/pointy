import '../../../core/authorization.dart';
import '../../../shared/navigation/app_navigation.dart';
import '../models/learning_guide.dart';

/// Customers and suppliers: the two ledgers of who owes whom.
const contactsGuides = <LearningGuide>[
  LearningGuide(
    id: 'contacts.customers',
    title: 'إضافة عميل وإدارة بياناته',
    summary: 'أقل ما يلزم لفتح حساب عميل، ولماذا يستحق ذلك دقيقة.',
    track: LearningTrack.contacts,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 2,
    capability: AppCapability.manageContacts,
    keywords: ['customer', 'عميل', 'زبون', 'إضافة عميل'],
    related: [
      'contacts.customer_file',
      'money.credit_sale',
      'selling.customer',
    ],
    opens: AppNavigationDestination.contacts,
    sections: [
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep(
              'افتح «العملاء والموردون» وأضِف عميلًا، أو أنشئه مباشرة من نافذة اختيار العميل في شاشة البيع.',
            ),
            LearningStep('أدخل الاسم ورقم الهاتف.'),
            LearningStep('أضِف العنوان وسقف الدين إن لزم.'),
          ]),
          LearningNote(
            tone: LearningNoteTone.tip,
            title: 'رقم الهاتف هو المفتاح',
            message:
                'به تجد العميل بسرعة، وبه تُرسَل له الفاتورة، وبه تميّز عميلين '
                'بنفس الاسم — وما أكثرهما.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'contacts.customer_file',
    title: 'ملف العميل: ماذا يخبرك',
    summary: 'رصيده المستحق، تاريخ شرائه، مرتجعاته، وسقفه.',
    track: LearningTrack.contacts,
    level: LearningLevel.intermediate,
    kind: LearningKind.reference,
    minutes: 3,
    capability: AppCapability.manageContacts,
    keywords: ['customer file', 'ملف العميل', 'رصيد', 'حساب العميل'],
    related: ['money.collect_debt', 'money.credit_limits', 'contacts.segments'],
    sections: [
      LearningSection(
        title: 'أقسام الصفحة',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'الرصيد المستحق',
              'مجموع ما عليه من فواتير آجلة غير مسدّدة.',
            ),
            LearningDefinition(
              'سقف الدين',
              'السقف المطبَّق عليه والمتاح له للشراء الآجل.',
            ),
            LearningDefinition(
              'الفواتير',
              'كل مشترياته، مع المتبقّي على كل فاتورة.',
            ),
            LearningDefinition('المدفوعات', 'ما حصّلته منه ومتى وبأي طريقة.'),
            LearningDefinition('المرتجعات والاستبدالات', 'عددها وقيمتها.'),
            LearningDefinition(
              'التصنيف',
              'أين يقع بين عملائك من حيث القيمة وحداثة الشراء.',
            ),
          ]),
          LearningParagraph(
            'من هذه الصفحة تُسجَّل دفعة تحصيل مباشرة، وتُوزَّع على أقدم فواتيره أولًا.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'contacts.suppliers',
    title: 'الموردون وأرصدتهم',
    summary: 'ما تدين به لكل مورد، وما لك عنده من رصيد.',
    track: LearningTrack.contacts,
    level: LearningLevel.intermediate,
    kind: LearningKind.reference,
    minutes: 2,
    capability: AppCapability.manageContacts,
    keywords: ['supplier', 'مورد', 'مستحقات', 'رصيد المورد'],
    related: [
      'purchasing.pay_supplier',
      'purchasing.returns',
      'money.payments_hub',
    ],
    sections: [
      LearningSection(
        title: 'ثلاثة أرقام',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'مستحق',
              'ما عليك للمورد من أوامر شراء غير مسدّدة.',
            ),
            LearningDefinition(
              'رصيد دائن',
              'ما لك عنده — من إرجاع سابق عادةً.',
            ),
            LearningDefinition(
              'الصافي',
              'الفرق بينهما، وهو الرقم الذي تتفاوض عليه فعلًا.',
            ),
          ]),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'contacts.segments',
    title: 'تصنيف العملاء تلقائيًا',
    summary: 'من هو العميل الوفي، ومن كان وفيًا وتوقّف.',
    track: LearningTrack.contacts,
    level: LearningLevel.advanced,
    kind: LearningKind.concept,
    minutes: 2,
    capability: AppCapability.manageContacts,
    keywords: ['rfm', 'segment', 'تصنيف العملاء', 'ولاء'],
    related: ['setup.discount_rules', 'contacts.customer_file'],
    sections: [
      LearningSection(
        title: 'كيف يُحسب',
        blocks: [
          LearningParagraph(
            'يُصنَّف كل عميل تلقائيًا بثلاثة مقاييس: متى اشترى آخر مرة، كم مرة '
            'يشتري، وكم ينفق. تُعاد الحسبة دوريًا بلا تدخّل منك.',
          ),
          LearningParagraph(
            'الفائدة العملية: توجيه قواعد الخصم إلى فئة بعينها — استرجاع من '
            'انقطع، أو مكافأة من يشتري كثيرًا — بدل خصم عام يُعطى لمن كان سيشتري أصلًا.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'contacts.payment_cards',
    title: 'بطاقات الدفع المسجّلة',
    summary: 'كيف تُعرَف مشتريات العميل من بطاقته حتى بلا تسجيل اسمه.',
    track: LearningTrack.contacts,
    level: LearningLevel.advanced,
    kind: LearningKind.concept,
    minutes: 2,
    capability: AppCapability.manageContacts,
    keywords: ['card', 'بطاقة', 'ربط بطاقة', 'عميل'],
    related: ['money.card_receipt', 'contacts.customer_file'],
    sections: [
      LearningSection(
        title: 'الفكرة',
        blocks: [
          LearningParagraph(
            'إيصالات البطاقة المطابَقة تُبنى منها بطاقة مسجّلة تُربط بالعميل. '
            'فإذا دفع العميل نفسه ببطاقته مرة أخرى، عُرف حتى لو لم يُسجَّل اسمه '
            'على الفاتورة.',
          ),
          LearningParagraph(
            'يمكن إخفاء بطاقة، أو ربطها بعميل، أو دمج بطاقتين تبيّن أنهما لشخص واحد.',
          ),
        ],
      ),
    ],
  ),
];
