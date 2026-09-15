/// Customers: creating one from inside the sale that needs it.
library;

import '../../../core/authorization.dart';
import '../../../shared/tutor/anchors.dart';
import '../engine/lesson.dart';

/// A walk-in who wants to buy on credit has to become a name first. Doing it
/// without leaving the sale is the point — a cashier who has to abandon a cart
/// to add a customer will simply not add the customer.
const contactsAddCustomerLesson = TutorLesson(
  id: 'contacts.add_customer',
  title: 'إضافة زبون أثناء البيع',
  summary: 'أضِف زبونًا جديدًا من داخل الفاتورة دون أن تترك السلة.',
  seed: SandboxSeed.groceryMorning,
  capability: AppCapability.collectCustomerDebt,
  guideId: 'contacts.customers',
  requires: ['pos.cash_sale'],
  steps: [
    TutorStep(
      say: 'افتح الوردية بنقدية افتتاح 50.',
      anchor: TutorAnchor.registerOpeningCashField,
      act: TutorAct.type('50'),
      expect: TutorExpect.fieldEquals(
        TutorAnchor.registerOpeningCashField,
        '50',
      ),
      hint: 'اكتب 50 في خانة «نقدية الافتتاح».',
    ),
    TutorStep(
      say: 'اضغط «بدء الجلسة».',
      anchor: TutorAnchor.registerStartSessionButton,
      act: TutorAct.tap(),
      expect: TutorExpect.sessionOpen(),
      hint: 'لا يمكن البيع قبل فتح وردية.',
    ),
    TutorStep(
      say: 'افتح إعدادات الفاتورة.',
      anchor: TutorAnchor.posSaleSettingsButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.contactSelectionTile),
      hint: 'زر الإعدادات أعلى السلة.',
    ),
    TutorStep(
      say: 'اضغط على خانة الزبون.',
      anchor: TutorAnchor.contactSelectionTile,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.contactPickerCreateButton),
      hint: 'الخانة مكتوب فيها «زبون عابر».',
    ),
    TutorStep(
      say: 'اضغط «إضافة زبون» — الزبون جديد وليس في القائمة.',
      anchor: TutorAnchor.contactPickerCreateButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.contactFormNameField),
      hint: 'الزر أعلى قائمة الزبائن.',
    ),
    TutorStep(
      say: 'اكتب الاسم: «سالم الفيتوري».',
      anchor: TutorAnchor.contactFormNameField,
      act: TutorAct.type('سالم الفيتوري'),
      expect: TutorExpect.fieldEquals(
        TutorAnchor.contactFormNameField,
        'سالم الفيتوري',
      ),
      hint: 'الاسم كما يُنادى به في المحل.',
    ),
    TutorStep(
      say: 'اكتب رقم هاتفه: 0911234567.',
      anchor: TutorAnchor.contactFormPhoneField,
      act: TutorAct.type('0911234567'),
      expect: TutorExpect.fieldEquals(
        TutorAnchor.contactFormPhoneField,
        '0911234567',
      ),
      // Without a number there is no way to chase the debt later, which is the
      // whole reason a credit customer is a named customer.
      hint: 'بدون رقم لا سبيل لتذكيره بالدين لاحقًا.',
    ),
    TutorStep(
      say: 'اضغط «حفظ الزبون».',
      anchor: TutorAnchor.contactFormSaveButton,
      act: TutorAct.tap(),
      expect: TutorExpect.customerCount(4),
      hint: 'يُضاف الزبون ويُختار للفاتورة مباشرة.',
    ),
    TutorStep(
      say: 'احفظ إعدادات الفاتورة لتُربط باسمه.',
      anchor: TutorAnchor.posSaleSettingsSaveButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(
        TutorAnchor.posCartCustomer,
        id: 'سالم الفيتوري',
      ),
      hint: 'زر «حفظ» أسفل النافذة.',
    ),
  ],
  outcome: TutorExpect.all([
    TutorExpect.customerCount(4),
    // Added, and owing nothing: a customer file is not a debt.
    TutorExpect.customerBalanceOf('سالم الفيتوري', 0),
    TutorExpect.orderCount(0),
  ]),
);

const contactsLessons = <TutorLesson>[contactsAddCustomerLesson];
