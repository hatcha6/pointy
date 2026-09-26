import '../../../core/authorization.dart';
import '../../../shared/navigation/app_navigation.dart';
import '../models/learning_guide.dart';

/// The supply side: ordering, receiving, paying, and putting right what the
/// supplier got wrong.
const purchasingGuides = <LearningGuide>[
  LearningGuide(
    id: 'purchasing.lifecycle',
    title: 'دورة حياة أمر الشراء',
    summary: 'مسودة ← مُرسل ← مستلم ← مدفوع: ما الذي يتغيّر في كل مرحلة.',
    track: LearningTrack.purchasing,
    level: LearningLevel.beginner,
    kind: LearningKind.concept,
    minutes: 3,
    capability: AppCapability.accessPurchasing,
    keywords: ['purchase order', 'po', 'أمر شراء', 'طلبية', 'مورد', 'دورة'],
    related: [
      'purchasing.create_po',
      'purchasing.receive',
      'purchasing.pay_supplier',
    ],
    opens: AppNavigationDestination.purchasing,
    sections: [
      LearningSection(
        title: 'المراحل',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'مسودة',
              'طلبية تُبنى عندك. لا شيء يتحرّك: لا مخزون ولا مال. يمكن تعديلها ومسحها بحرية.',
            ),
            LearningDefinition(
              'مُرسل',
              'أُرسل الأمر إلى المورد. صار مستندًا ينتظر توريدًا، وما زال المخزون بلا تغيير.',
            ),
            LearningDefinition(
              'مستلم جزئيًا',
              'وصل بعض الكميات. المخزون زاد بما وصل فقط، والباقي يبقى «مفتوحًا».',
            ),
            LearningDefinition(
              'مستلم',
              'وصلت الكميات كلها. المخزون كامل، ويبقى السداد.',
            ),
            LearningDefinition('ملغى', 'أُلغي الأمر ولا يمكن تعديله بعدها.'),
          ]),
        ],
      ),
      LearningSection(
        title: 'القاعدة المهمة',
        blocks: [
          LearningNote(
            tone: LearningNoteTone.danger,
            title: 'الاستلام وحده هو ما يزيد المخزون',
            message:
                'إنشاء أمر الشراء أو إرساله لا يضيف قطعة واحدة إلى الرصيد. من '
                'ينتظر ظهور البضاعة بعد الإرسال سيظن أن البرنامج معطّل، وهو '
                'يقول له الحقيقة: البضاعة لم تصل بعد.',
          ),
          LearningParagraph(
            'حالة الدفع مستقلّة عن حالة التوريد: أمر مستلم قد يكون غير مدفوع، '
            'وأمر مدفوع مقدّمًا قد يكون لم يصل بعد.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'purchasing.create_po',
    title: 'إنشاء أمر شراء',
    summary: 'من كتالوج الشراء إلى أمر مُرسل للمورد، بالتكاليف وأسعار البيع.',
    track: LearningTrack.purchasing,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 5,
    capability: AppCapability.createPurchaseOrder,
    keywords: ['create po', 'order', 'أمر شراء', 'طلبية', 'شراء', 'إنشاء'],
    related: [
      'purchasing.lifecycle',
      'purchasing.receive',
      'purchasing.landed_costs',
      'purchasing.suggestions',
    ],
    opens: AppNavigationDestination.purchasing,
    sections: [
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep(
              'افتح «المشتريات». تُبنى الطلبية في «مسودة الشراء» على اليمين من كتالوج الشراء على اليسار.',
            ),
            LearningStep(
              'اختر المورد أولًا.',
              detail:
                  'اختياره مبكرًا يُظهر لك اقتراحاته المعتادة وأسعاره السابقة، ولا يمكن إرسال أمر بلا مورد.',
            ),
            LearningStep(
              'أضِف الأصناف: بالبحث، أو بالمسح، أو من شرائح «الطلب المعتاد» والاقتراحات.',
            ),
            LearningStep(
              'أدخل لكل سطر: الكمية، ووحدة الشراء، وتكلفة الوحدة.',
              detail:
                  'إن كانت الفاتورة تعطيك الإجمالي فقط، استعمل «إدخال الإجمالي بدل سعر الوحدة» ويُقسَم على الكمية تلقائيًا.',
            ),
            LearningStep(
              'راجع سعر البيع وهامش الربح المعروضين على كل سطر.',
              detail:
                  'هذه هي اللحظة المناسبة لتصحيح سعر بيع لم يعد يغطّي التكلفة الجديدة.',
            ),
            LearningStep(
              'أدخل رقم فاتورة المورد وتاريخها من «بيانات فاتورة المورد».',
              detail:
                  'يربط أمرك بالورقة التي في يدك، فتُراجَع لاحقًا بلا تخمين.',
            ),
            LearningStep('احفظ مسودة، أو اضغط «إرسال أمر الشراء» لإرساله.'),
          ]),
        ],
      ),
      LearningSection(
        title: 'إضافات مفيدة على الأمر',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'مكان الاستلام',
              'المخزن الذي ستصل إليه البضاعة، إن كان للمتجر أكثر من مكان.',
            ),
            LearningDefinition(
              'تاريخ الاستحقاق',
              'موعد سداد المورد؛ هو ما يجعل الأمر يظهر متأخرًا حين يتأخر.',
            ),
            LearningDefinition(
              'خصم على أمر الشراء',
              'مبلغ يخصمه المورد من الإجمالي — لكسر الكسور مثلًا.',
            ),
            LearningDefinition(
              'كود خصم المورد',
              'إن كان للمورد قواعد خصم مسجّلة عندك.',
            ),
            LearningDefinition(
              'عملة المورد',
              'إن فوتر بعملة أجنبية، يُثبَّت سعر الصرف على الأمر ولا يتغيّر بعدها.',
            ),
            LearningDefinition(
              'تاريخ الانتهاء',
              'إلزامي لكل صنف يتابع الانتهاء قبل الحفظ.',
            ),
          ]),
        ],
      ),
      LearningSection(
        title: 'حارس التكلفة',
        blocks: [
          LearningParagraph(
            'إن بدت التكلفة المُدخَلة غريبة مقارنةً بتاريخ الصنف، يتوقف البرنامج '
            'ويطلب مراجعتها. الخطأ الشائع الذي يمسكه: كتابة إجمالي السطر في '
            'خانة سعر الوحدة — وهو خطأ يضاعف تكلفة المخزون ويمحو هامش الربح '
            'على كل بيعة تالية.',
          ),
          LearningParagraph(
            'إن كانت التكلفة صحيحة فعلًا، اضغط «التكلفة صحيحة، تابع» وامضِ.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'purchasing.receive',
    title: 'استلام البضاعة (وما ينقص منها)',
    summary: 'سجّل ما وصل فعلًا: السليم والتالف والمرفوض، لا ما طلبته.',
    track: LearningTrack.purchasing,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 4,
    capability: AppCapability.receivePurchaseOrder,
    keywords: ['receive', 'delivery', 'استلام', 'توريد', 'ناقص', 'تالف'],
    related: [
      'purchasing.lifecycle',
      'purchasing.returns',
      'inventory.stock_basics',
    ],
    opens: AppNavigationDestination.purchasing,
    sections: [
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep('افتح أمر الشراء واختر «استلام».'),
            LearningStep(
              'لكل سطر أدخل ما وصل فعلًا في الخانة المناسبة.',
              detail:
                  'يعرض السطر: المطلوب، المستلم سابقًا، المفتوح، والفرق بعد الإدخال — فترى أثر ما تكتبه قبل الحفظ.',
            ),
            LearningStep('اكتب ملاحظة الاستلام عند وجود نقص أو زيادة.'),
            LearningStep('احفظ.'),
          ]),
        ],
      ),
      LearningSection(
        title: 'الخانات الثلاث',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'مستلم سليم',
              'وصل وصالح للبيع. هذا وحده ما يدخل المخزون.',
            ),
            LearningDefinition(
              'تالف عند الوصول',
              'وصل مكسورًا أو منتهيًا. مسجَّل كواصل لكنه لا يدخل رصيد البيع، وهو أساس مطالبة المورد.',
            ),
            LearningDefinition(
              'مرفوض / لن يصل',
              'لن يورّده المورد أصلًا. يُغلق المفتوح فلا يبقى الأمر معلّقًا للأبد.',
            ),
          ]),
          LearningNote(
            tone: LearningNoteTone.danger,
            title: 'لا تستلم ما لم يصل',
            message:
                'تسجيل الكمية كاملة «لأنها ستصل غدًا» يزيد المخزون بقطع ليست في '
                'الرف، فيبيعها الكاشير ويظهر رصيد سالب لا أحد يفهم سببه.',
          ),
        ],
      ),
      LearningSection(
        title: 'الاستلام على دفعات',
        blocks: [
          LearningParagraph(
            'يمكن الاستلام أكثر من مرة على الأمر نفسه. يصبح «مستلم جزئيًا» '
            'ويبقى المفتوح ظاهرًا، ويُسجَّل كل استلام في «سجل الاستلام» بتاريخه '
            'وكمياته — فتعرف لاحقًا متى وصل ماذا.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'purchasing.pay_supplier',
    title: 'تسجيل دفعة للمورد',
    summary: 'سداد كامل أو جزئي، من الدرج أو البنك، مع سند صرف.',
    track: LearningTrack.purchasing,
    level: LearningLevel.beginner,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.recordSupplierPayment,
    keywords: ['supplier payment', 'دفعة مورد', 'سداد', 'دفع', 'مستحقات'],
    related: [
      'purchasing.lifecycle',
      'money.payments_hub',
      'contacts.suppliers',
    ],
    sections: [
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep('افتح أمر الشراء واختر «تسجيل دفعة».'),
            LearningStep('أدخل المبلغ — ولا يتجاوز «المتبقي للمورد».'),
            LearningStep('اختر طريقة الدفع، وأضِف مرجعًا أو ملاحظة إن لزم.'),
            LearningStep('فعّل «طباعة سند صرف» إن أردت ورقة للمورد.'),
          ]),
        ],
      ),
      LearningSection(
        title: 'حالات السداد',
        blocks: [
          LearningDefinitions([
            LearningDefinition('غير مدفوع', 'لم يُسدَّد منه شيء.'),
            LearningDefinition(
              'مدفوع جزئيًا',
              'سُدِّد بعضه وبقي «المتبقي للمورد».',
            ),
            LearningDefinition('مدفوع', 'أُقفل بالكامل.'),
            LearningDefinition(
              'رصيد دائن',
              'لك رصيد عند المورد — من إرجاع سابق عادةً — يمكن استعماله في سداد هذا الأمر.',
            ),
          ]),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'الدفع نقدًا من الدرج',
            message:
                'إن دفعت من درج الوردية فسجّل سحبًا نقديًا مقابلًا، وإلا ظهر '
                'المبلغ عجزًا عند الإغلاق.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'purchasing.edit_po',
    title: 'تعديل أمر شراء بعد إنشائه',
    summary: 'حتى متى يمكن التعديل، وماذا يحدث لاستلام سُجّل من قبل.',
    track: LearningTrack.purchasing,
    level: LearningLevel.advanced,
    kind: LearningKind.concept,
    minutes: 3,
    capability: AppCapability.editDraftPurchaseOrder,
    keywords: ['edit po', 'تعديل', 'أمر شراء', 'تصحيح'],
    related: ['purchasing.receive', 'purchasing.lifecycle'],
    sections: [
      LearningSection(
        title: 'القاعدة',
        blocks: [
          LearningParagraph(
            'يبقى أمر الشراء قابلًا للتعديل حتى يستقرّ المال عليه. الاستلام '
            'وحده لا يقفله: كثيرًا ما تُكتشف كمية خاطئة أو تكلفة خاطئة بعد '
            'تفريغ البضاعة، والاضطرار إلى إلغاء الأمر وإعادة إدخاله كله هو ما '
            'يدفع الناس إلى تركه خاطئًا.',
          ),
          LearningNote(
            tone: LearningNoteTone.warning,
            title: 'التعديل بعد الاستلام يُعيد تسجيله',
            message:
                'يُنبّهك البرنامج: «تم استلام هذا الأمر بالفعل. عند الحفظ سيُعاد '
                'تسجيل الاستلام بالكميات والتكاليف الجديدة.» أي أن أثر الاستلام '
                'القديم يُفكّ ويُعاد بناؤه بالأرقام الصحيحة.',
          ),
        ],
      ),
      LearningSection(
        title: 'ما لا يُعدَّل',
        blocks: [
          LearningBullets([
            'أمر ملغى.',
            'كمية بِيعت أو لم تعد موجودة في المخزون — لا يمكن سحبها من أمر الشراء.',
          ]),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'purchasing.returns',
    title: 'الإرجاع والاستبدال والاسترداد مع المورد',
    summary: 'بضاعة تالفة أو خطأ في الفاتورة: كيف تُسوّى وتُتابَع.',
    track: LearningTrack.purchasing,
    level: LearningLevel.advanced,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.adjustPurchaseOrder,
    keywords: ['supplier return', 'إرجاع للمورد', 'استرداد', 'تالف'],
    related: [
      'purchasing.receive',
      'purchasing.pay_supplier',
      'contacts.suppliers',
    ],
    sections: [
      LearningSection(
        title: 'الأنواع الثلاثة',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'إرجاع',
              'ترجع البضاعة ويُنشأ لك رصيد عند المورد.',
            ),
            LearningDefinition('استرداد', 'ترجع البضاعة ويُرَدّ المال.'),
            LearningDefinition(
              'استبدال',
              'ترجع أصنافًا وتستلم بديلها بكميات وتكاليف جديدة.',
            ),
          ]),
          LearningParagraph(
            'في الحالات كلها تُخصم الكميات المرتجعة من المخزون وتُسجَّل في '
            '«المرتجعات والاستبدالات» على الأمر مع سببها.',
          ),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'لا يمكن إرجاع ما بِيع',
            message:
                'إن كانت الكمية قد بِيعت أو لم تعد في المخزون، يرفض البرنامج '
                'التعديل — لأنك لا تستطيع إعادة ما ليس عندك.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'purchasing.landed_costs',
    title: 'تكاليف الوصول (الشحن والجمارك)',
    summary: 'وزّع مصاريف الشحنة على أصنافها لتعرف تكلفتها الحقيقية.',
    track: LearningTrack.purchasing,
    level: LearningLevel.advanced,
    kind: LearningKind.concept,
    minutes: 3,
    capability: AppCapability.accessPurchasing,
    keywords: [
      'landed cost',
      'shipping',
      'تكاليف وصول',
      'شحن',
      'جمارك',
      'مناولة',
    ],
    related: ['purchasing.create_po', 'inventory.valuation'],
    sections: [
      LearningSection(
        title: 'لماذا',
        blocks: [
          LearningParagraph(
            'شحنة بألف دينار ومئة دينار شحنًا تكلّفك ألفًا ومئة. إن أهملت المئة '
            'فكل حساب ربح تفعله بعدها متفائل بمقدار لا تعرفه.',
          ),
        ],
      ),
      LearningSection(
        title: 'طرق التوزيع',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'حسب قيمة السطر',
              'الأغلى يتحمّل أكثر. الافتراضي والأنسب غالبًا.',
            ),
            LearningDefinition(
              'حسب الكمية',
              'مناسب حين تكون الأصناف متشابهة الحجم والوزن.',
            ),
            LearningDefinition(
              'حسب قيمة البيع',
              'يوزّع بحسب ما ستبيع به لا ما اشتريت به.',
            ),
            LearningDefinition(
              'بالتساوي على السطور',
              'لمصاريف ثابتة لا علاقة لها بالحجم، كرسوم معاملة.',
            ),
          ]),
          LearningParagraph(
            'أضِف بنود التكلفة (شحن، جمارك، مناولة) من نافذة «تكاليف الوصول» على '
            'الأمر، واختر طريقة التوزيع؛ تظهر بعدها «التكلفة الفعلية» على كل سطر.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'purchasing.cash_purchase',
    title: 'شراء نقدي سريع من شاشة البيع',
    summary: 'للمشتريات الصغيرة التي تُدفع من الدرج فورًا.',
    track: LearningTrack.purchasing,
    level: LearningLevel.intermediate,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.createPosCashPurchase,
    keywords: ['cash purchase', 'شراء نقدي', 'من الدرج', 'شراء سريع'],
    related: [
      'register.cash_movements',
      'purchasing.create_po',
      'purchasing.cost_guard',
    ],
    sections: [
      LearningSection(
        title: 'متى',
        blocks: [
          LearningParagraph(
            'جاء مورد الخبز بصندوقين وأخذ ثمنهما نقدًا من الدرج الآن. لا معنى '
            'لأمر شراء بمراحله لهذه الحالة.',
          ),
        ],
      ),
      LearningSection(
        title: 'الخطوات',
        blocks: [
          LearningSteps([
            LearningStep('من إجراءات الجلسة اختر «شراء نقدي من الصندوق».'),
            LearningStep('اختر المورد.'),
            LearningStep('أضِف الأصناف بكمياتها وسعر شرائها.'),
            LearningStep('اضغط «تسجيل الشراء والدفع نقداً».'),
          ]),
          LearningParagraph(
            'يُنشئ البرنامج أمر شراء مستلمًا ومدفوعًا دفعة واحدة، ويسجّل سحبًا '
            'نقديًا من درجك بنفس القيمة — فيزيد المخزون وينقص النقد في خطوة واحدة.',
          ),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'حدّان يضبطان الاستعمال',
            message:
                'تحتاج وردية مفتوحة، وقد يضع المتجر حدًّا أقصى لقيمة الشراء '
                'النقدي الواحد. وهو صلاحية مستقلة لا تعطي الكاشير شاشة المشتريات.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'purchasing.suggestions',
    title: 'اقتراحات الشراء والطلب المعتاد',
    summary: 'كيف يقترح البرنامج ما تنساه عادةً من كل مورد.',
    track: LearningTrack.purchasing,
    level: LearningLevel.intermediate,
    kind: LearningKind.concept,
    minutes: 2,
    capability: AppCapability.createPurchaseOrder,
    keywords: ['suggestions', 'اقتراحات', 'الطلب المعتاد', 'إعادة طلب'],
    related: ['purchasing.create_po'],
    sections: [
      LearningSection(
        title: 'من أين تأتي',
        blocks: [
          LearningParagraph(
            'من عادتك أنت مع هذا المورد: ما تشتريه منه غالبًا، ما يُشترى عادةً '
            'مع صنف أضفته للتو، وما مرّ على شرائه ما يكفي ليُطلب ثانية. يعرض كل '
            'اقتراح سببه، وتظهر معه «الكمية المعتادة» لهذا الصنف من هذا المورد.',
          ),
          LearningParagraph(
            'شريحة «الطلب المعتاد» تملأ المسودة بسلّتك المتكرّرة دفعة واحدة، ثم '
            'تعدّل ما تشاء. ويمكن إخفاء الاقتراحات لهذا الأمر أو إسكات صنف بعينه نهائيًا.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'purchasing.cost_guard',
    title: 'تحذير التكلفة غير المنطقية',
    summary: 'لماذا يوقفك البرنامج أحيانًا قبل حفظ سعر شراء.',
    track: LearningTrack.purchasing,
    level: LearningLevel.intermediate,
    kind: LearningKind.concept,
    minutes: 2,
    capability: AppCapability.createPurchaseOrder,
    keywords: ['cost', 'warning', 'تكلفة', 'تحذير', 'خطأ إدخال'],
    related: ['purchasing.create_po', 'catalog.units', 'inventory.valuation'],
    sections: [
      LearningSection(
        title: 'مستويان',
        blocks: [
          LearningDefinitions([
            LearningDefinition(
              'تحذير',
              'التكلفة غير معتادة لهذا الصنف. راجعها، وإن كانت صحيحة تابع.',
            ),
            LearningDefinition(
              'منع',
              'التكلفة غير منطقية إلى حدّ يجعلها خطأ إدخال شبه مؤكد، فلا تُحفظ.',
            ),
          ]),
          LearningParagraph(
            'أشيع سببين: كتابة إجمالي السطر مكان سعر الوحدة، وخلط وحدة الشراء '
            '(سعر الكرتونة مُدخل على أنه سعر القطعة). كلاهما يفسد تكلفة المخزون '
            'وهامش الربح على كل بيعة لاحقة، ولا يظهر أثره إلا بعد أسابيع.',
          ),
        ],
      ),
    ],
  ),
];
