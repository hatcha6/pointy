import '../../../core/authorization.dart';
import '../../../shared/navigation/app_navigation.dart';
import '../models/learning_guide.dart';

/// The hardware around the till: printers, labels, scales, the price checker,
/// the phone camera and the shop's cameras.
const devicesGuides = <LearningGuide>[
  LearningGuide(
    id: 'devices.printers',
    title: 'إعداد الطابعات وأدوارها',
    summary: 'طابعة الإيصالات وطابعة المطبخ وطابعة الملصقات، لكل دورها.',
    track: LearningTrack.devices,
    level: LearningLevel.intermediate,
    kind: LearningKind.walkthrough,
    minutes: 4,
    capability: AppCapability.manageDeviceSettings,
    keywords: ['printer', 'طابعة', 'طباعة', 'إيصال', 'حرارية'],
    related: ['selling.receipt', 'devices.labels', 'operations.kitchen'],
    opens: AppNavigationDestination.deviceSettings,
    sections: [
      LearningSection(
        title: 'الإضافة',
        blocks: [
          LearningSteps([
            LearningStep('افتح «إعدادات الجهاز» ثم الطابعات.'),
            LearningStep(
              'اضغط «اكتشاف الطابعات» لعرض المتاح، أو أضِف طابعة يدويًا بعنوانها.',
              detail: 'يدعم البرنامج الشبكة وUSB وبلوتوث والطباعة عبر النظام.',
            ),
            LearningStep(
              'اختر دور الطابعة: إيصالات نقطة البيع، أو محطة تحضير، أو ملصقات.',
            ),
            LearningStep('اضغط «فحص الاتصال» وجرّب طباعة اختبارية.'),
          ]),
        ],
      ),
      LearningSection(
        title: 'مقاسات الورق',
        blocks: [
          LearningParagraph(
            'تُدعم لفّات ٥٨ و٧٠ و٨٠ ملم إضافة إلى A4. اختر ما يطابق طابعتك — '
            'المقاس الخاطئ يقصّ الأسطر أو يهدر الورق.',
          ),
          LearningNote(
            tone: LearningNoteTone.tip,
            title: 'وضع الإيصال المختصر',
            message:
                'يقلّل ارتفاع الإيصال ويوفّر ورقًا محسوسًا في متجر يطبع مئات الإيصالات يوميًا.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'devices.labels',
    title: 'طباعة ملصقات الباركود',
    summary: 'ملصقات للأصناف بلا باركود، ومعايرة مقاس الملصق.',
    track: LearningTrack.devices,
    level: LearningLevel.advanced,
    kind: LearningKind.walkthrough,
    minutes: 4,
    capability: AppCapability.manageDeviceSettings,
    keywords: ['label', 'barcode label', 'ملصق', 'ليبل', 'معايرة'],
    related: ['catalog.barcodes', 'devices.printers'],
    sections: [
      LearningSection(
        title: 'الطباعة',
        blocks: [
          LearningSteps([
            LearningStep('من بطاقة المنتج أو الخيار اختر طباعة ملصقات.'),
            LearningStep(
              'حدّد العدد وما يظهر على الملصق (الاسم، السعر، الباركود).',
            ),
            LearningStep('اطبع.'),
          ]),
        ],
      ),
      LearningSection(
        title: 'حين لا يخرج الملصق صحيحًا',
        blocks: [
          LearningParagraph(
            'طابعات الملصقات تتكلّم لغات مختلفة (TSPL، ZPL، EPL، CPCL، وبعضها '
            'ESC/POS). إن خرجت الطباعة رموزًا أو فارغة، استعمل «اكتشاف لغة طابعة '
            'الملصقات»، أو اخترها يدويًا إن تعذّر الاكتشاف.',
          ),
          LearningNote(
            tone: LearningNoteTone.warning,
            title: 'قِس قبل أن تعاير',
            message:
                'إن كان الملصق مزاحًا أو مقصوصًا، اطبع مسطرة معايرة وقِس الإزاحة '
                'والمقاس والمسافة بين الملصقات فعليًا. التخمين هنا يُهدر لفّة كاملة.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'devices.scales',
    title: 'الموازين',
    summary: 'ملصق الميزان الذي يحمل الوزن والسعر، ورفع الأصناف إلى الميزان.',
    track: LearningTrack.devices,
    level: LearningLevel.advanced,
    kind: LearningKind.concept,
    minutes: 3,
    capability: AppCapability.manageScales,
    keywords: ['scale', 'ميزان', 'وزن', 'plu'],
    related: ['selling.quantities_units', 'catalog.units'],
    sections: [
      LearningSection(
        title: 'كيف يتكامل',
        blocks: [
          LearningParagraph(
            'يطبع الميزان ملصقًا بباركود يحمل رمز الصنف ووزنه (أو سعره). مسحه '
            'على شاشة البيع يضيف الصنف بالوزن الصحيح مباشرة بلا إدخال يدوي.',
          ),
          LearningParagraph(
            'ويمكن رفع أرقام الأصناف وأسعارها من البرنامج إلى الميزان، فلا '
            'تُدخَل الأسعار مرتين ولا تختلف بين الجهازين.',
          ),
          LearningNote(
            tone: LearningNoteTone.tip,
            title: 'اختبر بصنف واحد أولًا',
            message:
                'تختلف تركيبة الباركود بين طرازات الموازين. اضبط الصيغة ثم '
                'تحقّق أن وزنًا معلومًا يظهر كما هو قبل تعميم الإعداد.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'devices.price_checker',
    title: 'جهاز فحص الأسعار',
    summary: 'شاشة للزبون يمسح عليها الصنف ليرى سعره.',
    track: LearningTrack.devices,
    level: LearningLevel.advanced,
    kind: LearningKind.walkthrough,
    minutes: 3,
    capability: AppCapability.managePriceCheckers,
    keywords: ['price checker', 'kiosk', 'فحص السعر', 'كشك', 'شاشة الزبون'],
    related: ['catalog.barcodes', 'setup.connection'],
    sections: [
      LearningSection(
        title: 'التشغيل',
        blocks: [
          LearningSteps([
            LearningStep('ثبّت التطبيق على الجهاز وصِله بشبكة المتجر.'),
            LearningStep(
              'يظهر الجهاز في قائمة الأجهزة «بانتظار التفعيل»؛ فعّله من الإعدادات.',
            ),
            LearningStep(
              'شغّل وضع الكشك ليعمل بملء الشاشة.',
              detail: 'الخروج منه يحتاج رمز PIN، فلا يعبث به أحد.',
            ),
          ]),
          LearningParagraph(
            'يعرض الجهاز السعر فقط ولا يسجّل بيعًا ولا يحتاج تسجيل دخول.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'devices.companion_camera',
    title: 'استعمال الهاتف ماسحًا للصندوق',
    summary: 'اقترن بهاتف على الشبكة ليعمل كاميرا مسح للصندوق.',
    track: LearningTrack.devices,
    level: LearningLevel.advanced,
    kind: LearningKind.walkthrough,
    minutes: 2,
    capability: AppCapability.accessPos,
    keywords: ['companion', 'phone camera', 'هاتف', 'كاميرا', 'مسح بالهاتف'],
    related: ['selling.add_items', 'setup.connection'],
    sections: [
      LearningSection(
        title: 'الاقتران',
        blocks: [
          LearningSteps([
            LearningStep(
              'من إعدادات الجهاز افتح الهواتف المقترنة وأنشئ رمز اقتران.',
            ),
            LearningStep('امسح الرمز بهاتف متصل بشبكة المتجر نفسها.'),
            LearningStep(
              'صوّب كاميرا الهاتف نحو الباركود؛ يُضاف الصنف إلى السلة كأنه مسح من الماسح.',
            ),
          ]),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'الاقتران ليس تسجيل دخول',
            message:
                'الهاتف المقترن يعمل ماسحًا لهذا الصندوق فقط، ولا يفتح حسابًا ولا '
                'يرى بيانات المتجر. ويمكن إلغاء اقترانه في أي وقت.',
          ),
        ],
      ),
    ],
  ),
  LearningGuide(
    id: 'devices.cameras',
    title: 'كاميرات المراقبة والفواتير',
    summary: 'ربط المسجّل، ومشاهدة لقطة فاتورة بعينها.',
    track: LearningTrack.devices,
    level: LearningLevel.advanced,
    kind: LearningKind.concept,
    minutes: 3,
    capability: AppCapability.watchCamerasLive,
    keywords: ['camera', 'dvr', 'كاميرا', 'مراقبة', 'تسجيل'],
    related: ['reports.invoices', 'reports.activity_log'],
    opens: AppNavigationDestination.cameras,
    sections: [
      LearningSection(
        title: 'ما يقدّمه',
        blocks: [
          LearningBullets([
            'مشاهدة مباشرة لكاميرات المسجّل داخل التطبيق.',
            'مراجعة تسجيل وقت واقعة بعينها.',
            'فتح لقطة الفاتورة: تنتقل مباشرة إلى وقت إصدارها بدل البحث اليدوي في ساعات التسجيل.',
          ]),
          LearningParagraph(
            'يحتاج الربط عنوان المسجّل على الشبكة وبيانات حسابه، وتُضبط الكاميرات مرة واحدة.',
          ),
          LearningNote(
            tone: LearningNoteTone.info,
            title: 'صلاحيات مستقلّة',
            message:
                'المشاهدة المباشرة، ومراجعة التسجيل، وتصدير مقطع — ثلاث صلاحيات '
                'منفصلة تُمنح كلٌّ على حدة.',
          ),
        ],
      ),
    ],
  ),
];
