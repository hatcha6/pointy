// Hand-written A2UI payloads for the generative-UI preview, in exactly the
// shape the backend's render_ui tool emits. Dev-only.
import 'package:pointy_frontend/src/data/models/ai_chat.dart';
import 'package:pointy_frontend/src/features/ai/ui/pointy_ai_catalog.dart';

AiUiSurface _surface(
  String id,
  String title,
  List<Map<String, dynamic>> components, {
  Map<String, Object?> data = const <String, Object?>{},
}) => AiUiSurface(
  surfaceId: id,
  title: title,
  components: components,
  data: data,
);

/// A realistic analytics answer: the shape most assistant replies should take.
AiUiSurface analyticsAnswerSurface() => _surface(
  'answer-1',
  'إجابة تحليلية',
  <Map<String, dynamic>>[
    {
      'id': 'root',
      'component': 'Column',
      'children': ['metrics', 'trend_card', 'top_card', 'advice', 'actions'],
    },
    {
      'id': 'metrics',
      'component': 'MetricGrid',
      'metrics': [
        {
          'label': 'صافي المبيعات',
          'value': 18420.75,
          'kind': 'money',
          'delta': 12.4,
          'subtitle': 'آخر ٣٠ يوم',
        },
        {'label': 'عدد الفواتير', 'value': 486, 'kind': 'number', 'delta': 4.1},
        {
          'label': 'متوسط الفاتورة',
          'value': 37.9,
          'kind': 'money',
          'delta': -2.8,
        },
        {'label': 'هامش الربح', 'value': 23.6, 'kind': 'percent'},
      ],
    },
    {
      'id': 'trend_card',
      'component': 'Card',
      'title': 'اتجاه المبيعات',
      'subtitle': 'يومياً — آخر أسبوعين',
      'child': 'trend',
    },
    {
      'id': 'trend',
      'component': 'LineChart',
      'kind': 'money',
      'series': [
        {
          'name': 'صافي المبيعات',
          'points': [
            {'label': '18/8', 'value': 980},
            {'label': '19/8', 'value': 1240},
            {'label': '20/8', 'value': 1105},
            {'label': '21/8', 'value': 1670},
            {'label': '22/8', 'value': 1890},
            {'label': '23/8', 'value': 1420},
            {'label': '24/8', 'value': 1010},
            {'label': '25/8', 'value': 1320},
            {'label': '26/8', 'value': 1580},
            {'label': '27/8', 'value': 1745},
            {'label': '28/8', 'value': 2010},
            {'label': '29/8', 'value': 1930},
            {'label': '30/8', 'value': 1490},
            {'label': '31/8', 'value': 1035},
          ],
        },
      ],
    },
    {
      'id': 'top_card',
      'component': 'Card',
      'title': 'الأصناف الأكثر مبيعاً',
      'child': 'top_table',
    },
    {
      'id': 'top_table',
      'component': 'Table',
      'columns': [
        {'key': 'name', 'label': 'الصنف'},
        {'key': 'qty', 'label': 'الكمية', 'kind': 'number', 'total': true},
        {'key': 'revenue', 'label': 'المبيعات', 'kind': 'money', 'total': true},
        {'key': 'margin', 'label': 'الهامش', 'kind': 'percent'},
      ],
      'rows': [
        {
          'name': 'شاي أخضر ٢٠٠غ',
          'qty': 184,
          'revenue': 2760,
          'margin': 31.5,
          'link': 'pointy://product/12',
        },
        {
          'name': 'سكر ١ كجم',
          'qty': 152,
          'revenue': 1824,
          'margin': 12.2,
          'link': 'pointy://product/31',
        },
        {'name': 'أرز بسمتي ٥ كجم', 'qty': 61, 'revenue': 1830, 'margin': 18.4},
        {'name': 'زيت ذرة ١.٥ لتر', 'qty': 48, 'revenue': 1152, 'margin': 9.8},
      ],
    },
    {
      'id': 'advice',
      'component': 'Callout',
      'tone': 'warning',
      'title': 'السكر يبيع كثيراً بهامش منخفض',
      'body':
          'يمثل ١٤٪ من الكمية المباعة وهامشه ١٢٪ فقط. رفع السعر ٥٪ يضيف نحو '
          '٩٠ د.ل شهرياً دون التأثير على الطلب غالباً.',
    },
    {
      'id': 'actions',
      'component': 'Row',
      'justify': 'start',
      'children': ['act_open', 'act_ask'],
    },
    {
      'id': 'act_open',
      'component': 'Button',
      'label': 'افتح السكر',
      'variant': 'secondary',
      'icon': 'open',
      'action': {
        'event': {
          'name': 'navigate:product',
          'context': {'link': 'pointy://product/31'},
        },
      },
    },
    {
      'id': 'act_ask',
      'component': 'Button',
      'label': 'وضّح الهوامش',
      'variant': 'primary',
      'icon': 'chart',
      'action': {
        'event': {
          'name': 'ask:margins',
          'context': {'prompt': 'اشرح لي هوامش الربح لكل صنف بالتفصيل'},
        },
      },
    },
  ],
);

/// The invoice-intake review surface: the flagship interactive card.
AiUiSurface invoiceReviewSurface() =>
    _surface('intake-1', 'مراجعة فاتورة مورد', <Map<String, dynamic>>[
      {
        'id': 'root',
        'component': 'Column',
        'children': ['header', 'summary', 'lines_card', 'issues', 'confirm'],
      },
      {
        'id': 'header',
        'component': 'Callout',
        'tone': 'info',
        'title': 'قرأت الفاتورة: مؤسسة النور للمواد الغذائية',
        'body': 'فاتورة رقم ٤٤١٢ بتاريخ ٢٠٢٦/٠٨/٢٨ — ١٢ سطراً.',
      },
      {
        'id': 'summary',
        'component': 'MetricGrid',
        'metrics': [
          {'label': 'مطابقة تلقائياً', 'value': 9, 'kind': 'number'},
          {'label': 'أصناف جديدة', 'value': 2, 'kind': 'number'},
          {'label': 'تحتاج مراجعة', 'value': 1, 'kind': 'number'},
          {'label': 'إجمالي الفاتورة', 'value': 3184.5, 'kind': 'money'},
        ],
      },
      {
        'id': 'lines_card',
        'component': 'Card',
        'title': 'السطور',
        'child': 'lines',
      },
      {
        'id': 'lines',
        'component': 'Table',
        'columns': [
          {'key': 'name', 'label': 'الصنف'},
          {'key': 'state', 'label': 'الحالة'},
          {'key': 'qty', 'label': 'الكمية', 'kind': 'number', 'total': true},
          {'key': 'cost', 'label': 'التكلفة', 'kind': 'money'},
          {'key': 'total', 'label': 'الإجمالي', 'kind': 'money', 'total': true},
        ],
        'rows': [
          {
            'name': 'شاي أخضر ٢٠٠غ',
            'state': 'مطابق',
            'qty': 24,
            'cost': 11.5,
            'total': 276,
          },
          {
            'name': 'سكر ١ كجم',
            'state': 'مطابق',
            'qty': 60,
            'cost': 9.2,
            'total': 552,
          },
          {
            'name': 'معجون طماطم ٨٠٠غ',
            'state': 'جديد',
            'qty': 36,
            'cost': 6.75,
            'total': 243,
          },
          {
            'name': 'زيت دوار الشمس ٣ل',
            'state': 'مراجعة',
            'qty': 12,
            'cost': 41.0,
            'total': 492,
          },
        ],
      },
      {
        'id': 'issues',
        'component': 'Callout',
        'tone': 'warning',
        'title': 'سطر واحد يحتاج انتباهك',
        'body':
            'زيت دوار الشمس ٣ل: التكلفة أعلى بنسبة ٦٢٪ من آخر شراء (٢٥.٣ د.ل). '
            'راجع الرقم قبل الاعتماد.',
      },
      {
        'id': 'confirm',
        'component': 'Row',
        'justify': 'start',
        'children': ['btn_draft', 'btn_fix'],
      },
      {
        'id': 'btn_draft',
        'component': 'Button',
        'label': 'أنشئ أمر شراء مسودة',
        'variant': 'primary',
        'icon': 'check',
        'action': {
          'event': {
            'name': 'submit:create_po',
            'context': {'intake_id': 1},
          },
        },
      },
      {
        'id': 'btn_fix',
        'component': 'Button',
        'label': 'صحّح السطر',
        'variant': 'secondary',
        'action': {
          'event': {
            'name': 'ask:fix_line',
            'context': {'prompt': 'صحّح تكلفة زيت دوار الشمس ٣ل'},
          },
        },
      },
    ]);

/// An interactive surface exercising inputs, bindings and a submit round trip.
AiUiSurface interactiveFormSurface() => _surface(
  'form-1',
  'نموذج تفاعلي',
  <Map<String, dynamic>>[
    {
      'id': 'root',
      'component': 'Card',
      'title': 'كم أطلب من هذا الصنف؟',
      'subtitle': 'شاي أخضر ٢٠٠غ — يكفي ٦ أيام بالمعدل الحالي',
      'child': 'form',
    },
    {
      'id': 'form',
      'component': 'Form',
      'child': 'fields',
      'submitLabel': 'أضف إلى أمر الشراء',
      'action': {
        'event': {
          'name': 'submit:reorder',
          'context': {'variant': 12},
        },
      },
    },
    {
      'id': 'fields',
      'component': 'Column',
      'children': ['qty', 'period', 'urgent', 'note'],
    },
    {
      'id': 'qty',
      'component': 'NumberField',
      'label': 'الكمية',
      'decimals': 0,
      'min': 1,
      'value': {'path': '/order/quantity'},
    },
    {
      'id': 'period',
      'component': 'ChoiceChips',
      'label': 'تغطية',
      'value': {'path': '/order/period'},
      'options': [
        {'value': 'week', 'label': 'أسبوع'},
        {'value': 'two_weeks', 'label': 'أسبوعان'},
        {'value': 'month', 'label': 'شهر'},
      ],
    },
    {
      'id': 'urgent',
      'component': 'Checkbox',
      'label': 'عاجل — أرسل الطلب اليوم',
      'value': {'path': '/order/urgent'},
    },
    {
      'id': 'note',
      'component': 'TextField',
      'label': 'ملاحظة للمورد',
      'value': {'path': '/order/note'},
    },
  ],
  data: <String, Object?>{
    'order': <String, Object?>{
      'quantity': 24,
      'period': 'two_weeks',
      'urgent': false,
      'note': '',
    },
  },
);

/// Every catalog item rendered from its own registered example data.
///
/// This is the visual counterpart of the catalog parity test: if an item is
/// added without example data, or its example no longer renders, it shows here.
List<AiUiSurface> catalogBoardSurfaces() {
  final surfaces = <AiUiSurface>[];
  for (final item in PointyAiCatalog.items) {
    final example = _exampleFor(item.name);
    if (example == null) continue;
    surfaces.add(
      _surface('item-${item.name}', item.name, example.$1, data: example.$2),
    );
  }
  return surfaces;
}

/// Representative payloads per item. Kept here rather than parsed out of the
/// catalog's own `exampleData` strings so the board can show richer, more
/// realistic content than a schema example needs to.
(List<Map<String, dynamic>>, Map<String, Object?>)? _exampleFor(String name) {
  switch (name) {
    case 'Column':
      return (
        [
          {
            'id': 'root',
            'component': 'Column',
            'children': ['a', 'b'],
          },
          {'id': 'a', 'component': 'Text', 'text': 'السطر الأول'},
          {'id': 'b', 'component': 'Text', 'text': 'السطر الثاني'},
        ],
        const {},
      );
    case 'Row':
      return (
        [
          {
            'id': 'root',
            'component': 'Row',
            'justify': 'spaceBetween',
            'children': ['a', 'b'],
          },
          {'id': 'a', 'component': 'Text', 'text': 'الإجمالي'},
          {
            'id': 'b',
            'component': 'Text',
            'text': '١٢٠٫٠٠ د.ل',
            'variant': 'numeric',
            'emphasis': 'strong',
          },
        ],
        const {},
      );
    case 'Card':
      return (
        [
          {
            'id': 'root',
            'component': 'Card',
            'title': 'مبيعات الأسبوع',
            'subtitle': 'مقارنة بالأسبوع السابق',
            'child': 'body',
          },
          {
            'id': 'body',
            'component': 'Text',
            'text': 'ارتفعت المبيعات ١٢٪ مدفوعة بيومي الخميس والجمعة.',
          },
        ],
        const {},
      );
    case 'Section':
      return (
        [
          {
            'id': 'root',
            'component': 'Section',
            'title': 'التوصيات',
            'child': 'body',
          },
          {
            'id': 'body',
            'component': 'Text',
            'text': 'أعد طلب ثلاثة أصناف قبل نهاية الأسبوع.',
          },
        ],
        const {},
      );
    case 'Divider':
      return (
        [
          {'id': 'root', 'component': 'Divider'},
        ],
        const {},
      );
    case 'Text':
      return (
        [
          {
            'id': 'root',
            'component': 'Text',
            'text': 'إجمالي مبيعات اليوم',
            'variant': 'title',
            'emphasis': 'strong',
          },
        ],
        const {},
      );
    case 'Markdown':
      return (
        [
          {
            'id': 'root',
            'component': 'Markdown',
            'text':
                '**السبب المرجّح:** ارتفاع الطلب في نهاية الأسبوع.\n\n'
                '- الخميس أعلى يوم\n- الاثنين أضعف يوم',
          },
        ],
        const {},
      );
    case 'Callout':
      return (
        [
          {
            'id': 'root',
            'component': 'Callout',
            'tone': 'warning',
            'title': 'ثلاثة أصناف قاربت على النفاد',
            'body': 'تكفي أقل من أسبوع بالمعدل الحالي.',
          },
        ],
        const {},
      );
    case 'StatusPill':
      return (
        [
          {
            'id': 'root',
            'component': 'StatusPill',
            'label': 'مدفوعة',
            'tone': 'success',
          },
        ],
        const {},
      );
    case 'MetricGrid':
      return (
        [
          {
            'id': 'root',
            'component': 'MetricGrid',
            'metrics': [
              {
                'label': 'صافي المبيعات',
                'value': 12480.5,
                'kind': 'money',
                'delta': 12.4,
                'subtitle': 'آخر ٣٠ يوم',
              },
              {'label': 'عدد الفواتير', 'value': 318, 'kind': 'number'},
              {
                'label': 'متوسط الفاتورة',
                'value': 39.2,
                'kind': 'money',
                'delta': -3.1,
              },
            ],
          },
        ],
        const {},
      );
    case 'SummaryList':
      return (
        [
          {
            'id': 'root',
            'component': 'SummaryList',
            'rows': [
              {'label': 'المجموع', 'value': 480, 'kind': 'money'},
              {'label': 'الخصم', 'value': 30, 'kind': 'money'},
              {
                'label': 'الإجمالي',
                'value': 450,
                'kind': 'money',
                'total': true,
              },
            ],
          },
        ],
        const {},
      );
    case 'Table':
      return (
        [
          {
            'id': 'root',
            'component': 'Table',
            'columns': [
              {'key': 'name', 'label': 'الصنف'},
              {
                'key': 'qty',
                'label': 'الكمية',
                'kind': 'number',
                'total': true,
              },
              {
                'key': 'total',
                'label': 'الإجمالي',
                'kind': 'money',
                'total': true,
              },
            ],
            'rows': [
              {
                'name': 'شاي أخضر',
                'qty': 12,
                'total': 240,
                'link': 'pointy://product/1',
              },
              {'name': 'سكر ١ كجم', 'qty': 8, 'total': 96},
            ],
          },
        ],
        const {},
      );
    case 'LineChart':
      return (
        [
          {
            'id': 'root',
            'component': 'LineChart',
            'kind': 'money',
            'series': [
              {
                'name': 'المبيعات',
                'points': [
                  {'label': 'السبت', 'value': 1200},
                  {'label': 'الأحد', 'value': 1580},
                  {'label': 'الاثنين', 'value': 990},
                  {'label': 'الثلاثاء', 'value': 1340},
                  {'label': 'الأربعاء', 'value': 1720},
                ],
              },
              {
                'name': 'الأسبوع السابق',
                'points': [
                  {'label': 'السبت', 'value': 1050},
                  {'label': 'الأحد', 'value': 1310},
                  {'label': 'الاثنين', 'value': 1180},
                  {'label': 'الثلاثاء', 'value': 1120},
                  {'label': 'الأربعاء', 'value': 1400},
                ],
              },
            ],
          },
        ],
        const {},
      );
    case 'BarChart':
      return (
        [
          {
            'id': 'root',
            'component': 'BarChart',
            'kind': 'number',
            'series': [
              {
                'name': 'الكمية',
                'points': [
                  {'label': 'شاي', 'value': 42},
                  {'label': 'سكر', 'value': 31},
                  {'label': 'أرز', 'value': 18},
                  {'label': 'زيت', 'value': 25},
                ],
              },
            ],
          },
        ],
        const {},
      );
    case 'DonutChart':
      return (
        [
          {
            'id': 'root',
            'component': 'DonutChart',
            'kind': 'money',
            'slices': [
              {'label': 'نقدي', 'value': 820},
              {'label': 'بطاقة', 'value': 410},
              {'label': 'آجل', 'value': 260},
            ],
          },
        ],
        const {},
      );
    case 'Sparkline':
      return (
        [
          {
            'id': 'root',
            'component': 'Sparkline',
            'points': [
              {'value': 4},
              {'value': 9},
              {'value': 6},
              {'value': 12},
              {'value': 10},
              {'value': 15},
            ],
          },
        ],
        const {},
      );
    case 'Button':
      return (
        [
          {
            'id': 'root',
            'component': 'Row',
            'justify': 'start',
            'children': ['p', 's'],
          },
          {
            'id': 'p',
            'component': 'Button',
            'label': 'اعتمد',
            'variant': 'primary',
            'icon': 'check',
            'action': {
              'event': {'name': 'submit:approve'},
            },
          },
          {
            'id': 's',
            'component': 'Button',
            'label': 'افتح المنتج',
            'variant': 'secondary',
            'icon': 'open',
            'action': {
              'event': {
                'name': 'navigate:product',
                'context': {'link': 'pointy://product/12'},
              },
            },
          },
        ],
        const {},
      );
    case 'EntityChip':
      return (
        [
          {
            'id': 'root',
            'component': 'Row',
            'justify': 'start',
            'children': ['a', 'b'],
          },
          {
            'id': 'a',
            'component': 'EntityChip',
            'entity': 'product',
            'entityId': '12',
            'label': 'شاي أخضر ٢٠٠غ',
          },
          {
            'id': 'b',
            'component': 'EntityChip',
            'entity': 'supplier',
            'entityId': '4',
            'label': 'مؤسسة النور',
          },
        ],
        const {},
      );
    case 'TextField':
      return (
        [
          {
            'id': 'root',
            'component': 'TextField',
            'label': 'اسم المورد',
            'value': {'path': '/supplier/name'},
          },
        ],
        const {
          'supplier': {'name': 'مؤسسة النور'},
        },
      );
    case 'NumberField':
      return (
        [
          {
            'id': 'root',
            'component': 'NumberField',
            'label': 'الكمية',
            'decimals': 0,
            'value': {'path': '/line/quantity'},
          },
        ],
        const {
          'line': {'quantity': 24},
        },
      );
    case 'Checkbox':
      return (
        [
          {
            'id': 'root',
            'component': 'Checkbox',
            'label': 'استلمت البضاعة',
            'value': {'path': '/received'},
          },
        ],
        const {'received': true},
      );
    case 'ChoiceChips':
      return (
        [
          {
            'id': 'root',
            'component': 'ChoiceChips',
            'label': 'الفترة',
            'value': {'path': '/period'},
            'options': [
              {'value': 'week', 'label': 'أسبوع'},
              {'value': 'month', 'label': 'شهر'},
              {'value': 'quarter', 'label': 'ربع سنة'},
            ],
          },
        ],
        const {'period': 'month'},
      );
    case 'Form':
      return (
        [
          {
            'id': 'root',
            'component': 'Form',
            'child': 'f',
            'submitLabel': 'احسب',
            'action': {
              'event': {'name': 'submit:calc'},
            },
          },
          {
            'id': 'f',
            'component': 'NumberField',
            'label': 'الكمية',
            'value': {'path': '/qty'},
          },
        ],
        const {'qty': 10},
      );
  }
  return null;
}
