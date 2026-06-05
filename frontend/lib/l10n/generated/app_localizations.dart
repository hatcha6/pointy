import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('ar')];

  /// Application title.
  ///
  /// In ar, this message translates to:
  /// **'نقطة البيع'**
  String get appTitle;

  /// No description provided for @refreshCatalogTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث المنتجات'**
  String get refreshCatalogTooltip;

  /// No description provided for @searchProductsHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث باسم المنتج أو الرمز'**
  String get searchProductsHint;

  /// No description provided for @categorySearchHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث باسم التصنيف'**
  String get categorySearchHint;

  /// No description provided for @categoriesLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل التصنيفات.'**
  String get categoriesLoadError;

  /// No description provided for @savingButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الحفظ...'**
  String get savingButton;

  /// No description provided for @retryButton.
  ///
  /// In ar, this message translates to:
  /// **'إعادة المحاولة'**
  String get retryButton;

  /// Reusable line count label for records that contain sale, purchase, or adjustment line items.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد عناصر} =1{عنصر واحد} =2{عنصران} other{{count} عناصر}}'**
  String lineItemCount(num count);

  /// No description provided for @clearSearchTooltip.
  ///
  /// In ar, this message translates to:
  /// **'مسح البحث'**
  String get clearSearchTooltip;

  /// No description provided for @openCameraScannerTooltip.
  ///
  /// In ar, this message translates to:
  /// **'فتح ماسح الكاميرا'**
  String get openCameraScannerTooltip;

  /// No description provided for @openFiltersTooltip.
  ///
  /// In ar, this message translates to:
  /// **'الفلاتر والترتيب'**
  String get openFiltersTooltip;

  /// No description provided for @filtersButtonLabel.
  ///
  /// In ar, this message translates to:
  /// **'الفلاتر'**
  String get filtersButtonLabel;

  /// No description provided for @filtersSheetTitle.
  ///
  /// In ar, this message translates to:
  /// **'الفلاتر والترتيب'**
  String get filtersSheetTitle;

  /// No description provided for @availabilityFilterTitle.
  ///
  /// In ar, this message translates to:
  /// **'حالة المنتج'**
  String get availabilityFilterTitle;

  /// No description provided for @availabilityAll.
  ///
  /// In ar, this message translates to:
  /// **'كل المنتجات'**
  String get availabilityAll;

  /// No description provided for @availabilityActive.
  ///
  /// In ar, this message translates to:
  /// **'المتاحة فقط'**
  String get availabilityActive;

  /// No description provided for @availabilityInactive.
  ///
  /// In ar, this message translates to:
  /// **'المتوقفة فقط'**
  String get availabilityInactive;

  /// No description provided for @orderingTitle.
  ///
  /// In ar, this message translates to:
  /// **'ترتيب النتائج'**
  String get orderingTitle;

  /// No description provided for @orderingName.
  ///
  /// In ar, this message translates to:
  /// **'الاسم'**
  String get orderingName;

  /// No description provided for @orderingPriceAsc.
  ///
  /// In ar, this message translates to:
  /// **'السعر: من الأقل إلى الأعلى'**
  String get orderingPriceAsc;

  /// No description provided for @orderingPriceDesc.
  ///
  /// In ar, this message translates to:
  /// **'السعر: من الأعلى إلى الأقل'**
  String get orderingPriceDesc;

  /// No description provided for @orderingNewest.
  ///
  /// In ar, this message translates to:
  /// **'الأحدث أولًا'**
  String get orderingNewest;

  /// No description provided for @resetFiltersButton.
  ///
  /// In ar, this message translates to:
  /// **'إعادة ضبط'**
  String get resetFiltersButton;

  /// No description provided for @applyFiltersButton.
  ///
  /// In ar, this message translates to:
  /// **'تطبيق'**
  String get applyFiltersButton;

  /// No description provided for @navigationMenuTooltip.
  ///
  /// In ar, this message translates to:
  /// **'فتح القائمة'**
  String get navigationMenuTooltip;

  /// No description provided for @navigationRailExpandTooltip.
  ///
  /// In ar, this message translates to:
  /// **'توسيع التنقل'**
  String get navigationRailExpandTooltip;

  /// No description provided for @navigationRailCollapseTooltip.
  ///
  /// In ar, this message translates to:
  /// **'طي التنقل'**
  String get navigationRailCollapseTooltip;

  /// No description provided for @navigationMenuTitle.
  ///
  /// In ar, this message translates to:
  /// **'القائمة'**
  String get navigationMenuTitle;

  /// No description provided for @navigationMenuSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'تنقل سريع بين شاشات نقطة البيع'**
  String get navigationMenuSubtitle;

  /// No description provided for @posDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'شاشة البيع'**
  String get posDrawerLabel;

  /// No description provided for @purchasingDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'المشتريات'**
  String get purchasingDrawerLabel;

  /// No description provided for @contactsDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'الجهات'**
  String get contactsDrawerLabel;

  /// No description provided for @catalogDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'المنتجات'**
  String get catalogDrawerLabel;

  /// No description provided for @categoriesDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'التصنيفات'**
  String get categoriesDrawerLabel;

  /// No description provided for @registerSessionsDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'جلسات الدرج'**
  String get registerSessionsDrawerLabel;

  /// No description provided for @invoicesDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'الفواتير'**
  String get invoicesDrawerLabel;

  /// No description provided for @deviceSettingsDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات الجهاز'**
  String get deviceSettingsDrawerLabel;

  /// No description provided for @usersDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'المستخدمون'**
  String get usersDrawerLabel;

  /// No description provided for @settingsDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات المتجر'**
  String get settingsDrawerLabel;

  /// No description provided for @dashboardDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'لوحة التحكم'**
  String get dashboardDrawerLabel;

  /// No description provided for @reportsDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'التقارير'**
  String get reportsDrawerLabel;

  /// No description provided for @activityLogDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'سجل النشاط'**
  String get activityLogDrawerLabel;

  /// No description provided for @activityLogTitle.
  ///
  /// In ar, this message translates to:
  /// **'سجل نشاط المستخدمين'**
  String get activityLogTitle;

  /// No description provided for @refreshActivityLogTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث سجل النشاط'**
  String get refreshActivityLogTooltip;

  /// No description provided for @activityLogSearchHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث باسم الحدث أو الأثر أو الكيان'**
  String get activityLogSearchHint;

  /// No description provided for @activityLogTotalMetric.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي النتائج'**
  String get activityLogTotalMetric;

  /// No description provided for @activityLogLoadedMetric.
  ///
  /// In ar, this message translates to:
  /// **'المعروض الآن'**
  String get activityLogLoadedMetric;

  /// No description provided for @activityLogFraudMetric.
  ///
  /// In ar, this message translates to:
  /// **'مؤشرات اشتباه'**
  String get activityLogFraudMetric;

  /// No description provided for @activityLogHighRiskMetric.
  ///
  /// In ar, this message translates to:
  /// **'مخاطر عالية'**
  String get activityLogHighRiskMetric;

  /// No description provided for @activityLogUsersLoadWarning.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل قائمة المستخدمين للفلاتر. يمكنك متابعة البحث والفلاتر الأخرى.'**
  String get activityLogUsersLoadWarning;

  /// No description provided for @activityLogLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل سجل النشاط.'**
  String get activityLogLoadError;

  /// No description provided for @activityLogEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد أحداث تطابق الفلاتر الحالية.'**
  String get activityLogEmpty;

  /// Activity log banner shown when opened from a suspected activity notification.
  ///
  /// In ar, this message translates to:
  /// **'تم فتح سجل النشاط بفلاتر مراجعة لأن النظام لاحظ نمطًا مشتبهًا: {reason}. راجع الأحداث والطلبات ضمن الفترة المحددة قبل اتخاذ أي إجراء.'**
  String activityLogSuspicionReviewBanner(String reason);

  /// No description provided for @activityLogNoEventSelected.
  ///
  /// In ar, this message translates to:
  /// **'اختر حدثًا لمراجعة التفاصيل.'**
  String get activityLogNoEventSelected;

  /// No description provided for @activityLogUnknownUser.
  ///
  /// In ar, this message translates to:
  /// **'مستخدم غير معروف'**
  String get activityLogUnknownUser;

  /// Activity timeline event subtitle.
  ///
  /// In ar, this message translates to:
  /// **'{date} بواسطة {user}'**
  String activityLogEventSubtitle(String date, String user);

  /// Activity timeline event subtitle with a readable summary.
  ///
  /// In ar, this message translates to:
  /// **'{date} بواسطة {user} - {summary}'**
  String activityLogEventSubtitleWithSummary(
    String date,
    String user,
    String summary,
  );

  /// Risk score label.
  ///
  /// In ar, this message translates to:
  /// **'مخاطر {score}'**
  String activityLogRiskScore(int score);

  /// No description provided for @activityLogDetailUser.
  ///
  /// In ar, this message translates to:
  /// **'المستخدم'**
  String get activityLogDetailUser;

  /// No description provided for @activityLogDetailRisk.
  ///
  /// In ar, this message translates to:
  /// **'درجة المخاطر'**
  String get activityLogDetailRisk;

  /// No description provided for @activityLogNoRiskScore.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد'**
  String get activityLogNoRiskScore;

  /// No description provided for @activityLogDetailEventSection.
  ///
  /// In ar, this message translates to:
  /// **'الحدث'**
  String get activityLogDetailEventSection;

  /// No description provided for @activityLogRawNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'الاسم الخام'**
  String get activityLogRawNameLabel;

  /// No description provided for @activityLogTypeLabel.
  ///
  /// In ar, this message translates to:
  /// **'النوع'**
  String get activityLogTypeLabel;

  /// No description provided for @activityLogSeverityLabel.
  ///
  /// In ar, this message translates to:
  /// **'الحدة'**
  String get activityLogSeverityLabel;

  /// No description provided for @activityLogSourceLabel.
  ///
  /// In ar, this message translates to:
  /// **'المصدر'**
  String get activityLogSourceLabel;

  /// No description provided for @activityLogDetailContextSection.
  ///
  /// In ar, this message translates to:
  /// **'السياق'**
  String get activityLogDetailContextSection;

  /// No description provided for @activityLogSessionLabel.
  ///
  /// In ar, this message translates to:
  /// **'الجلسة'**
  String get activityLogSessionLabel;

  /// No description provided for @activityLogEntityTypeLabel.
  ///
  /// In ar, this message translates to:
  /// **'نوع الكيان'**
  String get activityLogEntityTypeLabel;

  /// No description provided for @activityLogEntityIdLabel.
  ///
  /// In ar, this message translates to:
  /// **'معرّف الكيان'**
  String get activityLogEntityIdLabel;

  /// No description provided for @activityLogTraceIdLabel.
  ///
  /// In ar, this message translates to:
  /// **'أثر الطلب'**
  String get activityLogTraceIdLabel;

  /// No description provided for @activityLogPlatformLabel.
  ///
  /// In ar, this message translates to:
  /// **'المنصة'**
  String get activityLogPlatformLabel;

  /// No description provided for @activityLogAttributesSection.
  ///
  /// In ar, this message translates to:
  /// **'البيانات'**
  String get activityLogAttributesSection;

  /// No description provided for @activityLogNoAttributes.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد بيانات إضافية.'**
  String get activityLogNoAttributes;

  /// No description provided for @activityLogMetricsSection.
  ///
  /// In ar, this message translates to:
  /// **'المقاييس'**
  String get activityLogMetricsSection;

  /// No description provided for @activityLogNoMetrics.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مقاييس.'**
  String get activityLogNoMetrics;

  /// No description provided for @activityLogMissingValue.
  ///
  /// In ar, this message translates to:
  /// **'غير متوفر'**
  String get activityLogMissingValue;

  /// No description provided for @activityLogOpenInvoice.
  ///
  /// In ar, this message translates to:
  /// **'فتح الفاتورة'**
  String get activityLogOpenInvoice;

  /// No description provided for @activityLogOpenPurchaseOrder.
  ///
  /// In ar, this message translates to:
  /// **'فتح أمر الشراء'**
  String get activityLogOpenPurchaseOrder;

  /// No description provided for @activityLogOpenTargetError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر فتح تفاصيل هذا السجل.'**
  String get activityLogOpenTargetError;

  /// No description provided for @activityLogNoSummary.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد خلاصة إضافية.'**
  String get activityLogNoSummary;

  /// Activity log session summary.
  ///
  /// In ar, this message translates to:
  /// **'جلسة {session}'**
  String activityLogSessionSummary(String session);

  /// Activity log total metric summary.
  ///
  /// In ar, this message translates to:
  /// **'الإجمالي {total}'**
  String activityLogTotalSummary(String total);

  /// Activity log sale cart total summary.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي السلة {total}'**
  String activityLogCartTotalSummary(String total);

  /// Activity log purchase draft total summary.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي مسودة الشراء {total}'**
  String activityLogDraftTotalSummary(String total);

  /// Activity log product and quantity summary.
  ///
  /// In ar, this message translates to:
  /// **'{product} - الكمية {quantity}'**
  String activityLogProductSummary(String product, String quantity);

  /// Activity log supplier summary.
  ///
  /// In ar, this message translates to:
  /// **'المورد {supplier}'**
  String activityLogSupplierSummary(String supplier);

  /// Activity log target user summary.
  ///
  /// In ar, this message translates to:
  /// **'المستخدم {user}'**
  String activityLogUserSummary(String user);

  /// Activity log discount rule summary.
  ///
  /// In ar, this message translates to:
  /// **'قاعدة الخصم {rule}'**
  String activityLogDiscountRuleSummary(String rule);

  /// Activity log report type summary.
  ///
  /// In ar, this message translates to:
  /// **'التقرير {report}'**
  String activityLogReportSummary(String report);

  /// Activity log movement type summary.
  ///
  /// In ar, this message translates to:
  /// **'نوع الحركة {movementType}'**
  String activityLogMovementTypeSummary(String movementType);

  /// Activity log UI source summary.
  ///
  /// In ar, this message translates to:
  /// **'من {source}'**
  String activityLogUiSourceSummary(String source);

  /// Activity log reason summary.
  ///
  /// In ar, this message translates to:
  /// **'السبب: {reason}'**
  String activityLogReasonSummary(String reason);

  /// Summary for suspected activity detection rule.
  ///
  /// In ar, this message translates to:
  /// **'قاعدة المراجعة: {rule}'**
  String activityLogSuspicionRuleSummary(String rule);

  /// Readable backend request activity title.
  ///
  /// In ar, this message translates to:
  /// **'{method} {target}'**
  String activityBackendRequestTitle(String method, String target);

  /// Readable frontend interaction activity title.
  ///
  /// In ar, this message translates to:
  /// **'{action} {target}'**
  String activityFrontendInteractionTitle(String action, String target);

  /// Fallback title for unknown activity event names.
  ///
  /// In ar, this message translates to:
  /// **'حدث غير مصنف: {name}'**
  String activityEventUnknownTitle(String name);

  /// HTTP method and path summary.
  ///
  /// In ar, this message translates to:
  /// **'{method} {path}'**
  String activityLogMethodPathSummary(String method, String path);

  /// HTTP request summary with status.
  ///
  /// In ar, this message translates to:
  /// **'{method} {path} - الحالة {status}'**
  String activityLogRequestSummary(String method, String path, int status);

  /// Raw frontend interaction summary.
  ///
  /// In ar, this message translates to:
  /// **'الإجراء {action} على {target}'**
  String activityLogInteractionSummary(String action, String target);

  /// No description provided for @activityRequestMethodGet.
  ///
  /// In ar, this message translates to:
  /// **'استعرض'**
  String get activityRequestMethodGet;

  /// No description provided for @activityRequestMethodPost.
  ///
  /// In ar, this message translates to:
  /// **'نفّذ'**
  String get activityRequestMethodPost;

  /// No description provided for @activityRequestMethodPatch.
  ///
  /// In ar, this message translates to:
  /// **'عدّل'**
  String get activityRequestMethodPatch;

  /// No description provided for @activityRequestMethodDelete.
  ///
  /// In ar, this message translates to:
  /// **'حذف'**
  String get activityRequestMethodDelete;

  /// No description provided for @activityRequestMethodOther.
  ///
  /// In ar, this message translates to:
  /// **'طلب'**
  String get activityRequestMethodOther;

  /// No description provided for @activityTargetActivityLog.
  ///
  /// In ar, this message translates to:
  /// **'سجل النشاط'**
  String get activityTargetActivityLog;

  /// No description provided for @activityTargetUsers.
  ///
  /// In ar, this message translates to:
  /// **'المستخدمين'**
  String get activityTargetUsers;

  /// No description provided for @activityTargetInvoices.
  ///
  /// In ar, this message translates to:
  /// **'الفواتير'**
  String get activityTargetInvoices;

  /// No description provided for @activityTargetCheckout.
  ///
  /// In ar, this message translates to:
  /// **'إكمال بيع'**
  String get activityTargetCheckout;

  /// No description provided for @activityTargetPurchaseOrders.
  ///
  /// In ar, this message translates to:
  /// **'أوامر الشراء'**
  String get activityTargetPurchaseOrders;

  /// No description provided for @activityTargetCustomers.
  ///
  /// In ar, this message translates to:
  /// **'العملاء'**
  String get activityTargetCustomers;

  /// No description provided for @activityTargetSuppliers.
  ///
  /// In ar, this message translates to:
  /// **'الموردين'**
  String get activityTargetSuppliers;

  /// No description provided for @activityTargetCatalog.
  ///
  /// In ar, this message translates to:
  /// **'المنتجات والمخزون'**
  String get activityTargetCatalog;

  /// No description provided for @activityTargetRegisterSessions.
  ///
  /// In ar, this message translates to:
  /// **'جلسات الدرج'**
  String get activityTargetRegisterSessions;

  /// No description provided for @activityTargetDiscounts.
  ///
  /// In ar, this message translates to:
  /// **'الخصومات'**
  String get activityTargetDiscounts;

  /// No description provided for @activityTargetReports.
  ///
  /// In ar, this message translates to:
  /// **'التقارير'**
  String get activityTargetReports;

  /// No description provided for @activityTargetAuth.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الدخول'**
  String get activityTargetAuth;

  /// No description provided for @activityTargetSystem.
  ///
  /// In ar, this message translates to:
  /// **'النظام'**
  String get activityTargetSystem;

  /// No description provided for @activityTargetCurrentScreen.
  ///
  /// In ar, this message translates to:
  /// **'الشاشة الحالية'**
  String get activityTargetCurrentScreen;

  /// No description provided for @activityInteractionNavigation.
  ///
  /// In ar, this message translates to:
  /// **'فتح شاشة'**
  String get activityInteractionNavigation;

  /// No description provided for @activityInteractionLogout.
  ///
  /// In ar, this message translates to:
  /// **'اختار الخروج من'**
  String get activityInteractionLogout;

  /// No description provided for @activityInteractionProductSelected.
  ///
  /// In ar, this message translates to:
  /// **'فتح منتج من'**
  String get activityInteractionProductSelected;

  /// No description provided for @activityInteractionPointer.
  ///
  /// In ar, this message translates to:
  /// **'لمس'**
  String get activityInteractionPointer;

  /// No description provided for @activityInteractionScroll.
  ///
  /// In ar, this message translates to:
  /// **'مرر'**
  String get activityInteractionScroll;

  /// No description provided for @activityInteractionKeyboard.
  ///
  /// In ar, this message translates to:
  /// **'استخدم لوحة المفاتيح في'**
  String get activityInteractionKeyboard;

  /// No description provided for @activityInteractionFocus.
  ///
  /// In ar, this message translates to:
  /// **'نقل التركيز داخل'**
  String get activityInteractionFocus;

  /// No description provided for @activityInteractionGeneral.
  ///
  /// In ar, this message translates to:
  /// **'تفاعل مع'**
  String get activityInteractionGeneral;

  /// No description provided for @activityUiSourceProductTile.
  ///
  /// In ar, this message translates to:
  /// **'بطاقة المنتج'**
  String get activityUiSourceProductTile;

  /// No description provided for @activityUiSourceVariantPicker.
  ///
  /// In ar, this message translates to:
  /// **'نافذة اختيار المتغير'**
  String get activityUiSourceVariantPicker;

  /// No description provided for @activityUiSourceBarcodeLookup.
  ///
  /// In ar, this message translates to:
  /// **'حقل الباركود'**
  String get activityUiSourceBarcodeLookup;

  /// No description provided for @activityUiSourceHardwareScanner.
  ///
  /// In ar, this message translates to:
  /// **'ماسح الباركود الخارجي'**
  String get activityUiSourceHardwareScanner;

  /// No description provided for @activityUiSourceCameraScanner.
  ///
  /// In ar, this message translates to:
  /// **'ماسح الكاميرا'**
  String get activityUiSourceCameraScanner;

  /// No description provided for @activityUiSourceCartQuantityButton.
  ///
  /// In ar, this message translates to:
  /// **'أزرار كمية السلة'**
  String get activityUiSourceCartQuantityButton;

  /// No description provided for @activityUiSourceCartDeleteButton.
  ///
  /// In ar, this message translates to:
  /// **'زر حذف سطر السلة'**
  String get activityUiSourceCartDeleteButton;

  /// No description provided for @activityUiSourceCartClearButton.
  ///
  /// In ar, this message translates to:
  /// **'زر تفريغ السلة'**
  String get activityUiSourceCartClearButton;

  /// No description provided for @activityUiSourcePurchaseCatalog.
  ///
  /// In ar, this message translates to:
  /// **'كتالوج الشراء'**
  String get activityUiSourcePurchaseCatalog;

  /// No description provided for @activityUiSourcePurchaseBarcodeLookup.
  ///
  /// In ar, this message translates to:
  /// **'حقل باركود الشراء'**
  String get activityUiSourcePurchaseBarcodeLookup;

  /// No description provided for @activityUiSourcePurchaseCameraScanner.
  ///
  /// In ar, this message translates to:
  /// **'ماسح كاميرا الشراء'**
  String get activityUiSourcePurchaseCameraScanner;

  /// No description provided for @activityUiSourcePurchaseDraftQuantityButton.
  ///
  /// In ar, this message translates to:
  /// **'أزرار كمية مسودة الشراء'**
  String get activityUiSourcePurchaseDraftQuantityButton;

  /// No description provided for @activityUiSourcePurchaseDraftClearButton.
  ///
  /// In ar, this message translates to:
  /// **'زر تفريغ مسودة الشراء'**
  String get activityUiSourcePurchaseDraftClearButton;

  /// No description provided for @activityUiSourceRegisterSessionGate.
  ///
  /// In ar, this message translates to:
  /// **'واجهة فتح الدرج'**
  String get activityUiSourceRegisterSessionGate;

  /// No description provided for @activityUiSourceRegisterSessionCloseSheet.
  ///
  /// In ar, this message translates to:
  /// **'نافذة إغلاق الدرج'**
  String get activityUiSourceRegisterSessionCloseSheet;

  /// No description provided for @activityUiSourceRegisterCashMovementSheet.
  ///
  /// In ar, this message translates to:
  /// **'نافذة الحركة النقدية'**
  String get activityUiSourceRegisterCashMovementSheet;

  /// No description provided for @activityUiSourceRegisterSessionHistory.
  ///
  /// In ar, this message translates to:
  /// **'سجل جلسات الدرج'**
  String get activityUiSourceRegisterSessionHistory;

  /// No description provided for @activityUiSourceSaleOrderDetailsSheet.
  ///
  /// In ar, this message translates to:
  /// **'نافذة تفاصيل الفاتورة'**
  String get activityUiSourceSaleOrderDetailsSheet;

  /// No description provided for @activityUiSourceCatalogProductForm.
  ///
  /// In ar, this message translates to:
  /// **'نموذج المنتج'**
  String get activityUiSourceCatalogProductForm;

  /// No description provided for @activityUiSourceCatalogProductDetails.
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل المنتج'**
  String get activityUiSourceCatalogProductDetails;

  /// No description provided for @activityUiSourceCatalogVariantForm.
  ///
  /// In ar, this message translates to:
  /// **'نموذج متغير المنتج'**
  String get activityUiSourceCatalogVariantForm;

  /// No description provided for @activityUiSourceCatalogVariantGenerator.
  ///
  /// In ar, this message translates to:
  /// **'مولّد المتغيرات'**
  String get activityUiSourceCatalogVariantGenerator;

  /// No description provided for @activityUiSourceCategoryManagement.
  ///
  /// In ar, this message translates to:
  /// **'إدارة التصنيفات'**
  String get activityUiSourceCategoryManagement;

  /// No description provided for @activityUiSourceStockMovementForm.
  ///
  /// In ar, this message translates to:
  /// **'نموذج حركة المخزون'**
  String get activityUiSourceStockMovementForm;

  /// No description provided for @activityUiSourceBarcodeLabelPanel.
  ///
  /// In ar, this message translates to:
  /// **'لوحة طباعة الباركود'**
  String get activityUiSourceBarcodeLabelPanel;

  /// No description provided for @activityUiSourceUserManagement.
  ///
  /// In ar, this message translates to:
  /// **'إدارة المستخدمين'**
  String get activityUiSourceUserManagement;

  /// No description provided for @activityUiSourceShopSettings.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات المتجر'**
  String get activityUiSourceShopSettings;

  /// No description provided for @activityUiSourceDeviceSettings.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات الجهاز'**
  String get activityUiSourceDeviceSettings;

  /// No description provided for @activityUiSourceDiscountManagement.
  ///
  /// In ar, this message translates to:
  /// **'إدارة الخصومات'**
  String get activityUiSourceDiscountManagement;

  /// No description provided for @activityUiSourceReportsScreen.
  ///
  /// In ar, this message translates to:
  /// **'شاشة التقارير'**
  String get activityUiSourceReportsScreen;

  /// No description provided for @activityUiSourceAnalyticsExportSheet.
  ///
  /// In ar, this message translates to:
  /// **'نافذة تصدير التحليلات'**
  String get activityUiSourceAnalyticsExportSheet;

  /// No description provided for @activityUiSourcePrintingSettings.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات الطباعة'**
  String get activityUiSourcePrintingSettings;

  /// Fallback label for unknown UI source values.
  ///
  /// In ar, this message translates to:
  /// **'{source}'**
  String activityUiSourceUnknown(String source);

  /// No description provided for @activityLogScopeFilterTitle.
  ///
  /// In ar, this message translates to:
  /// **'نطاق السجل'**
  String get activityLogScopeFilterTitle;

  /// No description provided for @activityScopeReviewable.
  ///
  /// In ar, this message translates to:
  /// **'الأحداث المهمة فقط'**
  String get activityScopeReviewable;

  /// No description provided for @activityScopeAll.
  ///
  /// In ar, this message translates to:
  /// **'كل الأحداث'**
  String get activityScopeAll;

  /// No description provided for @activityScopeTechnical.
  ///
  /// In ar, this message translates to:
  /// **'السجل التقني فقط'**
  String get activityScopeTechnical;

  /// No description provided for @activityLogActionFilterTitle.
  ///
  /// In ar, this message translates to:
  /// **'الإجراء'**
  String get activityLogActionFilterTitle;

  /// No description provided for @activityLogDateFilterTitle.
  ///
  /// In ar, this message translates to:
  /// **'الفترة'**
  String get activityLogDateFilterTitle;

  /// No description provided for @activityLogFromDateOpen.
  ///
  /// In ar, this message translates to:
  /// **'من البداية'**
  String get activityLogFromDateOpen;

  /// No description provided for @activityLogToDateOpen.
  ///
  /// In ar, this message translates to:
  /// **'إلى الآن'**
  String get activityLogToDateOpen;

  /// Activity log start date value.
  ///
  /// In ar, this message translates to:
  /// **'من {date}'**
  String activityLogFromDateValue(String date);

  /// Activity log end date value.
  ///
  /// In ar, this message translates to:
  /// **'إلى {date}'**
  String activityLogToDateValue(String date);

  /// No description provided for @activityLogUserFilterTitle.
  ///
  /// In ar, this message translates to:
  /// **'المستخدم'**
  String get activityLogUserFilterTitle;

  /// No description provided for @activityLogUserFilterLabel.
  ///
  /// In ar, this message translates to:
  /// **'المستخدم'**
  String get activityLogUserFilterLabel;

  /// No description provided for @activityLogAllUsers.
  ///
  /// In ar, this message translates to:
  /// **'كل المستخدمين'**
  String get activityLogAllUsers;

  /// No description provided for @activityLogUserFilterHelper.
  ///
  /// In ar, this message translates to:
  /// **'اختر مستخدمًا أو أكثر لتصفية الإجراءات المسجلة.'**
  String get activityLogUserFilterHelper;

  /// No description provided for @activityLogUsersOpenPickerTooltip.
  ///
  /// In ar, this message translates to:
  /// **'اختيار المستخدمين'**
  String get activityLogUsersOpenPickerTooltip;

  /// No description provided for @activityLogUserPickerTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختيار المستخدمين'**
  String get activityLogUserPickerTitle;

  /// No description provided for @activityLogUserPickerSearchHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث باسم المستخدم أو البريد'**
  String get activityLogUserPickerSearchHint;

  /// No description provided for @activityLogUserPickerEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد مستخدمون مطابقون.'**
  String get activityLogUserPickerEmpty;

  /// No description provided for @activityLogUserPickerLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل المستخدمين.'**
  String get activityLogUserPickerLoadError;

  /// Fallback label for activity log user filters when the user name is not available.
  ///
  /// In ar, this message translates to:
  /// **'مستخدم #{id}'**
  String activityLogUserFallbackLabel(int id);

  /// No description provided for @activityLogContextFilterTitle.
  ///
  /// In ar, this message translates to:
  /// **'السياق'**
  String get activityLogContextFilterTitle;

  /// No description provided for @activityLogSessionFilterLabel.
  ///
  /// In ar, this message translates to:
  /// **'معرّف جلسة الدرج'**
  String get activityLogSessionFilterLabel;

  /// No description provided for @activityLogEntityTypeFilterLabel.
  ///
  /// In ar, this message translates to:
  /// **'نوع الكيان'**
  String get activityLogEntityTypeFilterLabel;

  /// No description provided for @activityLogEntityIdFilterLabel.
  ///
  /// In ar, this message translates to:
  /// **'معرّف الكيان'**
  String get activityLogEntityIdFilterLabel;

  /// No description provided for @activityLogEventTypeFilterTitle.
  ///
  /// In ar, this message translates to:
  /// **'نوع الحدث'**
  String get activityLogEventTypeFilterTitle;

  /// No description provided for @activityLogSeverityFilterTitle.
  ///
  /// In ar, this message translates to:
  /// **'الحدة'**
  String get activityLogSeverityFilterTitle;

  /// No description provided for @activityLogRiskFilterTitle.
  ///
  /// In ar, this message translates to:
  /// **'درجة المخاطر'**
  String get activityLogRiskFilterTitle;

  /// No description provided for @activityLogRiskAll.
  ///
  /// In ar, this message translates to:
  /// **'كل درجات المخاطر'**
  String get activityLogRiskAll;

  /// Minimum risk score filter.
  ///
  /// In ar, this message translates to:
  /// **'{score} فأعلى'**
  String activityLogRiskAtLeast(int score);

  /// No description provided for @activityLogSourceFilterTitle.
  ///
  /// In ar, this message translates to:
  /// **'المصدر'**
  String get activityLogSourceFilterTitle;

  /// No description provided for @activityLogOrderingTitle.
  ///
  /// In ar, this message translates to:
  /// **'ترتيب النتائج'**
  String get activityLogOrderingTitle;

  /// No description provided for @activityActionAll.
  ///
  /// In ar, this message translates to:
  /// **'كل الإجراءات'**
  String get activityActionAll;

  /// No description provided for @activityActionFraudSignal.
  ///
  /// In ar, this message translates to:
  /// **'مؤشرات الاشتباه'**
  String get activityActionFraudSignal;

  /// No description provided for @activityActionPosLineAdded.
  ///
  /// In ar, this message translates to:
  /// **'إضافة سطر بيع'**
  String get activityActionPosLineAdded;

  /// No description provided for @activityActionPosLineQuantityChanged.
  ///
  /// In ar, this message translates to:
  /// **'تغيير كمية سطر بيع'**
  String get activityActionPosLineQuantityChanged;

  /// No description provided for @activityActionPosLineDeleted.
  ///
  /// In ar, this message translates to:
  /// **'حذف سطر بيع'**
  String get activityActionPosLineDeleted;

  /// No description provided for @activityActionPosCartCleared.
  ///
  /// In ar, this message translates to:
  /// **'تفريغ سلة البيع'**
  String get activityActionPosCartCleared;

  /// No description provided for @activityActionPurchaseLineAdded.
  ///
  /// In ar, this message translates to:
  /// **'إضافة سطر شراء'**
  String get activityActionPurchaseLineAdded;

  /// No description provided for @activityActionPurchaseLineQuantityChanged.
  ///
  /// In ar, this message translates to:
  /// **'تغيير كمية سطر شراء'**
  String get activityActionPurchaseLineQuantityChanged;

  /// No description provided for @activityActionPurchaseLineDeleted.
  ///
  /// In ar, this message translates to:
  /// **'حذف سطر شراء'**
  String get activityActionPurchaseLineDeleted;

  /// No description provided for @activityActionPurchaseDraftCleared.
  ///
  /// In ar, this message translates to:
  /// **'تفريغ مسودة شراء'**
  String get activityActionPurchaseDraftCleared;

  /// No description provided for @activityActionPurchaseDraftSubmitted.
  ///
  /// In ar, this message translates to:
  /// **'إرسال مسودة شراء'**
  String get activityActionPurchaseDraftSubmitted;

  /// No description provided for @activityActionInvoiceCreated.
  ///
  /// In ar, this message translates to:
  /// **'إنشاء فاتورة'**
  String get activityActionInvoiceCreated;

  /// No description provided for @activityActionCustomerCreated.
  ///
  /// In ar, this message translates to:
  /// **'إنشاء عميل'**
  String get activityActionCustomerCreated;

  /// No description provided for @activityActionRegisterCashMovement.
  ///
  /// In ar, this message translates to:
  /// **'حركة نقدية في الدرج'**
  String get activityActionRegisterCashMovement;

  /// No description provided for @activityActionRegisterSessionStarted.
  ///
  /// In ar, this message translates to:
  /// **'فتح جلسة درج'**
  String get activityActionRegisterSessionStarted;

  /// No description provided for @activityActionRegisterSessionClosed.
  ///
  /// In ar, this message translates to:
  /// **'إغلاق جلسة درج'**
  String get activityActionRegisterSessionClosed;

  /// No description provided for @activityActionReceiptReprinted.
  ///
  /// In ar, this message translates to:
  /// **'إعادة طباعة إيصال'**
  String get activityActionReceiptReprinted;

  /// No description provided for @activityActionOrderVoided.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء فاتورة'**
  String get activityActionOrderVoided;

  /// No description provided for @activityActionOrderReturned.
  ///
  /// In ar, this message translates to:
  /// **'مرتجع فاتورة'**
  String get activityActionOrderReturned;

  /// No description provided for @activityActionProductChanged.
  ///
  /// In ar, this message translates to:
  /// **'تغييرات المنتجات'**
  String get activityActionProductChanged;

  /// No description provided for @activityActionStockMovementCreated.
  ///
  /// In ar, this message translates to:
  /// **'حركات المخزون'**
  String get activityActionStockMovementCreated;

  /// No description provided for @activityActionBarcodeLabelsPrinted.
  ///
  /// In ar, this message translates to:
  /// **'طباعة ملصقات باركود'**
  String get activityActionBarcodeLabelsPrinted;

  /// No description provided for @activityActionUserChanged.
  ///
  /// In ar, this message translates to:
  /// **'تغييرات المستخدمين'**
  String get activityActionUserChanged;

  /// No description provided for @activityActionSettingsChanged.
  ///
  /// In ar, this message translates to:
  /// **'تغييرات الإعدادات'**
  String get activityActionSettingsChanged;

  /// No description provided for @activityActionDiscountChanged.
  ///
  /// In ar, this message translates to:
  /// **'تغييرات الخصومات'**
  String get activityActionDiscountChanged;

  /// No description provided for @activityActionReportActivity.
  ///
  /// In ar, this message translates to:
  /// **'نشاط التقارير'**
  String get activityActionReportActivity;

  /// No description provided for @activityActionPrinterActivity.
  ///
  /// In ar, this message translates to:
  /// **'نشاط الطباعة'**
  String get activityActionPrinterActivity;

  /// No description provided for @activityActionAnalyticsExport.
  ///
  /// In ar, this message translates to:
  /// **'تصدير التحليلات'**
  String get activityActionAnalyticsExport;

  /// No description provided for @activityActionPurchaseOrderDeleted.
  ///
  /// In ar, this message translates to:
  /// **'حذف أمر شراء'**
  String get activityActionPurchaseOrderDeleted;

  /// No description provided for @activityActionAnyDeleted.
  ///
  /// In ar, this message translates to:
  /// **'أي حذف'**
  String get activityActionAnyDeleted;

  /// No description provided for @activityDateRangeAll.
  ///
  /// In ar, this message translates to:
  /// **'كل الفترات'**
  String get activityDateRangeAll;

  /// No description provided for @activityDateRangeToday.
  ///
  /// In ar, this message translates to:
  /// **'اليوم'**
  String get activityDateRangeToday;

  /// No description provided for @activityDateRange7Days.
  ///
  /// In ar, this message translates to:
  /// **'آخر 7 أيام'**
  String get activityDateRange7Days;

  /// No description provided for @activityDateRange30Days.
  ///
  /// In ar, this message translates to:
  /// **'آخر 30 يومًا'**
  String get activityDateRange30Days;

  /// No description provided for @activityDateRangeCustom.
  ///
  /// In ar, this message translates to:
  /// **'فترة مخصصة'**
  String get activityDateRangeCustom;

  /// No description provided for @activityOrderingNewest.
  ///
  /// In ar, this message translates to:
  /// **'الأحدث أولًا'**
  String get activityOrderingNewest;

  /// No description provided for @activityOrderingOldest.
  ///
  /// In ar, this message translates to:
  /// **'الأقدم أولًا'**
  String get activityOrderingOldest;

  /// No description provided for @activityOrderingHighestRisk.
  ///
  /// In ar, this message translates to:
  /// **'الأعلى مخاطرة أولًا'**
  String get activityOrderingHighestRisk;

  /// No description provided for @activityOrderingNewestReceived.
  ///
  /// In ar, this message translates to:
  /// **'الأحدث وصولًا أولًا'**
  String get activityOrderingNewestReceived;

  /// No description provided for @activityEventCheckoutCompleted.
  ///
  /// In ar, this message translates to:
  /// **'اكتملت عملية بيع'**
  String get activityEventCheckoutCompleted;

  /// No description provided for @activityEventOrderPaid.
  ///
  /// In ar, this message translates to:
  /// **'تم دفع فاتورة'**
  String get activityEventOrderPaid;

  /// No description provided for @activityEventOrderVoided.
  ///
  /// In ar, this message translates to:
  /// **'ألغيت فاتورة'**
  String get activityEventOrderVoided;

  /// No description provided for @activityEventOrderReturned.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل مرتجع'**
  String get activityEventOrderReturned;

  /// No description provided for @activityEventSuspectedActivityDetected.
  ///
  /// In ar, this message translates to:
  /// **'رُصد نمط مشتبه للمراجعة'**
  String get activityEventSuspectedActivityDetected;

  /// No description provided for @activityEventReceiptReprintQueued.
  ///
  /// In ar, this message translates to:
  /// **'أعيدت طباعة إيصال'**
  String get activityEventReceiptReprintQueued;

  /// No description provided for @activityEventReceiptReprintFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشلت إعادة طباعة إيصال'**
  String get activityEventReceiptReprintFailed;

  /// No description provided for @activityEventRegisterSessionStarted.
  ///
  /// In ar, this message translates to:
  /// **'بدأت جلسة درج'**
  String get activityEventRegisterSessionStarted;

  /// No description provided for @activityEventRegisterSessionResumed.
  ///
  /// In ar, this message translates to:
  /// **'استؤنفت جلسة درج'**
  String get activityEventRegisterSessionResumed;

  /// No description provided for @activityEventRegisterSessionClosed.
  ///
  /// In ar, this message translates to:
  /// **'أغلقت جلسة درج'**
  String get activityEventRegisterSessionClosed;

  /// No description provided for @activityEventRegisterCashMovementCreated.
  ///
  /// In ar, this message translates to:
  /// **'سجلت حركة نقدية'**
  String get activityEventRegisterCashMovementCreated;

  /// No description provided for @activityEventSalesHistorySessionSelected.
  ///
  /// In ar, this message translates to:
  /// **'فتحت جلسة من السجل'**
  String get activityEventSalesHistorySessionSelected;

  /// No description provided for @activityEventSalesHistoryOrderVoidCompleted.
  ///
  /// In ar, this message translates to:
  /// **'اكتمل إلغاء فاتورة من السجل'**
  String get activityEventSalesHistoryOrderVoidCompleted;

  /// No description provided for @activityEventSalesHistoryOrderReturnCompleted.
  ///
  /// In ar, this message translates to:
  /// **'اكتمل مرتجع فاتورة من السجل'**
  String get activityEventSalesHistoryOrderReturnCompleted;

  /// No description provided for @activityEventPosLineAdded.
  ///
  /// In ar, this message translates to:
  /// **'أضيف سطر إلى سلة البيع'**
  String get activityEventPosLineAdded;

  /// No description provided for @activityEventPosLineQuantityIncreased.
  ///
  /// In ar, this message translates to:
  /// **'زادت كمية سطر في سلة البيع'**
  String get activityEventPosLineQuantityIncreased;

  /// No description provided for @activityEventPosLineQuantityDecreased.
  ///
  /// In ar, this message translates to:
  /// **'نقصت كمية سطر في سلة البيع'**
  String get activityEventPosLineQuantityDecreased;

  /// No description provided for @activityEventPosLineDeleted.
  ///
  /// In ar, this message translates to:
  /// **'حذف سطر من سلة البيع'**
  String get activityEventPosLineDeleted;

  /// No description provided for @activityEventPosCartCleared.
  ///
  /// In ar, this message translates to:
  /// **'أفرغت سلة البيع'**
  String get activityEventPosCartCleared;

  /// No description provided for @activityEventPosCheckoutStarted.
  ///
  /// In ar, this message translates to:
  /// **'بدأ إرسال عملية بيع'**
  String get activityEventPosCheckoutStarted;

  /// No description provided for @activityEventPosCheckoutCompleted.
  ///
  /// In ar, this message translates to:
  /// **'اكتملت عملية البيع من الواجهة'**
  String get activityEventPosCheckoutCompleted;

  /// No description provided for @activityEventPosCheckoutFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل إرسال عملية بيع'**
  String get activityEventPosCheckoutFailed;

  /// No description provided for @activityEventPosCheckoutStockRejected.
  ///
  /// In ar, this message translates to:
  /// **'رفضت عملية بيع بسبب المخزون'**
  String get activityEventPosCheckoutStockRejected;

  /// No description provided for @activityEventPurchaseLineAdded.
  ///
  /// In ar, this message translates to:
  /// **'أضيف سطر إلى مسودة الشراء'**
  String get activityEventPurchaseLineAdded;

  /// No description provided for @activityEventPurchaseLineQuantityIncreased.
  ///
  /// In ar, this message translates to:
  /// **'زادت كمية سطر في مسودة الشراء'**
  String get activityEventPurchaseLineQuantityIncreased;

  /// No description provided for @activityEventPurchaseLineQuantityDecreased.
  ///
  /// In ar, this message translates to:
  /// **'نقصت كمية سطر في مسودة الشراء'**
  String get activityEventPurchaseLineQuantityDecreased;

  /// No description provided for @activityEventPurchaseLineDeleted.
  ///
  /// In ar, this message translates to:
  /// **'حذف سطر من مسودة الشراء'**
  String get activityEventPurchaseLineDeleted;

  /// No description provided for @activityEventPurchaseDraftCleared.
  ///
  /// In ar, this message translates to:
  /// **'أفرغت مسودة الشراء'**
  String get activityEventPurchaseDraftCleared;

  /// No description provided for @activityEventPurchaseSupplierSelected.
  ///
  /// In ar, this message translates to:
  /// **'اختير مورد لمسودة الشراء'**
  String get activityEventPurchaseSupplierSelected;

  /// No description provided for @activityEventPurchaseDraftSubmitted.
  ///
  /// In ar, this message translates to:
  /// **'أرسلت مسودة شراء'**
  String get activityEventPurchaseDraftSubmitted;

  /// No description provided for @activityEventPurchaseDraftSubmitFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل إرسال مسودة شراء'**
  String get activityEventPurchaseDraftSubmitFailed;

  /// No description provided for @activityEventPurchaseOrderCreated.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ أمر شراء'**
  String get activityEventPurchaseOrderCreated;

  /// No description provided for @activityEventPurchaseOrderUpdated.
  ///
  /// In ar, this message translates to:
  /// **'حُدث أمر شراء'**
  String get activityEventPurchaseOrderUpdated;

  /// No description provided for @activityEventPurchaseOrderSubmitted.
  ///
  /// In ar, this message translates to:
  /// **'أرسل أمر شراء'**
  String get activityEventPurchaseOrderSubmitted;

  /// No description provided for @activityEventPurchaseOrderReceived.
  ///
  /// In ar, this message translates to:
  /// **'استلم أمر شراء'**
  String get activityEventPurchaseOrderReceived;

  /// No description provided for @activityEventPurchaseOrderAdjusted.
  ///
  /// In ar, this message translates to:
  /// **'عدّل أمر شراء'**
  String get activityEventPurchaseOrderAdjusted;

  /// No description provided for @activityEventPurchaseOrderCancelled.
  ///
  /// In ar, this message translates to:
  /// **'ألغي أمر شراء'**
  String get activityEventPurchaseOrderCancelled;

  /// No description provided for @activityEventPurchaseOrderDeleted.
  ///
  /// In ar, this message translates to:
  /// **'حذف أمر شراء'**
  String get activityEventPurchaseOrderDeleted;

  /// No description provided for @activityEventCustomerCreated.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ عميل'**
  String get activityEventCustomerCreated;

  /// No description provided for @activityEventCustomerUpdated.
  ///
  /// In ar, this message translates to:
  /// **'حُدث عميل'**
  String get activityEventCustomerUpdated;

  /// No description provided for @activityEventCustomerDeleted.
  ///
  /// In ar, this message translates to:
  /// **'حذف عميل'**
  String get activityEventCustomerDeleted;

  /// No description provided for @activityEventCatalogProductCreated.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ منتج'**
  String get activityEventCatalogProductCreated;

  /// No description provided for @activityEventCatalogProductUpdated.
  ///
  /// In ar, this message translates to:
  /// **'حُدث منتج'**
  String get activityEventCatalogProductUpdated;

  /// No description provided for @activityEventCatalogProductImageUploaded.
  ///
  /// In ar, this message translates to:
  /// **'رُفعت صورة منتج'**
  String get activityEventCatalogProductImageUploaded;

  /// No description provided for @activityEventCatalogProductImageImported.
  ///
  /// In ar, this message translates to:
  /// **'استوردت صورة منتج'**
  String get activityEventCatalogProductImageImported;

  /// No description provided for @activityEventCatalogVariantCreated.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ متغير منتج'**
  String get activityEventCatalogVariantCreated;

  /// No description provided for @activityEventCatalogVariantUpdated.
  ///
  /// In ar, this message translates to:
  /// **'حُدث متغير منتج'**
  String get activityEventCatalogVariantUpdated;

  /// No description provided for @activityEventCatalogVariantsGenerated.
  ///
  /// In ar, this message translates to:
  /// **'وُلدت متغيرات منتج'**
  String get activityEventCatalogVariantsGenerated;

  /// No description provided for @activityEventCatalogCategoryCreated.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ تصنيف منتج'**
  String get activityEventCatalogCategoryCreated;

  /// No description provided for @activityEventStockMovementCreated.
  ///
  /// In ar, this message translates to:
  /// **'سجلت حركة مخزون'**
  String get activityEventStockMovementCreated;

  /// No description provided for @activityEventStockMovementCreateFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل تسجيل حركة مخزون'**
  String get activityEventStockMovementCreateFailed;

  /// No description provided for @activityEventUserCreated.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ مستخدم'**
  String get activityEventUserCreated;

  /// No description provided for @activityEventUserUpdated.
  ///
  /// In ar, this message translates to:
  /// **'حُدث مستخدم'**
  String get activityEventUserUpdated;

  /// No description provided for @activityEventUserDeleted.
  ///
  /// In ar, this message translates to:
  /// **'حذف مستخدم'**
  String get activityEventUserDeleted;

  /// No description provided for @activityEventUserRoleChanged.
  ///
  /// In ar, this message translates to:
  /// **'تغير دور مستخدم'**
  String get activityEventUserRoleChanged;

  /// No description provided for @activityEventUserActiveChanged.
  ///
  /// In ar, this message translates to:
  /// **'تغيرت حالة مستخدم'**
  String get activityEventUserActiveChanged;

  /// No description provided for @activityEventShopSettingsUpdated.
  ///
  /// In ar, this message translates to:
  /// **'حُدثت إعدادات المتجر'**
  String get activityEventShopSettingsUpdated;

  /// No description provided for @activityEventShopLogoUploaded.
  ///
  /// In ar, this message translates to:
  /// **'رُفع شعار المتجر'**
  String get activityEventShopLogoUploaded;

  /// No description provided for @activityEventShopLogoRemoved.
  ///
  /// In ar, this message translates to:
  /// **'أزيل شعار المتجر'**
  String get activityEventShopLogoRemoved;

  /// No description provided for @activityEventDeviceUsageModeChanged.
  ///
  /// In ar, this message translates to:
  /// **'تغير وضع استخدام الجهاز'**
  String get activityEventDeviceUsageModeChanged;

  /// No description provided for @activityEventDiscountRuleCreated.
  ///
  /// In ar, this message translates to:
  /// **'أنشئت قاعدة خصم'**
  String get activityEventDiscountRuleCreated;

  /// No description provided for @activityEventDiscountRuleUpdated.
  ///
  /// In ar, this message translates to:
  /// **'حُدثت قاعدة خصم'**
  String get activityEventDiscountRuleUpdated;

  /// No description provided for @activityEventDiscountRuleEnabled.
  ///
  /// In ar, this message translates to:
  /// **'فُعلت قاعدة خصم'**
  String get activityEventDiscountRuleEnabled;

  /// No description provided for @activityEventDiscountRuleDisabled.
  ///
  /// In ar, this message translates to:
  /// **'عُطلت قاعدة خصم'**
  String get activityEventDiscountRuleDisabled;

  /// No description provided for @activityEventDiscountRuleArchived.
  ///
  /// In ar, this message translates to:
  /// **'أرشفت قاعدة خصم'**
  String get activityEventDiscountRuleArchived;

  /// No description provided for @activityEventBarcodeLabelsPrinted.
  ///
  /// In ar, this message translates to:
  /// **'طُبعت ملصقات باركود'**
  String get activityEventBarcodeLabelsPrinted;

  /// No description provided for @activityEventBarcodeLabelsFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشلت طباعة ملصقات باركود'**
  String get activityEventBarcodeLabelsFailed;

  /// No description provided for @activityEventPrinterDiscoveryCompleted.
  ///
  /// In ar, this message translates to:
  /// **'اكتمل البحث عن الطابعات'**
  String get activityEventPrinterDiscoveryCompleted;

  /// No description provided for @activityEventPrinterDiscoveryFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل البحث عن الطابعات'**
  String get activityEventPrinterDiscoveryFailed;

  /// No description provided for @activityEventPrinterTested.
  ///
  /// In ar, this message translates to:
  /// **'اختُبرت الطابعة'**
  String get activityEventPrinterTested;

  /// No description provided for @activityEventPrinterFakeReceiptPrinted.
  ///
  /// In ar, this message translates to:
  /// **'طُبع إيصال تجريبي'**
  String get activityEventPrinterFakeReceiptPrinted;

  /// No description provided for @activityEventAppFlutterError.
  ///
  /// In ar, this message translates to:
  /// **'سجل التطبيق خطأ'**
  String get activityEventAppFlutterError;

  /// No description provided for @activityEventAppPlatformError.
  ///
  /// In ar, this message translates to:
  /// **'سجل النظام خطأ'**
  String get activityEventAppPlatformError;

  /// No description provided for @activityEventAuthSessionStarted.
  ///
  /// In ar, this message translates to:
  /// **'بدأت جلسة دخول'**
  String get activityEventAuthSessionStarted;

  /// No description provided for @activityEventLoginSucceeded.
  ///
  /// In ar, this message translates to:
  /// **'نجح تسجيل الدخول'**
  String get activityEventLoginSucceeded;

  /// No description provided for @activityEventLoginFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل تسجيل الدخول'**
  String get activityEventLoginFailed;

  /// No description provided for @activityEventLogout.
  ///
  /// In ar, this message translates to:
  /// **'سجل المستخدم خروجه'**
  String get activityEventLogout;

  /// No description provided for @activityEventAnalyticsExportStarted.
  ///
  /// In ar, this message translates to:
  /// **'بدأ تصدير التحليلات'**
  String get activityEventAnalyticsExportStarted;

  /// No description provided for @activityEventAnalyticsExportCompleted.
  ///
  /// In ar, this message translates to:
  /// **'اكتمل تصدير التحليلات'**
  String get activityEventAnalyticsExportCompleted;

  /// No description provided for @activityEventAnalyticsExportFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل تصدير التحليلات'**
  String get activityEventAnalyticsExportFailed;

  /// No description provided for @activityEventAnalyticsExportDownloaded.
  ///
  /// In ar, this message translates to:
  /// **'نُزل ملف التحليلات'**
  String get activityEventAnalyticsExportDownloaded;

  /// No description provided for @activityEventAnalyticsExportDownloadFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل تنزيل ملف التحليلات'**
  String get activityEventAnalyticsExportDownloadFailed;

  /// No description provided for @activityEventReportGenerated.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ تقرير'**
  String get activityEventReportGenerated;

  /// No description provided for @activityEventReportGenerationFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل إنشاء تقرير'**
  String get activityEventReportGenerationFailed;

  /// No description provided for @activityEventReportPreviewed.
  ///
  /// In ar, this message translates to:
  /// **'عاين المستخدم تقريرًا'**
  String get activityEventReportPreviewed;

  /// No description provided for @activityEventReportPrinted.
  ///
  /// In ar, this message translates to:
  /// **'طبع المستخدم تقريرًا'**
  String get activityEventReportPrinted;

  /// No description provided for @activityEventReportShared.
  ///
  /// In ar, this message translates to:
  /// **'شارك المستخدم تقريرًا'**
  String get activityEventReportShared;

  /// No description provided for @activityEventReportRunCompleted.
  ///
  /// In ar, this message translates to:
  /// **'اكتمل تشغيل تقرير'**
  String get activityEventReportRunCompleted;

  /// No description provided for @activityEventReportRunFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل تشغيل تقرير'**
  String get activityEventReportRunFailed;

  /// No description provided for @reportsTitle.
  ///
  /// In ar, this message translates to:
  /// **'التقارير'**
  String get reportsTitle;

  /// No description provided for @reportsCatalogTitle.
  ///
  /// In ar, this message translates to:
  /// **'أنواع التقارير'**
  String get reportsCatalogTitle;

  /// No description provided for @reportsSetupTitle.
  ///
  /// In ar, this message translates to:
  /// **'إعداد التقرير'**
  String get reportsSetupTitle;

  /// No description provided for @reportCategorySales.
  ///
  /// In ar, this message translates to:
  /// **'المبيعات'**
  String get reportCategorySales;

  /// No description provided for @reportCategoryCash.
  ///
  /// In ar, this message translates to:
  /// **'النقدية'**
  String get reportCategoryCash;

  /// No description provided for @reportCategoryPayments.
  ///
  /// In ar, this message translates to:
  /// **'المدفوعات'**
  String get reportCategoryPayments;

  /// No description provided for @reportCategoryInventory.
  ///
  /// In ar, this message translates to:
  /// **'المخزون'**
  String get reportCategoryInventory;

  /// No description provided for @reportCategoryPurchasing.
  ///
  /// In ar, this message translates to:
  /// **'المشتريات'**
  String get reportCategoryPurchasing;

  /// No description provided for @reportCategoryContacts.
  ///
  /// In ar, this message translates to:
  /// **'الجهات'**
  String get reportCategoryContacts;

  /// No description provided for @reportCategoryDiscounts.
  ///
  /// In ar, this message translates to:
  /// **'الخصومات'**
  String get reportCategoryDiscounts;

  /// No description provided for @reportSalesSummaryTitle.
  ///
  /// In ar, this message translates to:
  /// **'ملخص المبيعات'**
  String get reportSalesSummaryTitle;

  /// No description provided for @reportSalesSummarySubtitle.
  ///
  /// In ar, this message translates to:
  /// **'إجماليات الطلبات والمرتجعات والخصومات حسب الفترة.'**
  String get reportSalesSummarySubtitle;

  /// No description provided for @reportRegisterSessionsTitle.
  ///
  /// In ar, this message translates to:
  /// **'جلسات الدرج'**
  String get reportRegisterSessionsTitle;

  /// No description provided for @reportRegisterSessionsSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'افتتاح وإغلاق الجلسات والفروقات النقدية لكل وردية.'**
  String get reportRegisterSessionsSubtitle;

  /// No description provided for @reportPaymentsTitle.
  ///
  /// In ar, this message translates to:
  /// **'المدفوعات'**
  String get reportPaymentsTitle;

  /// No description provided for @reportPaymentsSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'طرق الدفع والعمولات والتسويات خلال الفترة.'**
  String get reportPaymentsSubtitle;

  /// No description provided for @reportInventoryValueTitle.
  ///
  /// In ar, this message translates to:
  /// **'قيمة المخزون'**
  String get reportInventoryValueTitle;

  /// No description provided for @reportInventoryValueSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'الكميات الحالية وقيمة البيع والتكلفة عند توفرها.'**
  String get reportInventoryValueSubtitle;

  /// No description provided for @reportStockMovementTitle.
  ///
  /// In ar, this message translates to:
  /// **'حركات المخزون'**
  String get reportStockMovementTitle;

  /// No description provided for @reportStockMovementSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'الاستلام والتعديل والبيع لكل منتج.'**
  String get reportStockMovementSubtitle;

  /// No description provided for @reportPurchasesTitle.
  ///
  /// In ar, this message translates to:
  /// **'المشتريات والموردون'**
  String get reportPurchasesTitle;

  /// No description provided for @reportPurchasesSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'أوامر الشراء والاستلام والمستحقات.'**
  String get reportPurchasesSubtitle;

  /// No description provided for @reportContactsTitle.
  ///
  /// In ar, this message translates to:
  /// **'أرصدة الجهات'**
  String get reportContactsTitle;

  /// No description provided for @reportContactsSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'نشاط العملاء والموردين والأرصدة المرتبطة بهم.'**
  String get reportContactsSubtitle;

  /// No description provided for @reportDiscountsTitle.
  ///
  /// In ar, this message translates to:
  /// **'سجل الخصومات'**
  String get reportDiscountsTitle;

  /// No description provided for @reportDiscountsSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'الخصومات النشطة والاستخدامات خلال الفترة.'**
  String get reportDiscountsSubtitle;

  /// No description provided for @reportA4Chip.
  ///
  /// In ar, this message translates to:
  /// **'A4'**
  String get reportA4Chip;

  /// No description provided for @reportArchiveChip.
  ///
  /// In ar, this message translates to:
  /// **'أرشفة'**
  String get reportArchiveChip;

  /// No description provided for @reportAuditableChip.
  ///
  /// In ar, this message translates to:
  /// **'قابل للتدقيق'**
  String get reportAuditableChip;

  /// No description provided for @reportPeriodTitle.
  ///
  /// In ar, this message translates to:
  /// **'الفترة'**
  String get reportPeriodTitle;

  /// No description provided for @reportPeriodToday.
  ///
  /// In ar, this message translates to:
  /// **'اليوم'**
  String get reportPeriodToday;

  /// No description provided for @reportPeriodWeek.
  ///
  /// In ar, this message translates to:
  /// **'الأسبوع'**
  String get reportPeriodWeek;

  /// No description provided for @reportPeriodMonth.
  ///
  /// In ar, this message translates to:
  /// **'الشهر'**
  String get reportPeriodMonth;

  /// No description provided for @reportPeriodCustom.
  ///
  /// In ar, this message translates to:
  /// **'مخصص'**
  String get reportPeriodCustom;

  /// Start date selector label.
  ///
  /// In ar, this message translates to:
  /// **'من {date}'**
  String reportFromDateValue(String date);

  /// End date selector label.
  ///
  /// In ar, this message translates to:
  /// **'إلى {date}'**
  String reportToDateValue(String date);

  /// Selected report date range.
  ///
  /// In ar, this message translates to:
  /// **'{start} - {end}'**
  String reportDateRangeValue(String start, String end);

  /// No description provided for @reportGranularityTitle.
  ///
  /// In ar, this message translates to:
  /// **'التفصيل'**
  String get reportGranularityTitle;

  /// No description provided for @reportGranularitySummary.
  ///
  /// In ar, this message translates to:
  /// **'ملخص'**
  String get reportGranularitySummary;

  /// No description provided for @reportGranularityDaily.
  ///
  /// In ar, this message translates to:
  /// **'يومي'**
  String get reportGranularityDaily;

  /// No description provided for @reportGranularityDetailed.
  ///
  /// In ar, this message translates to:
  /// **'تفصيلي'**
  String get reportGranularityDetailed;

  /// No description provided for @reportArchiveOptionsTitle.
  ///
  /// In ar, this message translates to:
  /// **'الأرشفة'**
  String get reportArchiveOptionsTitle;

  /// No description provided for @reportIncludeAuditTrailLabel.
  ///
  /// In ar, this message translates to:
  /// **'إضافة سجل التدقيق'**
  String get reportIncludeAuditTrailLabel;

  /// No description provided for @reportIncludePreparedByLabel.
  ///
  /// In ar, this message translates to:
  /// **'إظهار معد التقرير والتاريخ'**
  String get reportIncludePreparedByLabel;

  /// No description provided for @reportOutputTitle.
  ///
  /// In ar, this message translates to:
  /// **'الإخراج'**
  String get reportOutputTitle;

  /// No description provided for @reportPreviewPdfAction.
  ///
  /// In ar, this message translates to:
  /// **'معاينة PDF'**
  String get reportPreviewPdfAction;

  /// No description provided for @reportPdfPreviewTitle.
  ///
  /// In ar, this message translates to:
  /// **'معاينة التقرير'**
  String get reportPdfPreviewTitle;

  /// No description provided for @reportPrintAction.
  ///
  /// In ar, this message translates to:
  /// **'طباعة'**
  String get reportPrintAction;

  /// No description provided for @reportExportArchiveAction.
  ///
  /// In ar, this message translates to:
  /// **'حفظ للأرشيف'**
  String get reportExportArchiveAction;

  /// Selected report output summary.
  ///
  /// In ar, this message translates to:
  /// **'الفترة: {range}، التفصيل: {granularity}'**
  String reportSelectedSummary(String range, String granularity);

  /// Placeholder message for report actions until services are wired.
  ///
  /// In ar, this message translates to:
  /// **'{action} غير موصول بعد لتقرير {report}.'**
  String reportActionPlaceholder(String action, String report);

  /// Shown while a report output action is running.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ تنفيذ {action}...'**
  String reportActionInProgress(String action);

  /// Shown when a report output action fails.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تنفيذ {action}. حاول مرة أخرى.'**
  String reportActionError(String action);

  /// No description provided for @reportGenerationError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إنشاء التقرير.'**
  String get reportGenerationError;

  /// No description provided for @reportPrintQueuedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم إرسال التقرير للطباعة.'**
  String get reportPrintQueuedMessage;

  /// No description provided for @reportArchiveSharedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم تجهيز نسخة الأرشيف.'**
  String get reportArchiveSharedMessage;

  /// No description provided for @dashboardTitle.
  ///
  /// In ar, this message translates to:
  /// **'لوحة التحكم'**
  String get dashboardTitle;

  /// No description provided for @dashboardOverviewTitle.
  ///
  /// In ar, this message translates to:
  /// **'نظرة تشغيلية'**
  String get dashboardOverviewTitle;

  /// No description provided for @refreshDashboardTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث لوحة التحكم'**
  String get refreshDashboardTooltip;

  /// No description provided for @dashboardLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل لوحة التحكم.'**
  String get dashboardLoadError;

  /// No description provided for @dashboardEmptyState.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مؤشرات متاحة لهذا المستخدم.'**
  String get dashboardEmptyState;

  /// No description provided for @dashboardNoWidgetData.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد بيانات لهذا المؤشر.'**
  String get dashboardNoWidgetData;

  /// Shows dashboard last refresh time.
  ///
  /// In ar, this message translates to:
  /// **'آخر تحديث: {value}'**
  String dashboardLastUpdated(String value);

  /// No description provided for @dashboardLastUpdatedUnknown.
  ///
  /// In ar, this message translates to:
  /// **'آخر تحديث غير معروف'**
  String get dashboardLastUpdatedUnknown;

  /// No description provided for @dashboardRange7Days.
  ///
  /// In ar, this message translates to:
  /// **'٧ أيام'**
  String get dashboardRange7Days;

  /// No description provided for @dashboardRange30Days.
  ///
  /// In ar, this message translates to:
  /// **'٣٠ يومًا'**
  String get dashboardRange30Days;

  /// No description provided for @dashboardRange90Days.
  ///
  /// In ar, this message translates to:
  /// **'٩٠ يومًا'**
  String get dashboardRange90Days;

  /// No description provided for @dashboardSalesSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'المبيعات'**
  String get dashboardSalesSectionTitle;

  /// No description provided for @dashboardPaymentsSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'المدفوعات'**
  String get dashboardPaymentsSectionTitle;

  /// No description provided for @dashboardInventorySectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'المخزون'**
  String get dashboardInventorySectionTitle;

  /// No description provided for @dashboardPurchasingSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'المشتريات'**
  String get dashboardPurchasingSectionTitle;

  /// No description provided for @dashboardCustomersSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'العملاء'**
  String get dashboardCustomersSectionTitle;

  /// No description provided for @dashboardDiscountsSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'الخصومات'**
  String get dashboardDiscountsSectionTitle;

  /// No description provided for @dashboardPrintingSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'الطباعة'**
  String get dashboardPrintingSectionTitle;

  /// No description provided for @dashboardNetSalesMetric.
  ///
  /// In ar, this message translates to:
  /// **'صافي المبيعات'**
  String get dashboardNetSalesMetric;

  /// No description provided for @dashboardGrossProfitMetric.
  ///
  /// In ar, this message translates to:
  /// **'الربح الإجمالي'**
  String get dashboardGrossProfitMetric;

  /// No description provided for @dashboardProfitMarginMetric.
  ///
  /// In ar, this message translates to:
  /// **'هامش الربح'**
  String get dashboardProfitMarginMetric;

  /// No description provided for @dashboardOrdersMetric.
  ///
  /// In ar, this message translates to:
  /// **'الطلبات'**
  String get dashboardOrdersMetric;

  /// No description provided for @dashboardAverageOrderMetric.
  ///
  /// In ar, this message translates to:
  /// **'متوسط الطلب'**
  String get dashboardAverageOrderMetric;

  /// No description provided for @dashboardItemsSoldMetric.
  ///
  /// In ar, this message translates to:
  /// **'القطع المباعة'**
  String get dashboardItemsSoldMetric;

  /// No description provided for @dashboardDiscountsMetric.
  ///
  /// In ar, this message translates to:
  /// **'الخصومات'**
  String get dashboardDiscountsMetric;

  /// No description provided for @dashboardRefundsMetric.
  ///
  /// In ar, this message translates to:
  /// **'المرتجعات'**
  String get dashboardRefundsMetric;

  /// Void and return counts for sales adjustments.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء {voids}، إرجاع {returns}'**
  String dashboardAdjustmentsDetail(int voids, int returns);

  /// No description provided for @dashboardSalesTrendTitle.
  ///
  /// In ar, this message translates to:
  /// **'اتجاه صافي المبيعات'**
  String get dashboardSalesTrendTitle;

  /// No description provided for @dashboardHourlySalesTitle.
  ///
  /// In ar, this message translates to:
  /// **'المبيعات حسب الساعة'**
  String get dashboardHourlySalesTitle;

  /// No description provided for @dashboardTopProductsTitle.
  ///
  /// In ar, this message translates to:
  /// **'أفضل المنتجات'**
  String get dashboardTopProductsTitle;

  /// No description provided for @dashboardTopCategoriesTitle.
  ///
  /// In ar, this message translates to:
  /// **'أفضل التصنيفات'**
  String get dashboardTopCategoriesTitle;

  /// No description provided for @dashboardRecentOrdersTitle.
  ///
  /// In ar, this message translates to:
  /// **'آخر الطلبات'**
  String get dashboardRecentOrdersTitle;

  /// No description provided for @dashboardRegistersTitle.
  ///
  /// In ar, this message translates to:
  /// **'جلسات الدرج'**
  String get dashboardRegistersTitle;

  /// No description provided for @dashboardOpenRegistersLabel.
  ///
  /// In ar, this message translates to:
  /// **'جلسات مفتوحة'**
  String get dashboardOpenRegistersLabel;

  /// No description provided for @dashboardClosedRegistersLabel.
  ///
  /// In ar, this message translates to:
  /// **'جلسات مغلقة'**
  String get dashboardClosedRegistersLabel;

  /// No description provided for @dashboardVarianceRegistersLabel.
  ///
  /// In ar, this message translates to:
  /// **'فروقات نقدية'**
  String get dashboardVarianceRegistersLabel;

  /// No description provided for @dashboardPaymentsTotalMetric.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي المدفوعات'**
  String get dashboardPaymentsTotalMetric;

  /// No description provided for @dashboardPaymentCountMetric.
  ///
  /// In ar, this message translates to:
  /// **'عدد المدفوعات'**
  String get dashboardPaymentCountMetric;

  /// No description provided for @dashboardCommissionMetric.
  ///
  /// In ar, this message translates to:
  /// **'العمولات'**
  String get dashboardCommissionMetric;

  /// No description provided for @dashboardPaymentMixTitle.
  ///
  /// In ar, this message translates to:
  /// **'توزيع طرق الدفع'**
  String get dashboardPaymentMixTitle;

  /// No description provided for @dashboardPaymentMethodsTitle.
  ///
  /// In ar, this message translates to:
  /// **'طرق الدفع'**
  String get dashboardPaymentMethodsTitle;

  /// Payment count for a payment method.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا مدفوعات} =1{دفعة واحدة} =2{دفعتان} other{{count} دفعات}}'**
  String dashboardPaymentMethodCount(int count);

  /// No description provided for @dashboardProductsMetric.
  ///
  /// In ar, this message translates to:
  /// **'المنتجات'**
  String get dashboardProductsMetric;

  /// No description provided for @dashboardLowStockMetric.
  ///
  /// In ar, this message translates to:
  /// **'مخزون منخفض'**
  String get dashboardLowStockMetric;

  /// No description provided for @dashboardOutOfStockMetric.
  ///
  /// In ar, this message translates to:
  /// **'نافد'**
  String get dashboardOutOfStockMetric;

  /// No description provided for @dashboardRetailStockValueMetric.
  ///
  /// In ar, this message translates to:
  /// **'قيمة المخزون بسعر البيع'**
  String get dashboardRetailStockValueMetric;

  /// No description provided for @dashboardCommittedUnitsMetric.
  ///
  /// In ar, this message translates to:
  /// **'محجوز'**
  String get dashboardCommittedUnitsMetric;

  /// No description provided for @dashboardExpectedUnitsMetric.
  ///
  /// In ar, this message translates to:
  /// **'متوقع'**
  String get dashboardExpectedUnitsMetric;

  /// No description provided for @dashboardLowStockTitle.
  ///
  /// In ar, this message translates to:
  /// **'تنبيهات المخزون المنخفض'**
  String get dashboardLowStockTitle;

  /// No description provided for @dashboardDustyInventoryTitle.
  ///
  /// In ar, this message translates to:
  /// **'مخزون راكد'**
  String get dashboardDustyInventoryTitle;

  /// No description provided for @dashboardStockMovementMixTitle.
  ///
  /// In ar, this message translates to:
  /// **'حركات المخزون'**
  String get dashboardStockMovementMixTitle;

  /// No description provided for @dashboardRecentStockMovementsTitle.
  ///
  /// In ar, this message translates to:
  /// **'آخر حركات المخزون'**
  String get dashboardRecentStockMovementsTitle;

  /// Stock item secondary information.
  ///
  /// In ar, this message translates to:
  /// **'{sku}، حد الطلب {reorderLevel}، المتوقع {expected}'**
  String dashboardStockItemSubtitle(String sku, int reorderLevel, int expected);

  /// No description provided for @dashboardPurchasesMetric.
  ///
  /// In ar, this message translates to:
  /// **'قيمة المشتريات'**
  String get dashboardPurchasesMetric;

  /// No description provided for @dashboardDueToSuppliersMetric.
  ///
  /// In ar, this message translates to:
  /// **'مستحق للموردين'**
  String get dashboardDueToSuppliersMetric;

  /// No description provided for @dashboardOpenPurchasesMetric.
  ///
  /// In ar, this message translates to:
  /// **'أوامر مفتوحة'**
  String get dashboardOpenPurchasesMetric;

  /// No description provided for @dashboardOverduePurchasesMetric.
  ///
  /// In ar, this message translates to:
  /// **'متأخرة'**
  String get dashboardOverduePurchasesMetric;

  /// No description provided for @dashboardPurchaseStatusTitle.
  ///
  /// In ar, this message translates to:
  /// **'حالات أوامر الشراء'**
  String get dashboardPurchaseStatusTitle;

  /// No description provided for @dashboardOverduePurchasesTitle.
  ///
  /// In ar, this message translates to:
  /// **'مشتريات متأخرة'**
  String get dashboardOverduePurchasesTitle;

  /// No description provided for @dashboardSupplierBalancesTitle.
  ///
  /// In ar, this message translates to:
  /// **'أرصدة الموردين'**
  String get dashboardSupplierBalancesTitle;

  /// No description provided for @dashboardActiveCustomersMetric.
  ///
  /// In ar, this message translates to:
  /// **'عملاء نشطون'**
  String get dashboardActiveCustomersMetric;

  /// No description provided for @dashboardNewCustomersMetric.
  ///
  /// In ar, this message translates to:
  /// **'عملاء جدد'**
  String get dashboardNewCustomersMetric;

  /// No description provided for @dashboardCustomersWithSalesMetric.
  ///
  /// In ar, this message translates to:
  /// **'عملاء اشتروا'**
  String get dashboardCustomersWithSalesMetric;

  /// No description provided for @dashboardRepeatCustomersMetric.
  ///
  /// In ar, this message translates to:
  /// **'عملاء متكررون'**
  String get dashboardRepeatCustomersMetric;

  /// No description provided for @dashboardMarketingConsentMetric.
  ///
  /// In ar, this message translates to:
  /// **'موافقات تسويقية'**
  String get dashboardMarketingConsentMetric;

  /// No description provided for @dashboardTopCustomersTitle.
  ///
  /// In ar, this message translates to:
  /// **'أفضل العملاء'**
  String get dashboardTopCustomersTitle;

  /// No description provided for @dashboardRecentCustomersTitle.
  ///
  /// In ar, this message translates to:
  /// **'عملاء مضافون حديثًا'**
  String get dashboardRecentCustomersTitle;

  /// No description provided for @dashboardActiveDiscountsMetric.
  ///
  /// In ar, this message translates to:
  /// **'خصومات نشطة'**
  String get dashboardActiveDiscountsMetric;

  /// No description provided for @dashboardCouponDiscountsMetric.
  ///
  /// In ar, this message translates to:
  /// **'كوبونات'**
  String get dashboardCouponDiscountsMetric;

  /// No description provided for @dashboardRedemptionsMetric.
  ///
  /// In ar, this message translates to:
  /// **'استخدامات الخصم'**
  String get dashboardRedemptionsMetric;

  /// No description provided for @dashboardSalesDiscountMetric.
  ///
  /// In ar, this message translates to:
  /// **'خصومات المبيعات'**
  String get dashboardSalesDiscountMetric;

  /// No description provided for @dashboardPurchaseDiscountMetric.
  ///
  /// In ar, this message translates to:
  /// **'خصومات المشتريات'**
  String get dashboardPurchaseDiscountMetric;

  /// No description provided for @dashboardTopDiscountsTitle.
  ///
  /// In ar, this message translates to:
  /// **'أكثر الخصومات استخدامًا'**
  String get dashboardTopDiscountsTitle;

  /// No description provided for @dashboardExpiringDiscountsTitle.
  ///
  /// In ar, this message translates to:
  /// **'خصومات تنتهي قريبًا'**
  String get dashboardExpiringDiscountsTitle;

  /// No description provided for @dashboardQueuedPrintJobsMetric.
  ///
  /// In ar, this message translates to:
  /// **'طباعة في الانتظار'**
  String get dashboardQueuedPrintJobsMetric;

  /// No description provided for @dashboardClaimedPrintJobsMetric.
  ///
  /// In ar, this message translates to:
  /// **'طباعة قيد التنفيذ'**
  String get dashboardClaimedPrintJobsMetric;

  /// No description provided for @dashboardFailedPrintJobsMetric.
  ///
  /// In ar, this message translates to:
  /// **'فشل الطباعة'**
  String get dashboardFailedPrintJobsMetric;

  /// No description provided for @dashboardActivePrintAgentsMetric.
  ///
  /// In ar, this message translates to:
  /// **'وكلاء نشطون'**
  String get dashboardActivePrintAgentsMetric;

  /// No description provided for @dashboardStalePrintAgentsMetric.
  ///
  /// In ar, this message translates to:
  /// **'وكلاء غير متصلين'**
  String get dashboardStalePrintAgentsMetric;

  /// No description provided for @dashboardPrintStatusTitle.
  ///
  /// In ar, this message translates to:
  /// **'حالات الطباعة'**
  String get dashboardPrintStatusTitle;

  /// No description provided for @dashboardPrintFailuresTitle.
  ///
  /// In ar, this message translates to:
  /// **'أخطاء الطباعة'**
  String get dashboardPrintFailuresTitle;

  /// No description provided for @dashboardPrintStatusQueued.
  ///
  /// In ar, this message translates to:
  /// **'بالانتظار'**
  String get dashboardPrintStatusQueued;

  /// No description provided for @dashboardPrintStatusClaimed.
  ///
  /// In ar, this message translates to:
  /// **'قيد التنفيذ'**
  String get dashboardPrintStatusClaimed;

  /// No description provided for @dashboardPrintStatusPrinted.
  ///
  /// In ar, this message translates to:
  /// **'مطبوعة'**
  String get dashboardPrintStatusPrinted;

  /// No description provided for @dashboardPrintStatusFailed.
  ///
  /// In ar, this message translates to:
  /// **'فاشلة'**
  String get dashboardPrintStatusFailed;

  /// No description provided for @dashboardPrintStatusCanceled.
  ///
  /// In ar, this message translates to:
  /// **'ملغاة'**
  String get dashboardPrintStatusCanceled;

  /// No description provided for @dashboardOrderStatusOpen.
  ///
  /// In ar, this message translates to:
  /// **'مفتوح'**
  String get dashboardOrderStatusOpen;

  /// No description provided for @dashboardOrderStatusPaid.
  ///
  /// In ar, this message translates to:
  /// **'مدفوع'**
  String get dashboardOrderStatusPaid;

  /// No description provided for @dashboardOrderStatusVoid.
  ///
  /// In ar, this message translates to:
  /// **'ملغى'**
  String get dashboardOrderStatusVoid;

  /// No description provided for @dashboardUncategorizedLabel.
  ///
  /// In ar, this message translates to:
  /// **'غير مصنف'**
  String get dashboardUncategorizedLabel;

  /// No description provided for @dashboardAnonymousCustomerLabel.
  ///
  /// In ar, this message translates to:
  /// **'عميل غير محدد'**
  String get dashboardAnonymousCustomerLabel;

  /// Quantity and SKU label.
  ///
  /// In ar, this message translates to:
  /// **'{quantity} قطعة، {sku}'**
  String dashboardQuantityWithSku(int quantity, String sku);

  /// Quantity-only dashboard label.
  ///
  /// In ar, this message translates to:
  /// **'{quantity} قطعة'**
  String dashboardQuantityOnly(int quantity);

  /// No description provided for @smartNotificationsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'التنبيهات الذكية'**
  String get smartNotificationsTooltip;

  /// Notification bell tooltip with active alert count.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{التنبيهات الذكية} =1{تنبيه ذكي واحد} =2{تنبيهان ذكيان} other{{count} تنبيهات ذكية}}'**
  String smartNotificationsTooltipWithCount(num count);

  /// No description provided for @smartNotificationsTitle.
  ///
  /// In ar, this message translates to:
  /// **'التنبيهات الذكية'**
  String get smartNotificationsTitle;

  /// Active smart notification count.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد تنبيهات نشطة} =1{تنبيه نشط واحد} =2{تنبيهان نشطان} other{{count} تنبيهات نشطة}}'**
  String smartNotificationsActiveCount(num count);

  /// Smart notification last refresh time.
  ///
  /// In ar, this message translates to:
  /// **'آخر فحص: {value}'**
  String smartNotificationsLastUpdated(String value);

  /// No description provided for @smartNotificationsRefreshTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث التنبيهات'**
  String get smartNotificationsRefreshTooltip;

  /// No description provided for @smartNotificationsRestoreTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إظهار التنبيهات المخفية'**
  String get smartNotificationsRestoreTooltip;

  /// No description provided for @smartNotificationsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل التنبيهات الذكية.'**
  String get smartNotificationsLoadError;

  /// No description provided for @smartNotificationsEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'الأمور المهمة تحت السيطرة'**
  String get smartNotificationsEmptyTitle;

  /// No description provided for @smartNotificationsEmptyMessage.
  ///
  /// In ar, this message translates to:
  /// **'سنظهر هنا فقط ما يحتاج انتباهًا فعليًا.'**
  String get smartNotificationsEmptyMessage;

  /// No description provided for @smartNotificationsHiddenOnlyTitle.
  ///
  /// In ar, this message translates to:
  /// **'كل التنبيهات الحالية مخفية'**
  String get smartNotificationsHiddenOnlyTitle;

  /// No description provided for @smartNotificationsHiddenOnlyMessage.
  ///
  /// In ar, this message translates to:
  /// **'يمكنك إظهارها مرة أخرى إذا أردت مراجعتها.'**
  String get smartNotificationsHiddenOnlyMessage;

  /// No description provided for @smartNotificationsRestoreHiddenButton.
  ///
  /// In ar, this message translates to:
  /// **'إظهار المخفية'**
  String get smartNotificationsRestoreHiddenButton;

  /// No description provided for @smartNotificationsDismissAllButton.
  ///
  /// In ar, this message translates to:
  /// **'إخفاء التنبيهات الحالية'**
  String get smartNotificationsDismissAllButton;

  /// No description provided for @smartNotificationDismissTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إخفاء التنبيه'**
  String get smartNotificationDismissTooltip;

  /// No description provided for @smartNotificationSnoozeAction.
  ///
  /// In ar, this message translates to:
  /// **'تأجيل ٤ ساعات'**
  String get smartNotificationSnoozeAction;

  /// No description provided for @smartNotificationReviewAction.
  ///
  /// In ar, this message translates to:
  /// **'مراجعة'**
  String get smartNotificationReviewAction;

  /// No description provided for @smartNotificationSeverityCritical.
  ///
  /// In ar, this message translates to:
  /// **'حرج'**
  String get smartNotificationSeverityCritical;

  /// No description provided for @smartNotificationSeverityWarning.
  ///
  /// In ar, this message translates to:
  /// **'مهم'**
  String get smartNotificationSeverityWarning;

  /// No description provided for @smartNotificationSeverityInfo.
  ///
  /// In ar, this message translates to:
  /// **'متابعة'**
  String get smartNotificationSeverityInfo;

  /// No description provided for @smartNotificationCategoryInventory.
  ///
  /// In ar, this message translates to:
  /// **'المخزون'**
  String get smartNotificationCategoryInventory;

  /// No description provided for @smartNotificationCategoryPurchasing.
  ///
  /// In ar, this message translates to:
  /// **'المشتريات'**
  String get smartNotificationCategoryPurchasing;

  /// No description provided for @smartNotificationCategoryPrinting.
  ///
  /// In ar, this message translates to:
  /// **'الطباعة'**
  String get smartNotificationCategoryPrinting;

  /// No description provided for @smartNotificationCategorySales.
  ///
  /// In ar, this message translates to:
  /// **'المبيعات'**
  String get smartNotificationCategorySales;

  /// No description provided for @smartNotificationCategoryFraud.
  ///
  /// In ar, this message translates to:
  /// **'مراجعة الاشتباه'**
  String get smartNotificationCategoryFraud;

  /// No description provided for @smartNotificationCategoryDiscounts.
  ///
  /// In ar, this message translates to:
  /// **'الخصومات'**
  String get smartNotificationCategoryDiscounts;

  /// No description provided for @smartNotificationCategoryOperations.
  ///
  /// In ar, this message translates to:
  /// **'التشغيل'**
  String get smartNotificationCategoryOperations;

  /// No description provided for @smartNotificationOutOfStockTitle.
  ///
  /// In ar, this message translates to:
  /// **'منتجات نافدة تحتاج إجراء'**
  String get smartNotificationOutOfStockTitle;

  /// Out-of-stock alert message.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{منتج واحد غير متاح للبيع الآن.} =2{منتجان غير متاحين للبيع الآن.} other{{count} منتجات غير متاحة للبيع الآن.}}'**
  String smartNotificationOutOfStockMessage(num count);

  /// No description provided for @smartNotificationLowStockTitle.
  ///
  /// In ar, this message translates to:
  /// **'مخزون منخفض'**
  String get smartNotificationLowStockTitle;

  /// Low stock alert message.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{منتج واحد وصل إلى حد إعادة الطلب.} =2{منتجان وصلا إلى حد إعادة الطلب.} other{{count} منتجات وصلت إلى حد إعادة الطلب.}}'**
  String smartNotificationLowStockMessage(num count);

  /// No description provided for @smartNotificationExpiringStockTitle.
  ///
  /// In ar, this message translates to:
  /// **'مخزون يقترب من الانتهاء'**
  String get smartNotificationExpiringStockTitle;

  /// Expiring stock batch alert message.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{دفعة مخزون واحدة تحتاج متابعة خلال {days} يوم.} =2{دفعتا مخزون تحتاجان متابعة، أقربهما خلال {days} يوم.} other{{count} دفعات مخزون تحتاج متابعة، أقربها خلال {days} يوم.}}'**
  String smartNotificationExpiringStockMessage(num count, int days);

  /// Stock alert detail.
  ///
  /// In ar, this message translates to:
  /// **'{name}: المتاح {quantity}، حد الطلب {threshold}'**
  String smartNotificationStockDetail(String name, int quantity, int threshold);

  /// Expiring stock detail without source context.
  ///
  /// In ar, this message translates to:
  /// **'{name}: المتبقي {quantity}، تاريخ الانتهاء {date}'**
  String smartNotificationExpiringStockDetailBasic(
    String name,
    int quantity,
    String date,
  );

  /// Expiring stock detail with source context.
  ///
  /// In ar, this message translates to:
  /// **'{name}: المتبقي {quantity}، تاريخ الانتهاء {date}، المرجع {context}'**
  String smartNotificationExpiringStockDetail(
    String name,
    int quantity,
    String date,
    String context,
  );

  /// No description provided for @smartNotificationDustyInventoryTitle.
  ///
  /// In ar, this message translates to:
  /// **'مخزون راكد يحتاج مراجعة'**
  String get smartNotificationDustyInventoryTitle;

  /// Dusty inventory alert message.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{منتج واحد متوفر ولم يتحرك خلال الفترة.} =2{منتجان متوفران ولم يتحركا خلال الفترة.} other{{count} منتجات متوفرة ولم تتحرك خلال الفترة.}}'**
  String smartNotificationDustyInventoryMessage(num count);

  /// Dusty inventory detail.
  ///
  /// In ar, this message translates to:
  /// **'{name}: {quantity} قطعة متاحة'**
  String smartNotificationDustyInventoryDetail(String name, int quantity);

  /// No description provided for @smartNotificationOverduePurchasesTitle.
  ///
  /// In ar, this message translates to:
  /// **'مستحقات شراء متأخرة'**
  String get smartNotificationOverduePurchasesTitle;

  /// Overdue purchase alert message.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{أمر شراء واحد متأخر بقيمة {amount}.} =2{أمرا شراء متأخران، أقرب رصيد {amount}.} other{{count} أوامر شراء متأخرة، أقرب رصيد {amount}.}}'**
  String smartNotificationOverduePurchasesMessage(num count, String amount);

  /// Overdue purchase detail.
  ///
  /// In ar, this message translates to:
  /// **'{order} لدى {supplier}'**
  String smartNotificationOverduePurchaseDetail(String order, String supplier);

  /// No description provided for @smartNotificationPrintFailuresTitle.
  ///
  /// In ar, this message translates to:
  /// **'فشل في الطباعة'**
  String get smartNotificationPrintFailuresTitle;

  /// Print failure alert message.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{مهمة طباعة واحدة فشلت وتحتاج متابعة.} =2{مهمتا طباعة فشلتا وتحتاجان متابعة.} other{{count} مهام طباعة فشلت وتحتاج متابعة.}}'**
  String smartNotificationPrintFailuresMessage(num count);

  /// No description provided for @smartNotificationStalePrintAgentsTitle.
  ///
  /// In ar, this message translates to:
  /// **'وكلاء طباعة غير متصلين'**
  String get smartNotificationStalePrintAgentsTitle;

  /// Stale print agents alert message.
  ///
  /// In ar, this message translates to:
  /// **'{agents, plural, =1{وكيل طباعة واحد غير متصل، و{queued} مهمة في الانتظار.} =2{وكيلا طباعة غير متصلين، و{queued} مهمة في الانتظار.} other{{agents} وكلاء طباعة غير متصلين، و{queued} مهمة في الانتظار.}}'**
  String smartNotificationStalePrintAgentsMessage(num agents, int queued);

  /// No description provided for @smartNotificationSuspectedActivityTitle.
  ///
  /// In ar, this message translates to:
  /// **'نشاط مشتبه يحتاج مراجعة'**
  String get smartNotificationSuspectedActivityTitle;

  /// Suspected cashier activity alert message.
  ///
  /// In ar, this message translates to:
  /// **'النظام لاحظ نمطًا مشتبهًا لدى {user} بدرجة {score}. هذه مراجعة أولية وليست حكمًا نهائيًا.'**
  String smartNotificationSuspectedActivityMessage(String user, int score);

  /// No description provided for @smartNotificationRegisterVarianceTitle.
  ///
  /// In ar, this message translates to:
  /// **'فروقات نقدية في الدرج'**
  String get smartNotificationRegisterVarianceTitle;

  /// Register cash variance alert message.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{جلسة درج واحدة فيها فرق نقدي بقيمة {amount}.} =2{جلستا درج فيهما فرق نقدي، الإجمالي {amount}.} other{{count} جلسات درج فيها فرق نقدي، الإجمالي {amount}.}}'**
  String smartNotificationRegisterVarianceMessage(num count, String amount);

  /// No description provided for @smartNotificationSalesDropTitle.
  ///
  /// In ar, this message translates to:
  /// **'انخفاض واضح في المبيعات'**
  String get smartNotificationSalesDropTitle;

  /// Sales drop alert message.
  ///
  /// In ar, this message translates to:
  /// **'صافي المبيعات أقل بنسبة {percent}% خلال آخر {days} يومًا مقارنة بالفترة السابقة.'**
  String smartNotificationSalesDropMessage(int days, String percent);

  /// No description provided for @smartNotificationLowProfitMarginTitle.
  ///
  /// In ar, this message translates to:
  /// **'بيع بهامش سلبي'**
  String get smartNotificationLowProfitMarginTitle;

  /// Negative margin alert message.
  ///
  /// In ar, this message translates to:
  /// **'الهامش سلبي بنسبة {percent}%، والفرق التقريبي {amount}.'**
  String smartNotificationLowProfitMarginMessage(String percent, String amount);

  /// No description provided for @smartNotificationExpiringDiscountsTitle.
  ///
  /// In ar, this message translates to:
  /// **'خصومات تنتهي قريبًا'**
  String get smartNotificationExpiringDiscountsTitle;

  /// Expiring discounts alert message.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{خصم واحد ينتهي خلال {days} يوم.} =2{خصمان ينتهيان قريبًا، أقربهما خلال {days} يوم.} other{{count} خصومات تنتهي قريبًا، أقربها خلال {days} يوم.}}'**
  String smartNotificationExpiringDiscountsMessage(num count, int days);

  /// Expiring discount detail.
  ///
  /// In ar, this message translates to:
  /// **'{name}'**
  String smartNotificationDiscountDetail(String name);

  /// No description provided for @smartNotificationOperationsErrorTitle.
  ///
  /// In ar, this message translates to:
  /// **'خطأ تشغيلي يحتاج متابعة'**
  String get smartNotificationOperationsErrorTitle;

  /// Operational backend/frontend error alert message.
  ///
  /// In ar, this message translates to:
  /// **'{name} من {source}'**
  String smartNotificationOperationsErrorMessage(String name, String source);

  /// No description provided for @smartNotificationUnknownTitle.
  ///
  /// In ar, this message translates to:
  /// **'تنبيه جديد'**
  String get smartNotificationUnknownTitle;

  /// No description provided for @smartNotificationUnknownMessage.
  ///
  /// In ar, this message translates to:
  /// **'يوجد تنبيه يحتاج مراجعة.'**
  String get smartNotificationUnknownMessage;

  /// Order count label.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا طلبات} =1{طلب واحد} =2{طلبان} other{{count} طلبات}}'**
  String dashboardOrderCount(int count);

  /// No description provided for @stockMovementExpected.
  ///
  /// In ar, this message translates to:
  /// **'متوقع'**
  String get stockMovementExpected;

  /// No description provided for @stockMovementReceiveExpected.
  ///
  /// In ar, this message translates to:
  /// **'استلام المتوقع'**
  String get stockMovementReceiveExpected;

  /// No description provided for @stockMovementReceiveDamaged.
  ///
  /// In ar, this message translates to:
  /// **'استلام تالف'**
  String get stockMovementReceiveDamaged;

  /// No description provided for @stockMovementCancelExpected.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء المتوقع'**
  String get stockMovementCancelExpected;

  /// No description provided for @logoutButton.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الخروج'**
  String get logoutButton;

  /// No description provided for @unauthorizedTitle.
  ///
  /// In ar, this message translates to:
  /// **'غير مصرح'**
  String get unauthorizedTitle;

  /// No description provided for @unauthorizedMessage.
  ///
  /// In ar, this message translates to:
  /// **'لا يملك هذا المستخدم صلاحية الوصول إلى هذه الشاشة.'**
  String get unauthorizedMessage;

  /// No description provided for @authCheckingSession.
  ///
  /// In ar, this message translates to:
  /// **'جار فحص الجلسة...'**
  String get authCheckingSession;

  /// No description provided for @loginTitle.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الدخول'**
  String get loginTitle;

  /// No description provided for @usernameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم المستخدم'**
  String get usernameLabel;

  /// No description provided for @passwordLabel.
  ///
  /// In ar, this message translates to:
  /// **'كلمة المرور'**
  String get passwordLabel;

  /// No description provided for @loginButton.
  ///
  /// In ar, this message translates to:
  /// **'دخول'**
  String get loginButton;

  /// No description provided for @loggingInButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الدخول...'**
  String get loggingInButton;

  /// No description provided for @loginError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تسجيل الدخول. تحقق من اسم المستخدم وكلمة المرور.'**
  String get loginError;

  /// No description provided for @managerRoleLabel.
  ///
  /// In ar, this message translates to:
  /// **'مدير'**
  String get managerRoleLabel;

  /// No description provided for @cashierRoleLabel.
  ///
  /// In ar, this message translates to:
  /// **'كاشير'**
  String get cashierRoleLabel;

  /// No description provided for @usersManagementTitle.
  ///
  /// In ar, this message translates to:
  /// **'إدارة المستخدمين'**
  String get usersManagementTitle;

  /// No description provided for @refreshUsersTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث المستخدمين'**
  String get refreshUsersTooltip;

  /// No description provided for @addUserButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة مستخدم'**
  String get addUserButton;

  /// No description provided for @userCreateTitle.
  ///
  /// In ar, this message translates to:
  /// **'مستخدم جديد'**
  String get userCreateTitle;

  /// No description provided for @displayNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'الاسم المعروض'**
  String get displayNameLabel;

  /// No description provided for @emailLabel.
  ///
  /// In ar, this message translates to:
  /// **'البريد الإلكتروني'**
  String get emailLabel;

  /// No description provided for @roleLabel.
  ///
  /// In ar, this message translates to:
  /// **'الدور'**
  String get roleLabel;

  /// No description provided for @activeUserLabel.
  ///
  /// In ar, this message translates to:
  /// **'مستخدم نشط'**
  String get activeUserLabel;

  /// No description provided for @createUserButton.
  ///
  /// In ar, this message translates to:
  /// **'إنشاء المستخدم'**
  String get createUserButton;

  /// No description provided for @createUserError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إنشاء المستخدم. راجع البيانات وحاول مرة أخرى.'**
  String get createUserError;

  /// No description provided for @usersLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل المستخدمين.'**
  String get usersLoadError;

  /// No description provided for @emptyUsers.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد مستخدمون بعد.'**
  String get emptyUsers;

  /// No description provided for @userStatusActive.
  ///
  /// In ar, this message translates to:
  /// **'نشط'**
  String get userStatusActive;

  /// No description provided for @userStatusInactive.
  ///
  /// In ar, this message translates to:
  /// **'متوقف'**
  String get userStatusInactive;

  /// No description provided for @userDetailsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'عرض تفاصيل المستخدم'**
  String get userDetailsTooltip;

  /// User details screen title.
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل {user}'**
  String userDetailsTitle(String user);

  /// No description provided for @refreshUserDetailsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث تفاصيل المستخدم'**
  String get refreshUserDetailsTooltip;

  /// No description provided for @userActivityLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل نشاط المستخدم.'**
  String get userActivityLoadError;

  /// No description provided for @userDetailsOverviewTitle.
  ///
  /// In ar, this message translates to:
  /// **'ملخص المستخدم'**
  String get userDetailsOverviewTitle;

  /// No description provided for @userDetailsRecentSalesTitle.
  ///
  /// In ar, this message translates to:
  /// **'آخر فواتير العملاء'**
  String get userDetailsRecentSalesTitle;

  /// No description provided for @userDetailsRecentPurchasesTitle.
  ///
  /// In ar, this message translates to:
  /// **'آخر فواتير الموردين'**
  String get userDetailsRecentPurchasesTitle;

  /// No description provided for @userDetailsRecentSessionsTitle.
  ///
  /// In ar, this message translates to:
  /// **'آخر جلسات الدرج'**
  String get userDetailsRecentSessionsTitle;

  /// No description provided for @userDetailsRecentActivityTitle.
  ///
  /// In ar, this message translates to:
  /// **'آخر النشاطات'**
  String get userDetailsRecentActivityTitle;

  /// No description provided for @userActivityNetSalesMetric.
  ///
  /// In ar, this message translates to:
  /// **'صافي المبيعات'**
  String get userActivityNetSalesMetric;

  /// No description provided for @userActivityCustomersMetric.
  ///
  /// In ar, this message translates to:
  /// **'العملاء'**
  String get userActivityCustomersMetric;

  /// No description provided for @userActivityPurchaseTotalMetric.
  ///
  /// In ar, this message translates to:
  /// **'قيمة المشتريات'**
  String get userActivityPurchaseTotalMetric;

  /// No description provided for @userActivitySupplierPaymentsMetric.
  ///
  /// In ar, this message translates to:
  /// **'مدفوعات الموردين'**
  String get userActivitySupplierPaymentsMetric;

  /// No description provided for @userActivityRegisterSessionsMetric.
  ///
  /// In ar, this message translates to:
  /// **'جلسات الدرج'**
  String get userActivityRegisterSessionsMetric;

  /// No description provided for @userActivityCashMovementsMetric.
  ///
  /// In ar, this message translates to:
  /// **'صافي حركة النقد'**
  String get userActivityCashMovementsMetric;

  /// Invoice count detail for a user.
  ///
  /// In ar, this message translates to:
  /// **'{invoices} فواتير، {paid} مدفوعة'**
  String userActivityInvoicesDetail(int invoices, int paid);

  /// Return count and total detail for a user.
  ///
  /// In ar, this message translates to:
  /// **'{count} إرجاع، {amount}'**
  String userActivityReturnsDetail(int count, String amount);

  /// Supplier invoice and purchase order count detail for a user.
  ///
  /// In ar, this message translates to:
  /// **'{invoices} فواتير موردين، {orders} أوامر'**
  String userActivitySupplierInvoicesDetail(int invoices, int orders);

  /// Supplier payment and refund count detail for a user.
  ///
  /// In ar, this message translates to:
  /// **'{payments} دفعات، {refunds} استرداد'**
  String userActivitySupplierPaymentsDetail(int payments, int refunds);

  /// Open and closed register session count detail for a user.
  ///
  /// In ar, this message translates to:
  /// **'{open} مفتوحة، {closed} مغلقة'**
  String userActivityRegisterSessionsDetail(int open, int closed);

  /// Pay in and pay out totals for a user.
  ///
  /// In ar, this message translates to:
  /// **'إيداع {payIn}، سحب {payOut}'**
  String userActivityCashMovementsDetail(String payIn, String payOut);

  /// No description provided for @userActivityEmptyRecentSales.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد فواتير عملاء لهذا المستخدم.'**
  String get userActivityEmptyRecentSales;

  /// No description provided for @userActivityEmptyRecentPurchases.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد فواتير موردين لهذا المستخدم.'**
  String get userActivityEmptyRecentPurchases;

  /// No description provided for @userActivityEmptyRecentSessions.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد جلسات درج لهذا المستخدم.'**
  String get userActivityEmptyRecentSessions;

  /// No description provided for @userActivityEmptyRecentActivity.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد نشاط مسجل لهذا المستخدم.'**
  String get userActivityEmptyRecentActivity;

  /// Fallback receipt title.
  ///
  /// In ar, this message translates to:
  /// **'فاتورة #{id}'**
  String userActivityReceiptFallback(int id);

  /// Fallback purchase order title.
  ///
  /// In ar, this message translates to:
  /// **'أمر شراء #{id}'**
  String userActivityPurchaseFallback(int id);

  /// Fallback register session title.
  ///
  /// In ar, this message translates to:
  /// **'جلسة درج #{id}'**
  String userActivitySessionFallback(int id);

  /// No description provided for @userActivityEventLogin.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل دخول ناجح'**
  String get userActivityEventLogin;

  /// No description provided for @userActivityEventRegisterStarted.
  ///
  /// In ar, this message translates to:
  /// **'بدء جلسة درج'**
  String get userActivityEventRegisterStarted;

  /// No description provided for @userActivityEventRegisterClosed.
  ///
  /// In ar, this message translates to:
  /// **'إغلاق جلسة درج'**
  String get userActivityEventRegisterClosed;

  /// No description provided for @userActivityEventCashMovement.
  ///
  /// In ar, this message translates to:
  /// **'حركة نقدية في الدرج'**
  String get userActivityEventCashMovement;

  /// No description provided for @userActivityEventUserCreated.
  ///
  /// In ar, this message translates to:
  /// **'إنشاء مستخدم'**
  String get userActivityEventUserCreated;

  /// No description provided for @userActivityEventUserUpdated.
  ///
  /// In ar, this message translates to:
  /// **'تعديل مستخدم'**
  String get userActivityEventUserUpdated;

  /// No description provided for @userActivityEventUserDeleted.
  ///
  /// In ar, this message translates to:
  /// **'حذف مستخدم'**
  String get userActivityEventUserDeleted;

  /// No description provided for @userActivityEventFallback.
  ///
  /// In ar, this message translates to:
  /// **'نشاط مسجل'**
  String get userActivityEventFallback;

  /// No description provided for @userActivityEventTypeSecurity.
  ///
  /// In ar, this message translates to:
  /// **'أمان'**
  String get userActivityEventTypeSecurity;

  /// No description provided for @userActivityEventTypeAudit.
  ///
  /// In ar, this message translates to:
  /// **'تدقيق'**
  String get userActivityEventTypeAudit;

  /// No description provided for @userActivityEventTypeError.
  ///
  /// In ar, this message translates to:
  /// **'خطأ'**
  String get userActivityEventTypeError;

  /// No description provided for @userActivityEventTypePerformance.
  ///
  /// In ar, this message translates to:
  /// **'أداء'**
  String get userActivityEventTypePerformance;

  /// No description provided for @userActivityEventTypeUsage.
  ///
  /// In ar, this message translates to:
  /// **'استخدام'**
  String get userActivityEventTypeUsage;

  /// No description provided for @shopSettingsTitle.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات المتجر'**
  String get shopSettingsTitle;

  /// No description provided for @refreshShopSettingsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث إعدادات المتجر'**
  String get refreshShopSettingsTooltip;

  /// No description provided for @shopSettingsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل إعدادات المتجر.'**
  String get shopSettingsLoadError;

  /// No description provided for @shopSettingsSaveError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ إعدادات المتجر. راجع البيانات وحاول مرة أخرى.'**
  String get shopSettingsSaveError;

  /// No description provided for @shopSettingsSavedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ إعدادات المتجر.'**
  String get shopSettingsSavedMessage;

  /// No description provided for @deviceSettingsTitle.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات الجهاز'**
  String get deviceSettingsTitle;

  /// No description provided for @refreshDeviceSettingsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث إعدادات الجهاز'**
  String get refreshDeviceSettingsTooltip;

  /// No description provided for @deviceSettingsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل إعدادات الجهاز المحلية.'**
  String get deviceSettingsLoadError;

  /// No description provided for @deviceSettingsSaveError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ إعدادات الجهاز المحلية.'**
  String get deviceSettingsSaveError;

  /// No description provided for @deviceUsageSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'استخدام الجهاز'**
  String get deviceUsageSectionTitle;

  /// No description provided for @deviceUsageSingleUserTitle.
  ///
  /// In ar, this message translates to:
  /// **'مستخدم واحد'**
  String get deviceUsageSingleUserTitle;

  /// No description provided for @deviceUsageSingleUserDescription.
  ///
  /// In ar, this message translates to:
  /// **'يفتح التطبيق بنفس الجلسة المحفوظة عند تشغيله مرة أخرى.'**
  String get deviceUsageSingleUserDescription;

  /// No description provided for @deviceUsageMultiUserTitle.
  ///
  /// In ar, this message translates to:
  /// **'عدة مستخدمين'**
  String get deviceUsageMultiUserTitle;

  /// No description provided for @deviceUsageMultiUserDescription.
  ///
  /// In ar, this message translates to:
  /// **'ينسى الجهاز المستخدم المسجل عند فتح التطبيق ويطلب تسجيل الدخول كل مرة.'**
  String get deviceUsageMultiUserDescription;

  /// No description provided for @devicePrinterSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'أدوار الطباعة'**
  String get devicePrinterSectionTitle;

  /// No description provided for @shopIdentitySectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'هوية المتجر'**
  String get shopIdentitySectionTitle;

  /// No description provided for @shopBehaviorSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'سلوك التطبيق'**
  String get shopBehaviorSectionTitle;

  /// No description provided for @receiptSettingsSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'الإيصالات'**
  String get receiptSettingsSectionTitle;

  /// No description provided for @registerSessionSettingsSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'جلسة الدرج'**
  String get registerSessionSettingsSectionTitle;

  /// No description provided for @paymentSettingsSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'طرق الدفع'**
  String get paymentSettingsSectionTitle;

  /// No description provided for @inventorySettingsSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'المخزون والربحية'**
  String get inventorySettingsSectionTitle;

  /// No description provided for @analyticsExportSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'تصدير التتبع'**
  String get analyticsExportSectionTitle;

  /// No description provided for @shopSettingsEmptyValue.
  ///
  /// In ar, this message translates to:
  /// **'غير محدد'**
  String get shopSettingsEmptyValue;

  /// No description provided for @shopSettingsEnabledValue.
  ///
  /// In ar, this message translates to:
  /// **'مفعل'**
  String get shopSettingsEnabledValue;

  /// No description provided for @shopSettingsDisabledValue.
  ///
  /// In ar, this message translates to:
  /// **'متوقف'**
  String get shopSettingsDisabledValue;

  /// Summary for shop identity settings.
  ///
  /// In ar, this message translates to:
  /// **'{shopName}، {logoStatus}'**
  String shopIdentitySummary(String shopName, String logoStatus);

  /// Summary for receipt settings in the shop settings index.
  ///
  /// In ar, this message translates to:
  /// **'الطباعة التلقائية: {status}'**
  String receiptSettingsSummary(String status);

  /// Summary for register session settings in the shop settings index.
  ///
  /// In ar, this message translates to:
  /// **'نقدية الافتتاح: {status}، صلاحية الكاشير للإرجاع: {window}'**
  String registerSessionSettingsSummary(String status, String window);

  /// Summary for inventory settings in the shop settings index.
  ///
  /// In ar, this message translates to:
  /// **'تنبيه عند {count} قطع أو أقل، البيع فوق المخزون: {oversellStatus}، منع الخسارة: {lossStatus}'**
  String inventorySettingsSummary(
    int count,
    String oversellStatus,
    String lossStatus,
  );

  /// Summary for payment settings in the shop settings index.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد طرق دفع مفعلة} =1{طريقة دفع واحدة مفعلة} =2{طريقتان مفعّلتان} other{{count} طرق دفع مفعلة}}، بطاقة {cardCommission}%، تحويل {transferCommission}%، إثبات البطاقة: {receiptStatus}، {terminalStatus}'**
  String paymentSettingsSummary(
    num count,
    String cardCommission,
    String transferCommission,
    String receiptStatus,
    String terminalStatus,
  );

  /// No description provided for @analyticsExportAllEventsSummary.
  ///
  /// In ar, this message translates to:
  /// **'كل أحداث التتبع'**
  String get analyticsExportAllEventsSummary;

  /// Summary for selected analytics export date range.
  ///
  /// In ar, this message translates to:
  /// **'من {from} إلى {to}'**
  String analyticsExportDateRangeSummary(String from, String to);

  /// No description provided for @analyticsExportTitle.
  ///
  /// In ar, this message translates to:
  /// **'تصدير التتبع'**
  String get analyticsExportTitle;

  /// No description provided for @analyticsExportFiltersSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'فلاتر التصدير'**
  String get analyticsExportFiltersSectionTitle;

  /// No description provided for @analyticsExportFormatLabel.
  ///
  /// In ar, this message translates to:
  /// **'صيغة الملف'**
  String get analyticsExportFormatLabel;

  /// No description provided for @analyticsExportFormatCsv.
  ///
  /// In ar, this message translates to:
  /// **'CSV'**
  String get analyticsExportFormatCsv;

  /// No description provided for @analyticsExportFormatJson.
  ///
  /// In ar, this message translates to:
  /// **'JSON'**
  String get analyticsExportFormatJson;

  /// No description provided for @analyticsExportFromDateLabel.
  ///
  /// In ar, this message translates to:
  /// **'من تاريخ'**
  String get analyticsExportFromDateLabel;

  /// No description provided for @analyticsExportToDateLabel.
  ///
  /// In ar, this message translates to:
  /// **'إلى تاريخ'**
  String get analyticsExportToDateLabel;

  /// No description provided for @analyticsExportOpenDateValue.
  ///
  /// In ar, this message translates to:
  /// **'مفتوح'**
  String get analyticsExportOpenDateValue;

  /// No description provided for @analyticsExportClearDatesButton.
  ///
  /// In ar, this message translates to:
  /// **'مسح التواريخ'**
  String get analyticsExportClearDatesButton;

  /// No description provided for @analyticsExportEventTypeLabel.
  ///
  /// In ar, this message translates to:
  /// **'نوع الحدث'**
  String get analyticsExportEventTypeLabel;

  /// No description provided for @analyticsExportSeverityLabel.
  ///
  /// In ar, this message translates to:
  /// **'الحدة'**
  String get analyticsExportSeverityLabel;

  /// No description provided for @analyticsExportSourceLabel.
  ///
  /// In ar, this message translates to:
  /// **'المصدر'**
  String get analyticsExportSourceLabel;

  /// No description provided for @analyticsExportAnyValue.
  ///
  /// In ar, this message translates to:
  /// **'الكل'**
  String get analyticsExportAnyValue;

  /// No description provided for @analyticsExportSearchLabel.
  ///
  /// In ar, this message translates to:
  /// **'بحث في الاسم أو الأثر'**
  String get analyticsExportSearchLabel;

  /// No description provided for @analyticsExportPlatformLabel.
  ///
  /// In ar, this message translates to:
  /// **'المنصة'**
  String get analyticsExportPlatformLabel;

  /// No description provided for @analyticsExportSessionLabel.
  ///
  /// In ar, this message translates to:
  /// **'معرّف الجلسة'**
  String get analyticsExportSessionLabel;

  /// No description provided for @analyticsExportDeviceLabel.
  ///
  /// In ar, this message translates to:
  /// **'معرّف الجهاز'**
  String get analyticsExportDeviceLabel;

  /// No description provided for @analyticsExportDownloadButton.
  ///
  /// In ar, this message translates to:
  /// **'تنزيل الملف'**
  String get analyticsExportDownloadButton;

  /// No description provided for @analyticsExportRunningButton.
  ///
  /// In ar, this message translates to:
  /// **'جار التصدير...'**
  String get analyticsExportRunningButton;

  /// No description provided for @analyticsExportStartedMessage.
  ///
  /// In ar, this message translates to:
  /// **'بدأ تنزيل ملف التتبع.'**
  String get analyticsExportStartedMessage;

  /// No description provided for @analyticsExportFailedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تصدير التتبع. راجع الفلاتر وحاول مرة أخرى.'**
  String get analyticsExportFailedMessage;

  /// No description provided for @analyticsEventTypeUsage.
  ///
  /// In ar, this message translates to:
  /// **'استخدام'**
  String get analyticsEventTypeUsage;

  /// No description provided for @analyticsEventTypeError.
  ///
  /// In ar, this message translates to:
  /// **'خطأ'**
  String get analyticsEventTypeError;

  /// No description provided for @analyticsEventTypePerformance.
  ///
  /// In ar, this message translates to:
  /// **'أداء'**
  String get analyticsEventTypePerformance;

  /// No description provided for @analyticsEventTypeSecurity.
  ///
  /// In ar, this message translates to:
  /// **'أمان'**
  String get analyticsEventTypeSecurity;

  /// No description provided for @analyticsEventTypeFraudSignal.
  ///
  /// In ar, this message translates to:
  /// **'مؤشر اشتباه'**
  String get analyticsEventTypeFraudSignal;

  /// No description provided for @analyticsEventTypeAudit.
  ///
  /// In ar, this message translates to:
  /// **'تدقيق'**
  String get analyticsEventTypeAudit;

  /// No description provided for @analyticsSeverityDebug.
  ///
  /// In ar, this message translates to:
  /// **'تصحيح'**
  String get analyticsSeverityDebug;

  /// No description provided for @analyticsSeverityInfo.
  ///
  /// In ar, this message translates to:
  /// **'معلومة'**
  String get analyticsSeverityInfo;

  /// No description provided for @analyticsSeverityWarning.
  ///
  /// In ar, this message translates to:
  /// **'تحذير'**
  String get analyticsSeverityWarning;

  /// No description provided for @analyticsSeverityError.
  ///
  /// In ar, this message translates to:
  /// **'خطأ'**
  String get analyticsSeverityError;

  /// No description provided for @analyticsSeverityCritical.
  ///
  /// In ar, this message translates to:
  /// **'حرج'**
  String get analyticsSeverityCritical;

  /// No description provided for @analyticsSourceFrontend.
  ///
  /// In ar, this message translates to:
  /// **'الواجهة'**
  String get analyticsSourceFrontend;

  /// No description provided for @analyticsSourceBackend.
  ///
  /// In ar, this message translates to:
  /// **'الخادم'**
  String get analyticsSourceBackend;

  /// No description provided for @analyticsSourcePrintAgent.
  ///
  /// In ar, this message translates to:
  /// **'وكيل الطباعة'**
  String get analyticsSourcePrintAgent;

  /// No description provided for @analyticsSourceIntegration.
  ///
  /// In ar, this message translates to:
  /// **'تكامل'**
  String get analyticsSourceIntegration;

  /// No description provided for @shopNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم المتجر'**
  String get shopNameLabel;

  /// No description provided for @shopLogoLabel.
  ///
  /// In ar, this message translates to:
  /// **'شعار المتجر'**
  String get shopLogoLabel;

  /// No description provided for @shopLogoEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لم يتم رفع شعار بعد.'**
  String get shopLogoEmpty;

  /// No description provided for @shopLogoUploadedValue.
  ///
  /// In ar, this message translates to:
  /// **'الشعار مرفوع'**
  String get shopLogoUploadedValue;

  /// No description provided for @shopLogoMissingValue.
  ///
  /// In ar, this message translates to:
  /// **'الشعار غير مرفوع'**
  String get shopLogoMissingValue;

  /// No description provided for @shopLogoMarkedForRemoval.
  ///
  /// In ar, this message translates to:
  /// **'سيتم إزالة الشعار عند الحفظ.'**
  String get shopLogoMarkedForRemoval;

  /// No description provided for @shopLogoUploadButton.
  ///
  /// In ar, this message translates to:
  /// **'رفع شعار'**
  String get shopLogoUploadButton;

  /// No description provided for @shopLogoReplaceButton.
  ///
  /// In ar, this message translates to:
  /// **'استبدال الشعار'**
  String get shopLogoReplaceButton;

  /// No description provided for @shopLogoRemoveButton.
  ///
  /// In ar, this message translates to:
  /// **'إزالة الشعار'**
  String get shopLogoRemoveButton;

  /// No description provided for @shopLogoPickError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر قراءة الشعار المختار.'**
  String get shopLogoPickError;

  /// No description provided for @receiptHeaderLabel.
  ///
  /// In ar, this message translates to:
  /// **'ترويسة الإيصال'**
  String get receiptHeaderLabel;

  /// No description provided for @receiptFooterLabel.
  ///
  /// In ar, this message translates to:
  /// **'خاتمة الإيصال'**
  String get receiptFooterLabel;

  /// No description provided for @requireOpeningCashLabel.
  ///
  /// In ar, this message translates to:
  /// **'طلب نقدية افتتاح الجلسة'**
  String get requireOpeningCashLabel;

  /// No description provided for @cashierReturnWindowLabel.
  ///
  /// In ar, this message translates to:
  /// **'مدة صلاحية الإرجاع للكاشير'**
  String get cashierReturnWindowLabel;

  /// No description provided for @cashierReturnWindowDialogTitle.
  ///
  /// In ar, this message translates to:
  /// **'مدة صلاحية الإرجاع'**
  String get cashierReturnWindowDialogTitle;

  /// No description provided for @cashierReturnWindowDaysLabel.
  ///
  /// In ar, this message translates to:
  /// **'الأيام'**
  String get cashierReturnWindowDaysLabel;

  /// No description provided for @cashierReturnWindowHoursLabel.
  ///
  /// In ar, this message translates to:
  /// **'الساعات'**
  String get cashierReturnWindowHoursLabel;

  /// Duration value when only hours are shown.
  ///
  /// In ar, this message translates to:
  /// **'{hours} ساعة'**
  String cashierReturnWindowHoursValue(int hours);

  /// Duration value when only days are shown.
  ///
  /// In ar, this message translates to:
  /// **'{days} يوم'**
  String cashierReturnWindowDaysValue(int days);

  /// Duration value when days and hours are shown.
  ///
  /// In ar, this message translates to:
  /// **'{days} يوم و{hours} ساعة'**
  String cashierReturnWindowDaysHoursValue(int days, int hours);

  /// No description provided for @autoPrintReceiptsLabel.
  ///
  /// In ar, this message translates to:
  /// **'طباعة الإيصالات تلقائيًا'**
  String get autoPrintReceiptsLabel;

  /// No description provided for @allowOversellingLabel.
  ///
  /// In ar, this message translates to:
  /// **'السماح بالبيع فوق المخزون'**
  String get allowOversellingLabel;

  /// No description provided for @preventSellingAtLossLabel.
  ///
  /// In ar, this message translates to:
  /// **'منع البيع بخسارة'**
  String get preventSellingAtLossLabel;

  /// No description provided for @preventSellingAtLossSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'عند إيقافه سيظهر تحذير للكاشير قبل إتمام بيع بخسارة.'**
  String get preventSellingAtLossSubtitle;

  /// No description provided for @paymentMethodCash.
  ///
  /// In ar, this message translates to:
  /// **'نقد'**
  String get paymentMethodCash;

  /// No description provided for @paymentMethodCard.
  ///
  /// In ar, this message translates to:
  /// **'بطاقة'**
  String get paymentMethodCard;

  /// No description provided for @paymentMethodTransfer.
  ///
  /// In ar, this message translates to:
  /// **'تحويل'**
  String get paymentMethodTransfer;

  /// No description provided for @requireCardReceiptSettingLabel.
  ///
  /// In ar, this message translates to:
  /// **'إلزام مسح ومطابقة إيصال البطاقة'**
  String get requireCardReceiptSettingLabel;

  /// No description provided for @requireCardReceiptSettingSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'يجب مسح رابط QR من إيصال معاملات ومطابقة المبلغ لكل دفعة بطاقة.'**
  String get requireCardReceiptSettingSubtitle;

  /// No description provided for @trustedCardTerminalIdsLabel.
  ///
  /// In ar, this message translates to:
  /// **'أجهزة البطاقة الموثوقة'**
  String get trustedCardTerminalIdsLabel;

  /// No description provided for @trustedCardTerminalIdsHelper.
  ///
  /// In ar, this message translates to:
  /// **'حدد أجهزة البطاقة التي تقبل إيصالاتها عند مطابقة الدفع. اترك القائمة فارغة لقبول أي جهاز.'**
  String get trustedCardTerminalIdsHelper;

  /// No description provided for @manageTrustedCardTerminalsButton.
  ///
  /// In ar, this message translates to:
  /// **'إدارة الأجهزة'**
  String get manageTrustedCardTerminalsButton;

  /// No description provided for @addTrustedCardTerminalButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة جهاز'**
  String get addTrustedCardTerminalButton;

  /// No description provided for @trustedCardTerminalsDialogTitle.
  ///
  /// In ar, this message translates to:
  /// **'إدارة أجهزة البطاقة'**
  String get trustedCardTerminalsDialogTitle;

  /// No description provided for @trustedCardTerminalsDialogDescription.
  ///
  /// In ar, this message translates to:
  /// **'أضف رقم الجهاز كما يظهر في إيصال البطاقة. عند ترك القائمة فارغة سيتم قبول أي جهاز.'**
  String get trustedCardTerminalsDialogDescription;

  /// No description provided for @trustedCardTerminalIdFieldLabel.
  ///
  /// In ar, this message translates to:
  /// **'رقم الجهاز'**
  String get trustedCardTerminalIdFieldLabel;

  /// No description provided for @trustedCardTerminalIdFieldHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: 0JA8Y13W'**
  String get trustedCardTerminalIdFieldHint;

  /// No description provided for @trustedCardTerminalRequiredError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل رقم الجهاز.'**
  String get trustedCardTerminalRequiredError;

  /// No description provided for @trustedCardTerminalDuplicateError.
  ///
  /// In ar, this message translates to:
  /// **'هذا الجهاز موجود في القائمة.'**
  String get trustedCardTerminalDuplicateError;

  /// No description provided for @trustedCardTerminalAllowAnyMessage.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد أجهزة محددة؛ سيتم قبول أي جهاز بطاقة عند مطابقة الإيصال.'**
  String get trustedCardTerminalAllowAnyMessage;

  /// Tooltip for removing a trusted card terminal from shop settings.
  ///
  /// In ar, this message translates to:
  /// **'إزالة الجهاز {terminalId}'**
  String removeTrustedCardTerminalTooltip(String terminalId);

  /// Trusted card terminal ID count in shop payment settings.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد أجهزة محددة} =1{جهاز موثوق واحد} =2{جهازان موثوقان} other{{count} أجهزة موثوقة}}'**
  String trustedCardTerminalCount(int count);

  /// No description provided for @cardCommissionPercentLabel.
  ///
  /// In ar, this message translates to:
  /// **'عمولة البطاقة (%)'**
  String get cardCommissionPercentLabel;

  /// No description provided for @transferCommissionPercentLabel.
  ///
  /// In ar, this message translates to:
  /// **'عمولة التحويل (%)'**
  String get transferCommissionPercentLabel;

  /// No description provided for @paymentMethodsRequiredError.
  ///
  /// In ar, this message translates to:
  /// **'فعّل طريقة دفع واحدة على الأقل.'**
  String get paymentMethodsRequiredError;

  /// No description provided for @lowStockThresholdLabel.
  ///
  /// In ar, this message translates to:
  /// **'حد تنبيه المخزون المنخفض'**
  String get lowStockThresholdLabel;

  /// No description provided for @printerTransportLabel.
  ///
  /// In ar, this message translates to:
  /// **'طريقة الاتصال'**
  String get printerTransportLabel;

  /// No description provided for @printerTransportSerial.
  ///
  /// In ar, this message translates to:
  /// **'تسلسلي'**
  String get printerTransportSerial;

  /// No description provided for @printerTransportBluetooth.
  ///
  /// In ar, this message translates to:
  /// **'بلوتوث'**
  String get printerTransportBluetooth;

  /// No description provided for @printerTransportWifi.
  ///
  /// In ar, this message translates to:
  /// **'شبكة'**
  String get printerTransportWifi;

  /// No description provided for @printerTransportFake.
  ///
  /// In ar, this message translates to:
  /// **'محاكاة'**
  String get printerTransportFake;

  /// No description provided for @posReceiptPrinterRoleTitle.
  ///
  /// In ar, this message translates to:
  /// **'إيصال نقطة البيع'**
  String get posReceiptPrinterRoleTitle;

  /// No description provided for @posReceiptPrinterRoleDescription.
  ///
  /// In ar, this message translates to:
  /// **'الطابعة الافتراضية لفواتير البيع وإعادة الطباعة من شاشة نقطة البيع.'**
  String get posReceiptPrinterRoleDescription;

  /// No description provided for @configurePrinterRoleButton.
  ///
  /// In ar, this message translates to:
  /// **'اختيار طابعة الإيصال'**
  String get configurePrinterRoleButton;

  /// No description provided for @printerRoleDialogTitle.
  ///
  /// In ar, this message translates to:
  /// **'طابعة إيصال نقطة البيع'**
  String get printerRoleDialogTitle;

  /// No description provided for @printerRoleDialogDoneButton.
  ///
  /// In ar, this message translates to:
  /// **'تم'**
  String get printerRoleDialogDoneButton;

  /// No description provided for @selectedPrinterLabel.
  ///
  /// In ar, this message translates to:
  /// **'طابعة إيصال نقطة البيع'**
  String get selectedPrinterLabel;

  /// No description provided for @noSelectedPrinter.
  ///
  /// In ar, this message translates to:
  /// **'لم يتم اختيار طابعة'**
  String get noSelectedPrinter;

  /// No description provided for @paperWidthLabel.
  ///
  /// In ar, this message translates to:
  /// **'عرض الورق بالملليمتر'**
  String get paperWidthLabel;

  /// No description provided for @printerCodeTableLabel.
  ///
  /// In ar, this message translates to:
  /// **'جدول ترميز الطابعة'**
  String get printerCodeTableLabel;

  /// No description provided for @discoveredPrintersLabel.
  ///
  /// In ar, this message translates to:
  /// **'اختر الطابعة'**
  String get discoveredPrintersLabel;

  /// No description provided for @selectDiscoveredPrinterHint.
  ///
  /// In ar, this message translates to:
  /// **'اختر طابعة'**
  String get selectDiscoveredPrinterHint;

  /// No description provided for @noDiscoveredPrinters.
  ///
  /// In ar, this message translates to:
  /// **'اضغط على البحث لاكتشاف الطابعات المتاحة'**
  String get noDiscoveredPrinters;

  /// No description provided for @discoverPrintersButton.
  ///
  /// In ar, this message translates to:
  /// **'اكتشاف الطابعات'**
  String get discoverPrintersButton;

  /// No description provided for @printerDiscoveryError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر اكتشاف الطابعات. تحقق من الاتصال وحاول مرة أخرى.'**
  String get printerDiscoveryError;

  /// No description provided for @checkPrinterConnectionButton.
  ///
  /// In ar, this message translates to:
  /// **'فحص الاتصال'**
  String get checkPrinterConnectionButton;

  /// No description provided for @printerStatusUnknown.
  ///
  /// In ar, this message translates to:
  /// **'لم يتم فحص اتصال الطابعة بعد.'**
  String get printerStatusUnknown;

  /// No description provided for @printerStatusNotConfigured.
  ///
  /// In ar, this message translates to:
  /// **'اختر طابعة إيصال حتى يبدأ الجهاز بفحص اتصالها.'**
  String get printerStatusNotConfigured;

  /// No description provided for @printerStatusChecking.
  ///
  /// In ar, this message translates to:
  /// **'جار فحص اتصال الطابعة...'**
  String get printerStatusChecking;

  /// No description provided for @printerStatusConnected.
  ///
  /// In ar, this message translates to:
  /// **'طابعة الإيصال متصلة وجاهزة.'**
  String get printerStatusConnected;

  /// No description provided for @printerStatusDisconnected.
  ///
  /// In ar, this message translates to:
  /// **'تعذر الاتصال بطابعة الإيصال. تحقق من تشغيلها واتصالها.'**
  String get printerStatusDisconnected;

  /// No description provided for @printerDisconnectedSnackBar.
  ///
  /// In ar, this message translates to:
  /// **'تعذر الاتصال بطابعة إيصال نقطة البيع.'**
  String get printerDisconnectedSnackBar;

  /// No description provided for @testPrinterButton.
  ///
  /// In ar, this message translates to:
  /// **'اختبار الطابعة'**
  String get testPrinterButton;

  /// No description provided for @testingPrinterButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الاختبار...'**
  String get testingPrinterButton;

  /// No description provided for @fakePrintButton.
  ///
  /// In ar, this message translates to:
  /// **'طباعة تجريبية بالمحاكاة'**
  String get fakePrintButton;

  /// No description provided for @printerTestSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم إرسال اختبار الطباعة.'**
  String get printerTestSuccess;

  /// No description provided for @printerTestFailure.
  ///
  /// In ar, this message translates to:
  /// **'تعذر اختبار الطابعة. تحقق من الاتصال والإعدادات وحاول مرة أخرى.'**
  String get printerTestFailure;

  /// No description provided for @printerTestUnsupported.
  ///
  /// In ar, this message translates to:
  /// **'طريقة الاتصال غير متاحة على هذا الجهاز.'**
  String get printerTestUnsupported;

  /// No description provided for @fakePrintSuccess.
  ///
  /// In ar, this message translates to:
  /// **'نجحت الطباعة التجريبية بالمحاكاة.'**
  String get fakePrintSuccess;

  /// No description provided for @fakePrintFailure.
  ///
  /// In ar, this message translates to:
  /// **'تعذرت الطباعة التجريبية بالمحاكاة.'**
  String get fakePrintFailure;

  /// No description provided for @saveSettingsButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ الإعدادات'**
  String get saveSettingsButton;

  /// No description provided for @catalogTitle.
  ///
  /// In ar, this message translates to:
  /// **'المنتجات'**
  String get catalogTitle;

  /// No description provided for @catalogManagementTitle.
  ///
  /// In ar, this message translates to:
  /// **'إدارة المنتجات'**
  String get catalogManagementTitle;

  /// No description provided for @backTooltip.
  ///
  /// In ar, this message translates to:
  /// **'رجوع'**
  String get backTooltip;

  /// No description provided for @sampleCatalogNotice.
  ///
  /// In ar, this message translates to:
  /// **'يتم عرض منتجات تجريبية إلى أن يعمل الخادم.'**
  String get sampleCatalogNotice;

  /// No description provided for @emptyCatalog.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد منتجات'**
  String get emptyCatalog;

  /// No description provided for @productListTitle.
  ///
  /// In ar, this message translates to:
  /// **'قائمة المنتجات'**
  String get productListTitle;

  /// No description provided for @addProductButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة منتج'**
  String get addProductButton;

  /// No description provided for @productTableProductColumn.
  ///
  /// In ar, this message translates to:
  /// **'المنتج'**
  String get productTableProductColumn;

  /// No description provided for @productTableStockColumn.
  ///
  /// In ar, this message translates to:
  /// **'المخزون'**
  String get productTableStockColumn;

  /// No description provided for @productTablePriceColumn.
  ///
  /// In ar, this message translates to:
  /// **'السعر'**
  String get productTablePriceColumn;

  /// No description provided for @productTableBarcodeColumn.
  ///
  /// In ar, this message translates to:
  /// **'الباركود'**
  String get productTableBarcodeColumn;

  /// No description provided for @productTableEditColumn.
  ///
  /// In ar, this message translates to:
  /// **'تعديل'**
  String get productTableEditColumn;

  /// No description provided for @openProductDetailsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'فتح تفاصيل المنتج'**
  String get openProductDetailsTooltip;

  /// No description provided for @stockStatusAvailable.
  ///
  /// In ar, this message translates to:
  /// **'متوفر'**
  String get stockStatusAvailable;

  /// No description provided for @stockStatusLow.
  ///
  /// In ar, this message translates to:
  /// **'منخفض'**
  String get stockStatusLow;

  /// No description provided for @stockStatusOut.
  ///
  /// In ar, this message translates to:
  /// **'نافد'**
  String get stockStatusOut;

  /// No description provided for @newProductTitle.
  ///
  /// In ar, this message translates to:
  /// **'منتج جديد'**
  String get newProductTitle;

  /// No description provided for @productNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم المنتج'**
  String get productNameLabel;

  /// No description provided for @productNameHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: قهوة عربية'**
  String get productNameHint;

  /// No description provided for @skuLabel.
  ///
  /// In ar, this message translates to:
  /// **'رمز المنتج'**
  String get skuLabel;

  /// No description provided for @skuHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: COF-100'**
  String get skuHint;

  /// No description provided for @barcodeLabel.
  ///
  /// In ar, this message translates to:
  /// **'الباركود'**
  String get barcodeLabel;

  /// No description provided for @barcodeHint.
  ///
  /// In ar, this message translates to:
  /// **'اختياري'**
  String get barcodeHint;

  /// No description provided for @descriptionLabel.
  ///
  /// In ar, this message translates to:
  /// **'الوصف'**
  String get descriptionLabel;

  /// No description provided for @descriptionHint.
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل قصيرة للمنتج'**
  String get descriptionHint;

  /// No description provided for @unitPriceLabel.
  ///
  /// In ar, this message translates to:
  /// **'السعر'**
  String get unitPriceLabel;

  /// No description provided for @productCategoriesLabel.
  ///
  /// In ar, this message translates to:
  /// **'تصنيفات المنتج'**
  String get productCategoriesLabel;

  /// No description provided for @productCategoriesEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد تصنيفات محددة'**
  String get productCategoriesEmpty;

  /// No description provided for @productCategoriesHelper.
  ///
  /// In ar, this message translates to:
  /// **'اختياري، يساعد في البحث والتصفية داخل نقطة البيع والمشتريات'**
  String get productCategoriesHelper;

  /// No description provided for @productCategoriesOpenPickerTooltip.
  ///
  /// In ar, this message translates to:
  /// **'اختيار التصنيفات'**
  String get productCategoriesOpenPickerTooltip;

  /// No description provided for @productImageLabel.
  ///
  /// In ar, this message translates to:
  /// **'صورة المنتج'**
  String get productImageLabel;

  /// No description provided for @productImageEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لم يتم اختيار صورة'**
  String get productImageEmpty;

  /// No description provided for @productImageUploadButton.
  ///
  /// In ar, this message translates to:
  /// **'رفع صورة'**
  String get productImageUploadButton;

  /// No description provided for @productImageSearchButton.
  ///
  /// In ar, this message translates to:
  /// **'بحث في الإنترنت'**
  String get productImageSearchButton;

  /// No description provided for @productImageClearSelectionButton.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء الاختيار'**
  String get productImageClearSelectionButton;

  /// No description provided for @productImagePickError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر قراءة الصورة المختارة.'**
  String get productImagePickError;

  /// No description provided for @productImageSearchTitle.
  ///
  /// In ar, this message translates to:
  /// **'بحث صور المنتج'**
  String get productImageSearchTitle;

  /// No description provided for @productImageSearchQueryLabel.
  ///
  /// In ar, this message translates to:
  /// **'كلمة البحث'**
  String get productImageSearchQueryLabel;

  /// No description provided for @productImageSearchSubmitButton.
  ///
  /// In ar, this message translates to:
  /// **'بحث'**
  String get productImageSearchSubmitButton;

  /// No description provided for @productImageLoadMoreButton.
  ///
  /// In ar, this message translates to:
  /// **'عرض المزيد'**
  String get productImageLoadMoreButton;

  /// No description provided for @productImageSearchEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد صور بعد.'**
  String get productImageSearchEmpty;

  /// No description provided for @productImageSearchShortQuery.
  ///
  /// In ar, this message translates to:
  /// **'أدخل حرفين على الأقل للبحث.'**
  String get productImageSearchShortQuery;

  /// No description provided for @productImageSearchError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر البحث عن الصور. تحقق من إعداد مزود البحث وحاول مرة أخرى.'**
  String get productImageSearchError;

  /// No description provided for @productImageAttachError.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ المنتج، لكن تعذر حفظ الصورة.'**
  String get productImageAttachError;

  /// No description provided for @productCategoryPickerTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختيار التصنيفات'**
  String get productCategoryPickerTitle;

  /// No description provided for @productCategoryPickerEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد تصنيفات مطابقة'**
  String get productCategoryPickerEmpty;

  /// Fallback category label when the category name is unavailable.
  ///
  /// In ar, this message translates to:
  /// **'تصنيف #{id}'**
  String productCategoryFallbackLabel(int id);

  /// No description provided for @variantOptionValuesLabel.
  ///
  /// In ar, this message translates to:
  /// **'قيم الخيارات'**
  String get variantOptionValuesLabel;

  /// No description provided for @variantOptionValuesEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد قيم خيارات محددة'**
  String get variantOptionValuesEmpty;

  /// No description provided for @variantOptionValuesHelper.
  ///
  /// In ar, this message translates to:
  /// **'اختياري'**
  String get variantOptionValuesHelper;

  /// No description provided for @variantOptionValuesOpenPickerTooltip.
  ///
  /// In ar, this message translates to:
  /// **'اختيار قيم الخيارات'**
  String get variantOptionValuesOpenPickerTooltip;

  /// No description provided for @variantOptionValuePickerTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختيار قيم الخيارات'**
  String get variantOptionValuePickerTitle;

  /// No description provided for @variantOptionValuePickerSearchHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث باسم الخيار أو القيمة'**
  String get variantOptionValuePickerSearchHint;

  /// No description provided for @variantOptionValuePickerEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد قيم خيارات مطابقة'**
  String get variantOptionValuePickerEmpty;

  /// No description provided for @variantOptionValuePickerLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل قيم الخيارات.'**
  String get variantOptionValuePickerLoadError;

  /// Fallback option value label when the option value name is unavailable.
  ///
  /// In ar, this message translates to:
  /// **'قيمة خيار #{id}'**
  String variantOptionValueFallbackLabel(int id);

  /// No description provided for @variantOptionsLabel.
  ///
  /// In ar, this message translates to:
  /// **'قوالب الخيارات'**
  String get variantOptionsLabel;

  /// No description provided for @variantOptionsHelper.
  ///
  /// In ar, this message translates to:
  /// **'اختر الخيارات التي تميز المنتج مثل اللون أو السعة. سيتم استخدام قيمها لتوليد الخيارات تلقائيًا.'**
  String get variantOptionsHelper;

  /// No description provided for @variantOptionsEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد قوالب خيارات جاهزة.'**
  String get variantOptionsEmpty;

  /// No description provided for @variantOptionsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل قوالب الخيارات.'**
  String get variantOptionsLoadError;

  /// No description provided for @addVariantOptionButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة قالب'**
  String get addVariantOptionButton;

  /// No description provided for @newVariantOptionTitle.
  ///
  /// In ar, this message translates to:
  /// **'قالب خيار جديد'**
  String get newVariantOptionTitle;

  /// No description provided for @variantOptionNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم القالب'**
  String get variantOptionNameLabel;

  /// No description provided for @variantOptionNameHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: اللون'**
  String get variantOptionNameHint;

  /// No description provided for @variantOptionCodeLabel.
  ///
  /// In ar, this message translates to:
  /// **'رمز القالب'**
  String get variantOptionCodeLabel;

  /// No description provided for @variantOptionCodeHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: color'**
  String get variantOptionCodeHint;

  /// No description provided for @createVariantOptionButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ القالب'**
  String get createVariantOptionButton;

  /// No description provided for @variantOptionCreateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إنشاء قالب الخيار.'**
  String get variantOptionCreateError;

  /// No description provided for @variantValuesNoOptions.
  ///
  /// In ar, this message translates to:
  /// **'اختر قالب خيار واحدًا على الأقل لتحديد القيم.'**
  String get variantValuesNoOptions;

  /// No description provided for @variantOptionNoValues.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد قيم جاهزة لهذا الخيار.'**
  String get variantOptionNoValues;

  /// No description provided for @variantOptionValueRequired.
  ///
  /// In ar, this message translates to:
  /// **'اختر قيمة واحدة على الأقل.'**
  String get variantOptionValueRequired;

  /// No description provided for @addVariantOptionValueButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة قيمة'**
  String get addVariantOptionValueButton;

  /// No description provided for @newVariantOptionValueTitle.
  ///
  /// In ar, this message translates to:
  /// **'قيمة خيار جديدة'**
  String get newVariantOptionValueTitle;

  /// No description provided for @variantOptionValueNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم القيمة'**
  String get variantOptionValueNameLabel;

  /// No description provided for @variantOptionValueNameHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: أحمر'**
  String get variantOptionValueNameHint;

  /// No description provided for @variantOptionValueCodeLabel.
  ///
  /// In ar, this message translates to:
  /// **'رمز القيمة'**
  String get variantOptionValueCodeLabel;

  /// No description provided for @variantOptionValueCodeHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: red'**
  String get variantOptionValueCodeHint;

  /// No description provided for @createVariantOptionValueButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ القيمة'**
  String get createVariantOptionValueButton;

  /// No description provided for @variantOptionValueCreateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إنشاء قيمة الخيار.'**
  String get variantOptionValueCreateError;

  /// No description provided for @skuPrefixLabel.
  ///
  /// In ar, this message translates to:
  /// **'بادئة الرمز'**
  String get skuPrefixLabel;

  /// No description provided for @skuPrefixHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: IPHONE'**
  String get skuPrefixHint;

  /// No description provided for @generatedVariantPriceLabel.
  ///
  /// In ar, this message translates to:
  /// **'سعر الخيارات المولدة'**
  String get generatedVariantPriceLabel;

  /// No description provided for @generatedVariantsEmpty.
  ///
  /// In ar, this message translates to:
  /// **'اختر قيم الخيارات لعرض كل التركيبات.'**
  String get generatedVariantsEmpty;

  /// Number of generated product variants.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد خيارات مولدة} =1{خيار واحد مولد} =2{خياران مولدان} other{{count} خيارات مولدة}}'**
  String generatedVariantsCount(num count);

  /// No description provided for @generatedVariantNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم الخيار'**
  String get generatedVariantNameLabel;

  /// No description provided for @generatedVariantsMissingValues.
  ///
  /// In ar, this message translates to:
  /// **'اختر قيمة واحدة على الأقل لكل قالب خيار.'**
  String get generatedVariantsMissingValues;

  /// No description provided for @generatedVariantsDuplicateSku.
  ///
  /// In ar, this message translates to:
  /// **'رموز الخيارات المولدة يجب أن تكون غير مكررة.'**
  String get generatedVariantsDuplicateSku;

  /// No description provided for @generatedVariantsTooMany.
  ///
  /// In ar, this message translates to:
  /// **'عدد الخيارات المولدة كبير جدًا. قلل القيم المحددة.'**
  String get generatedVariantsTooMany;

  /// No description provided for @generatedVariantsNoMissing.
  ///
  /// In ar, this message translates to:
  /// **'كل التركيبات المحددة موجودة بالفعل.'**
  String get generatedVariantsNoMissing;

  /// No description provided for @generateVariantsTitle.
  ///
  /// In ar, this message translates to:
  /// **'توليد الخيارات'**
  String get generateVariantsTitle;

  /// No description provided for @generateVariantsButton.
  ///
  /// In ar, this message translates to:
  /// **'توليد الخيارات'**
  String get generateVariantsButton;

  /// No description provided for @variantsGeneratedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ الخيارات المولدة'**
  String get variantsGeneratedMessage;

  /// No description provided for @variantGenerateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر توليد الخيارات. راجع البيانات وحاول مرة أخرى.'**
  String get variantGenerateError;

  /// No description provided for @productVariantOptionsTitle.
  ///
  /// In ar, this message translates to:
  /// **'خيارات المنتج'**
  String get productVariantOptionsTitle;

  /// No description provided for @productVariantOptionsEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد خيارات مرتبطة بهذا المنتج.'**
  String get productVariantOptionsEmpty;

  /// No description provided for @reloadButton.
  ///
  /// In ar, this message translates to:
  /// **'إعادة التحميل'**
  String get reloadButton;

  /// No description provided for @categoryFilterTitle.
  ///
  /// In ar, this message translates to:
  /// **'التصنيف'**
  String get categoryFilterTitle;

  /// No description provided for @categoryManagementTitle.
  ///
  /// In ar, this message translates to:
  /// **'إدارة التصنيفات'**
  String get categoryManagementTitle;

  /// No description provided for @addCategoryButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة تصنيف'**
  String get addCategoryButton;

  /// No description provided for @newCategoryTitle.
  ///
  /// In ar, this message translates to:
  /// **'تصنيف جديد'**
  String get newCategoryTitle;

  /// No description provided for @categoryNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم التصنيف'**
  String get categoryNameLabel;

  /// No description provided for @parentCategoryLabel.
  ///
  /// In ar, this message translates to:
  /// **'التصنيف الأب'**
  String get parentCategoryLabel;

  /// No description provided for @noParentCategory.
  ///
  /// In ar, this message translates to:
  /// **'تصنيف رئيسي'**
  String get noParentCategory;

  /// No description provided for @parentCategoryHelper.
  ///
  /// In ar, this message translates to:
  /// **'اختياري، اختر أبًا لإنشاء تصنيف فرعي'**
  String get parentCategoryHelper;

  /// No description provided for @activeCategoryLabel.
  ///
  /// In ar, this message translates to:
  /// **'تصنيف نشط'**
  String get activeCategoryLabel;

  /// No description provided for @createCategoryButton.
  ///
  /// In ar, this message translates to:
  /// **'إنشاء التصنيف'**
  String get createCategoryButton;

  /// No description provided for @creatingCategoryButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الإنشاء...'**
  String get creatingCategoryButton;

  /// No description provided for @categoryCreateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إنشاء التصنيف. راجع البيانات وحاول مرة أخرى.'**
  String get categoryCreateError;

  /// No description provided for @categoryEmptyState.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد تصنيفات بعد.'**
  String get categoryEmptyState;

  /// No description provided for @rootCategoryLabel.
  ///
  /// In ar, this message translates to:
  /// **'تصنيف رئيسي'**
  String get rootCategoryLabel;

  /// No description provided for @categoryExpandTooltip.
  ///
  /// In ar, this message translates to:
  /// **'عرض الفروع'**
  String get categoryExpandTooltip;

  /// No description provided for @categoryCollapseTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إخفاء الفروع'**
  String get categoryCollapseTooltip;

  /// No description provided for @categoryLoadingChildren.
  ///
  /// In ar, this message translates to:
  /// **'جار تحميل الفروع...'**
  String get categoryLoadingChildren;

  /// No description provided for @categoryChildrenLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل الفروع.'**
  String get categoryChildrenLoadError;

  /// No description provided for @categoryLoadMoreChildrenButton.
  ///
  /// In ar, this message translates to:
  /// **'تحميل فروع إضافية'**
  String get categoryLoadMoreChildrenButton;

  /// Shows the parent category name.
  ///
  /// In ar, this message translates to:
  /// **'ضمن {parent}'**
  String categoryParentValue(String parent);

  /// Number of child categories.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد فروع} =1{فرع واحد} =2{فرعان} other{{count} فروع}}'**
  String categoryChildrenCount(num count);

  /// No description provided for @activeProductLabel.
  ///
  /// In ar, this message translates to:
  /// **'متاح للبيع'**
  String get activeProductLabel;

  /// No description provided for @productTracksExpiryLabel.
  ///
  /// In ar, this message translates to:
  /// **'يتابع تاريخ الانتهاء'**
  String get productTracksExpiryLabel;

  /// No description provided for @productTracksExpiryHint.
  ///
  /// In ar, this message translates to:
  /// **'سيطلب تاريخ انتهاء عند شراء هذا المنتج ويظهر تنبيه قبل انتهائه.'**
  String get productTracksExpiryHint;

  /// No description provided for @activeVariantLabel.
  ///
  /// In ar, this message translates to:
  /// **'متاح للبيع'**
  String get activeVariantLabel;

  /// No description provided for @defaultVariantLabel.
  ///
  /// In ar, this message translates to:
  /// **'الخيار الافتراضي'**
  String get defaultVariantLabel;

  /// No description provided for @variantNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم الخيار'**
  String get variantNameLabel;

  /// No description provided for @variantNameHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: كبير أو أحمر'**
  String get variantNameHint;

  /// No description provided for @parentProductStepTitle.
  ///
  /// In ar, this message translates to:
  /// **'بيانات المنتج'**
  String get parentProductStepTitle;

  /// No description provided for @defaultVariantStepTitle.
  ///
  /// In ar, this message translates to:
  /// **'الخيار الافتراضي'**
  String get defaultVariantStepTitle;

  /// Current product creation wizard step.
  ///
  /// In ar, this message translates to:
  /// **'{step} من {total}'**
  String productWizardStepLabel(int step, int total);

  /// No description provided for @backButton.
  ///
  /// In ar, this message translates to:
  /// **'السابق'**
  String get backButton;

  /// No description provided for @nextButton.
  ///
  /// In ar, this message translates to:
  /// **'التالي'**
  String get nextButton;

  /// No description provided for @createProductButton.
  ///
  /// In ar, this message translates to:
  /// **'إنشاء المنتج'**
  String get createProductButton;

  /// No description provided for @creatingProductButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الإنشاء...'**
  String get creatingProductButton;

  /// No description provided for @saveProductButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ المنتج'**
  String get saveProductButton;

  /// No description provided for @editProductButton.
  ///
  /// In ar, this message translates to:
  /// **'تعديل المنتج'**
  String get editProductButton;

  /// No description provided for @requiredField.
  ///
  /// In ar, this message translates to:
  /// **'هذا الحقل مطلوب'**
  String get requiredField;

  /// No description provided for @invalidNumber.
  ///
  /// In ar, this message translates to:
  /// **'أدخل رقمًا صحيحًا'**
  String get invalidNumber;

  /// No description provided for @invalidDate.
  ///
  /// In ar, this message translates to:
  /// **'أدخل تاريخًا صحيحًا'**
  String get invalidDate;

  /// No description provided for @productCreatedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم إنشاء المنتج'**
  String get productCreatedMessage;

  /// No description provided for @productUpdatedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ المنتج'**
  String get productUpdatedMessage;

  /// No description provided for @productCreatedImageAttachError.
  ///
  /// In ar, this message translates to:
  /// **'تم إنشاء المنتج، لكن تعذر حفظ الصورة.'**
  String get productCreatedImageAttachError;

  /// No description provided for @productCreateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إنشاء المنتج. راجع البيانات وحاول مرة أخرى.'**
  String get productCreateError;

  /// No description provided for @productUpdateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ المنتج. راجع البيانات وحاول مرة أخرى.'**
  String get productUpdateError;

  /// No description provided for @catalogLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل المنتجات من الخادم.'**
  String get catalogLoadError;

  /// No description provided for @activeStatus.
  ///
  /// In ar, this message translates to:
  /// **'متاح'**
  String get activeStatus;

  /// No description provided for @inactiveStatus.
  ///
  /// In ar, this message translates to:
  /// **'متوقف'**
  String get inactiveStatus;

  /// No description provided for @productDetailsTitle.
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل المنتج'**
  String get productDetailsTitle;

  /// No description provided for @variantDetailsTitle.
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل الخيار'**
  String get variantDetailsTitle;

  /// No description provided for @productDetailLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل تفاصيل المنتج.'**
  String get productDetailLoadError;

  /// No description provided for @productSummaryTitle.
  ///
  /// In ar, this message translates to:
  /// **'ملخص المنتج'**
  String get productSummaryTitle;

  /// No description provided for @productPriceTitle.
  ///
  /// In ar, this message translates to:
  /// **'السعر'**
  String get productPriceTitle;

  /// No description provided for @productTotalStockLabel.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي المخزون'**
  String get productTotalStockLabel;

  /// No description provided for @productNoCategories.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد تصنيفات'**
  String get productNoCategories;

  /// No description provided for @productVariantsTitle.
  ///
  /// In ar, this message translates to:
  /// **'الخيارات'**
  String get productVariantsTitle;

  /// No description provided for @addVariantButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة خيار'**
  String get addVariantButton;

  /// No description provided for @noVariants.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد خيارات لهذا المنتج.'**
  String get noVariants;

  /// No description provided for @newVariantTitle.
  ///
  /// In ar, this message translates to:
  /// **'خيار جديد'**
  String get newVariantTitle;

  /// No description provided for @editVariantTitle.
  ///
  /// In ar, this message translates to:
  /// **'تعديل الخيار'**
  String get editVariantTitle;

  /// No description provided for @createVariantButton.
  ///
  /// In ar, this message translates to:
  /// **'إنشاء الخيار'**
  String get createVariantButton;

  /// No description provided for @saveVariantButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ الخيار'**
  String get saveVariantButton;

  /// No description provided for @variantCreatedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم إنشاء الخيار'**
  String get variantCreatedMessage;

  /// No description provided for @variantUpdatedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ الخيار'**
  String get variantUpdatedMessage;

  /// No description provided for @variantCreateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إنشاء الخيار. راجع البيانات وحاول مرة أخرى.'**
  String get variantCreateError;

  /// No description provided for @variantUpdateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ الخيار. راجع البيانات وحاول مرة أخرى.'**
  String get variantUpdateError;

  /// No description provided for @variantNameColumn.
  ///
  /// In ar, this message translates to:
  /// **'الخيار'**
  String get variantNameColumn;

  /// No description provided for @variantStockColumn.
  ///
  /// In ar, this message translates to:
  /// **'المخزون'**
  String get variantStockColumn;

  /// No description provided for @variantPriceColumn.
  ///
  /// In ar, this message translates to:
  /// **'السعر'**
  String get variantPriceColumn;

  /// No description provided for @variantSkuColumn.
  ///
  /// In ar, this message translates to:
  /// **'الرمز'**
  String get variantSkuColumn;

  /// No description provided for @variantBarcodeColumn.
  ///
  /// In ar, this message translates to:
  /// **'الباركود'**
  String get variantBarcodeColumn;

  /// No description provided for @variantStatusColumn.
  ///
  /// In ar, this message translates to:
  /// **'الحالة'**
  String get variantStatusColumn;

  /// No description provided for @actionsColumn.
  ///
  /// In ar, this message translates to:
  /// **'إجراءات'**
  String get actionsColumn;

  /// No description provided for @openVariantDetailsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'فتح تفاصيل الخيار'**
  String get openVariantDetailsTooltip;

  /// No description provided for @defaultVariantBadge.
  ///
  /// In ar, this message translates to:
  /// **'افتراضي'**
  String get defaultVariantBadge;

  /// No description provided for @productCostHistoryTitle.
  ///
  /// In ar, this message translates to:
  /// **'تكلفة الشراء والهامش'**
  String get productCostHistoryTitle;

  /// No description provided for @productCostHistoryLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل تاريخ تكلفة الشراء لهذا المنتج.'**
  String get productCostHistoryLoadError;

  /// No description provided for @productCostHistoryEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مشتريات مسجلة لهذا المنتج بعد.'**
  String get productCostHistoryEmpty;

  /// No description provided for @productDocumentHistoryTitle.
  ///
  /// In ar, this message translates to:
  /// **'الفواتير المرتبطة'**
  String get productDocumentHistoryTitle;

  /// No description provided for @productRecentInvoicesTitle.
  ///
  /// In ar, this message translates to:
  /// **'فواتير البيع الأخيرة'**
  String get productRecentInvoicesTitle;

  /// No description provided for @productRecentPurchaseBillsTitle.
  ///
  /// In ar, this message translates to:
  /// **'فواتير الشراء الأخيرة'**
  String get productRecentPurchaseBillsTitle;

  /// No description provided for @productRecentInvoicesLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل فواتير البيع لهذا المنتج.'**
  String get productRecentInvoicesLoadError;

  /// No description provided for @productRecentPurchaseBillsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل فواتير الشراء لهذا المنتج.'**
  String get productRecentPurchaseBillsLoadError;

  /// No description provided for @productRecentInvoicesEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لم يظهر هذا المنتج في أي فاتورة بيع بعد.'**
  String get productRecentInvoicesEmpty;

  /// No description provided for @productRecentPurchaseBillsEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لم يظهر هذا المنتج في أي فاتورة شراء بعد.'**
  String get productRecentPurchaseBillsEmpty;

  /// No description provided for @productLatestCostLabel.
  ///
  /// In ar, this message translates to:
  /// **'آخر تكلفة'**
  String get productLatestCostLabel;

  /// No description provided for @productGrossProfitLabel.
  ///
  /// In ar, this message translates to:
  /// **'ربح القطعة'**
  String get productGrossProfitLabel;

  /// No description provided for @productMarginPercentLabel.
  ///
  /// In ar, this message translates to:
  /// **'هامش الربح'**
  String get productMarginPercentLabel;

  /// Product margin percent value.
  ///
  /// In ar, this message translates to:
  /// **'{percent}%'**
  String productMarginPercentValue(String percent);

  /// No description provided for @productCostChangeLabel.
  ///
  /// In ar, this message translates to:
  /// **'تغير التكلفة'**
  String get productCostChangeLabel;

  /// No description provided for @productMarginChangeLabel.
  ///
  /// In ar, this message translates to:
  /// **'تغير الهامش'**
  String get productMarginChangeLabel;

  /// No description provided for @productIdentifierTitle.
  ///
  /// In ar, this message translates to:
  /// **'بيانات التعريف'**
  String get productIdentifierTitle;

  /// No description provided for @productDescriptionTitle.
  ///
  /// In ar, this message translates to:
  /// **'الوصف'**
  String get productDescriptionTitle;

  /// No description provided for @productAvailabilityTitle.
  ///
  /// In ar, this message translates to:
  /// **'حالة البيع'**
  String get productAvailabilityTitle;

  /// No description provided for @productAvailableForSale.
  ///
  /// In ar, this message translates to:
  /// **'هذا المنتج متاح للبيع في نقطة البيع.'**
  String get productAvailableForSale;

  /// No description provided for @productUnavailableForSale.
  ///
  /// In ar, this message translates to:
  /// **'هذا المنتج متوقف ولا يظهر للبيع.'**
  String get productUnavailableForSale;

  /// No description provided for @stockSummaryTitle.
  ///
  /// In ar, this message translates to:
  /// **'المخزون'**
  String get stockSummaryTitle;

  /// No description provided for @stockOnHandLabel.
  ///
  /// In ar, this message translates to:
  /// **'المتاح'**
  String get stockOnHandLabel;

  /// No description provided for @stockLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل المخزون.'**
  String get stockLoadError;

  /// No description provided for @stockMovementsButton.
  ///
  /// In ar, this message translates to:
  /// **'حركات المخزون'**
  String get stockMovementsButton;

  /// No description provided for @stockMovementsTitle.
  ///
  /// In ar, this message translates to:
  /// **'حركات المخزون'**
  String get stockMovementsTitle;

  /// No description provided for @emptyStockMovements.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد حركات مخزون لهذا المنتج.'**
  String get emptyStockMovements;

  /// No description provided for @stockMovementLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل حركات المخزون.'**
  String get stockMovementLoadError;

  /// No description provided for @newStockMovementButton.
  ///
  /// In ar, this message translates to:
  /// **'حركة مخزون جديدة'**
  String get newStockMovementButton;

  /// No description provided for @newStockMovementTitle.
  ///
  /// In ar, this message translates to:
  /// **'حركة مخزون جديدة'**
  String get newStockMovementTitle;

  /// No description provided for @stockMovementTypeLabel.
  ///
  /// In ar, this message translates to:
  /// **'نوع الحركة'**
  String get stockMovementTypeLabel;

  /// No description provided for @stockMovementQuantityLabel.
  ///
  /// In ar, this message translates to:
  /// **'الكمية'**
  String get stockMovementQuantityLabel;

  /// No description provided for @stockMovementNoteLabel.
  ///
  /// In ar, this message translates to:
  /// **'ملاحظة'**
  String get stockMovementNoteLabel;

  /// No description provided for @saveStockMovementButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ الحركة'**
  String get saveStockMovementButton;

  /// No description provided for @stockMovementCreateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ حركة المخزون. راجع الكمية وحاول مرة أخرى.'**
  String get stockMovementCreateError;

  /// No description provided for @stockMovementIncrease.
  ///
  /// In ar, this message translates to:
  /// **'زيادة المخزون'**
  String get stockMovementIncrease;

  /// No description provided for @stockMovementDecrease.
  ///
  /// In ar, this message translates to:
  /// **'نقص المخزون'**
  String get stockMovementDecrease;

  /// No description provided for @stockMovementDamaged.
  ///
  /// In ar, this message translates to:
  /// **'تالف'**
  String get stockMovementDamaged;

  /// Quantity shown on a stock movement row.
  ///
  /// In ar, this message translates to:
  /// **'{quantity} قطعة'**
  String stockMovementQuantityValue(int quantity);

  /// No description provided for @barcodeLabelPrintTitle.
  ///
  /// In ar, this message translates to:
  /// **'طباعة ملصق الباركود'**
  String get barcodeLabelPrintTitle;

  /// No description provided for @barcodeLabelPrintButton.
  ///
  /// In ar, this message translates to:
  /// **'طباعة ملصقات'**
  String get barcodeLabelPrintButton;

  /// No description provided for @barcodeLabelPrintInProgressButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الطباعة...'**
  String get barcodeLabelPrintInProgressButton;

  /// No description provided for @barcodeLabelPrintNoBarcode.
  ///
  /// In ar, this message translates to:
  /// **'أضف باركودًا للمنتج قبل طباعة الملصق.'**
  String get barcodeLabelPrintNoBarcode;

  /// No description provided for @barcodeLabelCopiesDialogTitle.
  ///
  /// In ar, this message translates to:
  /// **'طباعة ملصقات الباركود'**
  String get barcodeLabelCopiesDialogTitle;

  /// No description provided for @barcodeLabelCopiesLabel.
  ///
  /// In ar, this message translates to:
  /// **'عدد النسخ'**
  String get barcodeLabelCopiesLabel;

  /// No description provided for @barcodeLabelCopiesHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: 10'**
  String get barcodeLabelCopiesHint;

  /// No description provided for @barcodeLabelCopiesPrintButton.
  ///
  /// In ar, this message translates to:
  /// **'طباعة'**
  String get barcodeLabelCopiesPrintButton;

  /// Message shown after barcode label copies are sent to the printer.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{تم إرسال ملصق باركود واحد للطابعة.} =2{تم إرسال ملصقي باركود للطابعة.} other{تم إرسال {count} ملصقات باركود للطابعة.}}'**
  String barcodeLabelPrintSuccess(num count);

  /// No description provided for @barcodeLabelPrintError.
  ///
  /// In ar, this message translates to:
  /// **'تعذرت طباعة ملصق الباركود. تحقق من إعدادات الطابعة.'**
  String get barcodeLabelPrintError;

  /// No description provided for @noBarcode.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد باركود'**
  String get noBarcode;

  /// No description provided for @noDescription.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد وصف لهذا المنتج'**
  String get noDescription;

  /// No description provided for @posProductLookupHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث عن منتج أو امسح الباركود'**
  String get posProductLookupHint;

  /// No description provided for @posAllProductsFilterLabel.
  ///
  /// In ar, this message translates to:
  /// **'الكل'**
  String get posAllProductsFilterLabel;

  /// Title for the POS variant picker shown after tapping a product with multiple active variants.
  ///
  /// In ar, this message translates to:
  /// **'اختيار خيار {productName}'**
  String posVariantPickerTitle(String productName);

  /// Stock quantity shown for a variant in the POS variant picker.
  ///
  /// In ar, this message translates to:
  /// **'المتاح {quantity}'**
  String posVariantPickerStock(int quantity);

  /// No description provided for @posProductHasNoActiveVariants.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد خيارات نشطة لهذا المنتج.'**
  String get posProductHasNoActiveVariants;

  /// No description provided for @clearBarcodeStatusTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إخفاء حالة الباركود'**
  String get clearBarcodeStatusTooltip;

  /// No description provided for @barcodeScanResolving.
  ///
  /// In ar, this message translates to:
  /// **'جار البحث عن الباركود...'**
  String get barcodeScanResolving;

  /// Status shown after a barcode scan adds a product to the cart.
  ///
  /// In ar, this message translates to:
  /// **'تمت إضافة {productName}'**
  String barcodeScanAdded(String productName);

  /// Status shown when a barcode scan does not match a product.
  ///
  /// In ar, this message translates to:
  /// **'لم يتم العثور على منتج للباركود {barcode}'**
  String barcodeScanNotFound(String barcode);

  /// No description provided for @barcodeScanError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر البحث عن الباركود. حاول مرة أخرى.'**
  String get barcodeScanError;

  /// No description provided for @cameraScannerSingleTitle.
  ///
  /// In ar, this message translates to:
  /// **'مسح باركود'**
  String get cameraScannerSingleTitle;

  /// No description provided for @cameraScannerMultipleTitle.
  ///
  /// In ar, this message translates to:
  /// **'مسح عدة منتجات'**
  String get cameraScannerMultipleTitle;

  /// No description provided for @cameraScannerStarting.
  ///
  /// In ar, this message translates to:
  /// **'جار تشغيل الكاميرا...'**
  String get cameraScannerStarting;

  /// No description provided for @cameraScannerPermissionError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تشغيل الكاميرا. تحقق من صلاحية الكاميرا وحاول مرة أخرى.'**
  String get cameraScannerPermissionError;

  /// Status shown while camera scanner resolves a barcode into a product.
  ///
  /// In ar, this message translates to:
  /// **'جار البحث عن منتج للباركود {barcode}...'**
  String cameraScannerResolvingProduct(String barcode);

  /// No description provided for @cameraScannerScanQuantityLabel.
  ///
  /// In ar, this message translates to:
  /// **'كمية كل مسح'**
  String get cameraScannerScanQuantityLabel;

  /// No description provided for @cameraScannerEmptyScans.
  ///
  /// In ar, this message translates to:
  /// **'وجّه الكاميرا نحو الباركود أو رمز QR.'**
  String get cameraScannerEmptyScans;

  /// No description provided for @cameraScannerDoneButton.
  ///
  /// In ar, this message translates to:
  /// **'اعتماد المسح'**
  String get cameraScannerDoneButton;

  /// Quantity shown for a scanned camera barcode entry.
  ///
  /// In ar, this message translates to:
  /// **'الكمية: {quantity}'**
  String cameraScannerQuantityValue(int quantity);

  /// No description provided for @removeScannedCodeTooltip.
  ///
  /// In ar, this message translates to:
  /// **'حذف الرمز الممسوح'**
  String get removeScannedCodeTooltip;

  /// No description provided for @switchCameraTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تبديل الكاميرا'**
  String get switchCameraTooltip;

  /// No description provided for @toggleTorchTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تشغيل أو إيقاف الفلاش'**
  String get toggleTorchTooltip;

  /// No description provided for @currentSaleTitle.
  ///
  /// In ar, this message translates to:
  /// **'البيع الحالي'**
  String get currentSaleTitle;

  /// No description provided for @clearCartTooltip.
  ///
  /// In ar, this message translates to:
  /// **'مسح السلة'**
  String get clearCartTooltip;

  /// No description provided for @removeCartLineTooltip.
  ///
  /// In ar, this message translates to:
  /// **'حذف العنصر من السلة'**
  String get removeCartLineTooltip;

  /// No description provided for @emptyCart.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عناصر في السلة'**
  String get emptyCart;

  /// No description provided for @openCartSheetButton.
  ///
  /// In ar, this message translates to:
  /// **'مراجعة السلة'**
  String get openCartSheetButton;

  /// No description provided for @purchasingTitle.
  ///
  /// In ar, this message translates to:
  /// **'المشتريات'**
  String get purchasingTitle;

  /// No description provided for @purchaseOrdersTitle.
  ///
  /// In ar, this message translates to:
  /// **'فواتير المشتريات'**
  String get purchaseOrdersTitle;

  /// No description provided for @refreshPurchaseOrdersTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث فواتير المشتريات'**
  String get refreshPurchaseOrdersTooltip;

  /// No description provided for @refreshPurchaseOrderDetailsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث تفاصيل أمر الشراء'**
  String get refreshPurchaseOrderDetailsTooltip;

  /// No description provided for @newPurchaseOrderButton.
  ///
  /// In ar, this message translates to:
  /// **'أمر شراء جديد'**
  String get newPurchaseOrderButton;

  /// No description provided for @newPurchaseOrderTitle.
  ///
  /// In ar, this message translates to:
  /// **'أمر شراء جديد'**
  String get newPurchaseOrderTitle;

  /// No description provided for @searchPurchaseOrdersHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث برقم أمر الشراء أو فاتورة المورد أو المنتج'**
  String get searchPurchaseOrdersHint;

  /// No description provided for @purchaseOrderSupplierFilterTitle.
  ///
  /// In ar, this message translates to:
  /// **'المورد'**
  String get purchaseOrderSupplierFilterTitle;

  /// No description provided for @allSuppliersFilterLabel.
  ///
  /// In ar, this message translates to:
  /// **'كل الموردين'**
  String get allSuppliersFilterLabel;

  /// No description provided for @clearSupplierFilterTooltip.
  ///
  /// In ar, this message translates to:
  /// **'مسح فلتر المورد'**
  String get clearSupplierFilterTooltip;

  /// No description provided for @purchaseOrderStatusFilterTitle.
  ///
  /// In ar, this message translates to:
  /// **'حالة أمر الشراء'**
  String get purchaseOrderStatusFilterTitle;

  /// No description provided for @purchaseOrderStatusAll.
  ///
  /// In ar, this message translates to:
  /// **'كل أوامر الشراء'**
  String get purchaseOrderStatusAll;

  /// No description provided for @purchaseOrderStatusDraft.
  ///
  /// In ar, this message translates to:
  /// **'مسودة'**
  String get purchaseOrderStatusDraft;

  /// No description provided for @purchaseOrderStatusSubmitted.
  ///
  /// In ar, this message translates to:
  /// **'مرسل'**
  String get purchaseOrderStatusSubmitted;

  /// No description provided for @purchaseOrderStatusPartiallyReceived.
  ///
  /// In ar, this message translates to:
  /// **'مستلم جزئيًا'**
  String get purchaseOrderStatusPartiallyReceived;

  /// No description provided for @purchaseOrderStatusReceived.
  ///
  /// In ar, this message translates to:
  /// **'مستلم'**
  String get purchaseOrderStatusReceived;

  /// No description provided for @purchaseOrderStatusCancelled.
  ///
  /// In ar, this message translates to:
  /// **'ملغى'**
  String get purchaseOrderStatusCancelled;

  /// No description provided for @purchaseOrderOrderingNewest.
  ///
  /// In ar, this message translates to:
  /// **'الأحدث أولًا'**
  String get purchaseOrderOrderingNewest;

  /// No description provided for @purchaseOrderOrderingUpdated.
  ///
  /// In ar, this message translates to:
  /// **'آخر تحديث'**
  String get purchaseOrderOrderingUpdated;

  /// No description provided for @purchaseOrderOrderingTotalDesc.
  ///
  /// In ar, this message translates to:
  /// **'الإجمالي: من الأعلى إلى الأقل'**
  String get purchaseOrderOrderingTotalDesc;

  /// No description provided for @purchaseOrderOrderingNumber.
  ///
  /// In ar, this message translates to:
  /// **'رقم أمر الشراء'**
  String get purchaseOrderOrderingNumber;

  /// No description provided for @purchaseOrdersLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل فواتير المشتريات.'**
  String get purchaseOrdersLoadError;

  /// No description provided for @purchaseOrderDetailsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل تفاصيل أمر الشراء.'**
  String get purchaseOrderDetailsLoadError;

  /// No description provided for @outstandingPurchasesTitle.
  ///
  /// In ar, this message translates to:
  /// **'مستلم وغير مدفوع'**
  String get outstandingPurchasesTitle;

  /// No description provided for @outstandingPurchasesLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل المشتريات المستلمة غير المدفوعة.'**
  String get outstandingPurchasesLoadError;

  /// Summary for received but unpaid purchase orders.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد فواتير} =1{فاتورة واحدة • {amount}} =2{فاتورتان • {amount}} other{{count} فواتير • {amount}}}'**
  String outstandingPurchasesSummary(num count, String amount);

  /// Partial loaded summary for received but unpaid purchase orders while more pages are available.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لم يتم تحميل فواتير} =1{المحمّل: فاتورة واحدة • {amount}} =2{المحمّل: فاتورتان • {amount}} other{المحمّل: {count} فواتير • {amount}}}'**
  String outstandingPurchasesLoadedSummary(num count, String amount);

  /// Outstanding balance amount for a purchase order.
  ///
  /// In ar, this message translates to:
  /// **'متبقي {amount}'**
  String purchaseOutstandingAmountValue(String amount);

  /// No description provided for @emptyPurchaseOrders.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد فواتير مشتريات بعد.'**
  String get emptyPurchaseOrders;

  /// Fallback purchase order title when the generated order number is unavailable.
  ///
  /// In ar, this message translates to:
  /// **'أمر شراء #{id}'**
  String purchaseOrderFallbackTitle(int id);

  /// No description provided for @purchaseOrderDetailsSummaryTitle.
  ///
  /// In ar, this message translates to:
  /// **'ملخص أمر الشراء'**
  String get purchaseOrderDetailsSummaryTitle;

  /// No description provided for @purchaseOrderNumberLabel.
  ///
  /// In ar, this message translates to:
  /// **'رقم أمر الشراء'**
  String get purchaseOrderNumberLabel;

  /// Internal Pointy purchase order number label.
  ///
  /// In ar, this message translates to:
  /// **'أمر الشراء {orderNumber}'**
  String purchaseOrderNumberValue(String orderNumber);

  /// No description provided for @supplierInvoiceNumberLabel.
  ///
  /// In ar, this message translates to:
  /// **'رقم فاتورة المورد'**
  String get supplierInvoiceNumberLabel;

  /// No description provided for @supplierInvoiceNumberHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: INV-1024'**
  String get supplierInvoiceNumberHint;

  /// Supplier invoice number shown in purchase summaries.
  ///
  /// In ar, this message translates to:
  /// **'فاتورة المورد {invoiceNumber}'**
  String supplierInvoiceNumberValue(String invoiceNumber);

  /// No description provided for @supplierInvoiceDateLabel.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ فاتورة المورد'**
  String get supplierInvoiceDateLabel;

  /// No description provided for @supplierInvoiceDateHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: 2026-05-19'**
  String get supplierInvoiceDateHint;

  /// No description provided for @supplierInvoiceDateInvalid.
  ///
  /// In ar, this message translates to:
  /// **'أدخل التاريخ بصيغة سنة-شهر-يوم.'**
  String get supplierInvoiceDateInvalid;

  /// No description provided for @supplierInvoiceDatePickerTooltip.
  ///
  /// In ar, this message translates to:
  /// **'اختيار تاريخ فاتورة المورد'**
  String get supplierInvoiceDatePickerTooltip;

  /// Supplier invoice date shown in purchase summaries.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الفاتورة {date}'**
  String supplierInvoiceDateValue(String date);

  /// No description provided for @purchaseOrderLineCountLabel.
  ///
  /// In ar, this message translates to:
  /// **'العناصر'**
  String get purchaseOrderLineCountLabel;

  /// No description provided for @purchaseOrderCreatedAtLabel.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الإنشاء'**
  String get purchaseOrderCreatedAtLabel;

  /// No description provided for @purchaseOrderSubmittedAtLabel.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الإرسال'**
  String get purchaseOrderSubmittedAtLabel;

  /// No description provided for @purchaseOrderReceivedAtLabel.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الاستلام'**
  String get purchaseOrderReceivedAtLabel;

  /// No description provided for @purchaseOrderDueDateLabel.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الاستحقاق'**
  String get purchaseOrderDueDateLabel;

  /// Compact due date shown in purchase order lists.
  ///
  /// In ar, this message translates to:
  /// **'الاستحقاق {date}'**
  String purchaseOrderDueDateValue(String date);

  /// No description provided for @purchaseOrderOverdueValue.
  ///
  /// In ar, this message translates to:
  /// **'متأخر'**
  String get purchaseOrderOverdueValue;

  /// No description provided for @purchaseOrderPaymentStatusLabel.
  ///
  /// In ar, this message translates to:
  /// **'حالة السداد'**
  String get purchaseOrderPaymentStatusLabel;

  /// No description provided for @purchasePaymentStatusUnpaid.
  ///
  /// In ar, this message translates to:
  /// **'غير مدفوع'**
  String get purchasePaymentStatusUnpaid;

  /// No description provided for @purchasePaymentStatusPartial.
  ///
  /// In ar, this message translates to:
  /// **'مدفوع جزئيًا'**
  String get purchasePaymentStatusPartial;

  /// No description provided for @purchasePaymentStatusPaid.
  ///
  /// In ar, this message translates to:
  /// **'مدفوع'**
  String get purchasePaymentStatusPaid;

  /// No description provided for @purchasePaymentStatusCredit.
  ///
  /// In ar, this message translates to:
  /// **'رصيد دائن'**
  String get purchasePaymentStatusCredit;

  /// No description provided for @purchaseOrderPaidTotalLabel.
  ///
  /// In ar, this message translates to:
  /// **'المدفوع'**
  String get purchaseOrderPaidTotalLabel;

  /// No description provided for @purchaseOrderCreditAppliedLabel.
  ///
  /// In ar, this message translates to:
  /// **'رصيد مستخدم'**
  String get purchaseOrderCreditAppliedLabel;

  /// No description provided for @purchaseOrderAdjustmentCreditLabel.
  ///
  /// In ar, this message translates to:
  /// **'رصيد من المرتجعات'**
  String get purchaseOrderAdjustmentCreditLabel;

  /// No description provided for @purchaseOrderBalanceDueLabel.
  ///
  /// In ar, this message translates to:
  /// **'المتبقي للمورد'**
  String get purchaseOrderBalanceDueLabel;

  /// No description provided for @purchaseOrderActionsTitle.
  ///
  /// In ar, this message translates to:
  /// **'إجراءات الحالة'**
  String get purchaseOrderActionsTitle;

  /// No description provided for @submitPurchaseOrderAction.
  ///
  /// In ar, this message translates to:
  /// **'إرسال'**
  String get submitPurchaseOrderAction;

  /// No description provided for @receivePurchaseOrderAction.
  ///
  /// In ar, this message translates to:
  /// **'تحديد كمستلم'**
  String get receivePurchaseOrderAction;

  /// No description provided for @receivePurchaseLinesAction.
  ///
  /// In ar, this message translates to:
  /// **'استلام كميات'**
  String get receivePurchaseLinesAction;

  /// No description provided for @purchaseOrderAdjustmentsTitle.
  ///
  /// In ar, this message translates to:
  /// **'المرتجعات والاستبدالات'**
  String get purchaseOrderAdjustmentsTitle;

  /// No description provided for @returnPurchaseItemsAction.
  ///
  /// In ar, this message translates to:
  /// **'إرجاع'**
  String get returnPurchaseItemsAction;

  /// No description provided for @refundPurchaseItemsAction.
  ///
  /// In ar, this message translates to:
  /// **'استرداد'**
  String get refundPurchaseItemsAction;

  /// No description provided for @exchangePurchaseItemsAction.
  ///
  /// In ar, this message translates to:
  /// **'استبدال'**
  String get exchangePurchaseItemsAction;

  /// No description provided for @purchaseOrderStatusChangeError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تغيير حالة أمر الشراء. حاول مرة أخرى.'**
  String get purchaseOrderStatusChangeError;

  /// No description provided for @purchaseOrderAdjustmentError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تسجيل تعديل المشتريات. راجع الكميات والمخزون وحاول مرة أخرى.'**
  String get purchaseOrderAdjustmentError;

  /// No description provided for @purchaseOrderAdjustmentStockUnavailableError.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكن تعديل أمر الشراء لأن الكمية المستلمة بيعت أو لم تعد متوفرة في المخزون.'**
  String get purchaseOrderAdjustmentStockUnavailableError;

  /// No description provided for @purchaseOrderPermissionError.
  ///
  /// In ar, this message translates to:
  /// **'لا يملك هذا المستخدم صلاحية تنفيذ هذا الإجراء على أمر الشراء.'**
  String get purchaseOrderPermissionError;

  /// No description provided for @purchaseOrderValidationError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تنفيذ الإجراء. راجع حالة أمر الشراء والكميات ثم حاول مرة أخرى.'**
  String get purchaseOrderValidationError;

  /// No description provided for @purchaseOrderPaymentError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تسجيل دفعة المورد. راجع المبلغ وطريقة الدفع وحاول مرة أخرى.'**
  String get purchaseOrderPaymentError;

  /// No description provided for @recordSupplierPaymentAction.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل دفعة'**
  String get recordSupplierPaymentAction;

  /// No description provided for @supplierPaymentTitle.
  ///
  /// In ar, this message translates to:
  /// **'دفعة للمورد'**
  String get supplierPaymentTitle;

  /// No description provided for @supplierPaymentAmountLabel.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ'**
  String get supplierPaymentAmountLabel;

  /// No description provided for @supplierPaymentReferenceLabel.
  ///
  /// In ar, this message translates to:
  /// **'مرجع اختياري'**
  String get supplierPaymentReferenceLabel;

  /// No description provided for @supplierPaymentNotesLabel.
  ///
  /// In ar, this message translates to:
  /// **'ملاحظات اختيارية'**
  String get supplierPaymentNotesLabel;

  /// No description provided for @supplierPaymentPositiveAmountError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل مبلغًا أكبر من صفر ولا يتجاوز المتبقي.'**
  String get supplierPaymentPositiveAmountError;

  /// Message shown after a supplier payment is recorded for a purchase order.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل دفعة المورد لأمر الشراء رقم {orderNumber}.'**
  String supplierPaymentSuccess(String orderNumber);

  /// No description provided for @supplierPaymentMethodCredit.
  ///
  /// In ar, this message translates to:
  /// **'رصيد المورد'**
  String get supplierPaymentMethodCredit;

  /// No description provided for @purchaseReturnTitle.
  ///
  /// In ar, this message translates to:
  /// **'إرجاع مشتريات'**
  String get purchaseReturnTitle;

  /// No description provided for @purchaseRefundTitle.
  ///
  /// In ar, this message translates to:
  /// **'استرداد مشتريات'**
  String get purchaseRefundTitle;

  /// No description provided for @purchaseExchangeTitle.
  ///
  /// In ar, this message translates to:
  /// **'استبدال مشتريات'**
  String get purchaseExchangeTitle;

  /// No description provided for @purchaseAdjustmentReasonLabel.
  ///
  /// In ar, this message translates to:
  /// **'سبب التعديل'**
  String get purchaseAdjustmentReasonLabel;

  /// No description provided for @purchaseAdjustmentReasonHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: تالف، خطأ في الفاتورة، استبدال مع المورد'**
  String get purchaseAdjustmentReasonHint;

  /// No description provided for @purchaseNoAdjustableItems.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عناصر قابلة للتعديل.'**
  String get purchaseNoAdjustableItems;

  /// No description provided for @purchaseAdjustmentNoItemsSelected.
  ///
  /// In ar, this message translates to:
  /// **'اختر عنصرًا واحدًا على الأقل.'**
  String get purchaseAdjustmentNoItemsSelected;

  /// No description provided for @purchaseExchangeNoItemsSelected.
  ///
  /// In ar, this message translates to:
  /// **'اختر عناصر صادرة وعناصر بديلة للاستبدال.'**
  String get purchaseExchangeNoItemsSelected;

  /// No description provided for @purchaseExchangeOutboundSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'العناصر الصادرة'**
  String get purchaseExchangeOutboundSectionTitle;

  /// No description provided for @purchaseExchangeReplacementSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'العناصر البديلة'**
  String get purchaseExchangeReplacementSectionTitle;

  /// No description provided for @purchaseExchangeAddReplacementLine.
  ///
  /// In ar, this message translates to:
  /// **'إضافة بديل'**
  String get purchaseExchangeAddReplacementLine;

  /// No description provided for @purchaseExchangeNoReplacementProducts.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد منتجات متاحة للاختيار من هذا الأمر.'**
  String get purchaseExchangeNoReplacementProducts;

  /// No description provided for @purchaseExchangeInvalidLinesError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل كمية صادرة واحدة على الأقل وبديلًا بكمية وتكلفة صحيحتين.'**
  String get purchaseExchangeInvalidLinesError;

  /// No description provided for @purchaseExchangeReplacementProductLabel.
  ///
  /// In ar, this message translates to:
  /// **'المنتج البديل'**
  String get purchaseExchangeReplacementProductLabel;

  /// No description provided for @purchaseExchangeReplacementQuantityLabel.
  ///
  /// In ar, this message translates to:
  /// **'الكمية'**
  String get purchaseExchangeReplacementQuantityLabel;

  /// No description provided for @purchaseExchangeReplacementUnitCostLabel.
  ///
  /// In ar, this message translates to:
  /// **'التكلفة'**
  String get purchaseExchangeReplacementUnitCostLabel;

  /// Message shown after returning purchase items.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل إرجاع المشتريات رقم {orderNumber}.'**
  String purchaseReturnSuccess(String orderNumber);

  /// Message shown after refunding purchase items.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل استرداد المشتريات رقم {orderNumber}.'**
  String purchaseRefundSuccess(String orderNumber);

  /// Message shown after exchanging purchase items.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل استبدال المشتريات رقم {orderNumber}.'**
  String purchaseExchangeSuccess(String orderNumber);

  /// Remaining adjustable purchase line quantity.
  ///
  /// In ar, this message translates to:
  /// **'المتبقي {remaining} من {quantity}'**
  String purchaseAdjustmentLineRemaining(int remaining, int quantity);

  /// No description provided for @purchaseAdjustmentHistoryEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مرتجعات أو استبدالات مسجلة.'**
  String get purchaseAdjustmentHistoryEmpty;

  /// No description provided for @purchaseAdjustmentTypeReturn.
  ///
  /// In ar, this message translates to:
  /// **'إرجاع'**
  String get purchaseAdjustmentTypeReturn;

  /// No description provided for @purchaseAdjustmentTypeRefund.
  ///
  /// In ar, this message translates to:
  /// **'استرداد'**
  String get purchaseAdjustmentTypeRefund;

  /// No description provided for @purchaseAdjustmentTypeExchange.
  ///
  /// In ar, this message translates to:
  /// **'استبدال'**
  String get purchaseAdjustmentTypeExchange;

  /// Settlement method shown on a purchase adjustment.
  ///
  /// In ar, this message translates to:
  /// **'التسوية: {method}'**
  String purchaseAdjustmentSettlementMethod(String method);

  /// Supplier credit created by a purchase return or adjustment.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ رصيد مورد بقيمة {amount}'**
  String purchaseAdjustmentSupplierCreditCreated(String amount);

  /// Remaining supplier credit balance shown in adjustment history.
  ///
  /// In ar, this message translates to:
  /// **'المتبقي من الرصيد {amount}'**
  String purchaseAdjustmentSupplierCreditRemaining(String amount);

  /// Replacement line count label for a purchase exchange history item.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد بدائل} =1{بديل واحد} =2{بديلان} other{{count} بدائل}}'**
  String purchaseExchangeReplacementLineCount(num count);

  /// Replacement product line shown in purchase exchange history.
  ///
  /// In ar, this message translates to:
  /// **'بديل: {product} × {quantity} بتكلفة {unitCost}'**
  String purchaseExchangeReplacementHistoryLine(
    String product,
    int quantity,
    String unitCost,
  );

  /// Message shown after a purchase order is submitted from details.
  ///
  /// In ar, this message translates to:
  /// **'تم إرسال أمر الشراء رقم {orderNumber}.'**
  String purchaseOrderSubmitSuccess(String orderNumber);

  /// Message shown after a purchase order is received.
  ///
  /// In ar, this message translates to:
  /// **'تم استلام أمر الشراء رقم {orderNumber}.'**
  String purchaseOrderReceiveSuccess(String orderNumber);

  /// No description provided for @purchaseReceiveTitle.
  ///
  /// In ar, this message translates to:
  /// **'استلام كميات أمر الشراء'**
  String get purchaseReceiveTitle;

  /// No description provided for @purchaseReceiveNoOpenLines.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد كميات مفتوحة للاستلام.'**
  String get purchaseReceiveNoOpenLines;

  /// No description provided for @purchaseReceiveNoItemsSelected.
  ///
  /// In ar, this message translates to:
  /// **'أدخل كمية مستلمة أو تالفة أو مرفوضة لعنصر واحد على الأقل.'**
  String get purchaseReceiveNoItemsSelected;

  /// No description provided for @purchaseReceiveInvalidQuantityError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل كميات صحيحة لا تقل عن صفر.'**
  String get purchaseReceiveInvalidQuantityError;

  /// No description provided for @purchaseExpiryDatesRequired.
  ///
  /// In ar, this message translates to:
  /// **'أدخل تاريخ انتهاء لكل منتج يتابع الانتهاء.'**
  String get purchaseExpiryDatesRequired;

  /// No description provided for @purchaseReceiveReceivedLabel.
  ///
  /// In ar, this message translates to:
  /// **'مستلم سليم'**
  String get purchaseReceiveReceivedLabel;

  /// No description provided for @purchaseReceiveDamagedLabel.
  ///
  /// In ar, this message translates to:
  /// **'تالف عند الوصول'**
  String get purchaseReceiveDamagedLabel;

  /// No description provided for @purchaseReceiveRejectedLabel.
  ///
  /// In ar, this message translates to:
  /// **'مرفوض/لن يصل'**
  String get purchaseReceiveRejectedLabel;

  /// No description provided for @purchaseReceiveNoteLabel.
  ///
  /// In ar, this message translates to:
  /// **'ملاحظة الاستلام'**
  String get purchaseReceiveNoteLabel;

  /// No description provided for @purchaseReceiveNoteHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: نقص في الصندوق أو زيادة من المورد'**
  String get purchaseReceiveNoteHint;

  /// Expected purchase line quantity in the receiving dialog.
  ///
  /// In ar, this message translates to:
  /// **'المطلوب {quantity}'**
  String purchaseReceiveExpectedValue(int quantity);

  /// Already received quantity in the receiving dialog.
  ///
  /// In ar, this message translates to:
  /// **'استلم سابقًا {quantity}'**
  String purchaseReceiveAlreadyValue(int quantity);

  /// Open/backordered quantity in the receiving dialog.
  ///
  /// In ar, this message translates to:
  /// **'المفتوح {quantity}'**
  String purchaseReceiveOpenValue(int quantity);

  /// Open or backordered quantity after receiving dialog values are applied.
  ///
  /// In ar, this message translates to:
  /// **'المفتوح بعد الإدخال {quantity}'**
  String purchaseReceiveOpenAfterValue(int quantity);

  /// Receiving variance after entered quantities are applied.
  ///
  /// In ar, this message translates to:
  /// **'الفرق بعد الإدخال {quantity}'**
  String purchaseReceiveAfterVarianceValue(String quantity);

  /// Message shown after a purchase order is cancelled.
  ///
  /// In ar, this message translates to:
  /// **'تم إلغاء أمر الشراء رقم {orderNumber}.'**
  String purchaseOrderCancelSuccess(String orderNumber);

  /// No description provided for @purchaseOrderLinesTitle.
  ///
  /// In ar, this message translates to:
  /// **'محتويات أمر الشراء'**
  String get purchaseOrderLinesTitle;

  /// No description provided for @purchaseOrderUnknownProduct.
  ///
  /// In ar, this message translates to:
  /// **'منتج غير محدد'**
  String get purchaseOrderUnknownProduct;

  /// Purchase order line quantity label.
  ///
  /// In ar, this message translates to:
  /// **'الكمية {quantity}'**
  String purchaseOrderLineQuantity(int quantity);

  /// Total received quantity shown on purchase order lines and receipts.
  ///
  /// In ar, this message translates to:
  /// **'مستلم {quantity}'**
  String purchaseLineReceivedQuantity(int quantity);

  /// Open or backordered quantity shown on purchase order lines.
  ///
  /// In ar, this message translates to:
  /// **'مفتوح/متأخر {quantity}'**
  String purchaseLineOpenQuantity(int quantity);

  /// Damaged purchase quantity.
  ///
  /// In ar, this message translates to:
  /// **'تالف {quantity}'**
  String purchaseLineDamagedQuantity(int quantity);

  /// Rejected purchase quantity.
  ///
  /// In ar, this message translates to:
  /// **'مرفوض {quantity}'**
  String purchaseLineRejectedQuantity(int quantity);

  /// Purchase receiving variance quantity.
  ///
  /// In ar, this message translates to:
  /// **'الفرق {quantity}'**
  String purchaseLineVarianceValue(String quantity);

  /// No description provided for @purchaseReceiptHistoryTitle.
  ///
  /// In ar, this message translates to:
  /// **'سجل الاستلام'**
  String get purchaseReceiptHistoryTitle;

  /// No description provided for @purchaseReceiptHistoryEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عمليات استلام مسجلة.'**
  String get purchaseReceiptHistoryEmpty;

  /// No description provided for @purchaseReceiptHistoryItemFallback.
  ///
  /// In ar, this message translates to:
  /// **'عملية استلام'**
  String get purchaseReceiptHistoryItemFallback;

  /// Previous product purchase cost shown on a purchase order line.
  ///
  /// In ar, this message translates to:
  /// **'آخر تكلفة {amount}'**
  String purchaseOrderPreviousCostValue(String amount);

  /// Purchase order line cost change compared with the previous cost.
  ///
  /// In ar, this message translates to:
  /// **'تغير التكلفة {amount}'**
  String purchaseOrderCostChangeValue(String amount);

  /// Purchase order line cost change percent.
  ///
  /// In ar, this message translates to:
  /// **'{percent}%'**
  String purchaseOrderCostChangePercentValue(String percent);

  /// No description provided for @purchaseCatalogTitle.
  ///
  /// In ar, this message translates to:
  /// **'كتالوج الشراء'**
  String get purchaseCatalogTitle;

  /// No description provided for @purchaseProductLookupHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث عن منتج لإضافته للمشتريات'**
  String get purchaseProductLookupHint;

  /// No description provided for @purchaseDraftTitle.
  ///
  /// In ar, this message translates to:
  /// **'مسودة الشراء'**
  String get purchaseDraftTitle;

  /// No description provided for @openPurchaseDraftSheetButton.
  ///
  /// In ar, this message translates to:
  /// **'مراجعة المسودة'**
  String get openPurchaseDraftSheetButton;

  /// No description provided for @clearPurchaseDraftTooltip.
  ///
  /// In ar, this message translates to:
  /// **'مسح مسودة الشراء'**
  String get clearPurchaseDraftTooltip;

  /// No description provided for @emptyPurchaseDraft.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عناصر في مسودة الشراء'**
  String get emptyPurchaseDraft;

  /// No description provided for @purchaseLineCostLabel.
  ///
  /// In ar, this message translates to:
  /// **'التكلفة'**
  String get purchaseLineCostLabel;

  /// No description provided for @purchaseLineExpiryDateLabel.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الانتهاء'**
  String get purchaseLineExpiryDateLabel;

  /// No description provided for @purchaseLineExpiryDateHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: 2026-12-31'**
  String get purchaseLineExpiryDateHint;

  /// No description provided for @purchaseLineExpiryDatePickerTooltip.
  ///
  /// In ar, this message translates to:
  /// **'اختيار تاريخ الانتهاء'**
  String get purchaseLineExpiryDatePickerTooltip;

  /// No description provided for @purchaseLineExpiryDateInvalid.
  ///
  /// In ar, this message translates to:
  /// **'أدخل تاريخًا صحيحًا بصيغة سنة-شهر-يوم.'**
  String get purchaseLineExpiryDateInvalid;

  /// No description provided for @purchaseLineExpiryDateRequired.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الانتهاء مطلوب لهذا المنتج.'**
  String get purchaseLineExpiryDateRequired;

  /// No description provided for @purchaseShippingCostLabel.
  ///
  /// In ar, this message translates to:
  /// **'الشحن'**
  String get purchaseShippingCostLabel;

  /// No description provided for @purchaseCustomsCostLabel.
  ///
  /// In ar, this message translates to:
  /// **'الجمارك'**
  String get purchaseCustomsCostLabel;

  /// No description provided for @purchaseHandlingCostLabel.
  ///
  /// In ar, this message translates to:
  /// **'المناولة'**
  String get purchaseHandlingCostLabel;

  /// No description provided for @purchaseLandedCostTotalLabel.
  ///
  /// In ar, this message translates to:
  /// **'تكاليف الوصول'**
  String get purchaseLandedCostTotalLabel;

  /// Button label showing the purchase landed cost total.
  ///
  /// In ar, this message translates to:
  /// **'تكاليف الوصول {amount}'**
  String purchaseLandedCostButton(String amount);

  /// No description provided for @purchaseLandedCostSheetTitle.
  ///
  /// In ar, this message translates to:
  /// **'تكاليف الوصول'**
  String get purchaseLandedCostSheetTitle;

  /// No description provided for @landedCostAllocationMethodLabel.
  ///
  /// In ar, this message translates to:
  /// **'طريقة توزيع تكاليف الوصول'**
  String get landedCostAllocationMethodLabel;

  /// No description provided for @landedCostEntryNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم التكلفة'**
  String get landedCostEntryNameLabel;

  /// No description provided for @landedCostEntryCostLabel.
  ///
  /// In ar, this message translates to:
  /// **'القيمة'**
  String get landedCostEntryCostLabel;

  /// No description provided for @addLandedCostEntryButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة تكلفة'**
  String get addLandedCostEntryButton;

  /// No description provided for @saveLandedCostEntriesButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ التكاليف'**
  String get saveLandedCostEntriesButton;

  /// No description provided for @removeLandedCostEntryTooltip.
  ///
  /// In ar, this message translates to:
  /// **'حذف التكلفة'**
  String get removeLandedCostEntryTooltip;

  /// No description provided for @defaultLandedCostEntryName.
  ///
  /// In ar, this message translates to:
  /// **'تكلفة وصول'**
  String get defaultLandedCostEntryName;

  /// No description provided for @landedCostAllocationByLineValueLabel.
  ///
  /// In ar, this message translates to:
  /// **'حسب قيمة السطر'**
  String get landedCostAllocationByLineValueLabel;

  /// No description provided for @landedCostAllocationByQuantityLabel.
  ///
  /// In ar, this message translates to:
  /// **'حسب الكمية'**
  String get landedCostAllocationByQuantityLabel;

  /// No description provided for @landedCostAllocationByRetailValueLabel.
  ///
  /// In ar, this message translates to:
  /// **'حسب قيمة البيع'**
  String get landedCostAllocationByRetailValueLabel;

  /// No description provided for @landedCostAllocationEquallyByLineLabel.
  ///
  /// In ar, this message translates to:
  /// **'بالتساوي على السطور'**
  String get landedCostAllocationEquallyByLineLabel;

  /// Allocated landed cost shown on a purchase order line.
  ///
  /// In ar, this message translates to:
  /// **'تكلفة وصول {amount}'**
  String purchaseLineLandedCostValue(String amount);

  /// Effective unit cost after landed cost allocation.
  ///
  /// In ar, this message translates to:
  /// **'التكلفة الفعلية {amount}'**
  String purchaseLineEffectiveCostValue(String amount);

  /// No description provided for @receivePurchaseImmediatelyLabel.
  ///
  /// In ar, this message translates to:
  /// **'استلام أمر الشراء فورًا'**
  String get receivePurchaseImmediatelyLabel;

  /// No description provided for @quickCreateProductTitle.
  ///
  /// In ar, this message translates to:
  /// **'إضافة منتج سريع'**
  String get quickCreateProductTitle;

  /// Explains that a scanned barcode is missing and can be created quickly.
  ///
  /// In ar, this message translates to:
  /// **'الباركود {barcode} غير موجود. أضف المنتج الآن لمتابعة أمر الشراء.'**
  String quickCreateProductMessage(String barcode);

  /// No description provided for @quickCreateProductNameHint.
  ///
  /// In ar, this message translates to:
  /// **'اسم المنتج على فاتورة المورد'**
  String get quickCreateProductNameHint;

  /// No description provided for @quickCreateUnitCostLabel.
  ///
  /// In ar, this message translates to:
  /// **'تكلفة الشراء'**
  String get quickCreateUnitCostLabel;

  /// No description provided for @quickCreateProductButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة للشراء'**
  String get quickCreateProductButton;

  /// No description provided for @quickCreateProductSaving.
  ///
  /// In ar, this message translates to:
  /// **'جار الإضافة...'**
  String get quickCreateProductSaving;

  /// Submit purchase order button label with total amount.
  ///
  /// In ar, this message translates to:
  /// **'إرسال أمر الشراء {amount}'**
  String submitPurchaseDraftButton(String amount);

  /// No description provided for @purchaseSubmitInProgressButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الإرسال...'**
  String get purchaseSubmitInProgressButton;

  /// Message shown after a purchase order is submitted.
  ///
  /// In ar, this message translates to:
  /// **'تم إرسال أمر الشراء رقم {draftNumber}.'**
  String purchaseDraftSubmitSuccess(String draftNumber);

  /// No description provided for @purchaseDraftSubmitError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إرسال أمر الشراء. راجع العناصر ورقم فاتورة المورد وحاول مرة أخرى.'**
  String get purchaseDraftSubmitError;

  /// No description provided for @contactsTitle.
  ///
  /// In ar, this message translates to:
  /// **'العملاء والموردون'**
  String get contactsTitle;

  /// No description provided for @customersTab.
  ///
  /// In ar, this message translates to:
  /// **'العملاء'**
  String get customersTab;

  /// No description provided for @suppliersTab.
  ///
  /// In ar, this message translates to:
  /// **'الموردون'**
  String get suppliersTab;

  /// No description provided for @refreshContactsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث العملاء والموردين'**
  String get refreshContactsTooltip;

  /// No description provided for @contactSearchHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث بالاسم أو الهاتف أو البريد'**
  String get contactSearchHint;

  /// No description provided for @contactsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل العملاء والموردين.'**
  String get contactsLoadError;

  /// No description provided for @emptyCustomers.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد عملاء بعد.'**
  String get emptyCustomers;

  /// No description provided for @emptySuppliers.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد موردون بعد.'**
  String get emptySuppliers;

  /// No description provided for @addCustomerButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة عميل'**
  String get addCustomerButton;

  /// No description provided for @addSupplierButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة مورد'**
  String get addSupplierButton;

  /// No description provided for @customerFullNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم العميل'**
  String get customerFullNameLabel;

  /// No description provided for @supplierNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم المورد'**
  String get supplierNameLabel;

  /// No description provided for @contactPersonLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم جهة التواصل'**
  String get contactPersonLabel;

  /// No description provided for @phoneOptionalLabel.
  ///
  /// In ar, this message translates to:
  /// **'رقم الهاتف (اختياري)'**
  String get phoneOptionalLabel;

  /// No description provided for @emailOptionalLabel.
  ///
  /// In ar, this message translates to:
  /// **'البريد الإلكتروني (اختياري)'**
  String get emailOptionalLabel;

  /// No description provided for @birthdayOptionalLabel.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الميلاد (اختياري)'**
  String get birthdayOptionalLabel;

  /// No description provided for @birthdayHint.
  ///
  /// In ar, this message translates to:
  /// **'YYYY-MM-DD'**
  String get birthdayHint;

  /// No description provided for @genderLabel.
  ///
  /// In ar, this message translates to:
  /// **'الجنس'**
  String get genderLabel;

  /// No description provided for @genderUnspecified.
  ///
  /// In ar, this message translates to:
  /// **'غير محدد'**
  String get genderUnspecified;

  /// No description provided for @genderFemale.
  ///
  /// In ar, this message translates to:
  /// **'أنثى'**
  String get genderFemale;

  /// No description provided for @genderMale.
  ///
  /// In ar, this message translates to:
  /// **'ذكر'**
  String get genderMale;

  /// No description provided for @genderNonBinary.
  ///
  /// In ar, this message translates to:
  /// **'غير ثنائي'**
  String get genderNonBinary;

  /// No description provided for @genderPreferNotToSay.
  ///
  /// In ar, this message translates to:
  /// **'يفضل عدم الإفصاح'**
  String get genderPreferNotToSay;

  /// No description provided for @marketingConsentLabel.
  ///
  /// In ar, this message translates to:
  /// **'وافق على التواصل التسويقي'**
  String get marketingConsentLabel;

  /// No description provided for @addressOptionalLabel.
  ///
  /// In ar, this message translates to:
  /// **'العنوان (اختياري)'**
  String get addressOptionalLabel;

  /// No description provided for @notesOptionalLabel.
  ///
  /// In ar, this message translates to:
  /// **'ملاحظات (اختياري)'**
  String get notesOptionalLabel;

  /// No description provided for @activeContactLabel.
  ///
  /// In ar, this message translates to:
  /// **'نشط'**
  String get activeContactLabel;

  /// No description provided for @saveCustomerButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ العميل'**
  String get saveCustomerButton;

  /// No description provided for @saveSupplierButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ المورد'**
  String get saveSupplierButton;

  /// No description provided for @customerCreateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ العميل. راجع البيانات وحاول مرة أخرى.'**
  String get customerCreateError;

  /// No description provided for @supplierCreateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ المورد. راجع البيانات وحاول مرة أخرى.'**
  String get supplierCreateError;

  /// No description provided for @customerNumberLabel.
  ///
  /// In ar, this message translates to:
  /// **'رقم العميل'**
  String get customerNumberLabel;

  /// No description provided for @customerBirthdayLabel.
  ///
  /// In ar, this message translates to:
  /// **'الميلاد'**
  String get customerBirthdayLabel;

  /// No description provided for @marketingAllowedLabel.
  ///
  /// In ar, this message translates to:
  /// **'يسمح بالتسويق'**
  String get marketingAllowedLabel;

  /// No description provided for @inactiveContactLabel.
  ///
  /// In ar, this message translates to:
  /// **'غير نشط'**
  String get inactiveContactLabel;

  /// No description provided for @supplierContactLabel.
  ///
  /// In ar, this message translates to:
  /// **'جهة التواصل'**
  String get supplierContactLabel;

  /// Supplier contact person value.
  ///
  /// In ar, this message translates to:
  /// **'جهة التواصل {name}'**
  String supplierContactValue(String name);

  /// No description provided for @refreshSupplierDetailsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث تفاصيل المورد'**
  String get refreshSupplierDetailsTooltip;

  /// No description provided for @supplierDetailsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل ملخص المورد.'**
  String get supplierDetailsLoadError;

  /// No description provided for @supplierPurchaseSummaryTitle.
  ///
  /// In ar, this message translates to:
  /// **'ملخص الشراء من المورد'**
  String get supplierPurchaseSummaryTitle;

  /// No description provided for @supplierTotalBoughtLabel.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي المشتريات'**
  String get supplierTotalBoughtLabel;

  /// No description provided for @supplierPurchaseCountLabel.
  ///
  /// In ar, this message translates to:
  /// **'عدد أوامر الشراء'**
  String get supplierPurchaseCountLabel;

  /// Supplier purchase order count value.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد أوامر} =1{أمر واحد} =2{أمران} other{{count} أوامر}}'**
  String supplierPurchaseCountValue(num count);

  /// No description provided for @supplierPurchaseHistoryTitle.
  ///
  /// In ar, this message translates to:
  /// **'سجل مشتريات المورد'**
  String get supplierPurchaseHistoryTitle;

  /// No description provided for @supplierPurchaseHistoryLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل سجل مشتريات المورد.'**
  String get supplierPurchaseHistoryLoadError;

  /// No description provided for @supplierPurchaseHistoryEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مشتريات مسجلة لهذا المورد.'**
  String get supplierPurchaseHistoryEmpty;

  /// No description provided for @supplierReturnRefundHistoryTitle.
  ///
  /// In ar, this message translates to:
  /// **'سجل الإرجاع والاسترداد'**
  String get supplierReturnRefundHistoryTitle;

  /// No description provided for @supplierReturnRefundHistoryLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل سجل الإرجاع والاسترداد.'**
  String get supplierReturnRefundHistoryLoadError;

  /// No description provided for @supplierReturnRefundHistoryEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عمليات إرجاع أو استرداد لهذا المورد.'**
  String get supplierReturnRefundHistoryEmpty;

  /// Supplier payable balance shown in contacts.
  ///
  /// In ar, this message translates to:
  /// **'مستحق {amount}'**
  String supplierPayableBalanceValue(String amount);

  /// Supplier credit balance shown in contacts.
  ///
  /// In ar, this message translates to:
  /// **'رصيد {amount}'**
  String supplierCreditBalanceValue(String amount);

  /// Supplier net balance shown in contacts.
  ///
  /// In ar, this message translates to:
  /// **'الصافي {amount}'**
  String supplierNetBalanceValue(String amount);

  /// No description provided for @refreshCustomerDetailsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث تفاصيل العميل'**
  String get refreshCustomerDetailsTooltip;

  /// No description provided for @customerDetailsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل بيانات العميل.'**
  String get customerDetailsLoadError;

  /// No description provided for @customerProfileTitle.
  ///
  /// In ar, this message translates to:
  /// **'بيانات العميل'**
  String get customerProfileTitle;

  /// No description provided for @customerSalesSummaryTitle.
  ///
  /// In ar, this message translates to:
  /// **'ملخص تعاملات العميل'**
  String get customerSalesSummaryTitle;

  /// No description provided for @customerSalesSummaryLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل ملخص تعاملات العميل.'**
  String get customerSalesSummaryLoadError;

  /// No description provided for @customerInvoiceHistoryTitle.
  ///
  /// In ar, this message translates to:
  /// **'الفواتير'**
  String get customerInvoiceHistoryTitle;

  /// No description provided for @customerInvoiceHistoryLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل فواتير العميل.'**
  String get customerInvoiceHistoryLoadError;

  /// No description provided for @customerInvoiceHistoryEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد فواتير مسجلة لهذا العميل.'**
  String get customerInvoiceHistoryEmpty;

  /// No description provided for @customerAdjustmentHistoryTitle.
  ///
  /// In ar, this message translates to:
  /// **'الإرجاع والاستبدال والاسترداد'**
  String get customerAdjustmentHistoryTitle;

  /// No description provided for @customerAdjustmentHistoryLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل سجل الإرجاع والاسترداد.'**
  String get customerAdjustmentHistoryLoadError;

  /// No description provided for @customerAdjustmentHistoryEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عمليات إرجاع أو استبدال أو استرداد لهذا العميل.'**
  String get customerAdjustmentHistoryEmpty;

  /// No description provided for @customerEmptyValue.
  ///
  /// In ar, this message translates to:
  /// **'غير مسجل'**
  String get customerEmptyValue;

  /// No description provided for @customerMarketingConsentLabel.
  ///
  /// In ar, this message translates to:
  /// **'موافقة التسويق'**
  String get customerMarketingConsentLabel;

  /// No description provided for @customerStatusLabel.
  ///
  /// In ar, this message translates to:
  /// **'الحالة'**
  String get customerStatusLabel;

  /// No description provided for @customerNotesLabel.
  ///
  /// In ar, this message translates to:
  /// **'الملاحظات'**
  String get customerNotesLabel;

  /// No description provided for @customerTotalInvoicedLabel.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الفواتير'**
  String get customerTotalInvoicedLabel;

  /// No description provided for @customerNetSalesLabel.
  ///
  /// In ar, this message translates to:
  /// **'صافي المبيعات'**
  String get customerNetSalesLabel;

  /// No description provided for @customerInvoiceCountLabel.
  ///
  /// In ar, this message translates to:
  /// **'عدد الفواتير'**
  String get customerInvoiceCountLabel;

  /// Customer invoice count value.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد فواتير} =1{فاتورة واحدة} =2{فاتورتان} other{{count} فواتير}}'**
  String customerInvoiceCountValue(num count);

  /// No description provided for @customerPaidInvoiceCountLabel.
  ///
  /// In ar, this message translates to:
  /// **'الفواتير المدفوعة'**
  String get customerPaidInvoiceCountLabel;

  /// Customer paid invoice count value.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد فواتير مدفوعة} =1{فاتورة مدفوعة واحدة} =2{فاتورتان مدفوعتان} other{{count} فواتير مدفوعة}}'**
  String customerPaidInvoiceCountValue(num count);

  /// No description provided for @customerVoidCountLabel.
  ///
  /// In ar, this message translates to:
  /// **'الفواتير الملغاة'**
  String get customerVoidCountLabel;

  /// Customer voided invoice count value.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد فواتير ملغاة} =1{فاتورة ملغاة واحدة} =2{فاتورتان ملغاتان} other{{count} فواتير ملغاة}}'**
  String customerVoidCountValue(num count);

  /// No description provided for @customerVoidTotalLabel.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الإلغاء'**
  String get customerVoidTotalLabel;

  /// No description provided for @customerReturnCountLabel.
  ///
  /// In ar, this message translates to:
  /// **'عمليات الإرجاع'**
  String get customerReturnCountLabel;

  /// Customer return count value.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد عمليات إرجاع} =1{إرجاع واحد} =2{إرجاعان} other{{count} عمليات إرجاع}}'**
  String customerReturnCountValue(num count);

  /// No description provided for @customerReturnTotalLabel.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الإرجاع'**
  String get customerReturnTotalLabel;

  /// No description provided for @customerRefundCountLabel.
  ///
  /// In ar, this message translates to:
  /// **'عمليات الاسترداد'**
  String get customerRefundCountLabel;

  /// Customer refund count value.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد عمليات استرداد} =1{استرداد واحد} =2{استردادان} other{{count} عمليات استرداد}}'**
  String customerRefundCountValue(num count);

  /// No description provided for @customerRefundTotalLabel.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الاسترداد'**
  String get customerRefundTotalLabel;

  /// No description provided for @customerExchangeCountLabel.
  ///
  /// In ar, this message translates to:
  /// **'عمليات الاستبدال'**
  String get customerExchangeCountLabel;

  /// Customer exchange count value.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد عمليات استبدال} =1{استبدال واحد} =2{استبدالان} other{{count} عمليات استبدال}}'**
  String customerExchangeCountValue(num count);

  /// No description provided for @customerExchangeTotalLabel.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الاستبدال'**
  String get customerExchangeTotalLabel;

  /// No description provided for @customerLastInvoiceAtLabel.
  ///
  /// In ar, this message translates to:
  /// **'آخر فاتورة'**
  String get customerLastInvoiceAtLabel;

  /// No description provided for @saleOrderStatusPaid.
  ///
  /// In ar, this message translates to:
  /// **'مدفوعة'**
  String get saleOrderStatusPaid;

  /// No description provided for @saleOrderStatusVoid.
  ///
  /// In ar, this message translates to:
  /// **'ملغاة'**
  String get saleOrderStatusVoid;

  /// No description provided for @saleOrderStatusOpen.
  ///
  /// In ar, this message translates to:
  /// **'مفتوحة'**
  String get saleOrderStatusOpen;

  /// No description provided for @customerAdjustmentTypeReturn.
  ///
  /// In ar, this message translates to:
  /// **'إرجاع'**
  String get customerAdjustmentTypeReturn;

  /// No description provided for @customerAdjustmentTypeVoid.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء فاتورة'**
  String get customerAdjustmentTypeVoid;

  /// No description provided for @customerAdjustmentTypeExchange.
  ///
  /// In ar, this message translates to:
  /// **'استبدال'**
  String get customerAdjustmentTypeExchange;

  /// No description provided for @customerAdjustmentTypeRefund.
  ///
  /// In ar, this message translates to:
  /// **'استرداد'**
  String get customerAdjustmentTypeRefund;

  /// No description provided for @customerAdjustmentTypeUnknown.
  ///
  /// In ar, this message translates to:
  /// **'تعديل'**
  String get customerAdjustmentTypeUnknown;

  /// Refund method shown on a customer adjustment.
  ///
  /// In ar, this message translates to:
  /// **'استرداد: {method}'**
  String customerRefundMethodValue(String method);

  /// User who created a customer sales adjustment.
  ///
  /// In ar, this message translates to:
  /// **'بواسطة {username}'**
  String customerAdjustmentCreatedByValue(String username);

  /// No description provided for @selectedCustomerLabel.
  ///
  /// In ar, this message translates to:
  /// **'العميل'**
  String get selectedCustomerLabel;

  /// No description provided for @selectedSupplierLabel.
  ///
  /// In ar, this message translates to:
  /// **'المورد'**
  String get selectedSupplierLabel;

  /// No description provided for @walkInCustomerLabel.
  ///
  /// In ar, this message translates to:
  /// **'عميل عابر'**
  String get walkInCustomerLabel;

  /// No description provided for @noSupplierSelectedLabel.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد مورد محدد'**
  String get noSupplierSelectedLabel;

  /// No description provided for @purchaseSupplierRequiredHint.
  ///
  /// In ar, this message translates to:
  /// **'اختر موردًا قبل إرسال أمر الشراء.'**
  String get purchaseSupplierRequiredHint;

  /// No description provided for @chooseCustomerTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختيار العميل'**
  String get chooseCustomerTitle;

  /// No description provided for @chooseSupplierTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختيار المورد'**
  String get chooseSupplierTitle;

  /// No description provided for @changeContactAction.
  ///
  /// In ar, this message translates to:
  /// **'تغيير'**
  String get changeContactAction;

  /// No description provided for @clearContactTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إزالة الاختيار'**
  String get clearContactTooltip;

  /// No description provided for @createNewCustomerAction.
  ///
  /// In ar, this message translates to:
  /// **'عميل جديد'**
  String get createNewCustomerAction;

  /// No description provided for @createNewSupplierAction.
  ///
  /// In ar, this message translates to:
  /// **'مورد جديد'**
  String get createNewSupplierAction;

  /// Payment button label with the payable amount.
  ///
  /// In ar, this message translates to:
  /// **'ادفع {amount}'**
  String payAmount(String amount);

  /// No description provided for @checkoutInProgressButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الدفع...'**
  String get checkoutInProgressButton;

  /// No description provided for @paymentDialogTitle.
  ///
  /// In ar, this message translates to:
  /// **'إتمام الدفع'**
  String get paymentDialogTitle;

  /// No description provided for @paymentMethodLabel.
  ///
  /// In ar, this message translates to:
  /// **'طريقة الدفع'**
  String get paymentMethodLabel;

  /// No description provided for @cashReceivedLabel.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ المستلم'**
  String get cashReceivedLabel;

  /// No description provided for @cashReceivedTooLowError.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ المستلم أقل من الإجمالي.'**
  String get cashReceivedTooLowError;

  /// No description provided for @paymentTenderAmountLabel.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ'**
  String get paymentTenderAmountLabel;

  /// No description provided for @addSplitTenderButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة دفعة'**
  String get addSplitTenderButton;

  /// No description provided for @removeTenderTooltip.
  ///
  /// In ar, this message translates to:
  /// **'حذف الدفعة'**
  String get removeTenderTooltip;

  /// No description provided for @paymentMethodSplitTender.
  ///
  /// In ar, this message translates to:
  /// **'دفعات متعددة'**
  String get paymentMethodSplitTender;

  /// No description provided for @amountDueLabel.
  ///
  /// In ar, this message translates to:
  /// **'المستحق'**
  String get amountDueLabel;

  /// No description provided for @paymentQuickAmountsLabel.
  ///
  /// In ar, this message translates to:
  /// **'مبالغ سريعة'**
  String get paymentQuickAmountsLabel;

  /// No description provided for @paymentKeypadLabel.
  ///
  /// In ar, this message translates to:
  /// **'لوحة الإدخال'**
  String get paymentKeypadLabel;

  /// No description provided for @paymentKeypadBackspaceTooltip.
  ///
  /// In ar, this message translates to:
  /// **'حذف آخر رقم'**
  String get paymentKeypadBackspaceTooltip;

  /// No description provided for @paymentKeypadClearTooltip.
  ///
  /// In ar, this message translates to:
  /// **'مسح المبلغ'**
  String get paymentKeypadClearTooltip;

  /// Payment tender line title.
  ///
  /// In ar, this message translates to:
  /// **'دفعة {index}'**
  String paymentTenderLineTitle(int index);

  /// No description provided for @cardReceiptValidateButton.
  ///
  /// In ar, this message translates to:
  /// **'طابق الإيصال'**
  String get cardReceiptValidateButton;

  /// No description provided for @cardReceiptRescanButton.
  ///
  /// In ar, this message translates to:
  /// **'إعادة المسح'**
  String get cardReceiptRescanButton;

  /// No description provided for @cardReceiptRequiredInline.
  ///
  /// In ar, this message translates to:
  /// **'هذه الدفعة تحتاج مسح إيصال البطاقة.'**
  String get cardReceiptRequiredInline;

  /// No description provided for @cardReceiptRequiredError.
  ///
  /// In ar, this message translates to:
  /// **'يجب مطابقة كل دفعة بطاقة قبل تأكيد الدفع.'**
  String get cardReceiptRequiredError;

  /// Short successful card receipt validation summary.
  ///
  /// In ar, this message translates to:
  /// **'تمت المطابقة: {amount}، البطاقة {maskedPan}'**
  String cardReceiptValidatedSummary(String amount, String maskedPan);

  /// No description provided for @cardReceiptDialogTitle.
  ///
  /// In ar, this message translates to:
  /// **'مطابقة إيصال البطاقة'**
  String get cardReceiptDialogTitle;

  /// Expected card payment amount in the receipt validation dialog.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ المتوقع: {amount}'**
  String cardReceiptExpectedAmount(String amount);

  /// No description provided for @cardReceiptUrlLabel.
  ///
  /// In ar, this message translates to:
  /// **'رابط إيصال معاملات'**
  String get cardReceiptUrlLabel;

  /// No description provided for @cardReceiptCameraTooltip.
  ///
  /// In ar, this message translates to:
  /// **'مسح QR بالكاميرا'**
  String get cardReceiptCameraTooltip;

  /// No description provided for @cardReceiptCameraTitle.
  ///
  /// In ar, this message translates to:
  /// **'امسح QR إيصال البطاقة'**
  String get cardReceiptCameraTitle;

  /// Shown when a Moamalat receipt amount differs from the card tender amount.
  ///
  /// In ar, this message translates to:
  /// **'مبلغ الإيصال {receiptAmount} لا يطابق مبلغ الدفعة {expectedAmount}.'**
  String cardReceiptAmountMismatch(String receiptAmount, String expectedAmount);

  /// No description provided for @cardReceiptUrlRequiredError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل رابط الإيصال أو امسح رمز QR.'**
  String get cardReceiptUrlRequiredError;

  /// No description provided for @cardReceiptInvalidUrlError.
  ///
  /// In ar, this message translates to:
  /// **'الرابط ليس رابط إيصال معاملات صالحًا.'**
  String get cardReceiptInvalidUrlError;

  /// No description provided for @cardReceiptMissingQueryError.
  ///
  /// In ar, this message translates to:
  /// **'رابط الإيصال لا يحتوي على بيانات المطابقة.'**
  String get cardReceiptMissingQueryError;

  /// No description provided for @cardReceiptDecodeError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر قراءة بيانات إيصال معاملات.'**
  String get cardReceiptDecodeError;

  /// No description provided for @cardReceiptInvalidAmountError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر قراءة مبلغ الإيصال.'**
  String get cardReceiptInvalidAmountError;

  /// No description provided for @cardReceiptUnsuccessfulError.
  ///
  /// In ar, this message translates to:
  /// **'الإيصال لا يشير إلى عملية ناجحة.'**
  String get cardReceiptUnsuccessfulError;

  /// No description provided for @cardReceiptMissingReferenceError.
  ///
  /// In ar, this message translates to:
  /// **'الإيصال لا يحتوي على بيانات البطاقة أو مرجع العملية.'**
  String get cardReceiptMissingReferenceError;

  /// Shown when a card receipt terminal ID is not in the shop allowlist.
  ///
  /// In ar, this message translates to:
  /// **'جهاز البطاقة {terminalId} غير موجود ضمن الأجهزة الموثوقة.'**
  String cardReceiptTerminalNotTrusted(String terminalId);

  /// No description provided for @receiptToggleSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'سيتم إرسال الفاتورة إلى الطابعة بعد إتمام الدفع.'**
  String get receiptToggleSubtitle;

  /// No description provided for @receiptToggleTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تبديل طباعة الفاتورة'**
  String get receiptToggleTooltip;

  /// No description provided for @paidAmountLabel.
  ///
  /// In ar, this message translates to:
  /// **'المدفوع'**
  String get paidAmountLabel;

  /// No description provided for @remainingAmountLabel.
  ///
  /// In ar, this message translates to:
  /// **'المتبقي'**
  String get remainingAmountLabel;

  /// No description provided for @changeDueLabel.
  ///
  /// In ar, this message translates to:
  /// **'الباقي للعميل'**
  String get changeDueLabel;

  /// No description provided for @paymentTotalTooLowError.
  ///
  /// In ar, this message translates to:
  /// **'يجب أن يغطي مجموع الدفعات إجمالي البيع.'**
  String get paymentTotalTooLowError;

  /// No description provided for @confirmPaymentButton.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد الدفع'**
  String get confirmPaymentButton;

  /// No description provided for @noEnabledPaymentMethods.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد طريقة دفع مفعلة. راجع إعدادات المتجر.'**
  String get noEnabledPaymentMethods;

  /// No description provided for @printInvoiceAfterPaymentLabel.
  ///
  /// In ar, this message translates to:
  /// **'طباعة الفاتورة بعد الدفع'**
  String get printInvoiceAfterPaymentLabel;

  /// No description provided for @saleCheckoutSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل البيع.'**
  String get saleCheckoutSuccess;

  /// Checkout success message with the receipt number.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل البيع. رقم الإيصال: {receiptNumber}'**
  String saleCheckoutSuccessWithReceipt(String receiptNumber);

  /// No description provided for @invoicePrintSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم إرسال الفاتورة للطابعة.'**
  String get invoicePrintSuccess;

  /// No description provided for @invoicePrintError.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل البيع، لكن تعذرت طباعة الفاتورة.'**
  String get invoicePrintError;

  /// No description provided for @invoiceProfitLabel.
  ///
  /// In ar, this message translates to:
  /// **'الربح'**
  String get invoiceProfitLabel;

  /// Compact invoice profit label with amount.
  ///
  /// In ar, this message translates to:
  /// **'الربح {amount}'**
  String invoiceProfitValue(String amount);

  /// Invoice profit margin percent label.
  ///
  /// In ar, this message translates to:
  /// **'هامش {percent}%'**
  String invoiceProfitMarginValue(String percent);

  /// No description provided for @saleCheckoutError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تسجيل البيع. تحقق من جلسة الدرج وحاول مرة أخرى.'**
  String get saleCheckoutError;

  /// No description provided for @oversellWarningTitle.
  ///
  /// In ar, this message translates to:
  /// **'تنبيه المخزون'**
  String get oversellWarningTitle;

  /// No description provided for @oversellWarningMessage.
  ///
  /// In ar, this message translates to:
  /// **'تتجاوز بعض عناصر السلة الكمية المتاحة. هل تريد إتمام البيع رغم ذلك؟'**
  String get oversellWarningMessage;

  /// No description provided for @oversellBlockedMessage.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكن إتمام البيع لأن الكمية المطلوبة تتجاوز المخزون المتاح.'**
  String get oversellBlockedMessage;

  /// Stock shortage line in the oversell warning dialog.
  ///
  /// In ar, this message translates to:
  /// **'{productName}: المطلوب {requested}، المتاح {available}'**
  String oversellLine(String productName, int requested, int available);

  /// No description provided for @lossSaleWarningTitle.
  ///
  /// In ar, this message translates to:
  /// **'تنبيه الخسارة'**
  String get lossSaleWarningTitle;

  /// No description provided for @lossSaleWarningMessage.
  ///
  /// In ar, this message translates to:
  /// **'نحن نبيع بعض عناصر السلة بخسارة. هل تريد إتمام البيع رغم ذلك؟'**
  String get lossSaleWarningMessage;

  /// No description provided for @lossSaleBlockedMessage.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكن إتمام البيع لأن إعدادات المتجر تمنع البيع بخسارة.'**
  String get lossSaleBlockedMessage;

  /// Loss-making sale line in the loss warning dialog.
  ///
  /// In ar, this message translates to:
  /// **'{productName}: الخسارة {amount}'**
  String lossSaleLine(String productName, String amount);

  /// No description provided for @reviewCartButton.
  ///
  /// In ar, this message translates to:
  /// **'مراجعة السلة'**
  String get reviewCartButton;

  /// No description provided for @continueSaleButton.
  ///
  /// In ar, this message translates to:
  /// **'إتمام البيع'**
  String get continueSaleButton;

  /// No description provided for @paymentUnauthorizedMessage.
  ///
  /// In ar, this message translates to:
  /// **'لا يملك هذا المستخدم صلاحية إتمام الدفع.'**
  String get paymentUnauthorizedMessage;

  /// Unit price label for a cart item.
  ///
  /// In ar, this message translates to:
  /// **'{amount} للقطعة'**
  String unitPriceEach(String amount);

  /// No description provided for @removeOneTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إنقاص عنصر'**
  String get removeOneTooltip;

  /// No description provided for @addOneTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إضافة عنصر'**
  String get addOneTooltip;

  /// No description provided for @subtotal.
  ///
  /// In ar, this message translates to:
  /// **'المجموع الفرعي'**
  String get subtotal;

  /// No description provided for @total.
  ///
  /// In ar, this message translates to:
  /// **'الإجمالي'**
  String get total;

  /// No description provided for @registerSessionGateTitle.
  ///
  /// In ar, this message translates to:
  /// **'جلسة الدرج'**
  String get registerSessionGateTitle;

  /// No description provided for @checkingRegisterSession.
  ///
  /// In ar, this message translates to:
  /// **'جار فحص جلسة الدرج...'**
  String get checkingRegisterSession;

  /// No description provided for @noOpenRegisterSession.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد جلسة درج مفتوحة. ابدأ جلسة جديدة قبل البيع.'**
  String get noOpenRegisterSession;

  /// No description provided for @registerSessionLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر الاتصال بجلسة الدرج. حاول مرة أخرى.'**
  String get registerSessionLoadError;

  /// No description provided for @openingCashInputLabel.
  ///
  /// In ar, this message translates to:
  /// **'نقدية الافتتاح'**
  String get openingCashInputLabel;

  /// No description provided for @moneyAmountHint.
  ///
  /// In ar, this message translates to:
  /// **'0.00'**
  String get moneyAmountHint;

  /// No description provided for @openingCashRequiredError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل نقدية الافتتاح قبل بدء الجلسة.'**
  String get openingCashRequiredError;

  /// No description provided for @startRegisterSessionButton.
  ///
  /// In ar, this message translates to:
  /// **'بدء الجلسة'**
  String get startRegisterSessionButton;

  /// No description provided for @startingRegisterSessionButton.
  ///
  /// In ar, this message translates to:
  /// **'جار بدء الجلسة...'**
  String get startingRegisterSessionButton;

  /// Title for an open register session that can be resumed.
  ///
  /// In ar, this message translates to:
  /// **'جلسة {sessionNumber}'**
  String resumeRegisterSessionTitle(String sessionNumber);

  /// Opening cash amount for a register session.
  ///
  /// In ar, this message translates to:
  /// **'نقدية الافتتاح: {amount}'**
  String registerSessionOpeningCash(String amount);

  /// No description provided for @resumeRegisterSessionButton.
  ///
  /// In ar, this message translates to:
  /// **'متابعة البيع'**
  String get resumeRegisterSessionButton;

  /// Compact app bar label for the active register session.
  ///
  /// In ar, this message translates to:
  /// **'جلسة {sessionNumber}'**
  String activeRegisterSessionLabel(String sessionNumber);

  /// No description provided for @cashMovementMenuTooltip.
  ///
  /// In ar, this message translates to:
  /// **'حركات نقدية للدرج'**
  String get cashMovementMenuTooltip;

  /// No description provided for @payInRegisterSessionTitle.
  ///
  /// In ar, this message translates to:
  /// **'إضافة نقدية للدرج'**
  String get payInRegisterSessionTitle;

  /// No description provided for @payOutRegisterSessionTitle.
  ///
  /// In ar, this message translates to:
  /// **'سحب نقدية من الدرج'**
  String get payOutRegisterSessionTitle;

  /// No description provided for @payInRegisterSessionButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة نقدية'**
  String get payInRegisterSessionButton;

  /// No description provided for @payOutRegisterSessionButton.
  ///
  /// In ar, this message translates to:
  /// **'سحب نقدية'**
  String get payOutRegisterSessionButton;

  /// No description provided for @cashMovementAmountLabel.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ'**
  String get cashMovementAmountLabel;

  /// No description provided for @cashMovementReasonLabel.
  ///
  /// In ar, this message translates to:
  /// **'سبب الحركة'**
  String get cashMovementReasonLabel;

  /// No description provided for @cashMovementReasonRequiredError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل سبب الحركة قبل الحفظ.'**
  String get cashMovementReasonRequiredError;

  /// No description provided for @positiveAmountRequiredError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل مبلغًا أكبر من صفر.'**
  String get positiveAmountRequiredError;

  /// No description provided for @cashMovementCreateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ الحركة النقدية. راجع المبلغ والسبب وحاول مرة أخرى.'**
  String get cashMovementCreateError;

  /// No description provided for @cashMovementCreatedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ الحركة النقدية.'**
  String get cashMovementCreatedMessage;

  /// No description provided for @closeRegisterSessionTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إغلاق جلسة الدرج'**
  String get closeRegisterSessionTooltip;

  /// No description provided for @closeRegisterSessionTitle.
  ///
  /// In ar, this message translates to:
  /// **'إغلاق جلسة الدرج'**
  String get closeRegisterSessionTitle;

  /// No description provided for @closingCashInputLabel.
  ///
  /// In ar, this message translates to:
  /// **'النقد عند الإغلاق'**
  String get closingCashInputLabel;

  /// Label for a denomination count input.
  ///
  /// In ar, this message translates to:
  /// **'عدد فئة {denomination}'**
  String denominationCountLabel(String denomination);

  /// No description provided for @cancelButton.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء'**
  String get cancelButton;

  /// No description provided for @closeRegisterSessionButton.
  ///
  /// In ar, this message translates to:
  /// **'إغلاق الجلسة'**
  String get closeRegisterSessionButton;

  /// No description provided for @closingRegisterSessionButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الإغلاق...'**
  String get closingRegisterSessionButton;

  /// No description provided for @closeRegisterSessionError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إغلاق جلسة الدرج. راجع القيم وحاول مرة أخرى.'**
  String get closeRegisterSessionError;

  /// No description provided for @registerSessionHistoryTitle.
  ///
  /// In ar, this message translates to:
  /// **'سجل جلسات الدرج'**
  String get registerSessionHistoryTitle;

  /// No description provided for @refreshRegisterSessionsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث سجل الجلسات'**
  String get refreshRegisterSessionsTooltip;

  /// No description provided for @registerSessionsListTitle.
  ///
  /// In ar, this message translates to:
  /// **'جلسات الدرج'**
  String get registerSessionsListTitle;

  /// No description provided for @registerSessionHistoryLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل سجل الجلسات.'**
  String get registerSessionHistoryLoadError;

  /// No description provided for @emptyRegisterSessionHistory.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد جلسات درج مسجلة بعد.'**
  String get emptyRegisterSessionHistory;

  /// No description provided for @registerSessionStatusOpen.
  ///
  /// In ar, this message translates to:
  /// **'مفتوحة'**
  String get registerSessionStatusOpen;

  /// No description provided for @registerSessionStatusClosed.
  ///
  /// In ar, this message translates to:
  /// **'مغلقة'**
  String get registerSessionStatusClosed;

  /// No description provided for @sessionSalesPlaceholderTitle.
  ///
  /// In ar, this message translates to:
  /// **'مبيعات الجلسة'**
  String get sessionSalesPlaceholderTitle;

  /// No description provided for @selectRegisterSessionPrompt.
  ///
  /// In ar, this message translates to:
  /// **'اختر جلسة درج لعرض مبيعاتها.'**
  String get selectRegisterSessionPrompt;

  /// Title for sales linked to a register session.
  ///
  /// In ar, this message translates to:
  /// **'مبيعات جلسة {sessionNumber}'**
  String sessionSalesTitle(String sessionNumber);

  /// No description provided for @sessionSalesTab.
  ///
  /// In ar, this message translates to:
  /// **'المبيعات'**
  String get sessionSalesTab;

  /// No description provided for @sessionCashMovementsTab.
  ///
  /// In ar, this message translates to:
  /// **'حركات النقد'**
  String get sessionCashMovementsTab;

  /// No description provided for @sessionSummaryTab.
  ///
  /// In ar, this message translates to:
  /// **'الملخص'**
  String get sessionSummaryTab;

  /// No description provided for @sessionCashSummaryTitle.
  ///
  /// In ar, this message translates to:
  /// **'ملخص النقد'**
  String get sessionCashSummaryTitle;

  /// No description provided for @sessionOpeningCashMetric.
  ///
  /// In ar, this message translates to:
  /// **'نقدية الافتتاح'**
  String get sessionOpeningCashMetric;

  /// No description provided for @sessionCashSalesMetric.
  ///
  /// In ar, this message translates to:
  /// **'المبيعات النقدية'**
  String get sessionCashSalesMetric;

  /// No description provided for @sessionPayInMetric.
  ///
  /// In ar, this message translates to:
  /// **'إضافات الدرج'**
  String get sessionPayInMetric;

  /// No description provided for @sessionPayOutMetric.
  ///
  /// In ar, this message translates to:
  /// **'سحوبات الدرج'**
  String get sessionPayOutMetric;

  /// No description provided for @sessionCashRefundMetric.
  ///
  /// In ar, this message translates to:
  /// **'مبالغ الإرجاع النقدية'**
  String get sessionCashRefundMetric;

  /// No description provided for @sessionExpectedCashMetric.
  ///
  /// In ar, this message translates to:
  /// **'النقد المتوقع'**
  String get sessionExpectedCashMetric;

  /// No description provided for @sessionClosingCashMetric.
  ///
  /// In ar, this message translates to:
  /// **'النقد المعدود'**
  String get sessionClosingCashMetric;

  /// No description provided for @sessionDenominationTotalMetric.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الفئات'**
  String get sessionDenominationTotalMetric;

  /// No description provided for @sessionCashVarianceMetric.
  ///
  /// In ar, this message translates to:
  /// **'فرق النقد'**
  String get sessionCashVarianceMetric;

  /// No description provided for @sessionDenominationsTitle.
  ///
  /// In ar, this message translates to:
  /// **'الفئات عند الإغلاق'**
  String get sessionDenominationsTitle;

  /// Compact cash variance label.
  ///
  /// In ar, this message translates to:
  /// **'فرق {amount}'**
  String sessionVarianceFlag(String amount);

  /// No description provided for @sessionNoVariance.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد فرق مسجل'**
  String get sessionNoVariance;

  /// No description provided for @sessionSalesLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل مبيعات هذه الجلسة.'**
  String get sessionSalesLoadError;

  /// No description provided for @emptySessionSales.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مبيعات مسجلة في هذه الجلسة.'**
  String get emptySessionSales;

  /// No description provided for @allCustomersFilterLabel.
  ///
  /// In ar, this message translates to:
  /// **'كل العملاء'**
  String get allCustomersFilterLabel;

  /// No description provided for @clearCustomerFilterTooltip.
  ///
  /// In ar, this message translates to:
  /// **'مسح فلتر العميل'**
  String get clearCustomerFilterTooltip;

  /// No description provided for @sessionCashMovementsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل حركات النقد لهذه الجلسة.'**
  String get sessionCashMovementsLoadError;

  /// No description provided for @emptySessionCashMovements.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد حركات نقد مسجلة في هذه الجلسة.'**
  String get emptySessionCashMovements;

  /// No description provided for @cashMovementPayInLabel.
  ///
  /// In ar, this message translates to:
  /// **'إضافة نقدية'**
  String get cashMovementPayInLabel;

  /// No description provided for @cashMovementPayOutLabel.
  ///
  /// In ar, this message translates to:
  /// **'سحب نقدية'**
  String get cashMovementPayOutLabel;

  /// No description provided for @invoicesTitle.
  ///
  /// In ar, this message translates to:
  /// **'الفواتير'**
  String get invoicesTitle;

  /// No description provided for @refreshInvoicesTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث الفواتير'**
  String get refreshInvoicesTooltip;

  /// No description provided for @searchInvoicesHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث برقم الفاتورة أو المنتج أو SKU أو الباركود'**
  String get searchInvoicesHint;

  /// No description provided for @invoicesLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل الفواتير.'**
  String get invoicesLoadError;

  /// No description provided for @emptyInvoices.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد فواتير تطابق الفلاتر الحالية.'**
  String get emptyInvoices;

  /// Invoice details title.
  ///
  /// In ar, this message translates to:
  /// **'فاتورة {receiptNumber}'**
  String invoiceDetailsTitle(String receiptNumber);

  /// No description provided for @refreshInvoiceDetailsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث تفاصيل الفاتورة'**
  String get refreshInvoiceDetailsTooltip;

  /// No description provided for @invoiceDetailsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل تفاصيل الفاتورة.'**
  String get invoiceDetailsLoadError;

  /// No description provided for @invoiceActionsTitle.
  ///
  /// In ar, this message translates to:
  /// **'الإجراءات'**
  String get invoiceActionsTitle;

  /// No description provided for @invoiceSummaryTitle.
  ///
  /// In ar, this message translates to:
  /// **'ملخص الفاتورة'**
  String get invoiceSummaryTitle;

  /// No description provided for @invoiceNumberLabel.
  ///
  /// In ar, this message translates to:
  /// **'رقم الفاتورة'**
  String get invoiceNumberLabel;

  /// Invoice number displayed in a list row.
  ///
  /// In ar, this message translates to:
  /// **'فاتورة {receiptNumber}'**
  String invoiceNumberValue(String receiptNumber);

  /// No description provided for @invoiceStatusLabel.
  ///
  /// In ar, this message translates to:
  /// **'الحالة'**
  String get invoiceStatusLabel;

  /// No description provided for @invoiceStatusFilterTitle.
  ///
  /// In ar, this message translates to:
  /// **'حالة الفاتورة'**
  String get invoiceStatusFilterTitle;

  /// No description provided for @invoiceStatusAll.
  ///
  /// In ar, this message translates to:
  /// **'كل الحالات'**
  String get invoiceStatusAll;

  /// No description provided for @invoiceStatusOpen.
  ///
  /// In ar, this message translates to:
  /// **'مفتوحة'**
  String get invoiceStatusOpen;

  /// No description provided for @invoiceStatusPaid.
  ///
  /// In ar, this message translates to:
  /// **'مدفوعة'**
  String get invoiceStatusPaid;

  /// No description provided for @invoiceStatusVoid.
  ///
  /// In ar, this message translates to:
  /// **'ملغاة'**
  String get invoiceStatusVoid;

  /// No description provided for @invoiceCustomerFilterTitle.
  ///
  /// In ar, this message translates to:
  /// **'العميل'**
  String get invoiceCustomerFilterTitle;

  /// No description provided for @invoiceCustomerLabel.
  ///
  /// In ar, this message translates to:
  /// **'العميل'**
  String get invoiceCustomerLabel;

  /// No description provided for @invoiceRegisterSessionLabel.
  ///
  /// In ar, this message translates to:
  /// **'جلسة الدرج'**
  String get invoiceRegisterSessionLabel;

  /// Register session value shown in an invoice row.
  ///
  /// In ar, this message translates to:
  /// **'جلسة {sessionNumber}'**
  String invoiceRegisterSessionValue(String sessionNumber);

  /// No description provided for @invoiceLineCountLabel.
  ///
  /// In ar, this message translates to:
  /// **'العناصر'**
  String get invoiceLineCountLabel;

  /// No description provided for @invoiceCreatedAtLabel.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الإصدار'**
  String get invoiceCreatedAtLabel;

  /// No description provided for @invoiceUpdatedAtLabel.
  ///
  /// In ar, this message translates to:
  /// **'آخر تحديث'**
  String get invoiceUpdatedAtLabel;

  /// No description provided for @invoiceLinesTitle.
  ///
  /// In ar, this message translates to:
  /// **'المنتجات'**
  String get invoiceLinesTitle;

  /// No description provided for @invoiceLinesEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد منتجات في هذه الفاتورة.'**
  String get invoiceLinesEmpty;

  /// No description provided for @invoicePaymentsEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مدفوعات مسجلة لهذه الفاتورة.'**
  String get invoicePaymentsEmpty;

  /// No description provided for @invoiceTotalsTitle.
  ///
  /// In ar, this message translates to:
  /// **'الإجماليات'**
  String get invoiceTotalsTitle;

  /// No description provided for @invoiceOrderingNewest.
  ///
  /// In ar, this message translates to:
  /// **'الأحدث أولًا'**
  String get invoiceOrderingNewest;

  /// No description provided for @invoiceOrderingUpdated.
  ///
  /// In ar, this message translates to:
  /// **'آخر تحديث أولًا'**
  String get invoiceOrderingUpdated;

  /// No description provided for @invoiceOrderingTotalDesc.
  ///
  /// In ar, this message translates to:
  /// **'الإجمالي: من الأعلى إلى الأقل'**
  String get invoiceOrderingTotalDesc;

  /// No description provided for @invoiceOrderingReceiptNumber.
  ///
  /// In ar, this message translates to:
  /// **'رقم الفاتورة'**
  String get invoiceOrderingReceiptNumber;

  /// No description provided for @invoiceReprintButton.
  ///
  /// In ar, this message translates to:
  /// **'إعادة طباعة الفاتورة'**
  String get invoiceReprintButton;

  /// No description provided for @invoiceReprintInProgressButton.
  ///
  /// In ar, this message translates to:
  /// **'جار طلب الطباعة...'**
  String get invoiceReprintInProgressButton;

  /// No description provided for @invoiceReprintQueuedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم إرسال طلب إعادة طباعة الفاتورة.'**
  String get invoiceReprintQueuedMessage;

  /// No description provided for @invoiceReprintError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إرسال طلب إعادة طباعة الفاتورة.'**
  String get invoiceReprintError;

  /// No description provided for @saleReceiptFallback.
  ///
  /// In ar, this message translates to:
  /// **'بدون رقم'**
  String get saleReceiptFallback;

  /// Sale receipt title.
  ///
  /// In ar, this message translates to:
  /// **'إيصال {receiptNumber}'**
  String saleReceiptTitle(String receiptNumber);

  /// Fallback product label in a sale line.
  ///
  /// In ar, this message translates to:
  /// **'منتج رقم {productId}'**
  String saleProductFallback(int productId);

  /// Sale line quantity and unit price.
  ///
  /// In ar, this message translates to:
  /// **'{quantity} × {unitPrice}'**
  String saleLineQuantityAndPrice(int quantity, String unitPrice);

  /// No description provided for @saleReprintButton.
  ///
  /// In ar, this message translates to:
  /// **'إعادة طباعة الإيصال'**
  String get saleReprintButton;

  /// No description provided for @saleReprintInProgressButton.
  ///
  /// In ar, this message translates to:
  /// **'جار طلب الطباعة...'**
  String get saleReprintInProgressButton;

  /// No description provided for @saleReprintQueuedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم إرسال طلب إعادة الطباعة.'**
  String get saleReprintQueuedMessage;

  /// No description provided for @saleReprintError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إرسال طلب إعادة الطباعة.'**
  String get saleReprintError;

  /// No description provided for @saleVoidButton.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء الفاتورة'**
  String get saleVoidButton;

  /// No description provided for @saleVoidTitle.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء الفاتورة'**
  String get saleVoidTitle;

  /// No description provided for @saleVoidMessage.
  ///
  /// In ar, this message translates to:
  /// **'سيتم عكس كامل المبلغ وإرجاع الكميات المتبقية إلى المخزون.'**
  String get saleVoidMessage;

  /// No description provided for @saleVoidSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم إلغاء الفاتورة.'**
  String get saleVoidSuccess;

  /// No description provided for @saleVoidError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إلغاء الفاتورة.'**
  String get saleVoidError;

  /// No description provided for @saleReturnButton.
  ///
  /// In ar, this message translates to:
  /// **'إرجاع منتجات'**
  String get saleReturnButton;

  /// No description provided for @saleReturnTitle.
  ///
  /// In ar, this message translates to:
  /// **'إرجاع منتجات'**
  String get saleReturnTitle;

  /// No description provided for @saleReturnSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل الإرجاع.'**
  String get saleReturnSuccess;

  /// No description provided for @saleReturnError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تسجيل الإرجاع.'**
  String get saleReturnError;

  /// No description provided for @saleAdjustmentReasonLabel.
  ///
  /// In ar, this message translates to:
  /// **'سبب اختياري'**
  String get saleAdjustmentReasonLabel;

  /// No description provided for @saleAdjustmentReasonHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: طلب العميل الإرجاع'**
  String get saleAdjustmentReasonHint;

  /// No description provided for @saleReturnQuantityLabel.
  ///
  /// In ar, this message translates to:
  /// **'كمية الإرجاع'**
  String get saleReturnQuantityLabel;

  /// No description provided for @salePaymentsTitle.
  ///
  /// In ar, this message translates to:
  /// **'المدفوعات'**
  String get salePaymentsTitle;

  /// Commission line for a recorded payment.
  ///
  /// In ar, this message translates to:
  /// **'العمولة {amount} بنسبة {percent}%'**
  String salePaymentCommission(String amount, String percent);

  /// Returned quantity status for a sale line.
  ///
  /// In ar, this message translates to:
  /// **'تم إرجاع {returned} من {quantity}'**
  String saleLineReturnedQuantity(int returned, int quantity);

  /// No description provided for @saleReturnNoItemsSelected.
  ///
  /// In ar, this message translates to:
  /// **'اختر كمية واحدة على الأقل للإرجاع.'**
  String get saleReturnNoItemsSelected;

  /// No description provided for @saleNoReturnableItems.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد كميات متاحة للإرجاع.'**
  String get saleNoReturnableItems;

  /// No description provided for @discountCouponCodeLabel.
  ///
  /// In ar, this message translates to:
  /// **'كود الخصم'**
  String get discountCouponCodeLabel;

  /// No description provided for @discountCouponCodeHint.
  ///
  /// In ar, this message translates to:
  /// **'أدخل كود الكوبون'**
  String get discountCouponCodeHint;

  /// No description provided for @purchaseDiscountCodeHint.
  ///
  /// In ar, this message translates to:
  /// **'أدخل كود خصم المورد'**
  String get purchaseDiscountCodeHint;

  /// No description provided for @clearCouponCodeTooltip.
  ///
  /// In ar, this message translates to:
  /// **'مسح كود الخصم'**
  String get clearCouponCodeTooltip;

  /// No description provided for @refreshDiscountPreviewTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث الخصومات'**
  String get refreshDiscountPreviewTooltip;

  /// No description provided for @discountPreviewUnavailable.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحديث الخصومات الآن.'**
  String get discountPreviewUnavailable;

  /// Shown when a coupon code was not applied.
  ///
  /// In ar, this message translates to:
  /// **'الكود غير متاح: {code}'**
  String discountCouponUnavailable(String code);

  /// No description provided for @discountTotalLabel.
  ///
  /// In ar, this message translates to:
  /// **'الخصم'**
  String get discountTotalLabel;

  /// Applied coupon discount label.
  ///
  /// In ar, this message translates to:
  /// **'كوبون {code}'**
  String discountCouponAppliedLabel(String code);

  /// Line-level discount value.
  ///
  /// In ar, this message translates to:
  /// **'خصم {amount}'**
  String discountLineValue(String amount);

  /// Purchase line net unit cost after discounts.
  ///
  /// In ar, this message translates to:
  /// **'صافي التكلفة {amount}'**
  String purchaseLineNetCostValue(String amount);

  /// No description provided for @discountsDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'الخصومات'**
  String get discountsDrawerLabel;

  /// No description provided for @discountManagementTitle.
  ///
  /// In ar, this message translates to:
  /// **'إدارة الخصومات'**
  String get discountManagementTitle;

  /// No description provided for @refreshDiscountsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث الخصومات'**
  String get refreshDiscountsTooltip;

  /// No description provided for @discountCreateButton.
  ///
  /// In ar, this message translates to:
  /// **'خصم جديد'**
  String get discountCreateButton;

  /// No description provided for @discountCreateTitle.
  ///
  /// In ar, this message translates to:
  /// **'إضافة خصم'**
  String get discountCreateTitle;

  /// No description provided for @discountEditTitle.
  ///
  /// In ar, this message translates to:
  /// **'تعديل خصم'**
  String get discountEditTitle;

  /// No description provided for @discountLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل الخصومات.'**
  String get discountLoadError;

  /// No description provided for @discountSaveError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ الخصم. راجع البيانات وحاول مرة أخرى.'**
  String get discountSaveError;

  /// No description provided for @discountEmptyRules.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد خصومات مطابقة.'**
  String get discountEmptyRules;

  /// No description provided for @discountSearchHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث باسم الخصم أو الكود'**
  String get discountSearchHint;

  /// No description provided for @discountStatusFilterLabel.
  ///
  /// In ar, this message translates to:
  /// **'الحالة'**
  String get discountStatusFilterLabel;

  /// No description provided for @discountFilterAll.
  ///
  /// In ar, this message translates to:
  /// **'الكل'**
  String get discountFilterAll;

  /// No description provided for @discountStatusActive.
  ///
  /// In ar, this message translates to:
  /// **'نشط'**
  String get discountStatusActive;

  /// No description provided for @discountStatusInactive.
  ///
  /// In ar, this message translates to:
  /// **'متوقف'**
  String get discountStatusInactive;

  /// No description provided for @discountArchivedLabel.
  ///
  /// In ar, this message translates to:
  /// **'مؤرشف'**
  String get discountArchivedLabel;

  /// No description provided for @discountOrderingLabel.
  ///
  /// In ar, this message translates to:
  /// **'الترتيب'**
  String get discountOrderingLabel;

  /// No description provided for @discountOrderingPriority.
  ///
  /// In ar, this message translates to:
  /// **'الأولوية'**
  String get discountOrderingPriority;

  /// No description provided for @discountOrderingName.
  ///
  /// In ar, this message translates to:
  /// **'الاسم'**
  String get discountOrderingName;

  /// No description provided for @discountOrderingNewest.
  ///
  /// In ar, this message translates to:
  /// **'الأحدث'**
  String get discountOrderingNewest;

  /// No description provided for @discountOrderingUpdated.
  ///
  /// In ar, this message translates to:
  /// **'آخر تعديل'**
  String get discountOrderingUpdated;

  /// No description provided for @discountNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم الخصم'**
  String get discountNameLabel;

  /// No description provided for @discountDescriptionLabel.
  ///
  /// In ar, this message translates to:
  /// **'وصف داخلي'**
  String get discountDescriptionLabel;

  /// No description provided for @discountBasicsSection.
  ///
  /// In ar, this message translates to:
  /// **'الإعدادات الأساسية'**
  String get discountBasicsSection;

  /// No description provided for @discountConditionsSection.
  ///
  /// In ar, this message translates to:
  /// **'الشروط'**
  String get discountConditionsSection;

  /// No description provided for @discountUsageSection.
  ///
  /// In ar, this message translates to:
  /// **'حدود الاستخدام'**
  String get discountUsageSection;

  /// No description provided for @discountChannelLabel.
  ///
  /// In ar, this message translates to:
  /// **'نطاق الخصم'**
  String get discountChannelLabel;

  /// No description provided for @discountChannelSales.
  ///
  /// In ar, this message translates to:
  /// **'المبيعات'**
  String get discountChannelSales;

  /// No description provided for @discountChannelPurchasing.
  ///
  /// In ar, this message translates to:
  /// **'المشتريات'**
  String get discountChannelPurchasing;

  /// No description provided for @discountChannelBoth.
  ///
  /// In ar, this message translates to:
  /// **'المبيعات والمشتريات'**
  String get discountChannelBoth;

  /// No description provided for @discountApplicationTypeLabel.
  ///
  /// In ar, this message translates to:
  /// **'طريقة التطبيق'**
  String get discountApplicationTypeLabel;

  /// No description provided for @discountApplicationAutomatic.
  ///
  /// In ar, this message translates to:
  /// **'تلقائي'**
  String get discountApplicationAutomatic;

  /// No description provided for @discountApplicationCoupon.
  ///
  /// In ar, this message translates to:
  /// **'كود'**
  String get discountApplicationCoupon;

  /// No description provided for @discountScopeLabel.
  ///
  /// In ar, this message translates to:
  /// **'مستوى التطبيق'**
  String get discountScopeLabel;

  /// No description provided for @discountScopeDocument.
  ///
  /// In ar, this message translates to:
  /// **'الفاتورة'**
  String get discountScopeDocument;

  /// No description provided for @discountScopeLine.
  ///
  /// In ar, this message translates to:
  /// **'السطر'**
  String get discountScopeLine;

  /// No description provided for @discountValueTypeLabel.
  ///
  /// In ar, this message translates to:
  /// **'نوع الخصم'**
  String get discountValueTypeLabel;

  /// No description provided for @discountValueTypePercentage.
  ///
  /// In ar, this message translates to:
  /// **'نسبة مئوية'**
  String get discountValueTypePercentage;

  /// No description provided for @discountValueTypeFixedAmount.
  ///
  /// In ar, this message translates to:
  /// **'مبلغ ثابت'**
  String get discountValueTypeFixedAmount;

  /// No description provided for @discountValueTypeFixedUnitAmount.
  ///
  /// In ar, this message translates to:
  /// **'مبلغ ثابت لكل وحدة'**
  String get discountValueTypeFixedUnitAmount;

  /// No description provided for @discountValueTypeFixedPrice.
  ///
  /// In ar, this message translates to:
  /// **'سعر ثابت'**
  String get discountValueTypeFixedPrice;

  /// No description provided for @discountValueLabel.
  ///
  /// In ar, this message translates to:
  /// **'قيمة الخصم'**
  String get discountValueLabel;

  /// No description provided for @discountMaxAmountLabel.
  ///
  /// In ar, this message translates to:
  /// **'أقصى خصم'**
  String get discountMaxAmountLabel;

  /// No description provided for @discountPriorityLabel.
  ///
  /// In ar, this message translates to:
  /// **'الأولوية'**
  String get discountPriorityLabel;

  /// No description provided for @discountExclusiveLabel.
  ///
  /// In ar, this message translates to:
  /// **'يمنع الخصومات الأقل أولوية'**
  String get discountExclusiveLabel;

  /// No description provided for @discountExclusiveHelper.
  ///
  /// In ar, this message translates to:
  /// **'عند تفعيله لا تطبق القواعد التالية بعد هذا الخصم.'**
  String get discountExclusiveHelper;

  /// No description provided for @discountExclusiveShort.
  ///
  /// In ar, this message translates to:
  /// **'حصري'**
  String get discountExclusiveShort;

  /// No description provided for @discountActiveLabel.
  ///
  /// In ar, this message translates to:
  /// **'الخصم نشط'**
  String get discountActiveLabel;

  /// No description provided for @discountMinSubtotalLabel.
  ///
  /// In ar, this message translates to:
  /// **'أقل إجمالي'**
  String get discountMinSubtotalLabel;

  /// No description provided for @discountMinLineQuantityLabel.
  ///
  /// In ar, this message translates to:
  /// **'أقل كمية في السطر'**
  String get discountMinLineQuantityLabel;

  /// No description provided for @discountStartsAtLabel.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ البداية'**
  String get discountStartsAtLabel;

  /// No description provided for @discountEndsAtLabel.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ النهاية'**
  String get discountEndsAtLabel;

  /// No description provided for @discountNoDateSelected.
  ///
  /// In ar, this message translates to:
  /// **'بدون تاريخ'**
  String get discountNoDateSelected;

  /// No description provided for @discountPickDateTooltip.
  ///
  /// In ar, this message translates to:
  /// **'اختيار تاريخ'**
  String get discountPickDateTooltip;

  /// No description provided for @clearButton.
  ///
  /// In ar, this message translates to:
  /// **'مسح'**
  String get clearButton;

  /// No description provided for @discountProductIdsLabel.
  ///
  /// In ar, this message translates to:
  /// **'المنتجات الرئيسية'**
  String get discountProductIdsLabel;

  /// No description provided for @discountVariantIdsLabel.
  ///
  /// In ar, this message translates to:
  /// **'الخيارات / الرموز الدقيقة'**
  String get discountVariantIdsLabel;

  /// No description provided for @discountProductCategoryIdsLabel.
  ///
  /// In ar, this message translates to:
  /// **'التصنيفات'**
  String get discountProductCategoryIdsLabel;

  /// No description provided for @discountCustomerIdsLabel.
  ///
  /// In ar, this message translates to:
  /// **'العملاء'**
  String get discountCustomerIdsLabel;

  /// No description provided for @discountSupplierIdsLabel.
  ///
  /// In ar, this message translates to:
  /// **'الموردون'**
  String get discountSupplierIdsLabel;

  /// No description provided for @discountPickerHelper.
  ///
  /// In ar, this message translates to:
  /// **'اختر من القائمة'**
  String get discountPickerHelper;

  /// No description provided for @discountNoConstraintsSelected.
  ///
  /// In ar, this message translates to:
  /// **'كل العناصر'**
  String get discountNoConstraintsSelected;

  /// No description provided for @discountOpenPickerTooltip.
  ///
  /// In ar, this message translates to:
  /// **'فتح قائمة الاختيار'**
  String get discountOpenPickerTooltip;

  /// No description provided for @discountPickerLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل القائمة.'**
  String get discountPickerLoadError;

  /// Fallback label for an already selected constraint id.
  ///
  /// In ar, this message translates to:
  /// **'معرّف {id}'**
  String discountConstraintId(int id);

  /// No description provided for @discountProductPickerTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختيار المنتجات'**
  String get discountProductPickerTitle;

  /// No description provided for @discountProductPickerEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد منتجات مطابقة.'**
  String get discountProductPickerEmpty;

  /// No description provided for @discountVariantPickerTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختيار خيارات المنتجات'**
  String get discountVariantPickerTitle;

  /// No description provided for @discountVariantPickerSearchHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث باسم المنتج أو رمز SKU أو الباركود'**
  String get discountVariantPickerSearchHint;

  /// No description provided for @discountVariantPickerEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد خيارات مطابقة.'**
  String get discountVariantPickerEmpty;

  /// No description provided for @discountProductCategoryPickerTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختيار التصنيفات'**
  String get discountProductCategoryPickerTitle;

  /// No description provided for @discountProductCategoryPickerEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد تصنيفات مطابقة.'**
  String get discountProductCategoryPickerEmpty;

  /// No description provided for @discountCustomerPickerTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختيار العملاء'**
  String get discountCustomerPickerTitle;

  /// No description provided for @discountCustomerPickerSearchHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث باسم العميل أو الهاتف'**
  String get discountCustomerPickerSearchHint;

  /// No description provided for @discountCustomerPickerEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد عملاء مطابقون.'**
  String get discountCustomerPickerEmpty;

  /// No description provided for @discountSupplierPickerTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختيار الموردين'**
  String get discountSupplierPickerTitle;

  /// No description provided for @discountSupplierPickerSearchHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث باسم المورد أو الهاتف'**
  String get discountSupplierPickerSearchHint;

  /// No description provided for @discountSupplierPickerEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد موردون مطابقون.'**
  String get discountSupplierPickerEmpty;

  /// No description provided for @discountUsageLimitLabel.
  ///
  /// In ar, this message translates to:
  /// **'حد الاستخدام الكلي'**
  String get discountUsageLimitLabel;

  /// No description provided for @discountPerCustomerLimitLabel.
  ///
  /// In ar, this message translates to:
  /// **'حد الاستخدام لكل عميل'**
  String get discountPerCustomerLimitLabel;

  /// No description provided for @discountPerSupplierLimitLabel.
  ///
  /// In ar, this message translates to:
  /// **'حد الاستخدام لكل مورد'**
  String get discountPerSupplierLimitLabel;

  /// No description provided for @discountSaveButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ الخصم'**
  String get discountSaveButton;

  /// No description provided for @discountEditTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تعديل الخصم'**
  String get discountEditTooltip;

  /// No description provided for @discountEnableTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تفعيل الخصم'**
  String get discountEnableTooltip;

  /// No description provided for @discountDisableTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إيقاف الخصم'**
  String get discountDisableTooltip;

  /// No description provided for @discountArchiveTooltip.
  ///
  /// In ar, this message translates to:
  /// **'أرشفة الخصم'**
  String get discountArchiveTooltip;

  /// No description provided for @discountEnabledMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم تفعيل الخصم.'**
  String get discountEnabledMessage;

  /// No description provided for @discountDisabledMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم إيقاف الخصم.'**
  String get discountDisabledMessage;

  /// No description provided for @discountArchivedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تمت أرشفة الخصم.'**
  String get discountArchivedMessage;

  /// No description provided for @discountArchiveTitle.
  ///
  /// In ar, this message translates to:
  /// **'أرشفة الخصم'**
  String get discountArchiveTitle;

  /// Confirmation message before archiving a discount.
  ///
  /// In ar, this message translates to:
  /// **'سيتم إيقاف {name} وإخفاؤه من التطبيق التلقائي.'**
  String discountArchiveMessage(String name);

  /// No description provided for @discountArchiveConfirmButton.
  ///
  /// In ar, this message translates to:
  /// **'أرشف الخصم'**
  String get discountArchiveConfirmButton;

  /// No description provided for @requiredFieldError.
  ///
  /// In ar, this message translates to:
  /// **'هذا الحقل مطلوب.'**
  String get requiredFieldError;

  /// No description provided for @positiveNumberError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل رقما أكبر من صفر.'**
  String get positiveNumberError;

  /// No description provided for @nonNegativeNumberError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل رقما لا يقل عن صفر.'**
  String get nonNegativeNumberError;

  /// No description provided for @positiveIntegerError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل عددا صحيحا أكبر من صفر.'**
  String get positiveIntegerError;

  /// No description provided for @discountPercentError.
  ///
  /// In ar, this message translates to:
  /// **'النسبة لا يمكن أن تتجاوز 100%.'**
  String get discountPercentError;

  /// No description provided for @discountLineOnlyValueTypeError.
  ///
  /// In ar, this message translates to:
  /// **'هذا النوع يعمل على مستوى السطر فقط.'**
  String get discountLineOnlyValueTypeError;

  /// No description provided for @discountIdListError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل معرفات صحيحة مفصولة بفواصل.'**
  String get discountIdListError;

  /// No description provided for @discountCustomerChannelError.
  ///
  /// In ar, this message translates to:
  /// **'شروط العملاء متاحة للمبيعات أو لكلا النطاقين فقط.'**
  String get discountCustomerChannelError;

  /// No description provided for @discountSupplierChannelError.
  ///
  /// In ar, this message translates to:
  /// **'شروط الموردين متاحة للمشتريات أو لكلا النطاقين فقط.'**
  String get discountSupplierChannelError;

  /// No description provided for @discountDateRangeError.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ النهاية يجب أن يكون بعد تاريخ البداية.'**
  String get discountDateRangeError;

  /// Discount rule value summary.
  ///
  /// In ar, this message translates to:
  /// **'{type}: {value}'**
  String discountValueSummary(String type, String value);

  /// Percentage discount value.
  ///
  /// In ar, this message translates to:
  /// **'{value}%'**
  String discountPercentageValue(String value);

  /// Discount priority summary.
  ///
  /// In ar, this message translates to:
  /// **'الأولوية {priority}'**
  String discountPrioritySummary(int priority);

  /// Discount coupon summary.
  ///
  /// In ar, this message translates to:
  /// **'الكود {code}'**
  String discountCouponSummary(String code);

  /// Minimum subtotal summary.
  ///
  /// In ar, this message translates to:
  /// **'أقل إجمالي {amount}'**
  String discountMinSubtotalSummary(String amount);

  /// Minimum line quantity summary.
  ///
  /// In ar, this message translates to:
  /// **'أقل كمية {quantity}'**
  String discountMinLineQuantitySummary(int quantity);

  /// Maximum discount amount summary.
  ///
  /// In ar, this message translates to:
  /// **'أقصى خصم {amount}'**
  String discountMaxAmountSummary(String amount);

  /// Usage count with a limit.
  ///
  /// In ar, this message translates to:
  /// **'الاستخدام {used}/{limit}'**
  String discountUsageSummary(int used, int limit);

  /// Usage count without a limit.
  ///
  /// In ar, this message translates to:
  /// **'الاستخدام {used}'**
  String discountUsageCountSummary(int used);

  /// Applied discount count.
  ///
  /// In ar, this message translates to:
  /// **'التطبيقات {count}'**
  String discountAppliedCountSummary(int count);

  /// Start date summary.
  ///
  /// In ar, this message translates to:
  /// **'يبدأ {date}'**
  String discountStartsAtSummary(String date);

  /// End date summary.
  ///
  /// In ar, this message translates to:
  /// **'ينتهي {date}'**
  String discountEndsAtSummary(String date);

  /// Product constraint count.
  ///
  /// In ar, this message translates to:
  /// **'{count} منتجات'**
  String discountProductConstraintSummary(int count);

  /// Variant constraint count.
  ///
  /// In ar, this message translates to:
  /// **'{count} خيارات دقيقة'**
  String discountVariantConstraintSummary(int count);

  /// Product category constraint count.
  ///
  /// In ar, this message translates to:
  /// **'{count} تصنيفات'**
  String discountProductCategoryConstraintSummary(int count);

  /// Customer constraint count.
  ///
  /// In ar, this message translates to:
  /// **'{count} عملاء'**
  String discountCustomerConstraintSummary(int count);

  /// Supplier constraint count.
  ///
  /// In ar, this message translates to:
  /// **'{count} موردين'**
  String discountSupplierConstraintSummary(int count);

  /// No description provided for @confirmButton.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد'**
  String get confirmButton;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['ar'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AppLocalizationsAr();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
