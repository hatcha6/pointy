import '../../../core/authorization.dart';
import '../../../shared/navigation/app_navigation.dart';
import '../models/learning_guide.dart';

/// Payments, credit, collections, and where the shop's money sits.
const moneyGuides = <LearningGuide>[
  LearningGuide(
    id: 'money.payment_methods',
    title: 'طرق الدفع الثلاث',
    summary: 'نقد وبطاقة وتحويل: ما الفرق في الدفتر، لا في الشكل فقط.',
    track: LearningTrack.money,
    level: LearningLevel.beginner,
    kind: LearningKind.concept,
    minutes: 3,
    capability: AppCapability.checkoutSale,
    keywords: [
      'payment',
      'cash',
      'card',
      'transfer',
      'نقد',
      'بطاقة',
      'تحويل',
      'دفع',
    ],
    related: ['money.split_tender', 'money.card_receipt', 'money.treasury'],
    sections: [
      LearningSection(
        title: 'لماذا يهم الاختيار',
        blocks: [
          LearningParagraph(
            'الطريقة التي تختارها ليست وصفًا لما جرى فحسب؛ هي التي تقرّر أين '
            'يذهب المال في الدفتر. النقد وحده يدخل درج ورديتك ويُعدّ عند '
            'الإغلاق. البطاقة والتحويل لا يمرّان بالدرج أبدًا.',
          ),
          LearningNote(
            tone: LearningNoteTone.danger,
            title: 'تسجيل بطاقة على أنها نقد يخلق عجزًا وهميًا',
            message:
                'النظام سيتوقّع في درجك مبلغًا لم يدخله أحد، فيظهر عجز في نهاية '
                'الوردية لا سبب له. والعكس يخلق زيادة لا تفسير لها.',
          ),
        ],
      ),
      LearningSection(
        title: 'الفروق',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'نقد',
              'يدخل درج الوردية. هو وحده ما يُقارَن بالعدّ عند الإغلاق، وهو وحده ما يُصرف منه باقٍ للعميل.',
            ),
            LearningDefinition(
              'بطاقة',
              'يذهب إلى حساب المتجر البنكي. قد يُطلب إرفاق إيصال جهاز البطاقة ومطابقته قبل التأكيد.',
            ),
            LearningDefinition(
              'تحويل',
              'حوالة أو تطبيق دفع. يُسجَّل برقم مرجعي حين يتوفر.',
            ),
          ]),
          LearningParagraph(
            'يُفعّل المدير الطرق المتاحة من إعدادات المتجر، ويمكنه ضبط نسبة '
            'عمولة للبطاقة والتحويل تُحتسب تلقائيًا في التقارير.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'money.split_tender',
    title: 'تقسيم الدفع بين أكثر من طريقة',
    summary: 'فاتورة واحدة يدفع نصفها نقدًا ونصفها بالبطاقة — خطوة بخطوة.',
    track: LearningTrack.money,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 4,
    capability: AppCapability.checkoutSale,
    keywords: [
      'split',
      'split tender',
      'mixed payment',
      'تقسيم',
      'تجزئة',
      'دفعتين',
      'نصف نقد',
      'أكثر من طريقة',
    ],
    related: [
      'money.payment_methods',
      'money.card_receipt',
      'money.credit_down_payment',
      'selling.first_sale',
    ],
    opens: AppNavigationDestination.pos,
    sections: [
      LearningSection(
        title: 'متى تحتاجه',
        blocks: [
          LearningParagraph(
            'العميل معه ٥٠ دينارًا نقدًا والباقي على البطاقة. أو دفع بعض المبلغ '
            'تحويلًا قبل أن يأتي والباقي نقدًا عند الاستلام. هذه فاتورة واحدة '
            'بدفعتين، لا فاتورتان.',
          ),
          LearningNote(
            tone: LearningNoteTone.warning,
            title: 'لا تُصدر فاتورتين',
            message:
                'تقسيم الفاتورة إلى فاتورتين يفسد المرتجع (نصف البضاعة على كل '
                'ورقة)، ويشوّه متوسط قيمة الفاتورة، ويصعّب على العميل إثبات شرائه.',
          ),
        ],
      ),
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep('أكمل السلة واضغط «إتمام البيع» (Ctrl+Enter).'),
            LearningStep(
              'اترك نوع البيع «عادي»، وابدأ بالدفعة الأولى: اختر طريقتها وأدخل مبلغها.',
              detail: 'مثال: «نقد» ثم ٥٠.',
            ),
            LearningStep(
              'اضغط «إضافة دفعة».',
              detail:
                  'يظهر سطر دفعة ثانٍ، ويوضع فيه المتبقّي تلقائيًا حتى لا تحسبه بنفسك.',
            ),
            LearningStep(
              'اختر طريقة الدفعة الثانية من قائمتها على السطر.',
              detail:
                  'أو بالاختصار: Ctrl+٢ للبطاقة و Ctrl+٣ للتحويل. الرقم وحده '
                  'يُكتب في خانة المبلغ ولا يبدّل الطريقة.',
            ),
            LearningStep(
              'عدّل مبلغ أي دفعة إن لزم؛ يعيد البرنامج توزيع المتبقّي على السطر الآخر تلقائيًا.',
              detail:
                  'يمكنك إضافة أكثر من دفعتين إن احتجت، وحذف أي سطر بزر الحذف عليه.',
            ),
            LearningStep(
              'تحقّق من لوحة الملخّص: «المستحق» و«المدفوع» و«المتبقي» — ويجب أن يصير المتبقي صفرًا.',
            ),
            LearningStep('اضغط «تأكيد الدفع».'),
          ]),
        ],
      ),
      LearningSection(
        title: 'القواعد التي يفرضها البرنامج',
        blocks: [
          LearningBullets([
            'مجموع الدفعات يجب أن يغطّي الإجمالي، وإلا لم يُقبل التأكيد (في البيع العادي).',
            'الزيادة على الإجمالي تُقبل فقط إن كانت مغطّاة بالنقد، لأن الباقي لا يُصرف إلا نقدًا.',
            'إن كانت البطاقة مفعّلة مع اشتراط إثبات الإيصال، فلا تأكيد قبل مطابقة إيصال كل دفعة بطاقة.',
          ]),
          LearningParagraph(
            'حين تدفع زيادةً نقدًا في دفعة مقسّمة، يخصم البرنامج الباقي من الجزء '
            'النقدي لا من البطاقة — فالمسجَّل على البطاقة يساوي تمامًا ما مُرِّر '
            'على جهازها.',
          ),
          LearningNote(
            tone: LearningNoteTone.tip,
            title: 'مثال كامل',
            message:
                'الإجمالي ١٢٠. العميل ناولك ٦٠ نقدًا وسيمرّر الباقي بالبطاقة: '
                'نقد ٦٠ ← «إضافة دفعة» ← بطاقة تُملأ بـ ٦٠ تلقائيًا ← تأكيد. '
                'لو ناولك ٧٠ نقدًا: اكتب ٧٠ نقدًا و٥٠ بطاقة، فيظهر «الباقي للعميل ١٠».',
          ),
        ],
      ),
      LearningSection(
        title: 'بعد التأكيد',
        blocks: [
          LearningParagraph(
            'تُسجَّل الفاتورة مرة واحدة، وتحمل دفعتين منفصلتين. في تقارير طرق '
            'الدفع يظهر كل مبلغ تحت طريقته، وفي درج الوردية يظهر الجزء النقدي وحده.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'money.credit_sale',
    title: 'البيع الآجل (الدَّين)',
    summary:
        'بضاعة تخرج اليوم والمبلغ يُقيَّد على عميل بالاسم مع تاريخ استحقاق.',
    track: LearningTrack.money,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 4,
    capability: AppCapability.checkoutSale,
    keywords: ['credit', 'debt', 'account', 'آجل', 'دين', 'كاشي', 'على الحساب'],
    related: [
      'money.credit_down_payment',
      'money.collect_debt',
      'money.credit_limits',
      'contacts.customer_file',
    ],
    opens: AppNavigationDestination.pos,
    sections: [
      LearningSection(
        title: 'ما هو',
        blocks: [
          LearningParagraph(
            'البيع الآجل فاتورة كاملة تمامًا كغيرها: الأصناف تخرج من المخزون، '
            'والفاتورة لها رقم وتاريخ. الفرق الوحيد أن المبلغ — كله أو بعضه — '
            'يُسجَّل دَينًا على عميل معروف بدل أن يدخل الدرج.',
          ),
          LearningNote(
            tone: LearningNoteTone.danger,
            title: 'الورقة في الدرج ليست دفترًا',
            message:
                'كل بضاعة تخرج بلا دفع يجب أن تُسجَّل بيعًا آجلًا. وإلا فالمخزون '
                'يقول إن البضاعة موجودة، والدرج يقول إن النقد موجود، وكلاهما خطأ.',
          ),
        ],
      ),
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep(
              'اربط العميل بالفاتورة من زر العميل أعلى السلة.',
              detail: 'العميل شرط: لا يمكن تأكيد بيع آجل بلا اسم.',
            ),
            LearningStep('اضغط «إتمام البيع».'),
            LearningStep(
              'من «نوع البيع» اختر «آجل».',
              detail:
                  'إن لم يظهر هذا الخيار فالبيع الآجل غير مفعّل في إعدادات المتجر.',
            ),
            LearningStep(
              'حدّد «تاريخ الاستحقاق» — إما بكتابته أو بأحد الأزرار السريعة: بعد أسبوع، أسبوعين، شهر.',
              detail:
                  'اختياري، لكنه ما يجعل الفاتورة تظهر لاحقًا كمتأخرة بدل أن تبقى دَينًا بلا موعد.',
            ),
            LearningStep(
              'إن دفع العميل شيئًا الآن، أدخله كدفعة مقدّمة (انظر الدليل المخصّص).',
            ),
            LearningStep('اضغط «تأكيد الدفع».'),
          ]),
        ],
      ),
      LearningSection(
        title: 'ماذا تغيّر',
        blocks: [
          LearningBullets([
            'ارتفع رصيد العميل المستحق بقيمة المتبقّي عليه.',
            'خرجت الأصناف من المخزون كأي بيع آخر.',
            'لم يدخل الدرج شيء إلا الدفعة المقدّمة إن وُجدت.',
            'ظهرت الفاتورة في قائمة الفواتير بحالة آجل والمتبقّي عليها.',
          ]),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'تقرير الوردية يفرّق بينهما',
            message:
                'تقرير Z يعرض «إجمالي المبيعات» و«المقبوض» منفصلين: فاتورة آجلة تزيد '
                'الأول ولا تزيد الثاني. عدم تطابقهما ليس خطأً — هو الدَّين.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'money.credit_down_payment',
    title: 'دفعة مقدّمة على فاتورة آجلة',
    summary: 'يدفع العميل جزءًا الآن ويبقى الباقي دَينًا — في فاتورة واحدة.',
    track: LearningTrack.money,
    level: LearningLevel.intermediate,
    kind: LearningKind.walkthrough,
    minutes: 4,
    capability: AppCapability.checkoutSale,
    keywords: [
      'down payment',
      'deposit',
      'partial',
      'دفعة مقدمة',
      'عربون',
      'مقدم',
      'دفعة أولى',
      'سند قبض',
    ],
    related: ['money.credit_sale', 'money.split_tender', 'money.collect_debt'],
    opens: AppNavigationDestination.pos,
    sections: [
      LearningSection(
        title: 'الفكرة',
        blocks: [
          LearningParagraph(
            'الدفعة المقدّمة ليست فاتورة منفصلة ولا تحصيل دَين لاحق. هي مبلغ '
            'يُقبض في لحظة إصدار الفاتورة الآجلة نفسها، فيدخل الدرج فورًا '
            'ويُنقص الدَّين بنفس القيمة.',
          ),
        ],
      ),
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep('اربط العميل، ثم اضغط «إتمام البيع».'),
            LearningStep('اختر نوع البيع «آجل».'),
            LearningStep(
              'اضغط «إضافة دفعة مقدّمة».',
              detail:
                  'قبل ذلك تقرأ اللوحة: «كامل المبلغ سيُسجَّل دَينًا على العميل. '
                  'أضِف دفعة مقدّمة إن وُجدت.»',
            ),
            LearningStep(
              'اختر طريقة الدفعة المقدّمة وأدخل مبلغها.',
              detail:
                  'تتحوّل اللوحة إلى: «المبلغ المُدخَل دفعة مقدّمة؛ والباقي يُسجَّل دَينًا على العميل.»',
            ),
            LearningStep(
              'راجع «المتبقّي على العميل» في لوحة الملخّص — هذا هو الدَّين الذي سيُقيَّد.',
            ),
            LearningStep(
              'فعّل «طباعة سند قبض» إن أردت ورقة تُثبت للعميل ما دفعه الآن.',
            ),
            LearningStep('اضغط «تأكيد الدفع».'),
          ]),
        ],
      ),
      LearningSection(
        title: 'تفاصيل تستحق المعرفة',
        blocks: [
          LearningBullets([
            'يمكن تقسيم الدفعة المقدّمة نفسها: جزء نقدًا وجزء بالبطاقة، بإضافة أكثر من سطر.',
            'الدفعة المقدّمة لا تتجاوز الإجمالي أبدًا؛ إن تجاوزته تظهر رسالة «المبلغ المدفوع أكبر من الإجمالي».',
            'إن ناولك العميل ورقة أكبر وأردت إعطاءه باقيًا، يجب أن تكون الزيادة مغطّاة بالنقد — والباقي يُصرف من النقد وحده.',
            'دفعة مقدّمة تساوي الإجمالي تعني أنه لا دَين؛ والأنسب حينها بيع عادي لا آجل.',
          ]),
          LearningNote(
            tone: LearningNoteTone.tip,
            title: 'الفرق بينها وبين تحصيل الدَّين',
            message:
                'الدفعة المقدّمة تُدخَل داخل نافذة الدفع وقت إصدار الفاتورة. '
                'أما ما يدفعه العميل بعد أيام فيُسجَّل من «تحصيل دين»، ويُوزَّع '
                'تلقائيًا على أقدم فواتيره الآجلة أولًا.',
          ),
        ],
      ),
      LearningSection(
        title: 'أين ترى الأثر',
        blocks: [
          LearningBullets([
            'في الفاتورة: «المدفوع حتى الآن» و«المتبقّي على الفاتورة».',
            'في صفحة العميل: رصيده المستحق بعد خصم الدفعة.',
            'في درج ورديتك: الجزء النقدي من الدفعة المقدّمة فقط.',
            'في الخزينة: الدفعة مسجّلة باسم من قبضها وطريقتها.',
          ]),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'money.collect_debt',
    title: 'تحصيل دَين من عميل',
    summary: 'قبض مبلغ على حساب فواتير آجلة سابقة، وكيف يُوزَّع.',
    track: LearningTrack.money,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.collectCustomerDebt,
    keywords: ['collect', 'debt', 'تحصيل', 'سداد', 'دين', 'دفعة عميل'],
    related: [
      'money.credit_sale',
      'contacts.customer_file',
      'money.payments_hub',
    ],
    sections: [
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep(
              'افتح «تحصيل دين» من قائمة إجراءات الجلسة على شاشة البيع، أو من صفحة العميل.',
            ),
            LearningStep('اختر العميل؛ يظهر «المتبقّي على العميل».'),
            LearningStep('أدخل المبلغ المقبوض واختر طريقته.'),
            LearningStep('اضغط «تسجيل دفعة».'),
          ]),
        ],
      ),
      LearningSection(
        title: 'كيف يُوزَّع المبلغ',
        blocks: [
          LearningParagraph(
            'تُوزَّع الدفعة تلقائيًا على أقدم الفواتير الآجلة أولًا. فإن كان على '
            'العميل ثلاث فواتير ودفع ما يكفي أولاها ونصف ثانيتها، أُقفلت الأولى '
            'وبقيت الثانية جزئية والثالثة كما هي.',
          ),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'الدفعة النقدية تدخل درجك',
            message:
                'تحصيل نقدي يزيد النقد المتوقع في ورديتك تمامًا كالبيع، فاحرص '
                'على تسجيله وقت قبضه لا في آخر اليوم.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'money.credit_limits',
    title: 'سقف الدَّين للعملاء',
    summary: 'حدّ أقصى لما يمكن أن يستدينه عميل، ولماذا يُرفض بيع آجل أحيانًا.',
    track: LearningTrack.money,
    level: LearningLevel.intermediate,
    kind: LearningKind.concept,
    minutes: 3,
    capability: AppCapability.manageContacts,
    keywords: ['credit limit', 'سقف', 'حد الدين', 'ائتمان'],
    related: [
      'money.credit_sale',
      'contacts.customer_file',
      'setup.shop_settings',
    ],
    sections: [
      LearningSection(
        title: 'كيف يعمل',
        blocks: [
          LearningParagraph(
            'الميزة مغلقة افتراضيًا ولا يتغيّر شيء حتى يفعّلها المدير. عند '
            'تفعيلها يوضع سقف افتراضي لكل العملاء، ويمكن إعطاء عميل بعينه سقفًا '
            'خاصًا أو «بلا سقف» من صفحته.',
          ),
          LearningParagraph(
            'قبل تأكيد أي بيع آجل يحسب النظام: الدَّين الحالي + قيمة هذه '
            'الفاتورة. إن تجاوز المجموع السقف، رُفض البيع ورسالة الرفض تعرض '
            'الأرقام الأربعة: الدين الحالي، ما تضيفه الفاتورة، السقف، والمتاح.',
          ),
        ],
      ),
      LearningSection(
        title: 'ماذا تفعل عند الرفض',
        blocks: [
          LearningBullets([
            'حصِّل دفعة من العميل تخفض دَينه تحت السقف.',
            'أو اجعل جزءًا من الفاتورة دفعة مقدّمة حتى ينزل المتبقّي تحت المتاح.',
            'أو ارفع سقف هذا العميل من صفحته — قرار مدير، لا قرار كاشير.',
          ]),
          LearningNote(
            tone: LearningNoteTone.tip,
            title: 'سقف صفر يعني «نقدًا فقط»',
            message:
                'ضع السقف الافتراضي صفرًا لمنع البيع الآجل لكل العملاء، ثم '
                'استثنِ من تثق بهم بسقف خاص.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'money.quotation',
    title: 'عرض السعر',
    summary: 'ورقة سعر للعميل لا تُخصم من المخزون ولا تقبض مالًا.',
    track: LearningTrack.money,
    level: LearningLevel.intermediate,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.checkoutSale,
    keywords: ['quotation', 'quote', 'عرض سعر', 'تسعيرة', 'عرض'],
    related: ['money.credit_sale', 'reports.invoices'],
    sections: [
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep('جهّز السلة واربط العميل (شرط، كالآجل).'),
            LearningStep('اضغط «إتمام البيع» واختر نوع البيع «عرض سعر».'),
            LearningStep('حدّد «صالح حتى» — تاريخ انتهاء صلاحية السعر.'),
            LearningStep(
              'فعّل «حجز الكمية» إن أردت منع بيع هذه الكميات لغيره حتى انتهاء العرض.',
            ),
            LearningStep('أكّد، ثم اطبع العرض أو شاركه PDF.'),
          ]),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'لا دفع ولا خصم من المخزون',
            message:
                'عرض السعر لا يتضمّن أي دفع ولا يخصم من المخزون. الحجز — إن '
                'فعّلته — يمنع بيع الكمية لغيره فقط.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'money.card_receipt',
    title: 'إثبات إيصال البطاقة',
    summary: 'لماذا يطلب البرنامج مطابقة إيصال جهاز البطاقة قبل التأكيد.',
    track: LearningTrack.money,
    level: LearningLevel.intermediate,
    kind: LearningKind.concept,
    minutes: 3,
    capability: AppCapability.checkoutSale,
    keywords: [
      'card',
      'receipt',
      'pos terminal',
      'بطاقة',
      'إيصال',
      'جهاز البطاقة',
    ],
    related: [
      'money.payment_methods',
      'money.split_tender',
      'contacts.payment_cards',
    ],
    sections: [
      LearningSection(
        title: 'المشكلة التي يحلّها',
        blocks: [
          LearningParagraph(
            'دفعة بطاقة مسجّلة بلا إيصال هي ادّعاء لا دليل عليه: لا أحد يعرف إن '
            'مُرِّرت فعلًا على الجهاز أو بكم. حين يفعّل المتجر «اشتراط إثبات '
            'البطاقة» لا يقبل البرنامج التأكيد قبل مطابقة كل دفعة بطاقة بإيصالها.',
          ),
        ],
      ),
      LearningSection(
        title: 'كيف تطابق',
        blocks: [
          LearningSteps([
            LearningStep('مرّر البطاقة على جهاز البنك كالمعتاد.'),
            LearningStep(
              'امسح رمز الإيصال أو أدخل مرجعه في نافذة الدفع.',
              detail:
                  'تعرض النافذة الدفعة المنتظِرة ومبلغها حتى تعرف أي سطر تطابقه.',
            ),
            LearningStep('تأكّد أن المبلغ يطابق، ثم أكمل التأكيد.'),
          ]),
          LearningNote(
            tone: LearningNoteTone.tip,
            title: 'البطاقة تُعرف لاحقًا',
            message:
                'الإيصالات المطابَقة تُبنى منها بطاقات دفع مسجّلة تُربط بالعميل '
                'تلقائيًا، فتصير مشتريات العميل قابلة للتتبّع حتى لو لم يُسجَّل اسمه.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'money.payments_hub',
    title: 'الخزينة: كل المدفوعات في مكان واحد',
    summary: 'ما دخل من العملاء وما خرج للموردين، بالفلترة والبحث.',
    track: LearningTrack.money,
    level: LearningLevel.intermediate,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.viewMoneyAccounts,
    keywords: ['payments', 'hub', 'خزينة', 'مدفوعات', 'مقبوضات'],
    related: [
      'money.collect_debt',
      'purchasing.pay_supplier',
      'money.treasury',
    ],
    opens: AppNavigationDestination.payments,
    sections: [
      LearningSection(
        title: 'ما تجده هنا',
        blocks: [
          LearningParagraph(
            'قسمان: «مدفوعات العملاء (وارد)» و«مدفوعات الموردين (صادر)». كل صف '
            'يحمل المبلغ والطريقة والمستند المرتبط به (فاتورة أو أمر شراء) ومن سجّله.',
          ),
          LearningBullets([
            'رشِّح بالطريقة أو بنطاق تاريخ.',
            'افتح الفاتورة أو أمر الشراء من الصف مباشرة.',
            'أعد طباعة سند القبض أو الدفع عند الحاجة.',
          ]),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'money.treasury',
    title: 'موضع المال (الخزينة)',
    summary: 'كم في الأدراج، كم في البنك، وأين الفرق بين الدفتر والعدّ.',
    track: LearningTrack.money,
    level: LearningLevel.advanced,
    kind: LearningKind.concept,
    minutes: 3,
    capability: AppCapability.viewMoneyAccounts,
    keywords: ['treasury', 'cash position', 'خزينة', 'رصيد', 'بنك', 'نقد'],
    related: ['register.close', 'money.payments_hub', 'reports.reports'],
    sections: [
      LearningSection(
        title: 'الفكرة',
        blocks: [
          LearningParagraph(
            'كل رصيد هنا مشتقّ من الحركات لا مكتوب يدويًا: النقد في الدرج هو '
            'حاصل جمع ما دخله وما خرج منه. لذلك لا يمكن «تصحيح» رقم بكتابته — '
            'يُصحَّح بتسجيل الحركة الناقصة.',
          ),
        ],
      ),
      LearningSection(
        title: 'قراءة الفروقات',
        blocks: [
          LearningDefinitions([
            LearningDefinition('مطابق', 'العدّ يساوي ما يقوله الدفتر.'),
            LearningDefinition(
              'زيادة',
              'عددت أكثر مما يتوقع الدفتر — غالبًا دفعة قُبضت ولم تُسجَّل.',
            ),
            LearningDefinition(
              'عجز',
              'عددت أقل — غالبًا صرف خرج بلا تسجيل، أو خطأ في طريقة دفع.',
            ),
          ]),
          LearningParagraph(
            'افتح الحساب لترى الحركات التي كوّنت الرصيد وتعرف أين نشأ الفرق، بدل '
            'أن تبحث عنه في الذاكرة.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'money.expenses',
    title: 'تسجيل مصروفات المتجر',
    summary: 'إيجار، كهرباء، وقود مولّد — وربطها بالسحب من الدرج.',
    track: LearningTrack.money,
    level: LearningLevel.intermediate,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.manageExpenses,
    keywords: ['expenses', 'مصروفات', 'مصاريف', 'إيجار', 'كهرباء'],
    related: ['register.cash_movements', 'money.treasury', 'reports.reports'],
    opens: AppNavigationDestination.expenses,
    sections: [
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep('افتح «المصروفات» وأضِف مصروفًا جديدًا.'),
            LearningStep('اختر التصنيف وأدخل المبلغ والوصف والتاريخ.'),
            LearningStep(
              'إن دُفع المصروف من درج الوردية، اربطه بسحب نقدي.',
              detail:
                  'هذا ما يمنع ظهور المبلغ كعجز في الدرج عند الإغلاق: النقد خرج، والدفتر يعرف لماذا.',
            ),
          ]),
          LearningNote(
            tone: LearningNoteTone.warning,
            title: 'مصروف بلا سحب = عجز في الدرج',
            message:
                'إن أخذت من الدرج لشراء وقود ولم تسجّل شيئًا، سيعدّ النظام '
                'المبلغ ناقصًا ويسجّل فرقًا نقديًا باسمك.',
          ),
        ],
      ),
    ],
  ),
];
