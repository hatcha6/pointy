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

  /// Customer-facing brand name, shown on the login brand panel.
  ///
  /// In ar, this message translates to:
  /// **'دفتر'**
  String get brandName;

  /// Generic fallback shown when an action fails without a specific message.
  ///
  /// In ar, this message translates to:
  /// **'حدث خطأ غير متوقع. حاول مرة أخرى.'**
  String get errorUnexpectedMessage;

  /// Shown when the server returns a 5xx error without a specific message.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر إكمال العملية على الخادم. حاول مرة أخرى لاحقًا.'**
  String get errorServerMessage;

  /// Title of the global command palette overlay.
  ///
  /// In ar, this message translates to:
  /// **'تنقّل سريع'**
  String get commandPaletteTitle;

  /// Search field hint inside the command palette.
  ///
  /// In ar, this message translates to:
  /// **'ابحث عن شاشة أو منتج أو عميل أو فاتورة…'**
  String get commandPaletteSearchHint;

  /// Section header for navigable screens in the command palette.
  ///
  /// In ar, this message translates to:
  /// **'الشاشات'**
  String get commandPaletteScreensSection;

  /// Command palette section header for product results.
  ///
  /// In ar, this message translates to:
  /// **'المنتجات'**
  String get commandPaletteProductsSection;

  /// Command palette section header for customer results.
  ///
  /// In ar, this message translates to:
  /// **'العملاء'**
  String get commandPaletteCustomersSection;

  /// Command palette section header for supplier results.
  ///
  /// In ar, this message translates to:
  /// **'الموردون'**
  String get commandPaletteSuppliersSection;

  /// Command palette section header for invoice results.
  ///
  /// In ar, this message translates to:
  /// **'الفواتير'**
  String get commandPaletteInvoicesSection;

  /// Command palette section header for purchase order results.
  ///
  /// In ar, this message translates to:
  /// **'أوامر الشراء'**
  String get commandPalettePurchaseOrdersSection;

  /// Shown while the command palette is searching entities.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ البحث…'**
  String get commandPaletteSearching;

  /// Command palette section header for quick actions.
  ///
  /// In ar, this message translates to:
  /// **'إجراءات سريعة'**
  String get commandPaletteActionsSection;

  /// Command palette section header for recently opened items.
  ///
  /// In ar, this message translates to:
  /// **'المفتوحة مؤخرًا'**
  String get commandPaletteRecentsSection;

  /// Quick action: go to the POS to start a new sale.
  ///
  /// In ar, this message translates to:
  /// **'بيع جديد'**
  String get commandPaletteActionNewSale;

  /// Quick action: open a blank purchase order draft.
  ///
  /// In ar, this message translates to:
  /// **'أمر شراء جديد'**
  String get commandPaletteActionNewPurchaseOrder;

  /// Quick action: open the expenses screen to record an expense.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل مصروف'**
  String get commandPaletteActionRecordExpense;

  /// Quick action: open the stock count screen.
  ///
  /// In ar, this message translates to:
  /// **'بدء جرد'**
  String get commandPaletteActionStockCount;

  /// Live stock shown on a product row in the command palette.
  ///
  /// In ar, this message translates to:
  /// **'{count} في المخزون'**
  String commandPaletteStockLabel(String count);

  /// Row action tooltip: print the product's barcode label.
  ///
  /// In ar, this message translates to:
  /// **'طباعة الملصق'**
  String get commandPalettePrintLabelAction;

  /// Row action tooltip: reorder the product (new purchase order).
  ///
  /// In ar, this message translates to:
  /// **'إعادة الطلب'**
  String get commandPaletteReorderAction;

  /// Row action tooltip: reprint the invoice.
  ///
  /// In ar, this message translates to:
  /// **'إعادة طباعة الفاتورة'**
  String get commandPaletteReprintAction;

  /// Snackbar after a barcode label prints from the palette.
  ///
  /// In ar, this message translates to:
  /// **'تمت طباعة الملصق'**
  String get commandPaletteLabelPrinted;

  /// Snackbar when a barcode label fails to print from the palette.
  ///
  /// In ar, this message translates to:
  /// **'تعذرت طباعة الملصق'**
  String get commandPaletteLabelPrintFailed;

  /// Snackbar when a product has no variant to reorder.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكن إعادة طلب هذا المنتج'**
  String get commandPaletteReorderNoVariant;

  /// Snackbar after an invoice reprints from the palette.
  ///
  /// In ar, this message translates to:
  /// **'تمت طباعة الفاتورة'**
  String get commandPaletteInvoicePrinted;

  /// Snackbar when an invoice fails to reprint from the palette.
  ///
  /// In ar, this message translates to:
  /// **'تعذرت طباعة الفاتورة'**
  String get commandPaletteInvoicePrintFailed;

  /// Snackbar when a recent item can no longer be opened.
  ///
  /// In ar, this message translates to:
  /// **'تعذر فتح العنصر'**
  String get commandPaletteOpenError;

  /// Empty state when no command palette results match the query.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد نتائج مطابقة'**
  String get commandPaletteNoResults;

  /// Label for the entry point that opens the command palette.
  ///
  /// In ar, this message translates to:
  /// **'بحث وتنقّل سريع'**
  String get commandPaletteOpenLabel;

  /// Keyboard hint shown at the bottom of the command palette.
  ///
  /// In ar, this message translates to:
  /// **'↑↓ للتنقل · Enter للفتح · Esc للإغلاق'**
  String get commandPaletteFooterHint;

  /// Hint shown when the selected row has inline actions (Tab cycles them).
  ///
  /// In ar, this message translates to:
  /// **'Tab للإجراءات'**
  String get commandPaletteActionsHint;

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

  /// No description provided for @orderingMostBought.
  ///
  /// In ar, this message translates to:
  /// **'الأكثر مبيعًا'**
  String get orderingMostBought;

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

  /// No description provided for @userSettingsDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'إعداداتي'**
  String get userSettingsDrawerLabel;

  /// No description provided for @navigationGroupPrimary.
  ///
  /// In ar, this message translates to:
  /// **'الرئيسية'**
  String get navigationGroupPrimary;

  /// No description provided for @navigationGroupSales.
  ///
  /// In ar, this message translates to:
  /// **'المبيعات'**
  String get navigationGroupSales;

  /// No description provided for @navigationGroupStock.
  ///
  /// In ar, this message translates to:
  /// **'المخزون والمشتريات'**
  String get navigationGroupStock;

  /// No description provided for @navigationGroupPeople.
  ///
  /// In ar, this message translates to:
  /// **'الأشخاص والرواتب'**
  String get navigationGroupPeople;

  /// No description provided for @navigationGroupReports.
  ///
  /// In ar, this message translates to:
  /// **'التقارير والمراجعة'**
  String get navigationGroupReports;

  /// No description provided for @navigationGroupSettings.
  ///
  /// In ar, this message translates to:
  /// **'الإعدادات'**
  String get navigationGroupSettings;

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
      String date, String user, String summary);

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

  /// No description provided for @reportCategoryEmployees.
  ///
  /// In ar, this message translates to:
  /// **'الموظفون'**
  String get reportCategoryEmployees;

  /// No description provided for @reportReorderItemsTitle.
  ///
  /// In ar, this message translates to:
  /// **'أصناف تحتاج إعادة طلب'**
  String get reportReorderItemsTitle;

  /// No description provided for @reportReorderItemsSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'المنتجات التي بلغت حد إعادة الطلب مع الكميات المقترحة للشراء.'**
  String get reportReorderItemsSubtitle;

  /// No description provided for @reportPayrollSummaryTitle.
  ///
  /// In ar, this message translates to:
  /// **'الرواتب والأجور'**
  String get reportPayrollSummaryTitle;

  /// No description provided for @reportPayrollSummarySubtitle.
  ///
  /// In ar, this message translates to:
  /// **'مسيرات الرواتب وتكلفة الموظفين خلال الفترة.'**
  String get reportPayrollSummarySubtitle;

  /// No description provided for @reportProfitCostsTitle.
  ///
  /// In ar, this message translates to:
  /// **'الأرباح والتكاليف'**
  String get reportProfitCostsTitle;

  /// No description provided for @reportProfitCostsSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'الربح الإجمالي مقابل الرواتب والعمولات وإنفاق المشتريات.'**
  String get reportProfitCostsSubtitle;

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

  /// Supporting line on the dashboard banner shown when today is a holiday/special event; the event name(s) appear as the bold title above it.
  ///
  /// In ar, this message translates to:
  /// **'يعرف دفتر أن اليوم مناسبة خاصة 🎉'**
  String get dashboardSpecialDayMessage;

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
      String name, int quantity, String date);

  /// Expiring stock detail with source context.
  ///
  /// In ar, this message translates to:
  /// **'{name}: المتبقي {quantity}، تاريخ الانتهاء {date}، المرجع {context}'**
  String smartNotificationExpiringStockDetail(
      String name, int quantity, String date, String context);

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

  /// No description provided for @smartNotificationPayrollReadyTitle.
  ///
  /// In ar, this message translates to:
  /// **'مسودة رواتب جاهزة للاعتماد'**
  String get smartNotificationPayrollReadyTitle;

  /// Payroll ready notification message.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{مسودة راتب لموظف واحد جاهزة بإجمالي {amount}.} =2{مسودة رواتب لموظفين جاهزة بإجمالي {amount}.} other{مسودة رواتب لـ {count} موظفين جاهزة بإجمالي {amount}.}}'**
  String smartNotificationPayrollReadyMessage(num count, String amount);

  /// Payroll ready notification detail.
  ///
  /// In ar, this message translates to:
  /// **'{runNumber}: من {start} إلى {end}'**
  String smartNotificationPayrollReadyDetail(
      String runNumber, String start, String end);

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

  /// No description provided for @onboardingTitle.
  ///
  /// In ar, this message translates to:
  /// **'إعداد نقطة البيع'**
  String get onboardingTitle;

  /// No description provided for @onboardingIntro.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ حساب المدير الأول للمتجر.'**
  String get onboardingIntro;

  /// No description provided for @onboardingAdminSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'حساب المدير'**
  String get onboardingAdminSectionTitle;

  /// No description provided for @onboardingCreateAdminButton.
  ///
  /// In ar, this message translates to:
  /// **'إنشاء المدير'**
  String get onboardingCreateAdminButton;

  /// No description provided for @onboardingCreatingAdminButton.
  ///
  /// In ar, this message translates to:
  /// **'جار إنشاء المدير...'**
  String get onboardingCreatingAdminButton;

  /// No description provided for @onboardingCreateAdminError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إنشاء المدير. تحقق من البيانات وقوة كلمة المرور ثم حاول مرة أخرى.'**
  String get onboardingCreateAdminError;

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

  /// No description provided for @supervisorRoleLabel.
  ///
  /// In ar, this message translates to:
  /// **'مشرف'**
  String get supervisorRoleLabel;

  /// No description provided for @auditorRoleLabel.
  ///
  /// In ar, this message translates to:
  /// **'مدقق'**
  String get auditorRoleLabel;

  /// No description provided for @purchasingAgentRoleLabel.
  ///
  /// In ar, this message translates to:
  /// **'مسؤول المشتريات'**
  String get purchasingAgentRoleLabel;

  /// No description provided for @inventoryClerkRoleLabel.
  ///
  /// In ar, this message translates to:
  /// **'أمين المخزن'**
  String get inventoryClerkRoleLabel;

  /// No description provided for @managerRoleDescription.
  ///
  /// In ar, this message translates to:
  /// **'صلاحية كاملة على كل أقسام النظام والإعدادات.'**
  String get managerRoleDescription;

  /// No description provided for @supervisorRoleDescription.
  ///
  /// In ar, this message translates to:
  /// **'إشراف على المبيعات والمخزون والمشتريات والتقارير على مستوى المتجر، دون إدارة المستخدمين أو الإعدادات أو اعتماد الرواتب.'**
  String get supervisorRoleDescription;

  /// No description provided for @accountantRoleDescription.
  ///
  /// In ar, this message translates to:
  /// **'المالية والرواتب والسلف والمصروفات والتقارير.'**
  String get accountantRoleDescription;

  /// No description provided for @auditorRoleDescription.
  ///
  /// In ar, this message translates to:
  /// **'اطّلاع فقط على المبيعات والتقارير والمخزون والمشتريات دون أي تعديل.'**
  String get auditorRoleDescription;

  /// No description provided for @purchasingAgentRoleDescription.
  ///
  /// In ar, this message translates to:
  /// **'إدارة دورة أوامر الشراء كاملة والموردين.'**
  String get purchasingAgentRoleDescription;

  /// No description provided for @inventoryClerkRoleDescription.
  ///
  /// In ar, this message translates to:
  /// **'إدارة المخزون والجرد واستلام المشتريات.'**
  String get inventoryClerkRoleDescription;

  /// No description provided for @technicianRoleDescription.
  ///
  /// In ar, this message translates to:
  /// **'تنفيذ أوامر الصيانة والتصنيع ومتابعة العملاء.'**
  String get technicianRoleDescription;

  /// No description provided for @cashierRoleDescription.
  ///
  /// In ar, this message translates to:
  /// **'البيع عبر نقطة البيع وإدارة وردية الصندوق.'**
  String get cashierRoleDescription;

  /// No description provided for @usersSearchHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث عن مستخدم'**
  String get usersSearchHint;

  /// No description provided for @roleFilterAllLabel.
  ///
  /// In ar, this message translates to:
  /// **'كل الأدوار'**
  String get roleFilterAllLabel;

  /// No description provided for @usersTotalMetric.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي المستخدمين'**
  String get usersTotalMetric;

  /// No description provided for @usersActiveMetric.
  ///
  /// In ar, this message translates to:
  /// **'النشطون'**
  String get usersActiveMetric;

  /// No description provided for @usersCustomPermissionsMetric.
  ///
  /// In ar, this message translates to:
  /// **'صلاحيات مخصصة'**
  String get usersCustomPermissionsMetric;

  /// Badge showing how many custom permissions a user has.
  ///
  /// In ar, this message translates to:
  /// **'{count} مخصصة'**
  String usersCustomPermissionsBadge(int count);

  /// No description provided for @usersNoMatches.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد مستخدمون مطابقون'**
  String get usersNoMatches;

  /// No description provided for @userActionsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إجراءات'**
  String get userActionsTooltip;

  /// No description provided for @userEditAction.
  ///
  /// In ar, this message translates to:
  /// **'تعديل'**
  String get userEditAction;

  /// No description provided for @userManagePermissionsAction.
  ///
  /// In ar, this message translates to:
  /// **'الصلاحيات'**
  String get userManagePermissionsAction;

  /// No description provided for @userActivateAction.
  ///
  /// In ar, this message translates to:
  /// **'تفعيل'**
  String get userActivateAction;

  /// No description provided for @userDeactivateAction.
  ///
  /// In ar, this message translates to:
  /// **'تعطيل'**
  String get userDeactivateAction;

  /// No description provided for @userEditTitle.
  ///
  /// In ar, this message translates to:
  /// **'تعديل المستخدم'**
  String get userEditTitle;

  /// No description provided for @passwordResetLabel.
  ///
  /// In ar, this message translates to:
  /// **'كلمة مرور جديدة (اتركها فارغة لعدم التغيير)'**
  String get passwordResetLabel;

  /// No description provided for @userEditSelfRoleLocked.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكنك تغيير دورك أو تعطيل حسابك بنفسك.'**
  String get userEditSelfRoleLocked;

  /// No description provided for @userManagePermissionsLinkTitle.
  ///
  /// In ar, this message translates to:
  /// **'الصلاحيات الإضافية'**
  String get userManagePermissionsLinkTitle;

  /// No description provided for @userManagePermissionsLinkSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'منح صلاحيات فوق صلاحيات الدور'**
  String get userManagePermissionsLinkSubtitle;

  /// No description provided for @updateUserError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحديث المستخدم'**
  String get updateUserError;

  /// Permission editor screen title.
  ///
  /// In ar, this message translates to:
  /// **'صلاحيات {user}'**
  String userPermissionsTitle(String user);

  /// No description provided for @permissionsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل الصلاحيات'**
  String get permissionsLoadError;

  /// No description provided for @permissionsManagerHasAll.
  ///
  /// In ar, this message translates to:
  /// **'هذا المستخدم مدير ويملك جميع الصلاحيات.'**
  String get permissionsManagerHasAll;

  /// Summary of inherited vs extra permission counts.
  ///
  /// In ar, this message translates to:
  /// **'{inherited} من الدور • {extra} مخصصة'**
  String permissionsSummaryInheritedExtra(int inherited, int extra);

  /// No description provided for @permissionsSearchHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث في الصلاحيات'**
  String get permissionsSearchHint;

  /// No description provided for @permissionsEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد صلاحيات مطابقة'**
  String get permissionsEmpty;

  /// No description provided for @permissionsSelectGroup.
  ///
  /// In ar, this message translates to:
  /// **'تحديد الكل'**
  String get permissionsSelectGroup;

  /// No description provided for @permissionsClearGroup.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء التحديد'**
  String get permissionsClearGroup;

  /// No description provided for @permissionsInheritedFromRole.
  ///
  /// In ar, this message translates to:
  /// **'من الدور'**
  String get permissionsInheritedFromRole;

  /// No description provided for @permissionsNeedsHigherPermission.
  ///
  /// In ar, this message translates to:
  /// **'تحتاج صلاحية أعلى'**
  String get permissionsNeedsHigherPermission;

  /// No description provided for @permissionsSaveError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حفظ الصلاحيات'**
  String get permissionsSaveError;

  /// No description provided for @permissionsSaveButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ الصلاحيات'**
  String get permissionsSaveButton;

  /// No description provided for @permissionsSavedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم تحديث الصلاحيات'**
  String get permissionsSavedMessage;

  /// No description provided for @userPermissionsSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'الصلاحيات'**
  String get userPermissionsSectionTitle;

  /// No description provided for @userEditPermissionsAction.
  ///
  /// In ar, this message translates to:
  /// **'تعديل'**
  String get userEditPermissionsAction;

  /// Count of role-inherited permissions.
  ///
  /// In ar, this message translates to:
  /// **'{count} من الدور'**
  String userPermissionsInheritedCount(int count);

  /// Count of extra (directly granted) permissions.
  ///
  /// In ar, this message translates to:
  /// **'{count} مخصصة'**
  String userPermissionsExtraCount(int count);

  /// No description provided for @userPermissionsNoExtras.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد صلاحيات إضافية مخصصة لهذا المستخدم.'**
  String get userPermissionsNoExtras;

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

  /// No description provided for @firstNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'الاسم الأول'**
  String get firstNameLabel;

  /// No description provided for @lastNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم العائلة'**
  String get lastNameLabel;

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

  /// No description provided for @currentPasswordLabel.
  ///
  /// In ar, this message translates to:
  /// **'كلمة المرور الحالية'**
  String get currentPasswordLabel;

  /// No description provided for @newPasswordLabel.
  ///
  /// In ar, this message translates to:
  /// **'كلمة المرور الجديدة'**
  String get newPasswordLabel;

  /// No description provided for @confirmPasswordLabel.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد كلمة المرور'**
  String get confirmPasswordLabel;

  /// No description provided for @saveChangesButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ التغييرات'**
  String get saveChangesButton;

  /// No description provided for @changePasswordButton.
  ///
  /// In ar, this message translates to:
  /// **'تغيير كلمة المرور'**
  String get changePasswordButton;

  /// No description provided for @passwordConfirmationMismatch.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد كلمة المرور غير مطابق.'**
  String get passwordConfirmationMismatch;

  /// No description provided for @userSettingsTitle.
  ///
  /// In ar, this message translates to:
  /// **'إعداداتي'**
  String get userSettingsTitle;

  /// No description provided for @userSettingsRefreshLoansTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث طلبات السلفة'**
  String get userSettingsRefreshLoansTooltip;

  /// No description provided for @userSettingsOverviewTitle.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات الحساب'**
  String get userSettingsOverviewTitle;

  /// No description provided for @userSettingsOverviewSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'بيانات الدخول وطلبات السلفة المرتبطة بسجل الموظف'**
  String get userSettingsOverviewSubtitle;

  /// No description provided for @userSettingsProfileSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'البيانات الشخصية'**
  String get userSettingsProfileSectionTitle;

  /// No description provided for @userSettingsPasswordSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'كلمة المرور'**
  String get userSettingsPasswordSectionTitle;

  /// No description provided for @userSettingsLoansSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'طلبات السلفة'**
  String get userSettingsLoansSectionTitle;

  /// No description provided for @userSettingsProfileSaveError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ بيانات الحساب. تحقق من اسم المستخدم ثم حاول مرة أخرى.'**
  String get userSettingsProfileSaveError;

  /// No description provided for @userSettingsProfileSaved.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ بيانات الحساب.'**
  String get userSettingsProfileSaved;

  /// No description provided for @userSettingsPasswordChangeError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تغيير كلمة المرور. تحقق من كلمة المرور الحالية وشروط كلمة المرور الجديدة.'**
  String get userSettingsPasswordChangeError;

  /// No description provided for @userSettingsPasswordChanged.
  ///
  /// In ar, this message translates to:
  /// **'تم تغيير كلمة المرور.'**
  String get userSettingsPasswordChanged;

  /// No description provided for @userSettingsLoansLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل طلبات السلفة.'**
  String get userSettingsLoansLoadError;

  /// No description provided for @userSettingsLoanNoEmployeeRecord.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد سجل موظف مرتبط بهذا المستخدم، لذلك لا يمكن إرسال طلب سلفة.'**
  String get userSettingsLoanNoEmployeeRecord;

  /// No description provided for @loanAmountLabel.
  ///
  /// In ar, this message translates to:
  /// **'مبلغ السلفة'**
  String get loanAmountLabel;

  /// No description provided for @loanMonthlyDeductionLabel.
  ///
  /// In ar, this message translates to:
  /// **'الخصم الشهري'**
  String get loanMonthlyDeductionLabel;

  /// No description provided for @loanPurposeLabel.
  ///
  /// In ar, this message translates to:
  /// **'سبب الطلب'**
  String get loanPurposeLabel;

  /// No description provided for @loanMonthlyDeductionTooHigh.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكن أن يكون الخصم الشهري أكبر من مبلغ السلفة.'**
  String get loanMonthlyDeductionTooHigh;

  /// No description provided for @submitLoanRequestButton.
  ///
  /// In ar, this message translates to:
  /// **'إرسال طلب السلفة'**
  String get submitLoanRequestButton;

  /// No description provided for @userSettingsLoanRequestError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إرسال طلب السلفة. راجع المبلغ والخصم الشهري ثم حاول مرة أخرى.'**
  String get userSettingsLoanRequestError;

  /// No description provided for @userSettingsLoanRequested.
  ///
  /// In ar, this message translates to:
  /// **'تم إرسال طلب السلفة للاعتماد.'**
  String get userSettingsLoanRequested;

  /// No description provided for @userSettingsNoLoans.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد طلبات سلفة بعد.'**
  String get userSettingsNoLoans;

  /// No description provided for @userSettingsLoanHistoryTitle.
  ///
  /// In ar, this message translates to:
  /// **'سجل طلبات السلفة'**
  String get userSettingsLoanHistoryTitle;

  /// Current employee loan remaining balance and monthly deduction.
  ///
  /// In ar, this message translates to:
  /// **'المتبقي {balance}، الخصم الشهري {monthlyDeduction}'**
  String userSettingsLoanBalanceDetail(String balance, String monthlyDeduction);

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

  /// No description provided for @appearanceSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'المظهر'**
  String get appearanceSectionTitle;

  /// No description provided for @appearanceSectionSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'يُحفظ هذا الاختيار على هذا الجهاز فقط، مناسب للمتاجر ذات الإضاءة المنخفضة.'**
  String get appearanceSectionSubtitle;

  /// No description provided for @themeModeLight.
  ///
  /// In ar, this message translates to:
  /// **'فاتح'**
  String get themeModeLight;

  /// No description provided for @themeModeDark.
  ///
  /// In ar, this message translates to:
  /// **'داكن'**
  String get themeModeDark;

  /// No description provided for @themeModeSystem.
  ///
  /// In ar, this message translates to:
  /// **'تلقائي'**
  String get themeModeSystem;

  /// No description provided for @themeModeSystemHint.
  ///
  /// In ar, this message translates to:
  /// **'يتبع إعداد النظام'**
  String get themeModeSystemHint;

  /// No description provided for @appearanceToggleTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تبديل بين الفاتح والداكن'**
  String get appearanceToggleTooltip;

  /// No description provided for @switchToDarkAction.
  ///
  /// In ar, this message translates to:
  /// **'التبديل إلى الوضع الداكن'**
  String get switchToDarkAction;

  /// No description provided for @switchToLightAction.
  ///
  /// In ar, this message translates to:
  /// **'التبديل إلى الوضع الفاتح'**
  String get switchToLightAction;

  /// No description provided for @shopSetupTitle.
  ///
  /// In ar, this message translates to:
  /// **'إعداد المتجر'**
  String get shopSetupTitle;

  /// No description provided for @shopSetupSkip.
  ///
  /// In ar, this message translates to:
  /// **'تخطٍّ'**
  String get shopSetupSkip;

  /// No description provided for @shopSetupPickTypeTitle.
  ///
  /// In ar, this message translates to:
  /// **'ما نوع متجرك؟'**
  String get shopSetupPickTypeTitle;

  /// No description provided for @shopSetupPickTypeSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'نفعّل لك الإعدادات المناسبة تلقائيًا — يمكنك تغيير أي شيء لاحقًا.'**
  String get shopSetupPickTypeSubtitle;

  /// No description provided for @shopSetupTuneTitle.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات سريعة'**
  String get shopSetupTuneTitle;

  /// No description provided for @shopSetupTuneSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'اضبط القليل من الإعدادات الأساسية للبدء.'**
  String get shopSetupTuneSubtitle;

  /// No description provided for @shopSetupFinish.
  ///
  /// In ar, this message translates to:
  /// **'إنهاء الإعداد'**
  String get shopSetupFinish;

  /// No description provided for @shopSetupError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حفظ الإعداد، حاول مرة أخرى.'**
  String get shopSetupError;

  /// No description provided for @shopSetupShopNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم المتجر'**
  String get shopSetupShopNameLabel;

  /// No description provided for @shopSetupCurrencyLabel.
  ///
  /// In ar, this message translates to:
  /// **'العملة'**
  String get shopSetupCurrencyLabel;

  /// No description provided for @shopSetupCurrencyValue.
  ///
  /// In ar, this message translates to:
  /// **'د.ل (دينار ليبي)'**
  String get shopSetupCurrencyValue;

  /// No description provided for @shopSetupCurrencyHint.
  ///
  /// In ar, this message translates to:
  /// **'دعم العملات المتعددة قادم قريبًا.'**
  String get shopSetupCurrencyHint;

  /// No description provided for @shopSetupOversellingTitle.
  ///
  /// In ar, this message translates to:
  /// **'السماح بالبيع رغم نفاد المخزون'**
  String get shopSetupOversellingTitle;

  /// No description provided for @shopSetupOversellingSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'يسمح ببيع المنتجات غير المتوفرة في المخزون.'**
  String get shopSetupOversellingSubtitle;

  /// No description provided for @shopSetupOpeningCashTitle.
  ///
  /// In ar, this message translates to:
  /// **'طلب رصيد افتتاحي للدرج'**
  String get shopSetupOpeningCashTitle;

  /// No description provided for @shopSetupOpeningCashSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'يطلب من الكاشير إدخال النقد الافتتاحي عند بدء جلسة الدرج.'**
  String get shopSetupOpeningCashSubtitle;

  /// No description provided for @shopSetupReceiptsTitle.
  ///
  /// In ar, this message translates to:
  /// **'طباعة الإيصالات تلقائيًا'**
  String get shopSetupReceiptsTitle;

  /// No description provided for @shopSetupReceiptsSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'يطبع إيصال العميل تلقائيًا بعد كل عملية بيع.'**
  String get shopSetupReceiptsSubtitle;

  /// No description provided for @shopTypeGeneral.
  ///
  /// In ar, this message translates to:
  /// **'متجر عام'**
  String get shopTypeGeneral;

  /// No description provided for @shopTypeGeneralDescription.
  ///
  /// In ar, this message translates to:
  /// **'بيع بالتجزئة بسيط دون ميزات إضافية.'**
  String get shopTypeGeneralDescription;

  /// No description provided for @shopTypeRestaurant.
  ///
  /// In ar, this message translates to:
  /// **'مطعم / مقهى'**
  String get shopTypeRestaurant;

  /// No description provided for @shopTypeRestaurantDescription.
  ///
  /// In ar, this message translates to:
  /// **'عمليات المطبخ وطباعة طلبات المطبخ والتحضير عند الطلب.'**
  String get shopTypeRestaurantDescription;

  /// No description provided for @shopTypeGrocery.
  ///
  /// In ar, this message translates to:
  /// **'بقالة / سوبر ماركت'**
  String get shopTypeGrocery;

  /// No description provided for @shopTypeGroceryDescription.
  ///
  /// In ar, this message translates to:
  /// **'وحدات قياس متعددة وتنبيهات نقص المخزون ومراقبة صارمة.'**
  String get shopTypeGroceryDescription;

  /// No description provided for @shopTypePharmacy.
  ///
  /// In ar, this message translates to:
  /// **'صيدلية'**
  String get shopTypePharmacy;

  /// No description provided for @shopTypePharmacyDescription.
  ///
  /// In ar, this message translates to:
  /// **'مراقبة مخزون صارمة ومنع البيع بخسارة.'**
  String get shopTypePharmacyDescription;

  /// No description provided for @shopTypePhoneRepair.
  ///
  /// In ar, this message translates to:
  /// **'هواتف وصيانة'**
  String get shopTypePhoneRepair;

  /// No description provided for @shopTypePhoneRepairDescription.
  ///
  /// In ar, this message translates to:
  /// **'عمليات الصيانة وتتبّع الأعمال.'**
  String get shopTypePhoneRepairDescription;

  /// No description provided for @shopTypeBakery.
  ///
  /// In ar, this message translates to:
  /// **'مخبز / حلويات'**
  String get shopTypeBakery;

  /// No description provided for @shopTypeBakeryDescription.
  ///
  /// In ar, this message translates to:
  /// **'عمليات المطبخ والإنتاج للتحضير المسبق.'**
  String get shopTypeBakeryDescription;

  /// No description provided for @shopTypeRetail.
  ///
  /// In ar, this message translates to:
  /// **'ملابس وتجزئة'**
  String get shopTypeRetail;

  /// No description provided for @shopTypeRetailDescription.
  ///
  /// In ar, this message translates to:
  /// **'متجر تجزئة مع مراقبة مخزون صارمة.'**
  String get shopTypeRetailDescription;

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

  /// No description provided for @salesChannelsSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'قنوات البيع'**
  String get salesChannelsSectionTitle;

  /// No description provided for @salesChannelsSectionSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'ربط تطبيقات التوصيل والمتاجر الإلكترونية وإدارة تفويضها'**
  String get salesChannelsSectionSubtitle;

  /// No description provided for @salesChannelsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل قنوات البيع.'**
  String get salesChannelsLoadError;

  /// No description provided for @salesChannelsEmptyMessage.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد قنوات بيع خارجية بعد. أضف قناة لربط تطبيقات التوصيل أو المتاجر الإلكترونية.'**
  String get salesChannelsEmptyMessage;

  /// No description provided for @salesChannelAddButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة قناة'**
  String get salesChannelAddButton;

  /// No description provided for @salesChannelCreateTitle.
  ///
  /// In ar, this message translates to:
  /// **'إضافة قناة بيع'**
  String get salesChannelCreateTitle;

  /// No description provided for @salesChannelCreateSubmit.
  ///
  /// In ar, this message translates to:
  /// **'إنشاء القناة'**
  String get salesChannelCreateSubmit;

  /// No description provided for @salesChannelNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم القناة'**
  String get salesChannelNameLabel;

  /// No description provided for @salesChannelNameRequired.
  ///
  /// In ar, this message translates to:
  /// **'أدخل اسم القناة.'**
  String get salesChannelNameRequired;

  /// No description provided for @salesChannelTypeLabel.
  ///
  /// In ar, this message translates to:
  /// **'نوع القناة'**
  String get salesChannelTypeLabel;

  /// No description provided for @salesChannelNotesLabel.
  ///
  /// In ar, this message translates to:
  /// **'ملاحظات (اختياري)'**
  String get salesChannelNotesLabel;

  /// No description provided for @salesChannelTypePos.
  ///
  /// In ar, this message translates to:
  /// **'نقطة البيع'**
  String get salesChannelTypePos;

  /// No description provided for @salesChannelTypeDelivery.
  ///
  /// In ar, this message translates to:
  /// **'تطبيق توصيل'**
  String get salesChannelTypeDelivery;

  /// No description provided for @salesChannelTypeEcommerce.
  ///
  /// In ar, this message translates to:
  /// **'متجر إلكتروني'**
  String get salesChannelTypeEcommerce;

  /// No description provided for @salesChannelTypeMarketplace.
  ///
  /// In ar, this message translates to:
  /// **'سوق إلكتروني'**
  String get salesChannelTypeMarketplace;

  /// No description provided for @salesChannelTypeOther.
  ///
  /// In ar, this message translates to:
  /// **'أخرى'**
  String get salesChannelTypeOther;

  /// No description provided for @salesChannelStatusActive.
  ///
  /// In ar, this message translates to:
  /// **'مفوضة'**
  String get salesChannelStatusActive;

  /// No description provided for @salesChannelStatusInactive.
  ///
  /// In ar, this message translates to:
  /// **'موقوفة'**
  String get salesChannelStatusInactive;

  /// No description provided for @salesChannelSystemBadge.
  ///
  /// In ar, this message translates to:
  /// **'القناة الافتراضية'**
  String get salesChannelSystemBadge;

  /// No description provided for @salesChannelPosSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'تطبيق نقطة البيع الخاص بالمتجر. يحدد الخادم هذه القناة تلقائيًا من جلسة الدخول ولا يمكن إيقافها.'**
  String get salesChannelPosSubtitle;

  /// Shows the public prefix of a channel API key.
  ///
  /// In ar, this message translates to:
  /// **'معرف المفتاح: {prefix}'**
  String salesChannelKeyPrefixLabel(String prefix);

  /// No description provided for @salesChannelDeauthorizeAction.
  ///
  /// In ar, this message translates to:
  /// **'إيقاف التفويض'**
  String get salesChannelDeauthorizeAction;

  /// No description provided for @salesChannelAuthorizeAction.
  ///
  /// In ar, this message translates to:
  /// **'إعادة التفويض'**
  String get salesChannelAuthorizeAction;

  /// No description provided for @salesChannelDeauthorizeConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'إيقاف تفويض القناة؟'**
  String get salesChannelDeauthorizeConfirmTitle;

  /// Confirmation message before deauthorizing a sales channel.
  ///
  /// In ar, this message translates to:
  /// **'سيرفض الخادم جميع طلبات «{name}» فورًا حتى تتم إعادة التفويض.'**
  String salesChannelDeauthorizeConfirmMessage(String name);

  /// No description provided for @salesChannelRotateKeyAction.
  ///
  /// In ar, this message translates to:
  /// **'تدوير مفتاح الربط'**
  String get salesChannelRotateKeyAction;

  /// No description provided for @salesChannelRotateKeyConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'تدوير مفتاح الربط؟'**
  String get salesChannelRotateKeyConfirmTitle;

  /// No description provided for @salesChannelRotateKeyConfirmMessage.
  ///
  /// In ar, this message translates to:
  /// **'سيتوقف المفتاح الحالي عن العمل فورًا وسيظهر مفتاح جديد لمرة واحدة.'**
  String get salesChannelRotateKeyConfirmMessage;

  /// No description provided for @salesChannelDeleteAction.
  ///
  /// In ar, this message translates to:
  /// **'حذف القناة'**
  String get salesChannelDeleteAction;

  /// No description provided for @salesChannelDeleteConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'حذف القناة؟'**
  String get salesChannelDeleteConfirmTitle;

  /// Confirmation message before deleting a sales channel.
  ///
  /// In ar, this message translates to:
  /// **'سيتم حذف «{name}» نهائيًا. القنوات التي لديها فواتير مسجلة لا يمكن حذفها ويمكن إيقاف تفويضها بدلًا من ذلك.'**
  String salesChannelDeleteConfirmMessage(String name);

  /// No description provided for @salesChannelApiKeyDialogTitle.
  ///
  /// In ar, this message translates to:
  /// **'مفتاح ربط القناة'**
  String get salesChannelApiKeyDialogTitle;

  /// No description provided for @salesChannelApiKeyDialogMessage.
  ///
  /// In ar, this message translates to:
  /// **'انسخ المفتاح الآن واحفظه في مكان آمن، لن يظهر مرة أخرى.'**
  String get salesChannelApiKeyDialogMessage;

  /// No description provided for @salesChannelApiKeyCopyButton.
  ///
  /// In ar, this message translates to:
  /// **'نسخ المفتاح'**
  String get salesChannelApiKeyCopyButton;

  /// No description provided for @salesChannelApiKeyCopiedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم نسخ المفتاح.'**
  String get salesChannelApiKeyCopiedMessage;

  /// No description provided for @salesChannelActionError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تنفيذ العملية على القناة. حاول مرة أخرى.'**
  String get salesChannelActionError;

  /// No description provided for @technicianRoleLabel.
  ///
  /// In ar, this message translates to:
  /// **'فني'**
  String get technicianRoleLabel;

  /// No description provided for @navigationGroupOperations.
  ///
  /// In ar, this message translates to:
  /// **'العمليات'**
  String get navigationGroupOperations;

  /// No description provided for @operationsDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'المهام والتشغيل'**
  String get operationsDrawerLabel;

  /// No description provided for @jobsBoardTitle.
  ///
  /// In ar, this message translates to:
  /// **'المهام'**
  String get jobsBoardTitle;

  /// No description provided for @refreshJobsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث المهام'**
  String get refreshJobsTooltip;

  /// No description provided for @jobsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل المهام.'**
  String get jobsLoadError;

  /// No description provided for @operationsActionError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تنفيذ العملية. حاول مرة أخرى.'**
  String get operationsActionError;

  /// No description provided for @posWeightDialogTitle.
  ///
  /// In ar, this message translates to:
  /// **'أدخل الوزن'**
  String get posWeightDialogTitle;

  /// No description provided for @posWeightInvalid.
  ///
  /// In ar, this message translates to:
  /// **'أدخل وزنًا أكبر من صفر.'**
  String get posWeightInvalid;

  /// No description provided for @posQuantityInvalid.
  ///
  /// In ar, this message translates to:
  /// **'أدخل كمية أكبر من صفر.'**
  String get posQuantityInvalid;

  /// No description provided for @posUnitSelectLabel.
  ///
  /// In ar, this message translates to:
  /// **'الوحدة'**
  String get posUnitSelectLabel;

  /// No description provided for @posUnitQuantityLabel.
  ///
  /// In ar, this message translates to:
  /// **'الكمية'**
  String get posUnitQuantityLabel;

  /// No description provided for @posUnitSheetAdd.
  ///
  /// In ar, this message translates to:
  /// **'إضافة · {total}'**
  String posUnitSheetAdd(String total);

  /// No description provided for @posCartSwitchUnitTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تغيير الوحدة'**
  String get posCartSwitchUnitTooltip;

  /// No description provided for @cartEditWeightTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تعديل الوزن'**
  String get cartEditWeightTooltip;

  /// Helper showing the maximum returnable quantity.
  ///
  /// In ar, this message translates to:
  /// **'الكمية القابلة للإرجاع: {quantity}'**
  String saleReturnQuantityHint(String quantity);

  /// No description provided for @unitPiece.
  ///
  /// In ar, this message translates to:
  /// **'قطعة'**
  String get unitPiece;

  /// No description provided for @unitKilogram.
  ///
  /// In ar, this message translates to:
  /// **'كجم'**
  String get unitKilogram;

  /// No description provided for @unitGram.
  ///
  /// In ar, this message translates to:
  /// **'جم'**
  String get unitGram;

  /// No description provided for @unitLiter.
  ///
  /// In ar, this message translates to:
  /// **'لتر'**
  String get unitLiter;

  /// No description provided for @unitMilliliter.
  ///
  /// In ar, this message translates to:
  /// **'مل'**
  String get unitMilliliter;

  /// No description provided for @unitDozen.
  ///
  /// In ar, this message translates to:
  /// **'دزينة'**
  String get unitDozen;

  /// No description provided for @unitPair.
  ///
  /// In ar, this message translates to:
  /// **'زوج'**
  String get unitPair;

  /// No description provided for @unitPack.
  ///
  /// In ar, this message translates to:
  /// **'عبوة'**
  String get unitPack;

  /// No description provided for @unitBox.
  ///
  /// In ar, this message translates to:
  /// **'صندوق'**
  String get unitBox;

  /// No description provided for @unitCarton.
  ///
  /// In ar, this message translates to:
  /// **'كرتون'**
  String get unitCarton;

  /// No description provided for @unitBag.
  ///
  /// In ar, this message translates to:
  /// **'كيس'**
  String get unitBag;

  /// No description provided for @unitTon.
  ///
  /// In ar, this message translates to:
  /// **'طن'**
  String get unitTon;

  /// No description provided for @unitMeter.
  ///
  /// In ar, this message translates to:
  /// **'متر'**
  String get unitMeter;

  /// No description provided for @unitCentimeter.
  ///
  /// In ar, this message translates to:
  /// **'سم'**
  String get unitCentimeter;

  /// No description provided for @productUnitLabel.
  ///
  /// In ar, this message translates to:
  /// **'وحدة القياس'**
  String get productUnitLabel;

  /// No description provided for @productUnitsSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'الوحدات والتحويلات'**
  String get productUnitsSectionTitle;

  /// No description provided for @productUnitsSectionDescription.
  ///
  /// In ar, this message translates to:
  /// **'أضف وحدات بيع وشراء إضافية (صندوق، كرتون، جملة) مع معامل التحويل إلى الوحدة الأساسية وسعر مخصّص اختياري لكل وحدة.'**
  String get productUnitsSectionDescription;

  /// No description provided for @productUnitsAddButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة وحدة'**
  String get productUnitsAddButton;

  /// No description provided for @productUnitPickLabel.
  ///
  /// In ar, this message translates to:
  /// **'الوحدة'**
  String get productUnitPickLabel;

  /// No description provided for @productUnitRemoveTooltip.
  ///
  /// In ar, this message translates to:
  /// **'حذف الوحدة'**
  String get productUnitRemoveTooltip;

  /// No description provided for @productUnitPriceLabel.
  ///
  /// In ar, this message translates to:
  /// **'سعر مخصّص (اختياري)'**
  String get productUnitPriceLabel;

  /// No description provided for @productUnitPriceHelper.
  ///
  /// In ar, this message translates to:
  /// **'اتركه فارغًا ليُحتسب من سعر الوحدة الأساسية × المعامل.'**
  String get productUnitPriceHelper;

  /// No description provided for @productUnitSellable.
  ///
  /// In ar, this message translates to:
  /// **'متاح للبيع'**
  String get productUnitSellable;

  /// No description provided for @productUnitPurchasable.
  ///
  /// In ar, this message translates to:
  /// **'متاح للشراء'**
  String get productUnitPurchasable;

  /// No description provided for @productUnitBarcodesLabel.
  ///
  /// In ar, this message translates to:
  /// **'باركود الوحدة'**
  String get productUnitBarcodesLabel;

  /// No description provided for @productUnitBarcodesHelper.
  ///
  /// In ar, this message translates to:
  /// **'امسح أو اكتب باركود العبوة (الكرتون/الصندوق) ليُباع المنتج بهذه الوحدة وسعرها عند مسحه في نقطة البيع.'**
  String get productUnitBarcodesHelper;

  /// No description provided for @productUnitBarcodeAddHint.
  ///
  /// In ar, this message translates to:
  /// **'امسح أو اكتب الباركود'**
  String get productUnitBarcodeAddHint;

  /// No description provided for @productUnitBarcodeAddTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إضافة الباركود'**
  String get productUnitBarcodeAddTooltip;

  /// No description provided for @productUnitBarcodeScanTooltip.
  ///
  /// In ar, this message translates to:
  /// **'مسح بالكاميرا'**
  String get productUnitBarcodeScanTooltip;

  /// No description provided for @productUnitBarcodeScanTitle.
  ///
  /// In ar, this message translates to:
  /// **'مسح باركود الوحدة'**
  String get productUnitBarcodeScanTitle;

  /// No description provided for @productUnitBarcodeRemoveTooltip.
  ///
  /// In ar, this message translates to:
  /// **'حذف الباركود'**
  String get productUnitBarcodeRemoveTooltip;

  /// No description provided for @productUnitBarcodeDuplicate.
  ///
  /// In ar, this message translates to:
  /// **'هذا الباركود مُضاف بالفعل لهذه الوحدة.'**
  String get productUnitBarcodeDuplicate;

  /// No description provided for @productUnitBarcodeConflict.
  ///
  /// In ar, this message translates to:
  /// **'الباركود مُسجّل بالفعل للوحدة {unit}.'**
  String productUnitBarcodeConflict(String unit);

  /// No description provided for @productDefaultSaleUnitLabel.
  ///
  /// In ar, this message translates to:
  /// **'وحدة البيع الافتراضية'**
  String get productDefaultSaleUnitLabel;

  /// No description provided for @productDefaultPurchaseUnitLabel.
  ///
  /// In ar, this message translates to:
  /// **'وحدة الشراء الافتراضية'**
  String get productDefaultPurchaseUnitLabel;

  /// No description provided for @productUnitBaseOption.
  ///
  /// In ar, this message translates to:
  /// **'{unit} (أساسية)'**
  String productUnitBaseOption(String unit);

  /// No description provided for @productUnitsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل الوحدات.'**
  String get productUnitsLoadError;

  /// No description provided for @manageUnitsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إدارة وحدات القياس'**
  String get manageUnitsTooltip;

  /// No description provided for @moreActionsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إجراءات'**
  String get moreActionsTooltip;

  /// No description provided for @unitsManagementTitle.
  ///
  /// In ar, this message translates to:
  /// **'وحدات القياس'**
  String get unitsManagementTitle;

  /// No description provided for @unitsManagementIntroTitle.
  ///
  /// In ar, this message translates to:
  /// **'وحدات القياس'**
  String get unitsManagementIntroTitle;

  /// No description provided for @unitsManagementIntroMessage.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ وحدات مخصّصة للبيع والشراء (صندوق، كرتون، جملة) وعدّل الوحدات الجاهزة. الوحدات المضمّنة لا تُحذف بل تُعطَّل.'**
  String get unitsManagementIntroMessage;

  /// No description provided for @addUnitButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة وحدة'**
  String get addUnitButton;

  /// No description provided for @unitsCountLabel.
  ///
  /// In ar, this message translates to:
  /// **'{count} وحدة'**
  String unitsCountLabel(int count);

  /// No description provided for @unitsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل الوحدات.'**
  String get unitsLoadError;

  /// No description provided for @unitsEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد وحدات'**
  String get unitsEmptyTitle;

  /// No description provided for @unitsEmptyMessage.
  ///
  /// In ar, this message translates to:
  /// **'أضف أول وحدة قياس للبدء.'**
  String get unitsEmptyMessage;

  /// No description provided for @unitDimensionCount.
  ///
  /// In ar, this message translates to:
  /// **'العدد'**
  String get unitDimensionCount;

  /// No description provided for @unitDimensionWeight.
  ///
  /// In ar, this message translates to:
  /// **'الوزن'**
  String get unitDimensionWeight;

  /// No description provided for @unitDimensionVolume.
  ///
  /// In ar, this message translates to:
  /// **'الحجم'**
  String get unitDimensionVolume;

  /// No description provided for @unitDimensionLength.
  ///
  /// In ar, this message translates to:
  /// **'الطول'**
  String get unitDimensionLength;

  /// No description provided for @unitSystemBadge.
  ///
  /// In ar, this message translates to:
  /// **'مضمّنة'**
  String get unitSystemBadge;

  /// No description provided for @unitInactiveBadge.
  ///
  /// In ar, this message translates to:
  /// **'معطّلة'**
  String get unitInactiveBadge;

  /// No description provided for @unitInUseBadge.
  ///
  /// In ar, this message translates to:
  /// **'مستخدمة في {count}'**
  String unitInUseBadge(int count);

  /// No description provided for @unitReferenceSummary.
  ///
  /// In ar, this message translates to:
  /// **'تعادل {factor} {unit}'**
  String unitReferenceSummary(String factor, String unit);

  /// No description provided for @unitEditTitle.
  ///
  /// In ar, this message translates to:
  /// **'تعديل وحدة'**
  String get unitEditTitle;

  /// No description provided for @unitCreateTitle.
  ///
  /// In ar, this message translates to:
  /// **'وحدة جديدة'**
  String get unitCreateTitle;

  /// No description provided for @unitNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'الاسم'**
  String get unitNameLabel;

  /// No description provided for @unitCodeLabel.
  ///
  /// In ar, this message translates to:
  /// **'الرمز'**
  String get unitCodeLabel;

  /// No description provided for @unitCodeHelper.
  ///
  /// In ar, this message translates to:
  /// **'معرّف فريد بأحرف لاتينية صغيرة، مثل: box'**
  String get unitCodeHelper;

  /// No description provided for @unitAbbreviationLabel.
  ///
  /// In ar, this message translates to:
  /// **'الاختصار'**
  String get unitAbbreviationLabel;

  /// No description provided for @unitDimensionLabel.
  ///
  /// In ar, this message translates to:
  /// **'النوع'**
  String get unitDimensionLabel;

  /// No description provided for @unitReferenceFactorLabel.
  ///
  /// In ar, this message translates to:
  /// **'معامل التحويل المرجعي'**
  String get unitReferenceFactorLabel;

  /// No description provided for @unitReferenceFactorHelper.
  ///
  /// In ar, this message translates to:
  /// **'كمية الوحدة المرجعية في وحدة واحدة (مثلاً: 1 كجم = 1000 جم).'**
  String get unitReferenceFactorHelper;

  /// No description provided for @unitAllowsFractionalLabel.
  ///
  /// In ar, this message translates to:
  /// **'يسمح بكميات كسرية'**
  String get unitAllowsFractionalLabel;

  /// No description provided for @unitActiveLabel.
  ///
  /// In ar, this message translates to:
  /// **'مفعّلة'**
  String get unitActiveLabel;

  /// No description provided for @unitSystemLockedHint.
  ///
  /// In ar, this message translates to:
  /// **'وحدة مضمّنة: لا يمكن تغيير الرمز أو النوع أو المعامل المرجعي.'**
  String get unitSystemLockedHint;

  /// No description provided for @unitSaveError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حفظ الوحدة.'**
  String get unitSaveError;

  /// No description provided for @unitDeletedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم حذف الوحدة.'**
  String get unitDeletedMessage;

  /// No description provided for @unitDeleteError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حذف الوحدة.'**
  String get unitDeleteError;

  /// No description provided for @unitDeleteTitle.
  ///
  /// In ar, this message translates to:
  /// **'حذف الوحدة'**
  String get unitDeleteTitle;

  /// No description provided for @unitDeleteConfirm.
  ///
  /// In ar, this message translates to:
  /// **'سيتم حذف الوحدة «{name}» نهائيًا.'**
  String unitDeleteConfirm(String name);

  /// No description provided for @unitCannotDeleteSystemTitle.
  ///
  /// In ar, this message translates to:
  /// **'وحدة مضمّنة'**
  String get unitCannotDeleteSystemTitle;

  /// No description provided for @unitCannotDeleteSystemMessage.
  ///
  /// In ar, this message translates to:
  /// **'الوحدات المضمّنة لا تُحذف. يمكنك تعطيلها بدلاً من ذلك.'**
  String get unitCannotDeleteSystemMessage;

  /// No description provided for @unitCannotDeleteInUseTitle.
  ///
  /// In ar, this message translates to:
  /// **'الوحدة قيد الاستخدام'**
  String get unitCannotDeleteInUseTitle;

  /// No description provided for @unitCannotDeleteInUseMessage.
  ///
  /// In ar, this message translates to:
  /// **'هذه الوحدة مستخدمة في {count} منتج، لذا لا يمكن حذفها. عطّلها بدلاً من ذلك.'**
  String unitCannotDeleteInUseMessage(int count);

  /// No description provided for @unitActivateAction.
  ///
  /// In ar, this message translates to:
  /// **'تفعيل'**
  String get unitActivateAction;

  /// No description provided for @unitDeactivateAction.
  ///
  /// In ar, this message translates to:
  /// **'تعطيل'**
  String get unitDeactivateAction;

  /// No description provided for @productIsPreparedTitle.
  ///
  /// In ar, this message translates to:
  /// **'يُحضّر عند الطلب'**
  String get productIsPreparedTitle;

  /// No description provided for @productIsPreparedDescription.
  ///
  /// In ar, this message translates to:
  /// **'طبق مطبخ: يُباع دون مخزون خاص به وتُخصم مكوناته من الوصفة عند التحضير.'**
  String get productIsPreparedDescription;

  /// No description provided for @productIsServiceTitle.
  ///
  /// In ar, this message translates to:
  /// **'منتج خدمي'**
  String get productIsServiceTitle;

  /// No description provided for @productIsServiceDescription.
  ///
  /// In ar, this message translates to:
  /// **'خدمة أو رسوم تُباع دون أي مخزون.'**
  String get productIsServiceDescription;

  /// No description provided for @jobsEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مهام بعد'**
  String get jobsEmptyTitle;

  /// No description provided for @jobsEmptyMessage.
  ///
  /// In ar, this message translates to:
  /// **'المهمة هي أي عمل تتابعه خطوة بخطوة: تصليح جهاز، دفعة إنتاج، أو طلب مطبخ. أنشئ أول مهمة وسيظهر مسارها هنا.'**
  String get jobsEmptyMessage;

  /// No description provided for @newJobButton.
  ///
  /// In ar, this message translates to:
  /// **'مهمة جديدة'**
  String get newJobButton;

  /// No description provided for @jobSearchHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث برقم المهمة أو اسم الزبون أو رقم الجهاز'**
  String get jobSearchHint;

  /// No description provided for @jobFilterAll.
  ///
  /// In ar, this message translates to:
  /// **'الكل'**
  String get jobFilterAll;

  /// No description provided for @jobFilterMine.
  ///
  /// In ar, this message translates to:
  /// **'مهامي'**
  String get jobFilterMine;

  /// No description provided for @jobFilterOpenOnly.
  ///
  /// In ar, this message translates to:
  /// **'قيد العمل'**
  String get jobFilterOpenOnly;

  /// No description provided for @jobFilterDone.
  ///
  /// In ar, this message translates to:
  /// **'المنتهية'**
  String get jobFilterDone;

  /// No description provided for @jobStatusOpen.
  ///
  /// In ar, this message translates to:
  /// **'قيد العمل'**
  String get jobStatusOpen;

  /// No description provided for @jobStatusCompleted.
  ///
  /// In ar, this message translates to:
  /// **'منتهية'**
  String get jobStatusCompleted;

  /// No description provided for @jobStatusCancelled.
  ///
  /// In ar, this message translates to:
  /// **'ملغاة'**
  String get jobStatusCancelled;

  /// No description provided for @jobPriorityLabel.
  ///
  /// In ar, this message translates to:
  /// **'الأولوية'**
  String get jobPriorityLabel;

  /// No description provided for @jobPriorityLow.
  ///
  /// In ar, this message translates to:
  /// **'منخفضة'**
  String get jobPriorityLow;

  /// No description provided for @jobPriorityNormal.
  ///
  /// In ar, this message translates to:
  /// **'عادية'**
  String get jobPriorityNormal;

  /// No description provided for @jobPriorityHigh.
  ///
  /// In ar, this message translates to:
  /// **'مرتفعة'**
  String get jobPriorityHigh;

  /// No description provided for @jobPriorityUrgent.
  ///
  /// In ar, this message translates to:
  /// **'عاجلة'**
  String get jobPriorityUrgent;

  /// No description provided for @jobTypeRepair.
  ///
  /// In ar, this message translates to:
  /// **'تصليح'**
  String get jobTypeRepair;

  /// No description provided for @jobTypeProduction.
  ///
  /// In ar, this message translates to:
  /// **'إنتاج'**
  String get jobTypeProduction;

  /// No description provided for @jobTypeKitchen.
  ///
  /// In ar, this message translates to:
  /// **'مطبخ'**
  String get jobTypeKitchen;

  /// No description provided for @jobTypeWorkOrder.
  ///
  /// In ar, this message translates to:
  /// **'أمر عمل'**
  String get jobTypeWorkOrder;

  /// No description provided for @jobDetailsTitle.
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل المهمة'**
  String get jobDetailsTitle;

  /// No description provided for @jobTimelineTitle.
  ///
  /// In ar, this message translates to:
  /// **'مسار المهمة'**
  String get jobTimelineTitle;

  /// No description provided for @jobCurrentStageLabel.
  ///
  /// In ar, this message translates to:
  /// **'المرحلة الحالية'**
  String get jobCurrentStageLabel;

  /// Compact 'stage N of M' workflow progress caption.
  ///
  /// In ar, this message translates to:
  /// **'المرحلة {current} من {total}'**
  String jobStageProgress(int current, int total);

  /// No description provided for @jobOverdueBadge.
  ///
  /// In ar, this message translates to:
  /// **'متأخرة'**
  String get jobOverdueBadge;

  /// No description provided for @jobMaterialsTotalShort.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي المواد'**
  String get jobMaterialsTotalShort;

  /// Primary button advancing the job to its next stage.
  ///
  /// In ar, this message translates to:
  /// **'الخطوة التالية: {stageName}'**
  String jobNextActionButton(String stageName);

  /// No description provided for @jobMoveToStageAction.
  ///
  /// In ar, this message translates to:
  /// **'نقل إلى مرحلة أخرى'**
  String get jobMoveToStageAction;

  /// No description provided for @jobStageChangeNoteLabel.
  ///
  /// In ar, this message translates to:
  /// **'ملاحظة (اختياري)'**
  String get jobStageChangeNoteLabel;

  /// Snackbar after a stage change.
  ///
  /// In ar, this message translates to:
  /// **'انتقلت المهمة إلى «{stageName}».'**
  String jobStageChangedMessage(String stageName);

  /// No description provided for @jobManagerOnlyMoveHint.
  ///
  /// In ar, this message translates to:
  /// **'الرجوع للخلف أو تخطي مرحلة يحتاج صلاحية مدير.'**
  String get jobManagerOnlyMoveHint;

  /// No description provided for @jobCustomerSection.
  ///
  /// In ar, this message translates to:
  /// **'الزبون'**
  String get jobCustomerSection;

  /// No description provided for @jobNoCustomer.
  ///
  /// In ar, this message translates to:
  /// **'بدون زبون'**
  String get jobNoCustomer;

  /// No description provided for @jobAssetSection.
  ///
  /// In ar, this message translates to:
  /// **'الجهاز'**
  String get jobAssetSection;

  /// No description provided for @assetHistoryTitle.
  ///
  /// In ar, this message translates to:
  /// **'سجل الجهاز'**
  String get assetHistoryTitle;

  /// No description provided for @assetHistoryEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد سجل سابق لهذا الجهاز.'**
  String get assetHistoryEmpty;

  /// No description provided for @customerAssetsTitle.
  ///
  /// In ar, this message translates to:
  /// **'أجهزة الزبون'**
  String get customerAssetsTitle;

  /// No description provided for @customerAssetsEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد أجهزة مسجلة لهذا الزبون.'**
  String get customerAssetsEmpty;

  /// No description provided for @jobMaterialsSection.
  ///
  /// In ar, this message translates to:
  /// **'القطع والمواد'**
  String get jobMaterialsSection;

  /// No description provided for @jobMaterialsEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لم تُستخدم قطع بعد. أضف كل قطعة تركّبها وسيُخصم المخزون تلقائيًا.'**
  String get jobMaterialsEmpty;

  /// No description provided for @addMaterialButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة قطعة'**
  String get addMaterialButton;

  /// No description provided for @materialQuantityLabel.
  ///
  /// In ar, this message translates to:
  /// **'الكمية'**
  String get materialQuantityLabel;

  /// No description provided for @materialConsumedBadge.
  ///
  /// In ar, this message translates to:
  /// **'خُصمت من المخزون'**
  String get materialConsumedBadge;

  /// No description provided for @materialPendingBadge.
  ///
  /// In ar, this message translates to:
  /// **'بانتظار الخصم'**
  String get materialPendingBadge;

  /// No description provided for @materialReversedBadge.
  ///
  /// In ar, this message translates to:
  /// **'أُرجعت للمخزون'**
  String get materialReversedBadge;

  /// No description provided for @reverseMaterialAction.
  ///
  /// In ar, this message translates to:
  /// **'إرجاع للمخزون'**
  String get reverseMaterialAction;

  /// No description provided for @reverseMaterialConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'إرجاع القطعة للمخزون؟'**
  String get reverseMaterialConfirmTitle;

  /// No description provided for @reverseMaterialConfirmMessage.
  ///
  /// In ar, this message translates to:
  /// **'ستُعاد الكمية إلى المخزون وتُحذف من حساب المهمة.'**
  String get reverseMaterialConfirmMessage;

  /// Total price of materials used on a job.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي القطع: {amount}'**
  String jobMaterialsTotalLabel(String amount);

  /// No description provided for @jobQuotedPriceLabel.
  ///
  /// In ar, this message translates to:
  /// **'السعر المبدئي'**
  String get jobQuotedPriceLabel;

  /// No description provided for @jobApprovedPriceLabel.
  ///
  /// In ar, this message translates to:
  /// **'السعر المعتمد من الزبون'**
  String get jobApprovedPriceLabel;

  /// No description provided for @jobApprovalRequiredHint.
  ///
  /// In ar, this message translates to:
  /// **'سجّل السعر الذي وافق عليه الزبون قبل بدء العمل.'**
  String get jobApprovalRequiredHint;

  /// No description provided for @jobWarrantyDaysLabel.
  ///
  /// In ar, this message translates to:
  /// **'أيام الضمان'**
  String get jobWarrantyDaysLabel;

  /// No description provided for @jobSymptomsLabel.
  ///
  /// In ar, this message translates to:
  /// **'وصف المشكلة'**
  String get jobSymptomsLabel;

  /// No description provided for @jobDiagnosisLabel.
  ///
  /// In ar, this message translates to:
  /// **'التشخيص'**
  String get jobDiagnosisLabel;

  /// No description provided for @jobTechnicianNotesLabel.
  ///
  /// In ar, this message translates to:
  /// **'ملاحظات الفني'**
  String get jobTechnicianNotesLabel;

  /// No description provided for @jobSaveButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ التعديلات'**
  String get jobSaveButton;

  /// No description provided for @jobSavedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ المهمة.'**
  String get jobSavedMessage;

  /// No description provided for @jobAssignedToLabel.
  ///
  /// In ar, this message translates to:
  /// **'مسؤول التنفيذ'**
  String get jobAssignedToLabel;

  /// No description provided for @jobUnassigned.
  ///
  /// In ar, this message translates to:
  /// **'غير معيّن'**
  String get jobUnassigned;

  /// No description provided for @jobDueAtLabel.
  ///
  /// In ar, this message translates to:
  /// **'موعد التسليم'**
  String get jobDueAtLabel;

  /// No description provided for @jobCreatedAtLabel.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الاستلام'**
  String get jobCreatedAtLabel;

  /// No description provided for @jobInvoiceButton.
  ///
  /// In ar, this message translates to:
  /// **'تحصيل وفوترة'**
  String get jobInvoiceButton;

  /// No description provided for @jobInvoiceTitle.
  ///
  /// In ar, this message translates to:
  /// **'فاتورة المهمة'**
  String get jobInvoiceTitle;

  /// No description provided for @jobInvoiceExplainer.
  ///
  /// In ar, this message translates to:
  /// **'ستُنشأ فاتورة عادية بالقطع المستخدمة وأجور العمل، ويدخل المبلغ في جلسة الدرج الحالية.'**
  String get jobInvoiceExplainer;

  /// No description provided for @jobLaborTotalLabel.
  ///
  /// In ar, this message translates to:
  /// **'أجور العمل'**
  String get jobLaborTotalLabel;

  /// Job invoice grand total.
  ///
  /// In ar, this message translates to:
  /// **'الإجمالي: {amount}'**
  String jobInvoiceTotalLabel(String amount);

  /// Snackbar after invoicing a job.
  ///
  /// In ar, this message translates to:
  /// **'تم إنشاء الفاتورة {receiptNumber}.'**
  String jobInvoiceSuccess(String receiptNumber);

  /// No description provided for @jobInvoiceNeedsRegister.
  ///
  /// In ar, this message translates to:
  /// **'افتح جلسة الدرج أولًا حتى يُسجل المبلغ في حساباتك.'**
  String get jobInvoiceNeedsRegister;

  /// Badge linking a job to its receipt.
  ///
  /// In ar, this message translates to:
  /// **'مفوترة — {receiptNumber}'**
  String jobInvoicedBadge(String receiptNumber);

  /// No description provided for @jobCancelAction.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء المهمة'**
  String get jobCancelAction;

  /// No description provided for @jobCancelConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء المهمة؟'**
  String get jobCancelConfirmTitle;

  /// No description provided for @jobCancelConfirmMessage.
  ///
  /// In ar, this message translates to:
  /// **'ستُلغى المهمة وتُعاد أي قطع مستخدمة إلى المخزون.'**
  String get jobCancelConfirmMessage;

  /// No description provided for @jobCancelReasonLabel.
  ///
  /// In ar, this message translates to:
  /// **'سبب الإلغاء'**
  String get jobCancelReasonLabel;

  /// No description provided for @jobReopenAction.
  ///
  /// In ar, this message translates to:
  /// **'إعادة فتح المهمة'**
  String get jobReopenAction;

  /// No description provided for @intakeTitle.
  ///
  /// In ar, this message translates to:
  /// **'استلام مهمة جديدة'**
  String get intakeTitle;

  /// No description provided for @intakeStepCustomer.
  ///
  /// In ar, this message translates to:
  /// **'الزبون'**
  String get intakeStepCustomer;

  /// No description provided for @intakeStepAsset.
  ///
  /// In ar, this message translates to:
  /// **'الجهاز'**
  String get intakeStepAsset;

  /// No description provided for @intakeStepDetails.
  ///
  /// In ar, this message translates to:
  /// **'التفاصيل'**
  String get intakeStepDetails;

  /// No description provided for @intakeNextButton.
  ///
  /// In ar, this message translates to:
  /// **'التالي'**
  String get intakeNextButton;

  /// No description provided for @intakeBackButton.
  ///
  /// In ar, this message translates to:
  /// **'السابق'**
  String get intakeBackButton;

  /// No description provided for @intakeCreateButton.
  ///
  /// In ar, this message translates to:
  /// **'إنشاء المهمة'**
  String get intakeCreateButton;

  /// No description provided for @intakeSelectCustomerHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث عن الزبون بالاسم أو الهاتف، أو أنشئ زبونًا جديدًا.'**
  String get intakeSelectCustomerHint;

  /// No description provided for @intakeNewCustomerButton.
  ///
  /// In ar, this message translates to:
  /// **'زبون جديد'**
  String get intakeNewCustomerButton;

  /// No description provided for @intakeCustomerNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم الزبون'**
  String get intakeCustomerNameLabel;

  /// No description provided for @intakeCustomerPhoneLabel.
  ///
  /// In ar, this message translates to:
  /// **'رقم الهاتف'**
  String get intakeCustomerPhoneLabel;

  /// No description provided for @intakeCustomerRequired.
  ///
  /// In ar, this message translates to:
  /// **'اختر زبونًا للمتابعة.'**
  String get intakeCustomerRequired;

  /// No description provided for @intakeSelectAssetHint.
  ///
  /// In ar, this message translates to:
  /// **'اختر جهاز الزبون أو أضف جهازًا جديدًا. يساعدك هذا لاحقًا في معرفة تاريخ كل جهاز.'**
  String get intakeSelectAssetHint;

  /// No description provided for @intakeNewAssetButton.
  ///
  /// In ar, this message translates to:
  /// **'جهاز جديد'**
  String get intakeNewAssetButton;

  /// No description provided for @intakeSkipAssetButton.
  ///
  /// In ar, this message translates to:
  /// **'متابعة بدون جهاز'**
  String get intakeSkipAssetButton;

  /// No description provided for @assetTypeLabel.
  ///
  /// In ar, this message translates to:
  /// **'نوع الجهاز'**
  String get assetTypeLabel;

  /// No description provided for @assetBrandLabel.
  ///
  /// In ar, this message translates to:
  /// **'الماركة'**
  String get assetBrandLabel;

  /// No description provided for @assetModelLabel.
  ///
  /// In ar, this message translates to:
  /// **'الموديل'**
  String get assetModelLabel;

  /// No description provided for @assetSerialLabel.
  ///
  /// In ar, this message translates to:
  /// **'الرقم التسلسلي'**
  String get assetSerialLabel;

  /// No description provided for @assetImeiLabel.
  ///
  /// In ar, this message translates to:
  /// **'IMEI'**
  String get assetImeiLabel;

  /// No description provided for @assetColorLabel.
  ///
  /// In ar, this message translates to:
  /// **'اللون'**
  String get assetColorLabel;

  /// No description provided for @assetNotesLabel.
  ///
  /// In ar, this message translates to:
  /// **'ملاحظات'**
  String get assetNotesLabel;

  /// No description provided for @assetTypePhone.
  ///
  /// In ar, this message translates to:
  /// **'هاتف'**
  String get assetTypePhone;

  /// No description provided for @assetTypeTablet.
  ///
  /// In ar, this message translates to:
  /// **'تابلت'**
  String get assetTypeTablet;

  /// No description provided for @assetTypeLaptop.
  ///
  /// In ar, this message translates to:
  /// **'حاسوب محمول'**
  String get assetTypeLaptop;

  /// No description provided for @assetTypeConsole.
  ///
  /// In ar, this message translates to:
  /// **'جهاز ألعاب'**
  String get assetTypeConsole;

  /// No description provided for @assetTypeAppliance.
  ///
  /// In ar, this message translates to:
  /// **'جهاز منزلي'**
  String get assetTypeAppliance;

  /// No description provided for @assetTypeOther.
  ///
  /// In ar, this message translates to:
  /// **'أخرى'**
  String get assetTypeOther;

  /// No description provided for @intakeWorkflowLabel.
  ///
  /// In ar, this message translates to:
  /// **'نوع المهمة'**
  String get intakeWorkflowLabel;

  /// Snackbar after intake wizard creates a job.
  ///
  /// In ar, this message translates to:
  /// **'تم إنشاء المهمة {jobNumber}.'**
  String intakeJobCreated(String jobNumber);

  /// No description provided for @productionNewBatchButton.
  ///
  /// In ar, this message translates to:
  /// **'دفعة إنتاج جديدة'**
  String get productionNewBatchButton;

  /// No description provided for @productionRecipeLabel.
  ///
  /// In ar, this message translates to:
  /// **'الوصفة'**
  String get productionRecipeLabel;

  /// No description provided for @productionBatchesLabel.
  ///
  /// In ar, this message translates to:
  /// **'عدد الدفعات'**
  String get productionBatchesLabel;

  /// Preview of production output.
  ///
  /// In ar, this message translates to:
  /// **'سينتج {quantity} × {name}'**
  String productionOutputPreview(String quantity, String name);

  /// No description provided for @productionMaterialsPreviewTitle.
  ///
  /// In ar, this message translates to:
  /// **'المكونات المطلوبة'**
  String get productionMaterialsPreviewTitle;

  /// No description provided for @productionOutputSection.
  ///
  /// In ar, this message translates to:
  /// **'ناتج الإنتاج'**
  String get productionOutputSection;

  /// No description provided for @productionReceivedBadge.
  ///
  /// In ar, this message translates to:
  /// **'أُضيف للمخزون'**
  String get productionReceivedBadge;

  /// No description provided for @productionNoRecipesMessage.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ وصفة أولًا من إعدادات المتجر حتى يعرف النظام مكونات كل منتج.'**
  String get productionNoRecipesMessage;

  /// No description provided for @recipesTitle.
  ///
  /// In ar, this message translates to:
  /// **'الوصفات'**
  String get recipesTitle;

  /// No description provided for @recipesSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'حدد مكونات كل منتج تنتجه ليُخصم المخزون ويُحسب الناتج تلقائيًا'**
  String get recipesSubtitle;

  /// No description provided for @recipesEmptyMessage.
  ///
  /// In ar, this message translates to:
  /// **'الوصفة تخبر النظام بمكونات كل منتج تنتجه — مثل الدقيق والخميرة لرغيف الخبز — ليخصم المخزون ويضيف الناتج تلقائيًا.'**
  String get recipesEmptyMessage;

  /// No description provided for @newRecipeButton.
  ///
  /// In ar, this message translates to:
  /// **'وصفة جديدة'**
  String get newRecipeButton;

  /// No description provided for @recipeNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم الوصفة'**
  String get recipeNameLabel;

  /// No description provided for @recipeOutputVariantLabel.
  ///
  /// In ar, this message translates to:
  /// **'المنتج الناتج'**
  String get recipeOutputVariantLabel;

  /// No description provided for @recipeOutputQuantityLabel.
  ///
  /// In ar, this message translates to:
  /// **'الكمية الناتجة لكل دفعة'**
  String get recipeOutputQuantityLabel;

  /// No description provided for @recipeMakeToOrderLabel.
  ///
  /// In ar, this message translates to:
  /// **'يُحضّر عند الطلب'**
  String get recipeMakeToOrderLabel;

  /// No description provided for @recipeMakeToOrderHelper.
  ///
  /// In ar, this message translates to:
  /// **'يُخصم المكوّنات عند بيع المنتج، دون الحاجة لمخزون خاص به.'**
  String get recipeMakeToOrderHelper;

  /// No description provided for @recipeProduceToStockHelper.
  ///
  /// In ar, this message translates to:
  /// **'يُنتَج إلى المخزون مسبقًا عبر أمر إنتاج، ثم يُباع من المخزون.'**
  String get recipeProduceToStockHelper;

  /// No description provided for @recipeComponentsTitle.
  ///
  /// In ar, this message translates to:
  /// **'المكونات'**
  String get recipeComponentsTitle;

  /// No description provided for @recipeAddComponentButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة مكوّن'**
  String get recipeAddComponentButton;

  /// No description provided for @recipeComponentQuantityLabel.
  ///
  /// In ar, this message translates to:
  /// **'الكمية'**
  String get recipeComponentQuantityLabel;

  /// No description provided for @recipeWastePercentLabel.
  ///
  /// In ar, this message translates to:
  /// **'نسبة الهدر %'**
  String get recipeWastePercentLabel;

  /// No description provided for @recipeDeleteAction.
  ///
  /// In ar, this message translates to:
  /// **'حذف الوصفة'**
  String get recipeDeleteAction;

  /// No description provided for @recipeDeleteConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'حذف الوصفة؟'**
  String get recipeDeleteConfirmTitle;

  /// Confirmation before deleting a recipe.
  ///
  /// In ar, this message translates to:
  /// **'سيتم حذف «{name}» نهائيًا. الوصفات المستخدمة في دفعات إنتاج سابقة لا يمكن حذفها.'**
  String recipeDeleteConfirmMessage(String name);

  /// No description provided for @recipeSaveButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ الوصفة'**
  String get recipeSaveButton;

  /// No description provided for @recipeSavedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ الوصفة.'**
  String get recipeSavedMessage;

  /// No description provided for @recipesLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل الوصفات.'**
  String get recipesLoadError;

  /// No description provided for @recipeNameRequired.
  ///
  /// In ar, this message translates to:
  /// **'أدخل اسم الوصفة.'**
  String get recipeNameRequired;

  /// No description provided for @recipeComponentsRequired.
  ///
  /// In ar, this message translates to:
  /// **'أضف مكوّنًا واحدًا على الأقل.'**
  String get recipeComponentsRequired;

  /// No description provided for @operationsSettingsSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'العمليات والمهام'**
  String get operationsSettingsSectionTitle;

  /// No description provided for @operationsSettingsSectionSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'تشغيل التصليح والإنتاج والمطبخ وإدارة مراحل العمل'**
  String get operationsSettingsSectionSubtitle;

  /// No description provided for @operationsModesTitle.
  ///
  /// In ar, this message translates to:
  /// **'أقسام العمل'**
  String get operationsModesTitle;

  /// No description provided for @operationsModesHint.
  ///
  /// In ar, this message translates to:
  /// **'فعّل ما يناسب نشاطك فقط — كل قسم يضيف نوع مهام جاهزًا بمراحله.'**
  String get operationsModesHint;

  /// No description provided for @enableRepairOperationsTitle.
  ///
  /// In ar, this message translates to:
  /// **'التصليح والصيانة'**
  String get enableRepairOperationsTitle;

  /// No description provided for @enableRepairOperationsDescription.
  ///
  /// In ar, this message translates to:
  /// **'استلام أجهزة الزبائن، تتبع التصليح خطوة بخطوة، وفوترة القطع والأجور.'**
  String get enableRepairOperationsDescription;

  /// No description provided for @enableProductionOperationsTitle.
  ///
  /// In ar, this message translates to:
  /// **'الإنتاج'**
  String get enableProductionOperationsTitle;

  /// No description provided for @enableProductionOperationsDescription.
  ///
  /// In ar, this message translates to:
  /// **'دفعات إنتاج بوصفات محددة: تُخصم المكونات ويُضاف الناتج للمخزون تلقائيًا.'**
  String get enableProductionOperationsDescription;

  /// No description provided for @enableKitchenOperationsTitle.
  ///
  /// In ar, this message translates to:
  /// **'المطبخ'**
  String get enableKitchenOperationsTitle;

  /// No description provided for @enableKitchenOperationsDescription.
  ///
  /// In ar, this message translates to:
  /// **'طلبات مطبخ تمر بمراحل التحضير وتخصم المكونات عند الطبخ.'**
  String get enableKitchenOperationsDescription;

  /// No description provided for @kitchenPrintingSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'طباعة المطبخ'**
  String get kitchenPrintingSectionTitle;

  /// No description provided for @kitchenPrintingSectionHint.
  ///
  /// In ar, this message translates to:
  /// **'اطبع تذاكر المطبخ تلقائيًا للأصناف المحضّرة عند الدفع، ووجّهها إلى الطابعات حسب الفئة.'**
  String get kitchenPrintingSectionHint;

  /// No description provided for @autoPrintKitchenTicketsTitle.
  ///
  /// In ar, this message translates to:
  /// **'طباعة تذاكر المطبخ تلقائيًا'**
  String get autoPrintKitchenTicketsTitle;

  /// No description provided for @autoPrintKitchenTicketsDescription.
  ///
  /// In ar, this message translates to:
  /// **'عند الدفع، تُطبع تذكرة تحضير لكل محطة معنية بالأصناف المحضّرة.'**
  String get autoPrintKitchenTicketsDescription;

  /// No description provided for @prepStationsSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'محطات التحضير'**
  String get prepStationsSectionTitle;

  /// No description provided for @prepStationsSectionSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'وجّه الأصناف المحضّرة إلى طابعات المحطات حسب الفئة.'**
  String get prepStationsSectionSubtitle;

  /// No description provided for @prepStationAddButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة محطة'**
  String get prepStationAddButton;

  /// No description provided for @prepStationsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل محطات التحضير.'**
  String get prepStationsLoadError;

  /// No description provided for @prepStationsEmptyMessage.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد محطات تحضير بعد.'**
  String get prepStationsEmptyMessage;

  /// No description provided for @prepStationNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم المحطة'**
  String get prepStationNameLabel;

  /// No description provided for @prepStationCategoriesLabel.
  ///
  /// In ar, this message translates to:
  /// **'الفئات الموجّهة'**
  String get prepStationCategoriesLabel;

  /// No description provided for @prepStationDefaultLabel.
  ///
  /// In ar, this message translates to:
  /// **'المحطة الافتراضية (تستقبل الأصناف غير المصنّفة)'**
  String get prepStationDefaultLabel;

  /// No description provided for @prepStationActiveLabel.
  ///
  /// In ar, this message translates to:
  /// **'مفعّلة'**
  String get prepStationActiveLabel;

  /// No description provided for @prepStationDefaultBadge.
  ///
  /// In ar, this message translates to:
  /// **'افتراضية'**
  String get prepStationDefaultBadge;

  /// No description provided for @prepStationInactiveBadge.
  ///
  /// In ar, this message translates to:
  /// **'موقوفة'**
  String get prepStationInactiveBadge;

  /// No description provided for @prepStationCategoriesEmpty.
  ///
  /// In ar, this message translates to:
  /// **'كل الأصناف المحضّرة غير المصنّفة'**
  String get prepStationCategoriesEmpty;

  /// No description provided for @prepStationDeleteTitle.
  ///
  /// In ar, this message translates to:
  /// **'حذف المحطة؟'**
  String get prepStationDeleteTitle;

  /// No description provided for @prepStationDeleteMessage.
  ///
  /// In ar, this message translates to:
  /// **'لن تُطبع تذاكر هذه المحطة بعد الآن.'**
  String get prepStationDeleteMessage;

  /// No description provided for @prepStationSaveError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حفظ المحطة.'**
  String get prepStationSaveError;

  /// No description provided for @prepStationDeleteError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حذف المحطة.'**
  String get prepStationDeleteError;

  /// No description provided for @kitchenPrintersSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'طابعات المطبخ'**
  String get kitchenPrintersSectionTitle;

  /// No description provided for @kitchenPrintersSectionHint.
  ///
  /// In ar, this message translates to:
  /// **'اربط طابعة حرارية بكل محطة تحضير يخدمها هذا الجهاز.'**
  String get kitchenPrintersSectionHint;

  /// No description provided for @kitchenPrintersNoStations.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد محطات تحضير. أضِفها من إعدادات المتجر.'**
  String get kitchenPrintersNoStations;

  /// No description provided for @kitchenPrintersLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل محطات التحضير.'**
  String get kitchenPrintersLoadError;

  /// No description provided for @kitchenStationNotConfigured.
  ///
  /// In ar, this message translates to:
  /// **'لم تُضبط طابعة لهذه المحطة.'**
  String get kitchenStationNotConfigured;

  /// No description provided for @enableJobTrackingTitle.
  ///
  /// In ar, this message translates to:
  /// **'صفحة تتبع للزبائن'**
  String get enableJobTrackingTitle;

  /// No description provided for @enableJobTrackingDescription.
  ///
  /// In ar, this message translates to:
  /// **'رابط عام يطّلع منه الزبون على حالة مهمته دون الاتصال بك.'**
  String get enableJobTrackingDescription;

  /// No description provided for @workflowsTitle.
  ///
  /// In ar, this message translates to:
  /// **'مراحل العمل'**
  String get workflowsTitle;

  /// No description provided for @workflowStagesHint.
  ///
  /// In ar, this message translates to:
  /// **'هذه هي الخطوات التي تمر بها كل مهمة من الاستلام حتى التسليم. يمكنك إعادة تسميتها أو إضافة مراحل تناسب طريقة عملك.'**
  String get workflowStagesHint;

  /// No description provided for @workflowStageNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم المرحلة'**
  String get workflowStageNameLabel;

  /// No description provided for @workflowAddStageButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة مرحلة'**
  String get workflowAddStageButton;

  /// No description provided for @workflowStageInitialLabel.
  ///
  /// In ar, this message translates to:
  /// **'مرحلة البداية'**
  String get workflowStageInitialLabel;

  /// No description provided for @workflowStageTerminalLabel.
  ///
  /// In ar, this message translates to:
  /// **'مرحلة النهاية'**
  String get workflowStageTerminalLabel;

  /// No description provided for @workflowStageApprovalLabel.
  ///
  /// In ar, this message translates to:
  /// **'تتطلب موافقة الزبون على السعر'**
  String get workflowStageApprovalLabel;

  /// No description provided for @workflowStageConsumesLabel.
  ///
  /// In ar, this message translates to:
  /// **'تخصم المواد من المخزون'**
  String get workflowStageConsumesLabel;

  /// No description provided for @workflowStageProducesLabel.
  ///
  /// In ar, this message translates to:
  /// **'تضيف الناتج إلى المخزون'**
  String get workflowStageProducesLabel;

  /// No description provided for @workflowSaveButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ المراحل'**
  String get workflowSaveButton;

  /// No description provided for @workflowSavedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ مراحل العمل.'**
  String get workflowSavedMessage;

  /// No description provided for @workflowsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل مراحل العمل.'**
  String get workflowsLoadError;

  /// Count of jobs in a stage column.
  ///
  /// In ar, this message translates to:
  /// **'{count} مهمة'**
  String jobCountLabel(int count);

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

  /// Online invoice setting summary in the shop settings index.
  ///
  /// In ar, this message translates to:
  /// **'فواتير الإنترنت: {status}'**
  String onlineInvoiceSettingSummary(String status);

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
      int count, String oversellStatus, String lossStatus);

  /// Summary for payment settings in the shop settings index.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد طرق دفع مفعلة} =1{طريقة دفع واحدة مفعلة} =2{طريقتان مفعّلتان} other{{count} طرق دفع مفعلة}}، بطاقة {cardCommission}%، تحويل {transferCommission}%، إثبات البطاقة: {receiptStatus}، {terminalStatus}'**
  String paymentSettingsSummary(num count, String cardCommission,
      String transferCommission, String receiptStatus, String terminalStatus);

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

  /// No description provided for @backupRestoreSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'النسخ والاستعادة'**
  String get backupRestoreSectionTitle;

  /// No description provided for @backupStatusLoadingSummary.
  ///
  /// In ar, this message translates to:
  /// **'جار تحميل حالة النسخ الاحتياطي'**
  String get backupStatusLoadingSummary;

  /// No description provided for @backupScheduleDisabledSummary.
  ///
  /// In ar, this message translates to:
  /// **'النسخ التلقائي متوقف'**
  String get backupScheduleDisabledSummary;

  /// No description provided for @backupScheduleMissingDestinationSummary.
  ///
  /// In ar, this message translates to:
  /// **'اختر قرصا خارجيا لتفعيل النسخ التلقائي'**
  String get backupScheduleMissingDestinationSummary;

  /// Summary for the next scheduled backup time.
  ///
  /// In ar, this message translates to:
  /// **'النسخة التالية: {dateTime}'**
  String backupNextScheduledSummary(String dateTime);

  /// Summary when a backup or restore job is running.
  ///
  /// In ar, this message translates to:
  /// **'{operation} قيد التنفيذ، {percent}٪'**
  String backupJobRunningSummary(String operation, int percent);

  /// No description provided for @backupRestoreTitle.
  ///
  /// In ar, this message translates to:
  /// **'النسخ والاستعادة'**
  String get backupRestoreTitle;

  /// No description provided for @backupRefreshTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث حالة النسخ'**
  String get backupRefreshTooltip;

  /// No description provided for @backupScheduleSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'النسخ الاحتياطي التلقائي'**
  String get backupScheduleSectionTitle;

  /// No description provided for @backupScheduleEnabledLabel.
  ///
  /// In ar, this message translates to:
  /// **'تفعيل النسخ اليومي'**
  String get backupScheduleEnabledLabel;

  /// No description provided for @backupScheduleEnabledSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'ينشئ النظام ملف ZIP واحدا يحتوي قاعدة البيانات والملفات المرفوعة.'**
  String get backupScheduleEnabledSubtitle;

  /// No description provided for @backupDestinationLabel.
  ///
  /// In ar, this message translates to:
  /// **'قرص النسخ الاحتياطي'**
  String get backupDestinationLabel;

  /// Dropdown label for a backup destination.
  ///
  /// In ar, this message translates to:
  /// **'{label}، متاح {freeSpace}'**
  String backupDestinationOption(String label, String freeSpace);

  /// Details for the selected backup destination.
  ///
  /// In ar, this message translates to:
  /// **'سيتم الحفظ في {path}. المساحة المتاحة {freeSpace} من {totalSpace}.'**
  String backupDestinationDetails(
      String path, String freeSpace, String totalSpace);

  /// No description provided for @backupNoWritableDestinationsMessage.
  ///
  /// In ar, this message translates to:
  /// **'لم يجد الخادم قرصا خارجيا قابلا للكتابة. تأكد من توصيل القرص وربطه داخل Docker.'**
  String get backupNoWritableDestinationsMessage;

  /// No description provided for @backupScheduledTimeLabel.
  ///
  /// In ar, this message translates to:
  /// **'وقت النسخ اليومي'**
  String get backupScheduledTimeLabel;

  /// Retention explanation for automatic backups.
  ///
  /// In ar, this message translates to:
  /// **'بعد نجاح النسخ يحتفظ دفتر بآخر {count} نسخ ويحذف الأقدم من مجلد النسخ.'**
  String backupRetentionMessage(int count);

  /// No description provided for @backupDestinationRequiredError.
  ///
  /// In ar, this message translates to:
  /// **'اختر قرصا للنسخ الاحتياطي.'**
  String get backupDestinationRequiredError;

  /// No description provided for @backupSaveScheduleButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ الجدولة'**
  String get backupSaveScheduleButton;

  /// No description provided for @backupSavingScheduleButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الحفظ...'**
  String get backupSavingScheduleButton;

  /// No description provided for @backupStartNowButton.
  ///
  /// In ar, this message translates to:
  /// **'نسخ الآن'**
  String get backupStartNowButton;

  /// No description provided for @backupStartingButton.
  ///
  /// In ar, this message translates to:
  /// **'جار البدء...'**
  String get backupStartingButton;

  /// No description provided for @backupScheduleSavedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ جدولة النسخ الاحتياطي.'**
  String get backupScheduleSavedMessage;

  /// No description provided for @backupStartedMessage.
  ///
  /// In ar, this message translates to:
  /// **'بدأ النسخ الاحتياطي.'**
  String get backupStartedMessage;

  /// No description provided for @backupOperationFailedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تعذرت عملية النسخ أو الاستعادة. حاول مرة أخرى.'**
  String get backupOperationFailedMessage;

  /// Title for an active backup/restore job.
  ///
  /// In ar, this message translates to:
  /// **'{operation} قيد التنفيذ'**
  String backupActiveJobTitle(String operation);

  /// Progress percentage label.
  ///
  /// In ar, this message translates to:
  /// **'{percent}٪'**
  String backupProgressPercent(int percent);

  /// No description provided for @restoreSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'استعادة نسخة'**
  String get restoreSectionTitle;

  /// No description provided for @restoreWarningMessage.
  ///
  /// In ar, this message translates to:
  /// **'الاستعادة تستبدل قاعدة البيانات والملفات الحالية بمحتوى النسخة المختارة.'**
  String get restoreWarningMessage;

  /// No description provided for @restorePickFileButton.
  ///
  /// In ar, this message translates to:
  /// **'اختيار ملف ZIP'**
  String get restorePickFileButton;

  /// No description provided for @restoreUploadingButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الرفع...'**
  String get restoreUploadingButton;

  /// No description provided for @restorePickErrorMessage.
  ///
  /// In ar, this message translates to:
  /// **'تعذر قراءة ملف النسخة المختارة.'**
  String get restorePickErrorMessage;

  /// No description provided for @restoreConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد الاستعادة'**
  String get restoreConfirmTitle;

  /// No description provided for @restoreConfirmMessage.
  ///
  /// In ar, this message translates to:
  /// **'سيتم استبدال بيانات المتجر الحالية بعد بدء الاستعادة. تأكد أن ملف النسخة صحيح.'**
  String get restoreConfirmMessage;

  /// No description provided for @restoreConfirmButton.
  ///
  /// In ar, this message translates to:
  /// **'بدء الاستعادة'**
  String get restoreConfirmButton;

  /// No description provided for @restoreStartedMessage.
  ///
  /// In ar, this message translates to:
  /// **'بدأت الاستعادة.'**
  String get restoreStartedMessage;

  /// No description provided for @backupHistorySectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'آخر العمليات'**
  String get backupHistorySectionTitle;

  /// No description provided for @latestBackupLabel.
  ///
  /// In ar, this message translates to:
  /// **'آخر نسخة احتياطية'**
  String get latestBackupLabel;

  /// No description provided for @latestRestoreLabel.
  ///
  /// In ar, this message translates to:
  /// **'آخر استعادة'**
  String get latestRestoreLabel;

  /// No description provided for @backupNoJobValue.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عملية مسجلة'**
  String get backupNoJobValue;

  /// Summary for latest backup or restore job.
  ///
  /// In ar, this message translates to:
  /// **'{status}، {completedAt}، {filename}'**
  String backupJobHistorySummary(
      String status, String completedAt, String filename);

  /// No description provided for @backupOperationBackup.
  ///
  /// In ar, this message translates to:
  /// **'النسخ الاحتياطي'**
  String get backupOperationBackup;

  /// No description provided for @backupOperationRestore.
  ///
  /// In ar, this message translates to:
  /// **'الاستعادة'**
  String get backupOperationRestore;

  /// No description provided for @backupJobStatusQueued.
  ///
  /// In ar, this message translates to:
  /// **'في الانتظار'**
  String get backupJobStatusQueued;

  /// No description provided for @backupJobStatusRunning.
  ///
  /// In ar, this message translates to:
  /// **'قيد التنفيذ'**
  String get backupJobStatusRunning;

  /// No description provided for @backupJobStatusSucceeded.
  ///
  /// In ar, this message translates to:
  /// **'مكتملة'**
  String get backupJobStatusSucceeded;

  /// No description provided for @backupJobStatusFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشلت'**
  String get backupJobStatusFailed;

  /// No description provided for @backupStorageUnknownValue.
  ///
  /// In ar, this message translates to:
  /// **'غير معروف'**
  String get backupStorageUnknownValue;

  /// Storage size in GiB.
  ///
  /// In ar, this message translates to:
  /// **'{value} جيجابايت'**
  String backupStorageGigabytes(String value);

  /// Storage size in MiB.
  ///
  /// In ar, this message translates to:
  /// **'{value} ميجابايت'**
  String backupStorageMegabytes(String value);

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

  /// No description provided for @enableOnlineInvoicesLabel.
  ///
  /// In ar, this message translates to:
  /// **'إظهار رابط وQR للفاتورة عبر الإنترنت'**
  String get enableOnlineInvoicesLabel;

  /// No description provided for @enableOnlineInvoicesSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'بعد الدفع يظهر رابط الفاتورة الحقيقي عبر الريلاي ليتمكن العميل من حفظها كملف PDF.'**
  String get enableOnlineInvoicesSubtitle;

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

  /// No description provided for @requireCustomerForCreditLabel.
  ///
  /// In ar, this message translates to:
  /// **'طلب عميل للبيع الآجل وعروض الأسعار'**
  String get requireCustomerForCreditLabel;

  /// No description provided for @requireCustomerForCreditSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'عند تفعيله يجب اختيار عميل قبل إتمام بيع آجل أو عرض سعر.'**
  String get requireCustomerForCreditSubtitle;

  /// No description provided for @allowCashierCustomerAccessLabel.
  ///
  /// In ar, this message translates to:
  /// **'السماح للكاشير بالعملاء والتحصيل'**
  String get allowCashierCustomerAccessLabel;

  /// No description provided for @allowCashierCustomerAccessSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'يتيح للكاشير اختيار عميل للبيع الآجل/عرض السعر وتحصيل ديون العملاء — دون رؤية فواتير الكاشيرين الآخرين أو تعديل بيانات العملاء.'**
  String get allowCashierCustomerAccessSubtitle;

  /// No description provided for @collectDebtTitle.
  ///
  /// In ar, this message translates to:
  /// **'تحصيل دين'**
  String get collectDebtTitle;

  /// No description provided for @collectDebtPickCustomer.
  ///
  /// In ar, this message translates to:
  /// **'اختر عميلاً للتحصيل'**
  String get collectDebtPickCustomer;

  /// No description provided for @collectDebtChangeCustomer.
  ///
  /// In ar, this message translates to:
  /// **'تغيير العميل'**
  String get collectDebtChangeCustomer;

  /// No description provided for @collectDebtLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل رصيد العميل. حاول مرة أخرى.'**
  String get collectDebtLoadError;

  /// Customer outstanding debt total shown in the collect-debt flow.
  ///
  /// In ar, this message translates to:
  /// **'المتبقّي على العميل: {amount}'**
  String collectDebtOutstanding(String amount);

  /// No description provided for @collectDebtNoDebt.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد دين على هذا العميل.'**
  String get collectDebtNoDebt;

  /// No description provided for @collectDebtRecordPayment.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل دفعة'**
  String get collectDebtRecordPayment;

  /// No description provided for @collectDebtRecordedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل الدفعة وتحصيل الدين.'**
  String get collectDebtRecordedMessage;

  /// No description provided for @collectDebtFailedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تسجيل الدفعة. حاول مرة أخرى.'**
  String get collectDebtFailedMessage;

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

  /// No description provided for @printerTransportSystem.
  ///
  /// In ar, this message translates to:
  /// **'طابعة النظام'**
  String get printerTransportSystem;

  /// No description provided for @printerTransportUsb.
  ///
  /// In ar, this message translates to:
  /// **'USB'**
  String get printerTransportUsb;

  /// No description provided for @printerTransportFake.
  ///
  /// In ar, this message translates to:
  /// **'محاكاة'**
  String get printerTransportFake;

  /// No description provided for @printerOutputThermalReceipt.
  ///
  /// In ar, this message translates to:
  /// **'إخراج حراري ESC/POS'**
  String get printerOutputThermalReceipt;

  /// No description provided for @printerOutputA4Pdf.
  ///
  /// In ar, this message translates to:
  /// **'إخراج PDF بحجم A4'**
  String get printerOutputA4Pdf;

  /// Selected-printer summary line for a document/PDF printer set to a receipt roll width.
  ///
  /// In ar, this message translates to:
  /// **'إخراج إيصال PDF بعرض {width} مم'**
  String printerOutputPdfReceipt(int width);

  /// No description provided for @printerPdfPageSizeLabel.
  ///
  /// In ar, this message translates to:
  /// **'حجم صفحة PDF'**
  String get printerPdfPageSizeLabel;

  /// No description provided for @printerPdfPageSizeHelper.
  ///
  /// In ar, this message translates to:
  /// **'A4 لطباعة فاتورة كاملة، أو اختر عرض إيصال (58 أو 70 أو 80 مم) لطباعة إيصال مضغوط عبر تعريف الطابعة (مثل Xprinter) بدل أوامر ESC/POS غير المدعومة.'**
  String get printerPdfPageSizeHelper;

  /// No description provided for @printerPdfPageSizeA4.
  ///
  /// In ar, this message translates to:
  /// **'A4 (فاتورة كاملة)'**
  String get printerPdfPageSizeA4;

  /// No description provided for @printerPdfPageSizeRoll58.
  ///
  /// In ar, this message translates to:
  /// **'إيصال 58 مم'**
  String get printerPdfPageSizeRoll58;

  /// No description provided for @printerPdfPageSizeRoll70.
  ///
  /// In ar, this message translates to:
  /// **'إيصال 70 مم'**
  String get printerPdfPageSizeRoll70;

  /// No description provided for @printerPdfPageSizeRoll80.
  ///
  /// In ar, this message translates to:
  /// **'إيصال 80 مم'**
  String get printerPdfPageSizeRoll80;

  /// No description provided for @systemDefaultPrinterLabel.
  ///
  /// In ar, this message translates to:
  /// **'طابعة النظام الافتراضية'**
  String get systemDefaultPrinterLabel;

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

  /// No description provided for @printerCapabilityProfileLabel.
  ///
  /// In ar, this message translates to:
  /// **'ملف تعريف الطابعة'**
  String get printerCapabilityProfileLabel;

  /// No description provided for @printerCapabilityProfileHelper.
  ///
  /// In ar, this message translates to:
  /// **'اتركه default إن لم تكن متأكدًا. اختر ملف الشركة المصنعة للطابعات غير المتوافقة.'**
  String get printerCapabilityProfileHelper;

  /// No description provided for @printerCutModeLabel.
  ///
  /// In ar, this message translates to:
  /// **'وضع قص الورق'**
  String get printerCutModeLabel;

  /// No description provided for @printerCutModePartial.
  ///
  /// In ar, this message translates to:
  /// **'قص جزئي'**
  String get printerCutModePartial;

  /// No description provided for @printerCutModeFull.
  ///
  /// In ar, this message translates to:
  /// **'قص كامل'**
  String get printerCutModeFull;

  /// No description provided for @printerCutModeNone.
  ///
  /// In ar, this message translates to:
  /// **'بدون قص (تغذية فقط)'**
  String get printerCutModeNone;

  /// No description provided for @printerFeedLinesLabel.
  ///
  /// In ar, this message translates to:
  /// **'أسطر التغذية قبل القص'**
  String get printerFeedLinesLabel;

  /// No description provided for @printerFeedLinesHelper.
  ///
  /// In ar, this message translates to:
  /// **'زدها إذا كان آخر الإيصال يُقطع قبل اكتمال الطباعة.'**
  String get printerFeedLinesHelper;

  /// No description provided for @barcodeLabelPrinterSettingsTitle.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات ملصقات الباركود'**
  String get barcodeLabelPrinterSettingsTitle;

  /// No description provided for @printerBarcodeLabelLanguageLabel.
  ///
  /// In ar, this message translates to:
  /// **'لغة طابعة الملصقات'**
  String get printerBarcodeLabelLanguageLabel;

  /// No description provided for @printerBarcodeLabelLanguageAuto.
  ///
  /// In ar, this message translates to:
  /// **'اكتشاف تلقائي آمن'**
  String get printerBarcodeLabelLanguageAuto;

  /// No description provided for @printerBarcodeLabelLanguageZpl.
  ///
  /// In ar, this message translates to:
  /// **'ZPL'**
  String get printerBarcodeLabelLanguageZpl;

  /// No description provided for @printerBarcodeLabelLanguageTspl.
  ///
  /// In ar, this message translates to:
  /// **'TSPL/TSPL2'**
  String get printerBarcodeLabelLanguageTspl;

  /// No description provided for @printerBarcodeLabelLanguageEpl.
  ///
  /// In ar, this message translates to:
  /// **'EPL/EPL2'**
  String get printerBarcodeLabelLanguageEpl;

  /// No description provided for @printerBarcodeLabelLanguageCpcl.
  ///
  /// In ar, this message translates to:
  /// **'CPCL'**
  String get printerBarcodeLabelLanguageCpcl;

  /// No description provided for @detectBarcodeLabelLanguageButton.
  ///
  /// In ar, this message translates to:
  /// **'اكتشاف لغة طابعة الملصقات'**
  String get detectBarcodeLabelLanguageButton;

  /// No description provided for @printerLabelWidthLabel.
  ///
  /// In ar, this message translates to:
  /// **'عرض الملصق مم'**
  String get printerLabelWidthLabel;

  /// No description provided for @printerLabelHeightLabel.
  ///
  /// In ar, this message translates to:
  /// **'ارتفاع الملصق مم'**
  String get printerLabelHeightLabel;

  /// No description provided for @printerLabelGapLabel.
  ///
  /// In ar, this message translates to:
  /// **'الفاصل مم'**
  String get printerLabelGapLabel;

  /// No description provided for @printerLabelDpiLabel.
  ///
  /// In ar, this message translates to:
  /// **'الدقة DPI'**
  String get printerLabelDpiLabel;

  /// Selected barcode label printer language summary.
  ///
  /// In ar, this message translates to:
  /// **'لغة الملصقات: {language}'**
  String printerBarcodeLanguageSummary(String language);

  /// Barcode label dimensions and resolution summary.
  ///
  /// In ar, this message translates to:
  /// **'الملصق: {width}×{height} مم، فاصل {gap} مم، {dpi} DPI'**
  String printerLabelGeometrySummary(int width, int height, int gap, int dpi);

  /// No description provided for @barcodeLabelLanguageDetected.
  ///
  /// In ar, this message translates to:
  /// **'تم اكتشاف لغة طابعة الملصقات وحفظها.'**
  String get barcodeLabelLanguageDetected;

  /// No description provided for @barcodeLabelLanguageInferred.
  ///
  /// In ar, this message translates to:
  /// **'تم تخمين لغة طابعة الملصقات من اسم الطابعة. راجعها إذا لم تطبع الملصقات بشكل صحيح.'**
  String get barcodeLabelLanguageInferred;

  /// No description provided for @barcodeLabelLanguageDetectionUnavailable.
  ///
  /// In ar, this message translates to:
  /// **'تعذر اكتشاف لغة الملصقات تلقائيًا. اختر اللغة يدويًا لتجنب إرسال أوامر غير مناسبة.'**
  String get barcodeLabelLanguageDetectionUnavailable;

  /// No description provided for @barcodeLabelLanguageDetectionFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل اكتشاف لغة طابعة الملصقات. تحقق من الاتصال أو اختر اللغة يدويًا.'**
  String get barcodeLabelLanguageDetectionFailed;

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

  /// No description provided for @testBarcodeLabelPrinterButton.
  ///
  /// In ar, this message translates to:
  /// **'اختبار ملصق باركود'**
  String get testBarcodeLabelPrinterButton;

  /// No description provided for @testingBarcodeLabelPrinterButton.
  ///
  /// In ar, this message translates to:
  /// **'جار اختبار الملصق...'**
  String get testingBarcodeLabelPrinterButton;

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

  /// No description provided for @barcodeLabelTestSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم إرسال ملصق اختبار الباركود.'**
  String get barcodeLabelTestSuccess;

  /// No description provided for @barcodeLabelTestFailure.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إرسال ملصق اختبار الباركود. تحقق من لغة الملصقات والإعدادات.'**
  String get barcodeLabelTestFailure;

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

  /// No description provided for @productImageCameraButton.
  ///
  /// In ar, this message translates to:
  /// **'التقاط صورة'**
  String get productImageCameraButton;

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

  /// No description provided for @productImageCameraUnavailable.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر فتح الكاميرا على هذا الجهاز.'**
  String get productImageCameraUnavailable;

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
  /// **'خيارات المنتج'**
  String get variantOptionsLabel;

  /// No description provided for @variantOptionsHelper.
  ///
  /// In ar, this message translates to:
  /// **'أضِف خيارًا يميّز المنتج مثل اللون أو المقاس، ثم أدخل قيمه. ستُستخدم القيم لتوليد خيارات المنتج تلقائيًا.'**
  String get variantOptionsHelper;

  /// No description provided for @variantOptionsEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لم تُضِف أي خيار بعد.'**
  String get variantOptionsEmpty;

  /// No description provided for @variantOptionsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل الخيارات.'**
  String get variantOptionsLoadError;

  /// No description provided for @addVariantOptionButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة خيار'**
  String get addVariantOptionButton;

  /// No description provided for @reuseVariantOptionLabel.
  ///
  /// In ar, this message translates to:
  /// **'أو أعد استخدام خيار سابق'**
  String get reuseVariantOptionLabel;

  /// No description provided for @newVariantOptionTitle.
  ///
  /// In ar, this message translates to:
  /// **'خيار جديد'**
  String get newVariantOptionTitle;

  /// No description provided for @variantOptionNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم الخيار'**
  String get variantOptionNameLabel;

  /// No description provided for @variantOptionNameHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: اللون'**
  String get variantOptionNameHint;

  /// No description provided for @variantOptionCodeLabel.
  ///
  /// In ar, this message translates to:
  /// **'رمز الخيار'**
  String get variantOptionCodeLabel;

  /// No description provided for @variantOptionCodeHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: color'**
  String get variantOptionCodeHint;

  /// No description provided for @createVariantOptionButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ الخيار'**
  String get createVariantOptionButton;

  /// No description provided for @variantOptionCreateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إنشاء الخيار.'**
  String get variantOptionCreateError;

  /// No description provided for @variantValuesNoOptions.
  ///
  /// In ar, this message translates to:
  /// **'أضِف خيارًا واحدًا على الأقل لتحديد قيمه.'**
  String get variantValuesNoOptions;

  /// No description provided for @variantOptionNoValues.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد قيم لهذا الخيار بعد.'**
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
  /// **'اختر قيمة واحدة على الأقل لكل خيار.'**
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

  /// Number of products directly in a category.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا منتجات} =1{منتج واحد} =2{منتجان} other{{count} منتجات}}'**
  String categoryProductCount(num count);

  /// No description provided for @allCategoriesSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'كل التصنيفات'**
  String get allCategoriesSectionTitle;

  /// No description provided for @categorySearchResultsTitle.
  ///
  /// In ar, this message translates to:
  /// **'نتائج البحث'**
  String get categorySearchResultsTitle;

  /// No description provided for @categorySearchEmptyState.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد تصنيفات مطابقة لبحثك.'**
  String get categorySearchEmptyState;

  /// No description provided for @categoryEmptyHint.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ تصنيفك الأول لتنظيم منتجاتك.'**
  String get categoryEmptyHint;

  /// No description provided for @categoryInactiveBadge.
  ///
  /// In ar, this message translates to:
  /// **'غير نشط'**
  String get categoryInactiveBadge;

  /// No description provided for @categoryActionsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'خيارات'**
  String get categoryActionsTooltip;

  /// No description provided for @addSubcategoryAction.
  ///
  /// In ar, this message translates to:
  /// **'إضافة تصنيف فرعي'**
  String get addSubcategoryAction;

  /// No description provided for @editCategoryTitle.
  ///
  /// In ar, this message translates to:
  /// **'تعديل التصنيف'**
  String get editCategoryTitle;

  /// No description provided for @savingCategoryButton.
  ///
  /// In ar, this message translates to:
  /// **'جار الحفظ...'**
  String get savingCategoryButton;

  /// No description provided for @categoryUpdateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ التغييرات. حاول مرة أخرى.'**
  String get categoryUpdateError;

  /// No description provided for @categoryDeletedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم حذف التصنيف'**
  String get categoryDeletedMessage;

  /// No description provided for @categoryDeleteError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حذف التصنيف.'**
  String get categoryDeleteError;

  /// No description provided for @deleteCategoryTitle.
  ///
  /// In ar, this message translates to:
  /// **'حذف التصنيف'**
  String get deleteCategoryTitle;

  /// Delete category confirmation body.
  ///
  /// In ar, this message translates to:
  /// **'سيتم حذف «{name}» نهائيًا.'**
  String deleteCategoryConfirmMessage(String name);

  /// No description provided for @deleteCategoryHasChildrenTitle.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حذف التصنيف'**
  String get deleteCategoryHasChildrenTitle;

  /// No description provided for @deleteCategoryHasChildrenMessage.
  ///
  /// In ar, this message translates to:
  /// **'يحتوي هذا التصنيف على فروع. احذف أو انقل التصنيفات الفرعية أولًا.'**
  String get deleteCategoryHasChildrenMessage;

  /// No description provided for @quickAccessSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'الوصول السريع'**
  String get quickAccessSectionTitle;

  /// No description provided for @quickAccessSectionSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'تظهر كأزرار تصفية فوق البحث في نقطة البيع والمشتريات.'**
  String get quickAccessSectionSubtitle;

  /// No description provided for @quickAccessEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد تصنيفات سريعة بعد'**
  String get quickAccessEmptyTitle;

  /// No description provided for @quickAccessEmptyMessage.
  ///
  /// In ar, this message translates to:
  /// **'ثبّت تصنيفًا ليظهر كزر تصفية بنقرة واحدة. تشمل التصفية التصنيف وكل فروعه.'**
  String get quickAccessEmptyMessage;

  /// No description provided for @quickAccessReorderHint.
  ///
  /// In ar, this message translates to:
  /// **'اسحب الأزرار لإعادة ترتيبها'**
  String get quickAccessReorderHint;

  /// No description provided for @quickAccessLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل الوصول السريع.'**
  String get quickAccessLoadError;

  /// No description provided for @quickAccessUpdateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحديث الوصول السريع.'**
  String get quickAccessUpdateError;

  /// No description provided for @pinToQuickAccessTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تثبيت في الوصول السريع'**
  String get pinToQuickAccessTooltip;

  /// No description provided for @unpinFromQuickAccessTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إزالة من الوصول السريع'**
  String get unpinFromQuickAccessTooltip;

  /// Snackbar after pinning a category.
  ///
  /// In ar, this message translates to:
  /// **'{name} في الوصول السريع الآن'**
  String quickAccessAddedMessage(String name);

  /// Snackbar after unpinning a category.
  ///
  /// In ar, this message translates to:
  /// **'تمت إزالة {name} من الوصول السريع'**
  String quickAccessRemovedMessage(String name);

  /// No description provided for @quickAccessSwitchLabel.
  ///
  /// In ar, this message translates to:
  /// **'إظهار في الوصول السريع'**
  String get quickAccessSwitchLabel;

  /// No description provided for @quickAccessSwitchHelper.
  ///
  /// In ar, this message translates to:
  /// **'زر تصفية سريع في نقطة البيع والمشتريات'**
  String get quickAccessSwitchHelper;

  /// No description provided for @activeProductLabel.
  ///
  /// In ar, this message translates to:
  /// **'متاح للبيع'**
  String get activeProductLabel;

  /// No description provided for @applyButton.
  ///
  /// In ar, this message translates to:
  /// **'تطبيق'**
  String get applyButton;

  /// No description provided for @bulkSelectTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديد متعدد'**
  String get bulkSelectTooltip;

  /// No description provided for @bulkSelectedCount.
  ///
  /// In ar, this message translates to:
  /// **'{count} محدد'**
  String bulkSelectedCount(int count);

  /// No description provided for @bulkSelectAllAction.
  ///
  /// In ar, this message translates to:
  /// **'تحديد الكل'**
  String get bulkSelectAllAction;

  /// No description provided for @bulkClearSelectionAction.
  ///
  /// In ar, this message translates to:
  /// **'مسح التحديد'**
  String get bulkClearSelectionAction;

  /// No description provided for @bulkArchiveAction.
  ///
  /// In ar, this message translates to:
  /// **'أرشفة'**
  String get bulkArchiveAction;

  /// No description provided for @bulkRestoreAction.
  ///
  /// In ar, this message translates to:
  /// **'استعادة'**
  String get bulkRestoreAction;

  /// No description provided for @bulkRepriceAction.
  ///
  /// In ar, this message translates to:
  /// **'تعديل السعر'**
  String get bulkRepriceAction;

  /// No description provided for @bulkCategorizeAction.
  ///
  /// In ar, this message translates to:
  /// **'تصنيف'**
  String get bulkCategorizeAction;

  /// No description provided for @bulkFlagsAction.
  ///
  /// In ar, this message translates to:
  /// **'الخصائص'**
  String get bulkFlagsAction;

  /// No description provided for @bulkArchiveConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'أرشفة المنتجات المحددة؟'**
  String get bulkArchiveConfirmTitle;

  /// No description provided for @bulkArchiveConfirmMessage.
  ///
  /// In ar, this message translates to:
  /// **'سيتم أرشفة {count} منتج وإخفاؤها من القوائم ونقطة البيع. يمكن استعادتها لاحقًا.'**
  String bulkArchiveConfirmMessage(int count);

  /// No description provided for @bulkRestoreConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'استعادة المنتجات المحددة؟'**
  String get bulkRestoreConfirmTitle;

  /// No description provided for @bulkRestoreConfirmMessage.
  ///
  /// In ar, this message translates to:
  /// **'سيتم إعادة {count} منتج إلى القوائم.'**
  String bulkRestoreConfirmMessage(int count);

  /// No description provided for @bulkActionSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم تحديث {count} منتج'**
  String bulkActionSuccess(int count);

  /// No description provided for @bulkActionError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تنفيذ العملية، حاول مرة أخرى.'**
  String get bulkActionError;

  /// No description provided for @bulkActionNoChanges.
  ///
  /// In ar, this message translates to:
  /// **'لم يتغيّر أي منتج.'**
  String get bulkActionNoChanges;

  /// No description provided for @bulkRepriceTitle.
  ///
  /// In ar, this message translates to:
  /// **'تعديل أسعار المنتجات المحددة'**
  String get bulkRepriceTitle;

  /// No description provided for @bulkRepriceModeLabel.
  ///
  /// In ar, this message translates to:
  /// **'طريقة التعديل'**
  String get bulkRepriceModeLabel;

  /// No description provided for @bulkRepriceModeSet.
  ///
  /// In ar, this message translates to:
  /// **'تعيين سعر موحّد'**
  String get bulkRepriceModeSet;

  /// No description provided for @bulkRepriceModeIncreasePercent.
  ///
  /// In ar, this message translates to:
  /// **'زيادة بنسبة %'**
  String get bulkRepriceModeIncreasePercent;

  /// No description provided for @bulkRepriceModeDecreasePercent.
  ///
  /// In ar, this message translates to:
  /// **'خصم بنسبة %'**
  String get bulkRepriceModeDecreasePercent;

  /// No description provided for @bulkRepriceModeIncreaseAmount.
  ///
  /// In ar, this message translates to:
  /// **'زيادة بمبلغ'**
  String get bulkRepriceModeIncreaseAmount;

  /// No description provided for @bulkRepriceModeDecreaseAmount.
  ///
  /// In ar, this message translates to:
  /// **'خصم بمبلغ'**
  String get bulkRepriceModeDecreaseAmount;

  /// No description provided for @bulkRepricePercentLabel.
  ///
  /// In ar, this message translates to:
  /// **'النسبة'**
  String get bulkRepricePercentLabel;

  /// No description provided for @bulkRepriceAmountLabel.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ'**
  String get bulkRepriceAmountLabel;

  /// No description provided for @bulkRepriceValueRequired.
  ///
  /// In ar, this message translates to:
  /// **'أدخل قيمة صحيحة.'**
  String get bulkRepriceValueRequired;

  /// No description provided for @bulkCategorizeTitle.
  ///
  /// In ar, this message translates to:
  /// **'تصنيف المنتجات المحددة'**
  String get bulkCategorizeTitle;

  /// No description provided for @bulkCategorizeModeLabel.
  ///
  /// In ar, this message translates to:
  /// **'الإجراء'**
  String get bulkCategorizeModeLabel;

  /// No description provided for @bulkCategorizeModeAdd.
  ///
  /// In ar, this message translates to:
  /// **'إضافة تصنيفات'**
  String get bulkCategorizeModeAdd;

  /// No description provided for @bulkCategorizeModeReplace.
  ///
  /// In ar, this message translates to:
  /// **'استبدال التصنيفات'**
  String get bulkCategorizeModeReplace;

  /// No description provided for @bulkCategorizeModeRemove.
  ///
  /// In ar, this message translates to:
  /// **'إزالة تصنيفات'**
  String get bulkCategorizeModeRemove;

  /// No description provided for @bulkCategorizePickButton.
  ///
  /// In ar, this message translates to:
  /// **'اختيار التصنيفات'**
  String get bulkCategorizePickButton;

  /// No description provided for @bulkCategorizePickedCount.
  ///
  /// In ar, this message translates to:
  /// **'{count} تصنيف محدد'**
  String bulkCategorizePickedCount(int count);

  /// No description provided for @bulkFlagsTitle.
  ///
  /// In ar, this message translates to:
  /// **'تعديل خصائص المنتجات المحددة'**
  String get bulkFlagsTitle;

  /// No description provided for @bulkFlagNoChange.
  ///
  /// In ar, this message translates to:
  /// **'بدون تغيير'**
  String get bulkFlagNoChange;

  /// No description provided for @bulkFlagOn.
  ///
  /// In ar, this message translates to:
  /// **'تشغيل'**
  String get bulkFlagOn;

  /// No description provided for @bulkFlagOff.
  ///
  /// In ar, this message translates to:
  /// **'إيقاف'**
  String get bulkFlagOff;

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

  /// Status pill text for an archived (retired) product.
  ///
  /// In ar, this message translates to:
  /// **'مؤرشف'**
  String get archivedStatus;

  /// Toggle/chip label that switches the catalog list to show archived products.
  ///
  /// In ar, this message translates to:
  /// **'المؤرشفة'**
  String get archivedFilterLabel;

  /// No description provided for @viewArchivedProductsAction.
  ///
  /// In ar, this message translates to:
  /// **'عرض المنتجات المؤرشفة'**
  String get viewArchivedProductsAction;

  /// No description provided for @viewActiveProductsAction.
  ///
  /// In ar, this message translates to:
  /// **'عرض المنتجات النشطة'**
  String get viewActiveProductsAction;

  /// Label/tooltip for the action that archives a product.
  ///
  /// In ar, this message translates to:
  /// **'أرشفة'**
  String get archiveProductAction;

  /// Label/tooltip for the action that restores an archived product.
  ///
  /// In ar, this message translates to:
  /// **'استعادة'**
  String get restoreProductAction;

  /// Title of the confirmation dialog shown before archiving a product.
  ///
  /// In ar, this message translates to:
  /// **'أرشفة المنتج'**
  String get archiveProductConfirmTitle;

  /// Body of the confirmation dialog shown before archiving a product.
  ///
  /// In ar, this message translates to:
  /// **'سيتم إخفاء «{name}» من نقطة البيع والمشتريات وقائمة المنتجات، مع إمكانية استعادته لاحقًا.'**
  String archiveProductConfirmMessage(String name);

  /// Snackbar confirmation shown after a product is archived.
  ///
  /// In ar, this message translates to:
  /// **'تمت أرشفة المنتج'**
  String get archiveProductSuccess;

  /// Snackbar error shown when archiving a product fails.
  ///
  /// In ar, this message translates to:
  /// **'تعذرت أرشفة المنتج. حاول مرة أخرى.'**
  String get archiveProductError;

  /// Snackbar confirmation shown after an archived product is restored.
  ///
  /// In ar, this message translates to:
  /// **'تمت استعادة المنتج'**
  String get restoreProductSuccess;

  /// Snackbar error shown when restoring an archived product fails.
  ///
  /// In ar, this message translates to:
  /// **'تعذرت استعادة المنتج. حاول مرة أخرى.'**
  String get restoreProductError;

  /// No description provided for @productDetailsTitle.
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل المنتج'**
  String get productDetailsTitle;

  /// Placeholder shown in the catalog detail pane before a product is selected.
  ///
  /// In ar, this message translates to:
  /// **'اختر منتجًا من القائمة لعرض تفاصيله.'**
  String get catalogSelectProductPlaceholder;

  /// Placeholder shown in the invoices detail pane before an invoice is selected.
  ///
  /// In ar, this message translates to:
  /// **'اختر فاتورة من القائمة لعرض تفاصيلها.'**
  String get invoicesSelectInvoicePlaceholder;

  /// Placeholder shown in the contacts detail pane before a contact is selected.
  ///
  /// In ar, this message translates to:
  /// **'اختر جهة من القائمة لعرض تفاصيلها.'**
  String get contactsSelectContactPlaceholder;

  /// Placeholder shown in the discounts detail pane before a discount rule is selected.
  ///
  /// In ar, this message translates to:
  /// **'اختر قاعدة خصم من القائمة لعرض تفاصيلها.'**
  String get discountsSelectDiscountPlaceholder;

  /// Inline confirmation in the reports output panel showing the last successfully generated report.
  ///
  /// In ar, this message translates to:
  /// **'آخر إجراء ناجح: {action} — {report}'**
  String reportLastCompletedMessage(String action, String report);

  /// Button that re-runs the last successful report action.
  ///
  /// In ar, this message translates to:
  /// **'تشغيل مجددًا'**
  String get reportRunAgainButton;

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

  /// Title of the product-detail section listing products frequently bought in the same order as the one being viewed.
  ///
  /// In ar, this message translates to:
  /// **'يُشترى عادةً مع'**
  String get productBoughtTogetherTitle;

  /// Caption under the 'frequently bought together' section title.
  ///
  /// In ar, this message translates to:
  /// **'منتجات يضيفها العملاء عادةً إلى الطلب نفسه.'**
  String get productBoughtTogetherSubtitle;

  /// Caption on a bought-together product card showing how many paid orders pair it with the current product.
  ///
  /// In ar, this message translates to:
  /// **'في {count} طلبًا'**
  String productBoughtTogetherOrders(String count);

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

  /// Section title on the product/variant detail screens grouping cost insights and the change-prices action.
  ///
  /// In ar, this message translates to:
  /// **'التسعير والتكلفة'**
  String get productPricingAndCostTitle;

  /// No description provided for @productCostOverviewTitle.
  ///
  /// In ar, this message translates to:
  /// **'نظرة عامة على التكلفة'**
  String get productCostOverviewTitle;

  /// No description provided for @lowestCostLabel.
  ///
  /// In ar, this message translates to:
  /// **'أقل تكلفة'**
  String get lowestCostLabel;

  /// No description provided for @highestCostLabel.
  ///
  /// In ar, this message translates to:
  /// **'أعلى تكلفة'**
  String get highestCostLabel;

  /// No description provided for @lastCostLabel.
  ///
  /// In ar, this message translates to:
  /// **'آخر تكلفة'**
  String get lastCostLabel;

  /// No description provided for @averageCostLabel.
  ///
  /// In ar, this message translates to:
  /// **'متوسط التكلفة'**
  String get averageCostLabel;

  /// No description provided for @currentPriceLabel.
  ///
  /// In ar, this message translates to:
  /// **'السعر الحالي'**
  String get currentPriceLabel;

  /// No description provided for @noCostDataLabel.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد بيانات تكلفة بعد'**
  String get noCostDataLabel;

  /// No description provided for @changePricesButton.
  ///
  /// In ar, this message translates to:
  /// **'تغيير الأسعار'**
  String get changePricesButton;

  /// No description provided for @changePricesTitle.
  ///
  /// In ar, this message translates to:
  /// **'تغيير الأسعار'**
  String get changePricesTitle;

  /// No description provided for @changePricesSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'راجع تكلفة كل خيار وحدّد سعر البيع الجديد بثقة.'**
  String get changePricesSubtitle;

  /// No description provided for @changePricesNewPriceLabel.
  ///
  /// In ar, this message translates to:
  /// **'السعر الجديد'**
  String get changePricesNewPriceLabel;

  /// No description provided for @changePricesSaveButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ الأسعار'**
  String get changePricesSaveButton;

  /// No description provided for @changePricesSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم تحديث الأسعار.'**
  String get changePricesSuccess;

  /// No description provided for @changePricesError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحديث الأسعار. حاول مرة أخرى.'**
  String get changePricesError;

  /// No description provided for @changePricesLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل بيانات التكلفة.'**
  String get changePricesLoadError;

  /// No description provided for @changePricesNoVariants.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد خيارات لتسعيرها.'**
  String get changePricesNoVariants;

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
  String stockMovementQuantityValue(String quantity);

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

  /// No description provided for @barcodeLabelPrintNoBarcodeShort.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد باركود للطباعة'**
  String get barcodeLabelPrintNoBarcodeShort;

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

  /// No description provided for @barcodeLabelIncludePriceLabel.
  ///
  /// In ar, this message translates to:
  /// **'طباعة السعر'**
  String get barcodeLabelIncludePriceLabel;

  /// No description provided for @barcodeLabelIncludePriceHint.
  ///
  /// In ar, this message translates to:
  /// **'إظهار سعر البيع على الملصق.'**
  String get barcodeLabelIncludePriceHint;

  /// No description provided for @barcodeLabelIncludeExpiryLabel.
  ///
  /// In ar, this message translates to:
  /// **'طباعة تاريخ الانتهاء'**
  String get barcodeLabelIncludeExpiryLabel;

  /// No description provided for @barcodeLabelIncludeExpiryHint.
  ///
  /// In ar, this message translates to:
  /// **'إضافة تاريخ انتهاء الدفعة على الملصق.'**
  String get barcodeLabelIncludeExpiryHint;

  /// No description provided for @barcodeLabelExpiryDateLabel.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الانتهاء'**
  String get barcodeLabelExpiryDateLabel;

  /// No description provided for @barcodeLabelExpiryDatePickerTooltip.
  ///
  /// In ar, this message translates to:
  /// **'اختيار تاريخ الانتهاء'**
  String get barcodeLabelExpiryDatePickerTooltip;

  /// No description provided for @barcodeLabelExpiryDateRequired.
  ///
  /// In ar, this message translates to:
  /// **'اختر تاريخ الانتهاء أو أوقف طباعته.'**
  String get barcodeLabelExpiryDateRequired;

  /// No description provided for @barcodeLabelPreviewTitle.
  ///
  /// In ar, this message translates to:
  /// **'معاينة الملصق'**
  String get barcodeLabelPreviewTitle;

  /// Preview line showing the printed label price.
  ///
  /// In ar, this message translates to:
  /// **'السعر {price}'**
  String barcodeLabelPreviewPrice(String price);

  /// Preview line showing the printed label expiry date.
  ///
  /// In ar, this message translates to:
  /// **'الانتهاء {date}'**
  String barcodeLabelPreviewExpiry(String date);

  /// No description provided for @barcodeLabelPrintProductTooltip.
  ///
  /// In ar, this message translates to:
  /// **'طباعة ملصقات المنتج'**
  String get barcodeLabelPrintProductTooltip;

  /// No description provided for @barcodeLabelPrintVariantTooltip.
  ///
  /// In ar, this message translates to:
  /// **'طباعة ملصقات الخيار'**
  String get barcodeLabelPrintVariantTooltip;

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
  String posVariantPickerStock(String quantity);

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

  /// No description provided for @saleDraftSettingsActionTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات الفاتورة'**
  String get saleDraftSettingsActionTooltip;

  /// No description provided for @saleDraftSettingsDialogTitle.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات الفاتورة'**
  String get saleDraftSettingsDialogTitle;

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

  /// No description provided for @cartLineNoteAdd.
  ///
  /// In ar, this message translates to:
  /// **'إضافة ملاحظة للمطبخ'**
  String get cartLineNoteAdd;

  /// No description provided for @cartLineNoteEdit.
  ///
  /// In ar, this message translates to:
  /// **'تعديل ملاحظة المطبخ'**
  String get cartLineNoteEdit;

  /// No description provided for @cartLineNoteDialogTitle.
  ///
  /// In ar, this message translates to:
  /// **'ملاحظة للمطبخ'**
  String get cartLineNoteDialogTitle;

  /// No description provided for @cartLineNoteHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: بدون بصل'**
  String get cartLineNoteHint;

  /// No description provided for @modifierGroupRequiredLabel.
  ///
  /// In ar, this message translates to:
  /// **'مطلوب'**
  String get modifierGroupRequiredLabel;

  /// No description provided for @modifierGroupOptionalLabel.
  ///
  /// In ar, this message translates to:
  /// **'اختياري'**
  String get modifierGroupOptionalLabel;

  /// No description provided for @modifierGroupChooseUpToLabel.
  ///
  /// In ar, this message translates to:
  /// **'اختر حتى {count}'**
  String modifierGroupChooseUpToLabel(int count);

  /// No description provided for @modifierSheetAddButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة — {price}'**
  String modifierSheetAddButton(String price);

  /// No description provided for @modifierSheetEditTitle.
  ///
  /// In ar, this message translates to:
  /// **'تعديل الخيارات'**
  String get modifierSheetEditTitle;

  /// No description provided for @modifierGroupsSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'مجموعات الإضافات'**
  String get modifierGroupsSectionTitle;

  /// No description provided for @modifierGroupsSectionSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'خيارات تُضاف للأصناف عند البيع (الحليب، الإضافات...).'**
  String get modifierGroupsSectionSubtitle;

  /// No description provided for @modifierGroupAddButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة مجموعة'**
  String get modifierGroupAddButton;

  /// No description provided for @modifierGroupsEmptyMessage.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مجموعات إضافات بعد.'**
  String get modifierGroupsEmptyMessage;

  /// No description provided for @modifierGroupsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل مجموعات الإضافات.'**
  String get modifierGroupsLoadError;

  /// No description provided for @modifierGroupNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم المجموعة'**
  String get modifierGroupNameLabel;

  /// No description provided for @modifierGroupSingleSelectLabel.
  ///
  /// In ar, this message translates to:
  /// **'اختيار واحد فقط'**
  String get modifierGroupSingleSelectLabel;

  /// No description provided for @modifierGroupRequiredToggleLabel.
  ///
  /// In ar, this message translates to:
  /// **'إلزامية'**
  String get modifierGroupRequiredToggleLabel;

  /// No description provided for @modifierGroupOptionsLabel.
  ///
  /// In ar, this message translates to:
  /// **'الخيارات'**
  String get modifierGroupOptionsLabel;

  /// No description provided for @modifierOptionAddButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة خيار'**
  String get modifierOptionAddButton;

  /// No description provided for @modifierOptionNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'الاسم'**
  String get modifierOptionNameLabel;

  /// No description provided for @modifierOptionPriceLabel.
  ///
  /// In ar, this message translates to:
  /// **'السعر الإضافي'**
  String get modifierOptionPriceLabel;

  /// No description provided for @modifierOptionMaxQtyLabel.
  ///
  /// In ar, this message translates to:
  /// **'أقصى كمية'**
  String get modifierOptionMaxQtyLabel;

  /// No description provided for @modifierOptionDefaultLabel.
  ///
  /// In ar, this message translates to:
  /// **'افتراضي'**
  String get modifierOptionDefaultLabel;

  /// No description provided for @modifierGroupSummary.
  ///
  /// In ar, this message translates to:
  /// **'{selection} · {count} خيار'**
  String modifierGroupSummary(String selection, int count);

  /// No description provided for @modifierGroupDeleteTitle.
  ///
  /// In ar, this message translates to:
  /// **'حذف المجموعة؟'**
  String get modifierGroupDeleteTitle;

  /// No description provided for @modifierGroupDeleteMessage.
  ///
  /// In ar, this message translates to:
  /// **'ستُزال من كل الأصناف المرتبطة بها.'**
  String get modifierGroupDeleteMessage;

  /// No description provided for @modifierGroupSaveError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حفظ المجموعة.'**
  String get modifierGroupSaveError;

  /// No description provided for @modifierGroupDeleteError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حذف المجموعة.'**
  String get modifierGroupDeleteError;

  /// No description provided for @productModifierGroupsLabel.
  ///
  /// In ar, this message translates to:
  /// **'مجموعات الإضافات'**
  String get productModifierGroupsLabel;

  /// No description provided for @emptyCart.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عناصر في السلة'**
  String get emptyCart;

  /// No description provided for @emptyCartMessage.
  ///
  /// In ar, this message translates to:
  /// **'ابحث عن منتج أو امسح الباركود لبدء البيع'**
  String get emptyCartMessage;

  /// Live indicator while typing a quantity for the focused cart line.
  ///
  /// In ar, this message translates to:
  /// **'{productName} — الكمية: {quantity}'**
  String cartQuantityPendingLabel(String productName, String quantity);

  /// No description provided for @cartQuantityPendingHint.
  ///
  /// In ar, this message translates to:
  /// **'Enter للتأكيد'**
  String get cartQuantityPendingHint;

  /// No description provided for @openCartSheetButton.
  ///
  /// In ar, this message translates to:
  /// **'مراجعة السلة'**
  String get openCartSheetButton;

  /// No description provided for @openSaleSessionsTitle.
  ///
  /// In ar, this message translates to:
  /// **'الفواتير المفتوحة'**
  String get openSaleSessionsTitle;

  /// No description provided for @newSaleSessionButton.
  ///
  /// In ar, this message translates to:
  /// **'فاتورة جديدة'**
  String get newSaleSessionButton;

  /// No description provided for @newSaleSessionTooltip.
  ///
  /// In ar, this message translates to:
  /// **'بدء فاتورة جديدة'**
  String get newSaleSessionTooltip;

  /// No description provided for @saleSessionSwitcherTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إدارة الفواتير المفتوحة'**
  String get saleSessionSwitcherTooltip;

  /// No description provided for @activeSaleSessionStatusLabel.
  ///
  /// In ar, this message translates to:
  /// **'الحالية'**
  String get activeSaleSessionStatusLabel;

  /// No description provided for @parkedSaleSessionStatusLabel.
  ///
  /// In ar, this message translates to:
  /// **'معلقة'**
  String get parkedSaleSessionStatusLabel;

  /// Temporary POS sale session title shown while multiple invoices are open.
  ///
  /// In ar, this message translates to:
  /// **'فاتورة {number}'**
  String saleSessionTitle(int number);

  /// Tooltip for switching to another open POS sale session.
  ///
  /// In ar, this message translates to:
  /// **'فتح {title}'**
  String saleSessionSwitchTooltip(String title);

  /// No description provided for @discardSaleSessionTooltip.
  ///
  /// In ar, this message translates to:
  /// **'حذف الفاتورة المعلقة'**
  String get discardSaleSessionTooltip;

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

  /// No description provided for @purchasePayablesTitle.
  ///
  /// In ar, this message translates to:
  /// **'مستحقات الموردين'**
  String get purchasePayablesTitle;

  /// Count of received-but-unpaid purchase orders shown under the supplier-dues card.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{فاتورة واحدة بانتظار السداد} =2{فاتورتان بانتظار السداد} other{{count} فواتير بانتظار السداد}}'**
  String purchasePayablesCount(int count);

  /// No description provided for @purchasePayablesMore.
  ///
  /// In ar, this message translates to:
  /// **'والمزيد'**
  String get purchasePayablesMore;

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

  /// No description provided for @purchaseOrderActionsSheetTitle.
  ///
  /// In ar, this message translates to:
  /// **'إجراءات أمر الشراء'**
  String get purchaseOrderActionsSheetTitle;

  /// No description provided for @purchaseOrderMoreActionsLabel.
  ///
  /// In ar, this message translates to:
  /// **'إجراءات أخرى'**
  String get purchaseOrderMoreActionsLabel;

  /// No description provided for @purchaseOrderDocumentMenuTooltip.
  ///
  /// In ar, this message translates to:
  /// **'طباعة ومشاركة'**
  String get purchaseOrderDocumentMenuTooltip;

  /// No description provided for @purchaseOrderSubmitDescription.
  ///
  /// In ar, this message translates to:
  /// **'إرسال الأمر إلى المورد لبدء التوريد.'**
  String get purchaseOrderSubmitDescription;

  /// No description provided for @purchaseOrderReceiveDescription.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الكميات الواردة وإضافتها إلى المخزون.'**
  String get purchaseOrderReceiveDescription;

  /// No description provided for @purchaseOrderRecordPaymentDescription.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل دفعة للمورد مقابل هذا الأمر.'**
  String get purchaseOrderRecordPaymentDescription;

  /// No description provided for @purchaseOrderReturnDescription.
  ///
  /// In ar, this message translates to:
  /// **'إرجاع أصناف مستلمة إلى المورد.'**
  String get purchaseOrderReturnDescription;

  /// No description provided for @purchaseOrderRefundDescription.
  ///
  /// In ar, this message translates to:
  /// **'استرداد قيمة أصناف من المورد.'**
  String get purchaseOrderRefundDescription;

  /// No description provided for @purchaseOrderExchangeDescription.
  ///
  /// In ar, this message translates to:
  /// **'استبدال أصناف مستلمة بأخرى.'**
  String get purchaseOrderExchangeDescription;

  /// No description provided for @purchaseOrderCancelActionDescription.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء أمر الشراء نهائيًا.'**
  String get purchaseOrderCancelActionDescription;

  /// No description provided for @purchaseOrderCalloutDraftTitle.
  ///
  /// In ar, this message translates to:
  /// **'جاهز للإرسال'**
  String get purchaseOrderCalloutDraftTitle;

  /// No description provided for @purchaseOrderCalloutDraftMessage.
  ///
  /// In ar, this message translates to:
  /// **'أرسل الأمر إلى المورد عندما تكون جاهزًا.'**
  String get purchaseOrderCalloutDraftMessage;

  /// No description provided for @purchaseOrderCalloutAwaitingTitle.
  ///
  /// In ar, this message translates to:
  /// **'بانتظار الاستلام'**
  String get purchaseOrderCalloutAwaitingTitle;

  /// No description provided for @purchaseOrderCalloutAwaitingMessage.
  ///
  /// In ar, this message translates to:
  /// **'سجّل الكميات عند وصول البضاعة من المورد.'**
  String get purchaseOrderCalloutAwaitingMessage;

  /// No description provided for @purchaseOrderCalloutPartialTitle.
  ///
  /// In ar, this message translates to:
  /// **'مستلم جزئيًا'**
  String get purchaseOrderCalloutPartialTitle;

  /// No description provided for @purchaseOrderCalloutPartialMessage.
  ///
  /// In ar, this message translates to:
  /// **'ما زالت بعض الأصناف بانتظار الاستلام.'**
  String get purchaseOrderCalloutPartialMessage;

  /// No description provided for @purchaseOrderCalloutReceivedDueTitle.
  ///
  /// In ar, this message translates to:
  /// **'تم الاستلام بالكامل'**
  String get purchaseOrderCalloutReceivedDueTitle;

  /// No description provided for @purchaseOrderCalloutCompleteTitle.
  ///
  /// In ar, this message translates to:
  /// **'مكتمل'**
  String get purchaseOrderCalloutCompleteTitle;

  /// No description provided for @purchaseOrderCalloutCompleteMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم الاستلام والسداد بالكامل.'**
  String get purchaseOrderCalloutCompleteMessage;

  /// No description provided for @purchaseOrderCalloutCancelledTitle.
  ///
  /// In ar, this message translates to:
  /// **'أمر ملغى'**
  String get purchaseOrderCalloutCancelledTitle;

  /// No description provided for @purchaseOrderCalloutCancelledMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم إلغاء هذا الأمر ولا يمكن تعديله.'**
  String get purchaseOrderCalloutCancelledMessage;

  /// No description provided for @purchaseOrderReceivedProgressLabel.
  ///
  /// In ar, this message translates to:
  /// **'المستلم'**
  String get purchaseOrderReceivedProgressLabel;

  /// Received-vs-ordered quantity progress on a purchase order, e.g. 7 of 10.
  ///
  /// In ar, this message translates to:
  /// **'{received} من {ordered}'**
  String purchaseOrderReceivedProgressValue(String received, String ordered);

  /// No description provided for @purchaseOrderPrintAction.
  ///
  /// In ar, this message translates to:
  /// **'طباعة'**
  String get purchaseOrderPrintAction;

  /// No description provided for @purchaseOrderPrintInProgressAction.
  ///
  /// In ar, this message translates to:
  /// **'جار الطباعة...'**
  String get purchaseOrderPrintInProgressAction;

  /// No description provided for @purchaseOrderShareAction.
  ///
  /// In ar, this message translates to:
  /// **'مشاركة PDF'**
  String get purchaseOrderShareAction;

  /// No description provided for @purchaseOrderShareInProgressAction.
  ///
  /// In ar, this message translates to:
  /// **'جار تجهيز PDF...'**
  String get purchaseOrderShareInProgressAction;

  /// No description provided for @purchaseOrderRowActionsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إجراءات أمر الشراء'**
  String get purchaseOrderRowActionsTooltip;

  /// Message shown after a purchase order is sent to the printer.
  ///
  /// In ar, this message translates to:
  /// **'تم إرسال أمر الشراء رقم {orderNumber} للطابعة.'**
  String purchaseOrderPrintSuccess(String orderNumber);

  /// No description provided for @purchaseOrderPrintError.
  ///
  /// In ar, this message translates to:
  /// **'تعذرت طباعة أمر الشراء. راجع الطابعة وحاول مرة أخرى.'**
  String get purchaseOrderPrintError;

  /// Message shown after a purchase order PDF is shared or saved.
  ///
  /// In ar, this message translates to:
  /// **'تم تجهيز ملف PDF لأمر الشراء رقم {orderNumber}.'**
  String purchaseOrderShareSuccess(String orderNumber);

  /// No description provided for @purchaseOrderShareError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تجهيز ملف PDF لأمر الشراء.'**
  String get purchaseOrderShareError;

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

  /// No description provided for @supplierPaymentPrintProofLabel.
  ///
  /// In ar, this message translates to:
  /// **'طباعة سند صرف'**
  String get supplierPaymentPrintProofLabel;

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
  String purchaseAdjustmentLineRemaining(String remaining, String quantity);

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
      String product, String quantity, String unitCost);

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
  String purchaseReceiveExpectedValue(String quantity);

  /// Already received quantity in the receiving dialog.
  ///
  /// In ar, this message translates to:
  /// **'استلم سابقًا {quantity}'**
  String purchaseReceiveAlreadyValue(String quantity);

  /// Open/backordered quantity in the receiving dialog.
  ///
  /// In ar, this message translates to:
  /// **'المفتوح {quantity}'**
  String purchaseReceiveOpenValue(String quantity);

  /// Open or backordered quantity after receiving dialog values are applied.
  ///
  /// In ar, this message translates to:
  /// **'المفتوح بعد الإدخال {quantity}'**
  String purchaseReceiveOpenAfterValue(String quantity);

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
  String purchaseOrderLineQuantity(String quantity);

  /// Total received quantity shown on purchase order lines and receipts.
  ///
  /// In ar, this message translates to:
  /// **'مستلم {quantity}'**
  String purchaseLineReceivedQuantity(String quantity);

  /// Open or backordered quantity shown on purchase order lines.
  ///
  /// In ar, this message translates to:
  /// **'مفتوح/متأخر {quantity}'**
  String purchaseLineOpenQuantity(String quantity);

  /// Damaged purchase quantity.
  ///
  /// In ar, this message translates to:
  /// **'تالف {quantity}'**
  String purchaseLineDamagedQuantity(String quantity);

  /// Rejected purchase quantity.
  ///
  /// In ar, this message translates to:
  /// **'مرفوض {quantity}'**
  String purchaseLineRejectedQuantity(String quantity);

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

  /// No description provided for @purchaseDraftSettingsActionTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات مسودة الشراء'**
  String get purchaseDraftSettingsActionTooltip;

  /// No description provided for @purchaseDraftSettingsDialogTitle.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات مسودة الشراء'**
  String get purchaseDraftSettingsDialogTitle;

  /// No description provided for @purchaseSupplierActionTooltip.
  ///
  /// In ar, this message translates to:
  /// **'اختيار المورد'**
  String get purchaseSupplierActionTooltip;

  /// No description provided for @purchaseInvoiceDetailsActionTooltip.
  ///
  /// In ar, this message translates to:
  /// **'بيانات فاتورة المورد'**
  String get purchaseInvoiceDetailsActionTooltip;

  /// No description provided for @purchaseInvoiceDetailsDialogTitle.
  ///
  /// In ar, this message translates to:
  /// **'بيانات فاتورة المورد'**
  String get purchaseInvoiceDetailsDialogTitle;

  /// No description provided for @purchaseLandedCostActionTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تكاليف الوصول'**
  String get purchaseLandedCostActionTooltip;

  /// No description provided for @purchaseDiscountActionTooltip.
  ///
  /// In ar, this message translates to:
  /// **'كود خصم المورد'**
  String get purchaseDiscountActionTooltip;

  /// No description provided for @emptyPurchaseDraft.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عناصر في مسودة الشراء'**
  String get emptyPurchaseDraft;

  /// No description provided for @emptyPurchaseDraftMessage.
  ///
  /// In ar, this message translates to:
  /// **'أضف منتجات من الكتالوج لبناء أمر الشراء'**
  String get emptyPurchaseDraftMessage;

  /// No description provided for @purchaseLineCostLabel.
  ///
  /// In ar, this message translates to:
  /// **'التكلفة'**
  String get purchaseLineCostLabel;

  /// No description provided for @purchaseLineUnitLabel.
  ///
  /// In ar, this message translates to:
  /// **'وحدة الشراء'**
  String get purchaseLineUnitLabel;

  /// No description provided for @purchaseLineBaseEquivalent.
  ///
  /// In ar, this message translates to:
  /// **'= {quantity} {unit}'**
  String purchaseLineBaseEquivalent(String quantity, String unit);

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

  /// App-bar title when reopening a draft purchase order to edit it.
  ///
  /// In ar, this message translates to:
  /// **'تعديل أمر الشراء'**
  String get editPurchaseOrderTitle;

  /// Action label to edit a draft purchase order.
  ///
  /// In ar, this message translates to:
  /// **'تعديل'**
  String get editPurchaseOrderAction;

  /// Description for the edit action on a draft purchase order.
  ///
  /// In ar, this message translates to:
  /// **'فتح المسودة في شاشة الشراء لتعديل أصنافها قبل الإرسال.'**
  String get purchaseOrderEditDescription;

  /// Primary button label that saves edits to a draft purchase order without submitting it.
  ///
  /// In ar, this message translates to:
  /// **'حفظ التعديلات'**
  String get savePurchaseDraftButton;

  /// Primary button label while a draft purchase order is being saved.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ الحفظ...'**
  String get purchaseDraftSaveInProgressButton;

  /// Message shown after a draft purchase order's edits are saved.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ مسودة أمر الشراء رقم {draftNumber}.'**
  String purchaseDraftSaveSuccess(String draftNumber);

  /// Message shown when saving edits to a draft purchase order fails.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ المسودة. راجع العناصر ورقم فاتورة المورد وحاول مرة أخرى.'**
  String get purchaseDraftSaveError;

  /// Error shown when a draft purchase order cannot be loaded for editing.
  ///
  /// In ar, this message translates to:
  /// **'تعذر فتح أمر الشراء للتعديل.'**
  String get editPurchaseOrderLoadError;

  /// Error shown when trying to edit a purchase order that already has a receipt or payment recorded.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكن التعديل بعد استلام بضاعة أو تسجيل دفعة على أمر الشراء.'**
  String get editPurchaseOrderNotEditableError;

  /// Warning shown when some lines of an edited draft could not be resolved from the catalog.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل {count} من الأصناف لأنها لم تعد متوفرة في الكتالوج.'**
  String purchaseEditUnresolvedLines(int count);

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

  /// No description provided for @paymentCardsTitle.
  ///
  /// In ar, this message translates to:
  /// **'بطاقات الدفع'**
  String get paymentCardsTitle;

  /// No description provided for @paymentCardsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل بطاقات الدفع.'**
  String get paymentCardsLoadError;

  /// No description provided for @paymentCardsEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد بطاقات مرتبطة بهذا العميل.'**
  String get paymentCardsEmpty;

  /// Subtitle showing when a payment card was last used.
  ///
  /// In ar, this message translates to:
  /// **'آخر استخدام: {date}'**
  String paymentCardLastSeenValue(String date);

  /// Number of payment cards attached to a customer.
  ///
  /// In ar, this message translates to:
  /// **'{count} بطاقة'**
  String paymentCardCountValue(int count);

  /// No description provided for @reassignCardTooltip.
  ///
  /// In ar, this message translates to:
  /// **'نقل البطاقة إلى عميل آخر'**
  String get reassignCardTooltip;

  /// No description provided for @reassignCardTitle.
  ///
  /// In ar, this message translates to:
  /// **'نقل البطاقة'**
  String get reassignCardTitle;

  /// No description provided for @cardReassignedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم نقل البطاقة.'**
  String get cardReassignedMessage;

  /// No description provided for @cardReassignFailedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر نقل البطاقة.'**
  String get cardReassignFailedMessage;

  /// No description provided for @unclaimedCardCustomerCalloutTitle.
  ///
  /// In ar, this message translates to:
  /// **'عميل بطاقة غير مُسمّى'**
  String get unclaimedCardCustomerCalloutTitle;

  /// No description provided for @unclaimedCardCustomerCalloutBody.
  ///
  /// In ar, this message translates to:
  /// **'أُنشئ هذا العميل تلقائيًا من بطاقة دفع. ادمجه مع عميل موجود أو أعطه اسمًا ليصبح عميلًا مستقلًا.'**
  String get unclaimedCardCustomerCalloutBody;

  /// No description provided for @mergeIntoCustomerButton.
  ///
  /// In ar, this message translates to:
  /// **'دمج مع عميل'**
  String get mergeIntoCustomerButton;

  /// No description provided for @mergeCustomerSuccessMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم دمج العميل.'**
  String get mergeCustomerSuccessMessage;

  /// No description provided for @mergeCustomerFailedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر دمج العميل.'**
  String get mergeCustomerFailedMessage;

  /// No description provided for @nameCustomerButton.
  ///
  /// In ar, this message translates to:
  /// **'تسمية العميل'**
  String get nameCustomerButton;

  /// No description provided for @nameCustomerTitle.
  ///
  /// In ar, this message translates to:
  /// **'تسمية العميل'**
  String get nameCustomerTitle;

  /// No description provided for @customerClaimedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ العميل.'**
  String get customerClaimedMessage;

  /// No description provided for @customerClaimFailedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حفظ العميل.'**
  String get customerClaimFailedMessage;

  /// No description provided for @unclaimedCardsFilterLabel.
  ///
  /// In ar, this message translates to:
  /// **'بطاقات غير مُسمّاة'**
  String get unclaimedCardsFilterLabel;

  /// No description provided for @allCustomersFilterLabel.
  ///
  /// In ar, this message translates to:
  /// **'كل العملاء'**
  String get allCustomersFilterLabel;

  /// No description provided for @customerAutoCreatedBadge.
  ///
  /// In ar, this message translates to:
  /// **'بطاقة غير مُسمّاة'**
  String get customerAutoCreatedBadge;

  /// Label for the customer RFM rank filter on the contacts list.
  ///
  /// In ar, this message translates to:
  /// **'التصنيف'**
  String get customerRankFilterTitle;

  /// Filter chip selecting customers of any RFM rank.
  ///
  /// In ar, this message translates to:
  /// **'كل التصنيفات'**
  String get allRanksFilterLabel;

  /// RFM rank: recent, frequent, high-spending customers.
  ///
  /// In ar, this message translates to:
  /// **'مميّز'**
  String get customerRankChampion;

  /// RFM rank: loyal customers.
  ///
  /// In ar, this message translates to:
  /// **'وفيّ'**
  String get customerRankLoyal;

  /// RFM rank: customers who could become loyal.
  ///
  /// In ar, this message translates to:
  /// **'وفيّ محتمل'**
  String get customerRankPotentialLoyalist;

  /// RFM rank: new customers.
  ///
  /// In ar, this message translates to:
  /// **'جديد'**
  String get customerRankNew;

  /// RFM rank: promising customers.
  ///
  /// In ar, this message translates to:
  /// **'واعد'**
  String get customerRankPromising;

  /// RFM rank: customers who need attention.
  ///
  /// In ar, this message translates to:
  /// **'يحتاج اهتمامًا'**
  String get customerRankNeedsAttention;

  /// RFM rank: customers at risk of churning.
  ///
  /// In ar, this message translates to:
  /// **'معرّض للفقدان'**
  String get customerRankAtRisk;

  /// RFM rank: high-value customers who have gone quiet.
  ///
  /// In ar, this message translates to:
  /// **'لا يجب خسارته'**
  String get customerRankCantLose;

  /// RFM rank: hibernating customers.
  ///
  /// In ar, this message translates to:
  /// **'خامل'**
  String get customerRankHibernating;

  /// RFM rank: lost customers.
  ///
  /// In ar, this message translates to:
  /// **'مفقود'**
  String get customerRankLost;

  /// RFM rank: customers with no recognized purchase yet.
  ///
  /// In ar, this message translates to:
  /// **'بدون مشتريات'**
  String get customerRankInactive;

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

  /// No description provided for @customerOutstandingBalanceLabel.
  ///
  /// In ar, this message translates to:
  /// **'الرصيد المستحق'**
  String get customerOutstandingBalanceLabel;

  /// No description provided for @recordCustomerPaymentButton.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل دفعة'**
  String get recordCustomerPaymentButton;

  /// Title of the outstanding-balance callout on the customer details screen.
  ///
  /// In ar, this message translates to:
  /// **'على هذا العميل رصيد مستحق قدره {amount}.'**
  String customerOutstandingBalanceCalloutTitle(String amount);

  /// No description provided for @customerOutstandingBalanceCalloutBody.
  ///
  /// In ar, this message translates to:
  /// **'تُوزَّع الدفعة تلقائيًا على أقدم الفواتير الآجلة أولًا.'**
  String get customerOutstandingBalanceCalloutBody;

  /// No description provided for @customerAccountPaymentTitle.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل دفعة على الحساب'**
  String get customerAccountPaymentTitle;

  /// No description provided for @customerAccountPaymentAmountLabel.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ'**
  String get customerAccountPaymentAmountLabel;

  /// Shows the customer's outstanding balance inside the account-payment dialog.
  ///
  /// In ar, this message translates to:
  /// **'الرصيد المستحق: {amount}'**
  String customerAccountPaymentOutstandingValue(String amount);

  /// No description provided for @customerAccountPaymentAmountError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل مبلغًا أكبر من صفر ولا يتجاوز الرصيد المستحق.'**
  String get customerAccountPaymentAmountError;

  /// No description provided for @customerAccountPaymentSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل الدفعة على حساب العميل.'**
  String get customerAccountPaymentSuccess;

  /// No description provided for @customerAccountPaymentError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تسجيل الدفعة. حاول مرة أخرى.'**
  String get customerAccountPaymentError;

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

  /// No description provided for @shareInvoiceAfterPaymentLabel.
  ///
  /// In ar, this message translates to:
  /// **'مشاركة PDF بعد الدفع'**
  String get shareInvoiceAfterPaymentLabel;

  /// No description provided for @shareInvoiceToggleSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'سيتم فتح ورقة المشاركة على الجوال أو نافذة الحفظ على سطح المكتب.'**
  String get shareInvoiceToggleSubtitle;

  /// No description provided for @shareInvoiceToggleTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تبديل مشاركة ملف PDF للفاتورة'**
  String get shareInvoiceToggleTooltip;

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

  /// No description provided for @saleTypeLabel.
  ///
  /// In ar, this message translates to:
  /// **'نوع البيع'**
  String get saleTypeLabel;

  /// No description provided for @saleTypeStandardLabel.
  ///
  /// In ar, this message translates to:
  /// **'عادي'**
  String get saleTypeStandardLabel;

  /// No description provided for @saleTypeCreditLabel.
  ///
  /// In ar, this message translates to:
  /// **'آجل'**
  String get saleTypeCreditLabel;

  /// No description provided for @saleTypeQuotationLabel.
  ///
  /// In ar, this message translates to:
  /// **'عرض سعر'**
  String get saleTypeQuotationLabel;

  /// No description provided for @saleCustomerRequiredBanner.
  ///
  /// In ar, this message translates to:
  /// **'اختر عميلًا قبل إتمام بيع آجل أو عرض سعر.'**
  String get saleCustomerRequiredBanner;

  /// No description provided for @creditBalanceDueLabel.
  ///
  /// In ar, this message translates to:
  /// **'المتبقّي على العميل'**
  String get creditBalanceDueLabel;

  /// No description provided for @creditDownPaymentTooHighError.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ المدفوع أكبر من الإجمالي.'**
  String get creditDownPaymentTooHighError;

  /// No description provided for @creditFullyOnAccountHint.
  ///
  /// In ar, this message translates to:
  /// **'كامل المبلغ سيُسجَّل دَينًا على العميل. أضِف دفعة مقدّمة إن وُجدت.'**
  String get creditFullyOnAccountHint;

  /// No description provided for @creditDownPaymentHint.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ المُدخَل دفعة مقدّمة؛ والباقي يُسجَّل دَينًا على العميل.'**
  String get creditDownPaymentHint;

  /// No description provided for @creditDueDateLabel.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الاستحقاق'**
  String get creditDueDateLabel;

  /// No description provided for @creditDueDateUnset.
  ///
  /// In ar, this message translates to:
  /// **'اختر تاريخًا (اختياري)'**
  String get creditDueDateUnset;

  /// No description provided for @creditDueDateClearTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إزالة تاريخ الاستحقاق'**
  String get creditDueDateClearTooltip;

  /// No description provided for @creditDueDatePresetWeek.
  ///
  /// In ar, this message translates to:
  /// **'بعد أسبوع'**
  String get creditDueDatePresetWeek;

  /// No description provided for @creditDueDatePresetTwoWeeks.
  ///
  /// In ar, this message translates to:
  /// **'بعد أسبوعين'**
  String get creditDueDatePresetTwoWeeks;

  /// No description provided for @creditDueDatePresetMonth.
  ///
  /// In ar, this message translates to:
  /// **'بعد شهر'**
  String get creditDueDatePresetMonth;

  /// No description provided for @creditDownPaymentTenderTitle.
  ///
  /// In ar, this message translates to:
  /// **'دفعة مقدّمة'**
  String get creditDownPaymentTenderTitle;

  /// No description provided for @addDownPaymentButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة دفعة مقدّمة'**
  String get addDownPaymentButton;

  /// No description provided for @printDownPaymentProofLabel.
  ///
  /// In ar, this message translates to:
  /// **'طباعة سند قبض'**
  String get printDownPaymentProofLabel;

  /// No description provided for @printDownPaymentProofSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'طباعة إيصال بالدفعة المقدّمة على البيع الآجل.'**
  String get printDownPaymentProofSubtitle;

  /// No description provided for @quotationTotalLabel.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي العرض'**
  String get quotationTotalLabel;

  /// No description provided for @quotationReserveStockLabel.
  ///
  /// In ar, this message translates to:
  /// **'حجز الكمية'**
  String get quotationReserveStockLabel;

  /// No description provided for @quotationReserveStockSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'حجز الكميات المعروضة دون خصمها من المخزون حتى انتهاء صلاحية العرض.'**
  String get quotationReserveStockSubtitle;

  /// No description provided for @quotationValidUntilLabel.
  ///
  /// In ar, this message translates to:
  /// **'صالح حتى'**
  String get quotationValidUntilLabel;

  /// No description provided for @quotationValidUntilUnset.
  ///
  /// In ar, this message translates to:
  /// **'اختر تاريخًا'**
  String get quotationValidUntilUnset;

  /// No description provided for @quotationNoPaymentHint.
  ///
  /// In ar, this message translates to:
  /// **'عرض السعر لا يتضمّن أي دفع ولا يخصم من المخزون.'**
  String get quotationNoPaymentHint;

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

  /// No description provided for @invoiceShareSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم تجهيز ملف PDF للفاتورة.'**
  String get invoiceShareSuccess;

  /// No description provided for @invoiceShareError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تجهيز ملف PDF للفاتورة.'**
  String get invoiceShareError;

  /// No description provided for @publicInvoiceDialogTitle.
  ///
  /// In ar, this message translates to:
  /// **'فاتورة العميل عبر الإنترنت'**
  String get publicInvoiceDialogTitle;

  /// No description provided for @publicInvoiceDialogSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'اطلب من العميل مسح رمز QR لفتح الفاتورة.'**
  String get publicInvoiceDialogSubtitle;

  /// Public invoice QR dialog subtitle with the receipt number.
  ///
  /// In ar, this message translates to:
  /// **'اطلب من العميل مسح رمز QR لفتح الفاتورة {receiptNumber}.'**
  String publicInvoiceDialogSubtitleWithReceipt(String receiptNumber);

  /// No description provided for @publicInvoiceUrlLabel.
  ///
  /// In ar, this message translates to:
  /// **'رابط الفاتورة'**
  String get publicInvoiceUrlLabel;

  /// No description provided for @copyPublicInvoiceUrlButton.
  ///
  /// In ar, this message translates to:
  /// **'نسخ الرابط'**
  String get copyPublicInvoiceUrlButton;

  /// No description provided for @publicInvoiceUrlCopiedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم نسخ رابط الفاتورة.'**
  String get publicInvoiceUrlCopiedMessage;

  /// No description provided for @publicInvoiceQrSemanticsLabel.
  ///
  /// In ar, this message translates to:
  /// **'رمز QR لرابط الفاتورة'**
  String get publicInvoiceQrSemanticsLabel;

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

  /// No description provided for @saleCheckoutSessionExpired.
  ///
  /// In ar, this message translates to:
  /// **'لم تعد جلسة الدرج مفتوحة. يرجى فتح جلسة درج جديدة ثم إعادة المحاولة.'**
  String get saleCheckoutSessionExpired;

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
  String oversellLine(String productName, String requested, String available);

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

  /// No description provided for @posSessionMenuTitle.
  ///
  /// In ar, this message translates to:
  /// **'إجراءات الجلسة'**
  String get posSessionMenuTitle;

  /// No description provided for @posSessionMenuTooltip.
  ///
  /// In ar, this message translates to:
  /// **'خيارات الجلسة'**
  String get posSessionMenuTooltip;

  /// No description provided for @payInRegisterSessionDescription.
  ///
  /// In ar, this message translates to:
  /// **'إيداع مبلغ نقدي في الدرج'**
  String get payInRegisterSessionDescription;

  /// No description provided for @payOutRegisterSessionDescription.
  ///
  /// In ar, this message translates to:
  /// **'سحب مبلغ نقدي من الدرج'**
  String get payOutRegisterSessionDescription;

  /// No description provided for @collectDebtSessionDescription.
  ///
  /// In ar, this message translates to:
  /// **'استلام دفعة من عميل عليه رصيد آجل'**
  String get collectDebtSessionDescription;

  /// No description provided for @refreshCatalogDescription.
  ///
  /// In ar, this message translates to:
  /// **'مزامنة قائمة المنتجات مع الخادم'**
  String get refreshCatalogDescription;

  /// No description provided for @closeRegisterSessionDescription.
  ///
  /// In ar, this message translates to:
  /// **'إنهاء الجلسة وعدّ النقدية في الدرج'**
  String get closeRegisterSessionDescription;

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
  /// **'النقد عند الإغلاق (بدون الفئات)'**
  String get closingCashInputLabel;

  /// No description provided for @closingCashTotalLabel.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي النقد عند الإغلاق'**
  String get closingCashTotalLabel;

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

  /// No description provided for @editButton.
  ///
  /// In ar, this message translates to:
  /// **'تعديل'**
  String get editButton;

  /// No description provided for @deleteButton.
  ///
  /// In ar, this message translates to:
  /// **'حذف'**
  String get deleteButton;

  /// No description provided for @closeButton.
  ///
  /// In ar, this message translates to:
  /// **'إغلاق'**
  String get closeButton;

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

  /// No description provided for @sessionSummaryLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل ملخص الوردية.'**
  String get sessionSummaryLoadError;

  /// No description provided for @sessionSalesSummaryTitle.
  ///
  /// In ar, this message translates to:
  /// **'ملخص المبيعات'**
  String get sessionSalesSummaryTitle;

  /// No description provided for @sessionGrossSalesMetric.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي المبيعات'**
  String get sessionGrossSalesMetric;

  /// No description provided for @sessionDiscountsMetric.
  ///
  /// In ar, this message translates to:
  /// **'الخصومات'**
  String get sessionDiscountsMetric;

  /// No description provided for @sessionRefundsMetric.
  ///
  /// In ar, this message translates to:
  /// **'المرتجعات'**
  String get sessionRefundsMetric;

  /// No description provided for @sessionNetSalesMetric.
  ///
  /// In ar, this message translates to:
  /// **'صافي المبيعات'**
  String get sessionNetSalesMetric;

  /// No description provided for @sessionOrderCountMetric.
  ///
  /// In ar, this message translates to:
  /// **'عدد الفواتير'**
  String get sessionOrderCountMetric;

  /// No description provided for @sessionItemsSoldMetric.
  ///
  /// In ar, this message translates to:
  /// **'القطع المباعة'**
  String get sessionItemsSoldMetric;

  /// No description provided for @sessionVoidCountMetric.
  ///
  /// In ar, this message translates to:
  /// **'فواتير ملغاة'**
  String get sessionVoidCountMetric;

  /// No description provided for @sessionExpensesMetric.
  ///
  /// In ar, this message translates to:
  /// **'مصروفات الوردية'**
  String get sessionExpensesMetric;

  /// No description provided for @sessionPaymentMethodsTitle.
  ///
  /// In ar, this message translates to:
  /// **'حسب طريقة الدفع'**
  String get sessionPaymentMethodsTitle;

  /// No description provided for @sessionPaymentCollectedLabel.
  ///
  /// In ar, this message translates to:
  /// **'المقبوض'**
  String get sessionPaymentCollectedLabel;

  /// No description provided for @sessionPaymentCommissionLabel.
  ///
  /// In ar, this message translates to:
  /// **'العمولة'**
  String get sessionPaymentCommissionLabel;

  /// No description provided for @sessionPaymentRefundLabel.
  ///
  /// In ar, this message translates to:
  /// **'المرتجع'**
  String get sessionPaymentRefundLabel;

  /// No description provided for @sessionPaymentNetLabel.
  ///
  /// In ar, this message translates to:
  /// **'الصافي'**
  String get sessionPaymentNetLabel;

  /// No description provided for @sessionPaymentsTotalLabel.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي المقبوضات'**
  String get sessionPaymentsTotalLabel;

  /// Operation count for a payment method on the session summary.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا عمليات} =1{عملية واحدة} =2{عمليتان} other{{count} عملية}}'**
  String sessionPaymentOperationsCount(int count);

  /// No description provided for @sessionCategoriesTitle.
  ///
  /// In ar, this message translates to:
  /// **'المبيعات حسب الفئة'**
  String get sessionCategoriesTitle;

  /// No description provided for @sessionUncategorizedLabel.
  ///
  /// In ar, this message translates to:
  /// **'غير مصنف'**
  String get sessionUncategorizedLabel;

  /// No description provided for @sessionNoCategorySales.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مبيعات حسب الفئة في هذه الجلسة.'**
  String get sessionNoCategorySales;

  /// Category breakdown row label: category name and quantity sold.
  ///
  /// In ar, this message translates to:
  /// **'{category} ×{quantity}'**
  String sessionCategoryLineLabel(String category, String quantity);

  /// No description provided for @sessionZReportTitle.
  ///
  /// In ar, this message translates to:
  /// **'تقرير إغلاق الوردية (Z)'**
  String get sessionZReportTitle;

  /// No description provided for @sessionPrintZReportThermal.
  ///
  /// In ar, this message translates to:
  /// **'طباعة (إيصال)'**
  String get sessionPrintZReportThermal;

  /// No description provided for @sessionPrintZReportPdf.
  ///
  /// In ar, this message translates to:
  /// **'طباعة PDF'**
  String get sessionPrintZReportPdf;

  /// No description provided for @sessionShareZReportPdf.
  ///
  /// In ar, this message translates to:
  /// **'مشاركة / حفظ PDF'**
  String get sessionShareZReportPdf;

  /// No description provided for @sessionZReportPrintedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تمت طباعة تقرير الوردية.'**
  String get sessionZReportPrintedMessage;

  /// No description provided for @sessionZReportSharedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم تجهيز تقرير الوردية.'**
  String get sessionZReportSharedMessage;

  /// No description provided for @sessionZReportFailedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تعذّرت طباعة تقرير الوردية.'**
  String get sessionZReportFailedMessage;

  /// No description provided for @sessionClosedPrintZReportPrompt.
  ///
  /// In ar, this message translates to:
  /// **'تم إغلاق الوردية. هل تريد طباعة تقرير الإغلاق (Z)؟'**
  String get sessionClosedPrintZReportPrompt;

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

  /// No description provided for @recordInvoicePaymentButton.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل دفعة'**
  String get recordInvoicePaymentButton;

  /// Callout title on a credit invoice that still carries a balance.
  ///
  /// In ar, this message translates to:
  /// **'آجل — المتبقّي {amount}.'**
  String invoiceCreditBalanceCalloutTitle(String amount);

  /// No description provided for @invoiceCreditBalanceCalloutBody.
  ///
  /// In ar, this message translates to:
  /// **'فاتورة آجلة لم يُسدَّد منها شيء بعد.'**
  String get invoiceCreditBalanceCalloutBody;

  /// Shows how much has already been paid on a partly-paid credit invoice.
  ///
  /// In ar, this message translates to:
  /// **'المدفوع حتى الآن: {amount}'**
  String invoiceCreditBalancePaidValue(String amount);

  /// No description provided for @invoicePaymentTitle.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل دفعة على الفاتورة'**
  String get invoicePaymentTitle;

  /// No description provided for @invoicePaymentAmountLabel.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ'**
  String get invoicePaymentAmountLabel;

  /// No description provided for @invoicePaymentReferenceLabel.
  ///
  /// In ar, this message translates to:
  /// **'مرجع اختياري'**
  String get invoicePaymentReferenceLabel;

  /// No description provided for @invoicePaymentPrintProofLabel.
  ///
  /// In ar, this message translates to:
  /// **'طباعة سند قبض'**
  String get invoicePaymentPrintProofLabel;

  /// Shows the invoice's remaining balance inside the payment dialog.
  ///
  /// In ar, this message translates to:
  /// **'المتبقّي على الفاتورة: {amount}'**
  String invoicePaymentBalanceValue(String amount);

  /// No description provided for @invoicePaymentAmountError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل مبلغًا أكبر من صفر ولا يتجاوز المتبقّي.'**
  String get invoicePaymentAmountError;

  /// No description provided for @invoicePaymentSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل الدفعة على الفاتورة.'**
  String get invoicePaymentSuccess;

  /// Action on an unpaid debt invoice that has no customer yet: assign one.
  ///
  /// In ar, this message translates to:
  /// **'تعيين عميل'**
  String get invoiceAssignCustomerButton;

  /// Action on an unpaid debt invoice: change which customer owes it.
  ///
  /// In ar, this message translates to:
  /// **'تغيير العميل'**
  String get invoiceChangeCustomerButton;

  /// No description provided for @invoiceAssignCustomerSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم تعيين العميل على الفاتورة.'**
  String get invoiceAssignCustomerSuccess;

  /// No description provided for @invoiceAssignCustomerError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تعيين العميل على الفاتورة. لا يمكن ذلك بعد تسجيل أي دفعة.'**
  String get invoiceAssignCustomerError;

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
  /// **'جار الطباعة...'**
  String get invoiceReprintInProgressButton;

  /// No description provided for @invoiceReprintQueuedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم إرسال الفاتورة للطابعة.'**
  String get invoiceReprintQueuedMessage;

  /// No description provided for @invoiceReprintError.
  ///
  /// In ar, this message translates to:
  /// **'تعذرت طباعة الفاتورة.'**
  String get invoiceReprintError;

  /// No description provided for @invoiceShareButton.
  ///
  /// In ar, this message translates to:
  /// **'مشاركة PDF'**
  String get invoiceShareButton;

  /// No description provided for @invoiceShareInProgressButton.
  ///
  /// In ar, this message translates to:
  /// **'جار تجهيز PDF...'**
  String get invoiceShareInProgressButton;

  /// No description provided for @invoiceRowActionsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إجراءات الفاتورة'**
  String get invoiceRowActionsTooltip;

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

  /// No description provided for @saleReceiptShareButton.
  ///
  /// In ar, this message translates to:
  /// **'مشاركة PDF'**
  String get saleReceiptShareButton;

  /// No description provided for @saleReceiptShareInProgressButton.
  ///
  /// In ar, this message translates to:
  /// **'جار تجهيز PDF...'**
  String get saleReceiptShareInProgressButton;

  /// No description provided for @saleReceiptShareSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم تجهيز ملف PDF للإيصال.'**
  String get saleReceiptShareSuccess;

  /// No description provided for @saleReceiptShareError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تجهيز ملف PDF للإيصال.'**
  String get saleReceiptShareError;

  /// Fallback product label in a sale line.
  ///
  /// In ar, this message translates to:
  /// **'منتج رقم {productId}'**
  String saleProductFallback(int productId);

  /// Sale line quantity and unit price.
  ///
  /// In ar, this message translates to:
  /// **'{quantity} × {unitPrice}'**
  String saleLineQuantityAndPrice(String quantity, String unitPrice);

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

  /// No description provided for @saleExchangeButton.
  ///
  /// In ar, this message translates to:
  /// **'استبدال'**
  String get saleExchangeButton;

  /// No description provided for @saleExchangeTitle.
  ///
  /// In ar, this message translates to:
  /// **'استبدال منتجات'**
  String get saleExchangeTitle;

  /// No description provided for @saleExchangeSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل الاستبدال.'**
  String get saleExchangeSuccess;

  /// No description provided for @saleExchangeError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تسجيل الاستبدال.'**
  String get saleExchangeError;

  /// No description provided for @saleExchangeReturnedSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'العناصر المُرتجعة'**
  String get saleExchangeReturnedSectionTitle;

  /// No description provided for @saleExchangeReplacementSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'العناصر البديلة'**
  String get saleExchangeReplacementSectionTitle;

  /// No description provided for @saleExchangeSearchLabel.
  ///
  /// In ar, this message translates to:
  /// **'ابحث عن منتج بديل'**
  String get saleExchangeSearchLabel;

  /// No description provided for @saleExchangeSearchButton.
  ///
  /// In ar, this message translates to:
  /// **'بحث'**
  String get saleExchangeSearchButton;

  /// No description provided for @saleExchangeNoResults.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد نتائج مطابقة.'**
  String get saleExchangeNoResults;

  /// No description provided for @saleExchangeInvalidError.
  ///
  /// In ar, this message translates to:
  /// **'اختر عنصرًا مُرتجعًا واحدًا على الأقل وعنصرًا بديلًا.'**
  String get saleExchangeInvalidError;

  /// No description provided for @saleExchangeSettlementLabel.
  ///
  /// In ar, this message translates to:
  /// **'طريقة تسوية الفرق'**
  String get saleExchangeSettlementLabel;

  /// Net the customer owes on an exchange.
  ///
  /// In ar, this message translates to:
  /// **'على العميل دفع {amount}'**
  String saleExchangeNetPay(String amount);

  /// Net refunded to the customer on an exchange.
  ///
  /// In ar, this message translates to:
  /// **'يُرَدّ للعميل {amount}'**
  String saleExchangeNetRefund(String amount);

  /// No description provided for @saleExchangeNetEven.
  ///
  /// In ar, this message translates to:
  /// **'تبادل متكافئ — لا فرق'**
  String get saleExchangeNetEven;

  /// No description provided for @navReturnsExchange.
  ///
  /// In ar, this message translates to:
  /// **'المرتجعات والاستبدال'**
  String get navReturnsExchange;

  /// No description provided for @returnsLookupTitle.
  ///
  /// In ar, this message translates to:
  /// **'المرتجعات والاستبدال'**
  String get returnsLookupTitle;

  /// No description provided for @returnsLookupPrompt.
  ///
  /// In ar, this message translates to:
  /// **'أدخل رقم الفاتورة لإجراء إرجاع أو استبدال.'**
  String get returnsLookupPrompt;

  /// No description provided for @returnsLookupFieldLabel.
  ///
  /// In ar, this message translates to:
  /// **'رقم الفاتورة'**
  String get returnsLookupFieldLabel;

  /// No description provided for @returnsLookupSearchButton.
  ///
  /// In ar, this message translates to:
  /// **'بحث'**
  String get returnsLookupSearchButton;

  /// No description provided for @returnsLookupNotFound.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد فاتورة بهذا الرقم.'**
  String get returnsLookupNotFound;

  /// No description provided for @returnsLookupEmpty.
  ///
  /// In ar, this message translates to:
  /// **'ابحث عن فاتورة برقمها للبدء.'**
  String get returnsLookupEmpty;

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
  String saleLineReturnedQuantity(String returned, String quantity);

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

  /// No description provided for @applyDiscountCodeButton.
  ///
  /// In ar, this message translates to:
  /// **'تطبيق الخصم'**
  String get applyDiscountCodeButton;

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

  /// Current discount wizard step out of total steps.
  ///
  /// In ar, this message translates to:
  /// **'{step} من {total}'**
  String discountWizardStepLabel(int step, int total);

  /// No description provided for @discountWizardStepBasics.
  ///
  /// In ar, this message translates to:
  /// **'الأساسيات'**
  String get discountWizardStepBasics;

  /// No description provided for @discountWizardStepValue.
  ///
  /// In ar, this message translates to:
  /// **'قيمة الخصم'**
  String get discountWizardStepValue;

  /// No description provided for @discountWizardStepEligibility.
  ///
  /// In ar, this message translates to:
  /// **'ينطبق على'**
  String get discountWizardStepEligibility;

  /// No description provided for @discountWizardStepLimits.
  ///
  /// In ar, this message translates to:
  /// **'الحدود'**
  String get discountWizardStepLimits;

  /// No description provided for @discountWizardStepReview.
  ///
  /// In ar, this message translates to:
  /// **'المراجعة'**
  String get discountWizardStepReview;

  /// No description provided for @discountWizardDescriptionToggle.
  ///
  /// In ar, this message translates to:
  /// **'إضافة وصف داخلي'**
  String get discountWizardDescriptionToggle;

  /// No description provided for @discountWizardMaximumDiscountToggle.
  ///
  /// In ar, this message translates to:
  /// **'تحديد أقصى خصم'**
  String get discountWizardMaximumDiscountToggle;

  /// No description provided for @discountWizardRoundingToggle.
  ///
  /// In ar, this message translates to:
  /// **'تنظيف السعر بعد الخصم'**
  String get discountWizardRoundingToggle;

  /// No description provided for @discountWizardMinimumSubtotalToggle.
  ///
  /// In ar, this message translates to:
  /// **'اشتراط أقل إجمالي'**
  String get discountWizardMinimumSubtotalToggle;

  /// No description provided for @discountWizardMinimumLineQuantityToggle.
  ///
  /// In ar, this message translates to:
  /// **'اشتراط أقل كمية'**
  String get discountWizardMinimumLineQuantityToggle;

  /// No description provided for @discountWizardProductScopeToggle.
  ///
  /// In ar, this message translates to:
  /// **'تطبيقه على منتجات محددة'**
  String get discountWizardProductScopeToggle;

  /// No description provided for @discountWizardContactScopeToggle.
  ///
  /// In ar, this message translates to:
  /// **'تطبيقه على عملاء أو موردين محددين'**
  String get discountWizardContactScopeToggle;

  /// No description provided for @discountWizardScheduleToggle.
  ///
  /// In ar, this message translates to:
  /// **'تحديد فترة للخصم'**
  String get discountWizardScheduleToggle;

  /// No description provided for @discountWizardUsageLimitsToggle.
  ///
  /// In ar, this message translates to:
  /// **'تحديد مرات الاستخدام'**
  String get discountWizardUsageLimitsToggle;

  /// No description provided for @discountFormSummaryTitle.
  ///
  /// In ar, this message translates to:
  /// **'ملخص الخصم'**
  String get discountFormSummaryTitle;

  /// No description provided for @discountSummaryPlaceholder.
  ///
  /// In ar, this message translates to:
  /// **'أدخل قيمة الخصم لمعاينة الملخص'**
  String get discountSummaryPlaceholder;

  /// No description provided for @discountSummaryAppliesAll.
  ///
  /// In ar, this message translates to:
  /// **'كل المنتجات'**
  String get discountSummaryAppliesAll;

  /// No description provided for @discountTargetedShort.
  ///
  /// In ar, this message translates to:
  /// **'أصناف محددة'**
  String get discountTargetedShort;

  /// No description provided for @discountSectionBasicsHint.
  ///
  /// In ar, this message translates to:
  /// **'الاسم والقناة وطريقة التطبيق'**
  String get discountSectionBasicsHint;

  /// No description provided for @discountSectionValueHint.
  ///
  /// In ar, this message translates to:
  /// **'نوع الخصم وقيمته'**
  String get discountSectionValueHint;

  /// No description provided for @discountSectionTargeting.
  ///
  /// In ar, this message translates to:
  /// **'على ماذا ينطبق'**
  String get discountSectionTargeting;

  /// No description provided for @discountSectionTargetingHint.
  ///
  /// In ar, this message translates to:
  /// **'اتركه فارغًا لتطبيقه على كل شيء'**
  String get discountSectionTargetingHint;

  /// No description provided for @discountSectionConditions.
  ///
  /// In ar, this message translates to:
  /// **'الشروط'**
  String get discountSectionConditions;

  /// No description provided for @discountSectionConditionsHint.
  ///
  /// In ar, this message translates to:
  /// **'حدود الحد الأدنى لتطبيق الخصم'**
  String get discountSectionConditionsHint;

  /// No description provided for @discountSectionScheduleHint.
  ///
  /// In ar, this message translates to:
  /// **'فترة السريان وعدد مرات الاستخدام'**
  String get discountSectionScheduleHint;

  /// No description provided for @discountSectionAdvanced.
  ///
  /// In ar, this message translates to:
  /// **'خيارات متقدمة'**
  String get discountSectionAdvanced;

  /// No description provided for @discountSectionAdvancedHint.
  ///
  /// In ar, this message translates to:
  /// **'الأولوية والتكديس مع الخصومات الأخرى'**
  String get discountSectionAdvancedHint;

  /// No description provided for @discountScopeAutoNote.
  ///
  /// In ar, this message translates to:
  /// **'ينطبق على كل صنف مطابق'**
  String get discountScopeAutoNote;

  /// No description provided for @discountValueTypePercentageHelp.
  ///
  /// In ar, this message translates to:
  /// **'نسبة مئوية تُخصم من السعر'**
  String get discountValueTypePercentageHelp;

  /// No description provided for @discountValueTypeFixedAmountHelp.
  ///
  /// In ar, this message translates to:
  /// **'مبلغ ثابت يُخصم من الإجمالي'**
  String get discountValueTypeFixedAmountHelp;

  /// No description provided for @discountValueTypeFixedUnitAmountHelp.
  ///
  /// In ar, this message translates to:
  /// **'مبلغ يُخصم عن كل وحدة'**
  String get discountValueTypeFixedUnitAmountHelp;

  /// No description provided for @discountValueTypeFixedPriceHelp.
  ///
  /// In ar, this message translates to:
  /// **'تثبيت سعر الصنف عند قيمة محددة'**
  String get discountValueTypeFixedPriceHelp;

  /// No description provided for @discountValueTypeMultiBuy.
  ///
  /// In ar, this message translates to:
  /// **'اشترِ عدّة بسعر'**
  String get discountValueTypeMultiBuy;

  /// No description provided for @discountValueTypeMultiBuyHelp.
  ///
  /// In ar, this message translates to:
  /// **'حدّد عدد القطع في المجموعة وسعرها، مثل ٣ قطع بدينار.'**
  String get discountValueTypeMultiBuyHelp;

  /// No description provided for @discountValueTypeTiered.
  ///
  /// In ar, this message translates to:
  /// **'سعر متدرّج بالكمية'**
  String get discountValueTypeTiered;

  /// No description provided for @discountValueTypeTieredHelp.
  ///
  /// In ar, this message translates to:
  /// **'كلما زادت الكمية انخفض سعر الوحدة عبر شرائح.'**
  String get discountValueTypeTieredHelp;

  /// No description provided for @discountValueTypeBuyXGetY.
  ///
  /// In ar, this message translates to:
  /// **'اشترِ X واحصل على Y'**
  String get discountValueTypeBuyXGetY;

  /// No description provided for @discountValueTypeBuyXGetYHelp.
  ///
  /// In ar, this message translates to:
  /// **'اشترِ كمية واحصل على قطع مجانية أو بخصم.'**
  String get discountValueTypeBuyXGetYHelp;

  /// No description provided for @discountGroupSizeLabel.
  ///
  /// In ar, this message translates to:
  /// **'عدد قطع المجموعة'**
  String get discountGroupSizeLabel;

  /// No description provided for @discountGroupPriceLabel.
  ///
  /// In ar, this message translates to:
  /// **'سعر المجموعة'**
  String get discountGroupPriceLabel;

  /// No description provided for @discountBuyQuantityLabel.
  ///
  /// In ar, this message translates to:
  /// **'كمية الشراء (X)'**
  String get discountBuyQuantityLabel;

  /// No description provided for @discountGetQuantityLabel.
  ///
  /// In ar, this message translates to:
  /// **'كمية المكافأة (Y)'**
  String get discountGetQuantityLabel;

  /// No description provided for @discountRewardTypeLabel.
  ///
  /// In ar, this message translates to:
  /// **'نوع المكافأة'**
  String get discountRewardTypeLabel;

  /// No description provided for @discountRewardFree.
  ///
  /// In ar, this message translates to:
  /// **'مجانًا'**
  String get discountRewardFree;

  /// No description provided for @discountRewardPercentage.
  ///
  /// In ar, this message translates to:
  /// **'نسبة خصم'**
  String get discountRewardPercentage;

  /// No description provided for @discountRewardFixedPrice.
  ///
  /// In ar, this message translates to:
  /// **'سعر ثابت للقطعة'**
  String get discountRewardFixedPrice;

  /// No description provided for @discountTiersLabel.
  ///
  /// In ar, this message translates to:
  /// **'شرائح السعر'**
  String get discountTiersLabel;

  /// No description provided for @discountTiersHint.
  ///
  /// In ar, this message translates to:
  /// **'حدّد سعر الوحدة عند كل كمية. تُطبَّق أعلى شريحة مؤهَّلة.'**
  String get discountTiersHint;

  /// No description provided for @discountTierMinQuantityLabel.
  ///
  /// In ar, this message translates to:
  /// **'ابتداءً من كمية'**
  String get discountTierMinQuantityLabel;

  /// No description provided for @discountTierUnitPriceLabel.
  ///
  /// In ar, this message translates to:
  /// **'سعر الوحدة'**
  String get discountTierUnitPriceLabel;

  /// No description provided for @discountAddTierButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة شريحة'**
  String get discountAddTierButton;

  /// No description provided for @discountRemoveTierTooltip.
  ///
  /// In ar, this message translates to:
  /// **'حذف الشريحة'**
  String get discountRemoveTierTooltip;

  /// No description provided for @discountTiersRequiredError.
  ///
  /// In ar, this message translates to:
  /// **'أضف شريحة سعر واحدة على الأقل.'**
  String get discountTiersRequiredError;

  /// Multi-buy headline: N units for a group price.
  ///
  /// In ar, this message translates to:
  /// **'{count} بـ {price}'**
  String discountMultiBuyValue(int count, String price);

  /// Tiered discount headline showing the lowest tier unit price.
  ///
  /// In ar, this message translates to:
  /// **'من {price}'**
  String discountTieredValue(String price);

  /// Buy X get Y headline.
  ///
  /// In ar, this message translates to:
  /// **'اشترِ {buy} واحصل على {get}'**
  String discountBuyGetValue(int buy, int get);

  /// Live-summary chip for a multi-buy rule.
  ///
  /// In ar, this message translates to:
  /// **'{count} قطع بـ {price}'**
  String discountMultiBuySummary(int count, String price);

  /// Live-summary chip showing the number of price tiers.
  ///
  /// In ar, this message translates to:
  /// **'{count} شرائح سعر'**
  String discountTierCountSummary(int count);

  /// No description provided for @discountRewardSummaryFree.
  ///
  /// In ar, this message translates to:
  /// **'القطعة المكافأة مجانًا'**
  String get discountRewardSummaryFree;

  /// Buy X get Y percentage reward summary.
  ///
  /// In ar, this message translates to:
  /// **'خصم {percent}% على المكافأة'**
  String discountRewardSummaryPercentage(String percent);

  /// Buy X get Y fixed-price reward summary.
  ///
  /// In ar, this message translates to:
  /// **'المكافأة بسعر {price}'**
  String discountRewardSummaryFixedPrice(String price);

  /// No description provided for @discountWizardAdvancedToggle.
  ///
  /// In ar, this message translates to:
  /// **'إظهار خيارات متقدمة'**
  String get discountWizardAdvancedToggle;

  /// No description provided for @discountWizardFixStepError.
  ///
  /// In ar, this message translates to:
  /// **'راجع الخطوة المحددة وأكمل البيانات المطلوبة.'**
  String get discountWizardFixStepError;

  /// No description provided for @discountWizardNoExtraRules.
  ///
  /// In ar, this message translates to:
  /// **'بدون شروط إضافية'**
  String get discountWizardNoExtraRules;

  /// No description provided for @discountWizardNoLimits.
  ///
  /// In ar, this message translates to:
  /// **'بدون حدود'**
  String get discountWizardNoLimits;

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

  /// No description provided for @discountRoundingModeLabel.
  ///
  /// In ar, this message translates to:
  /// **'طريقة تنظيف السعر'**
  String get discountRoundingModeLabel;

  /// No description provided for @discountRoundingModeNone.
  ///
  /// In ar, this message translates to:
  /// **'بدون تنظيف'**
  String get discountRoundingModeNone;

  /// No description provided for @discountRoundingModeDown.
  ///
  /// In ar, this message translates to:
  /// **'نزولاً'**
  String get discountRoundingModeDown;

  /// No description provided for @discountRoundingModeNearest.
  ///
  /// In ar, this message translates to:
  /// **'لأقرب قيمة'**
  String get discountRoundingModeNearest;

  /// No description provided for @discountRoundingModeUp.
  ///
  /// In ar, this message translates to:
  /// **'صعوداً'**
  String get discountRoundingModeUp;

  /// No description provided for @discountRoundingIncrementLabel.
  ///
  /// In ar, this message translates to:
  /// **'قيمة التقريب'**
  String get discountRoundingIncrementLabel;

  /// No description provided for @discountRoundingIncrementError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل قيمة تقريب صحيحة.'**
  String get discountRoundingIncrementError;

  /// Summary for discount result rounding mode and increment.
  ///
  /// In ar, this message translates to:
  /// **'{mode} إلى {increment}'**
  String discountRoundingSummary(String mode, String increment);

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

  /// Toggle to limit a discount to specific customer RFM ranks.
  ///
  /// In ar, this message translates to:
  /// **'حصره على تصنيفات عملاء معيّنة'**
  String get discountRankScopeToggle;

  /// Subtitle explaining the customer-rank targeting toggle.
  ///
  /// In ar, this message translates to:
  /// **'يُطبَّق تلقائيًا فقط على العملاء ضمن التصنيفات المختارة.'**
  String get discountRankScopeHint;

  /// Label above the customer-rank multi-select chips.
  ///
  /// In ar, this message translates to:
  /// **'التصنيفات المستهدفة'**
  String get discountRankConstraintLabel;

  /// Summary chip for the number of targeted customer ranks.
  ///
  /// In ar, this message translates to:
  /// **'{count} تصنيف عميل'**
  String discountRankConstraintSummary(int count);

  /// No description provided for @yesLabel.
  ///
  /// In ar, this message translates to:
  /// **'نعم'**
  String get yesLabel;

  /// No description provided for @noLabel.
  ///
  /// In ar, this message translates to:
  /// **'لا'**
  String get noLabel;

  /// Discount details screen title.
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل {name}'**
  String discountDetailsTitle(String name);

  /// No description provided for @discountDetailsRefreshTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث تفاصيل الخصم'**
  String get discountDetailsRefreshTooltip;

  /// No description provided for @discountDetailsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل تفاصيل الخصم.'**
  String get discountDetailsLoadError;

  /// No description provided for @discountDetailsPerformanceSection.
  ///
  /// In ar, this message translates to:
  /// **'أداء الخصم'**
  String get discountDetailsPerformanceSection;

  /// No description provided for @discountDetailsConfigurationSection.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات الخصم'**
  String get discountDetailsConfigurationSection;

  /// No description provided for @discountDetailsConstraintsSection.
  ///
  /// In ar, this message translates to:
  /// **'الشروط والنطاق'**
  String get discountDetailsConstraintsSection;

  /// No description provided for @discountDetailsImpactSection.
  ///
  /// In ar, this message translates to:
  /// **'الأثر التقديري'**
  String get discountDetailsImpactSection;

  /// No description provided for @discountDetailsTrendSection.
  ///
  /// In ar, this message translates to:
  /// **'الاتجاه الشهري'**
  String get discountDetailsTrendSection;

  /// No description provided for @discountDetailsChannelBreakdownSection.
  ///
  /// In ar, this message translates to:
  /// **'توزيع النطاق'**
  String get discountDetailsChannelBreakdownSection;

  /// No description provided for @discountDetailsBeneficiariesSection.
  ///
  /// In ar, this message translates to:
  /// **'المستفيدون'**
  String get discountDetailsBeneficiariesSection;

  /// No description provided for @discountDetailsRedemptionsMetric.
  ///
  /// In ar, this message translates to:
  /// **'الاستخدامات'**
  String get discountDetailsRedemptionsMetric;

  /// Applied discount count subtitle.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد تطبيقات} =1{تطبيق واحد} =2{تطبيقان} other{{count} تطبيقات}}'**
  String discountDetailsApplicationsSubtitle(int count);

  /// No description provided for @discountDetailsBeneficiariesMetric.
  ///
  /// In ar, this message translates to:
  /// **'المستفيدون'**
  String get discountDetailsBeneficiariesMetric;

  /// Beneficiary split subtitle.
  ///
  /// In ar, this message translates to:
  /// **'{customers} عملاء • {suppliers} موردون'**
  String discountDetailsBeneficiariesSubtitle(int customers, int suppliers);

  /// No description provided for @discountDetailsGrossInfluencedMetric.
  ///
  /// In ar, this message translates to:
  /// **'قيمة متأثرة'**
  String get discountDetailsGrossInfluencedMetric;

  /// No description provided for @discountDetailsNetInfluencedMetric.
  ///
  /// In ar, this message translates to:
  /// **'صافي متأثر'**
  String get discountDetailsNetInfluencedMetric;

  /// No description provided for @discountDetailsDiscountCostMetric.
  ///
  /// In ar, this message translates to:
  /// **'تكلفة الخصم'**
  String get discountDetailsDiscountCostMetric;

  /// Discount rate subtitle.
  ///
  /// In ar, this message translates to:
  /// **'معدل الخصم {rate}'**
  String discountDetailsDiscountRateSubtitle(String rate);

  /// No description provided for @discountDetailsAverageDocumentMetric.
  ///
  /// In ar, this message translates to:
  /// **'متوسط المستند'**
  String get discountDetailsAverageDocumentMetric;

  /// Average discount subtitle.
  ///
  /// In ar, this message translates to:
  /// **'متوسط الخصم {amount}'**
  String discountDetailsAverageDiscountSubtitle(String amount);

  /// No description provided for @discountDetailsIncrementalNetMetric.
  ///
  /// In ar, this message translates to:
  /// **'قيمة صافية مقدرة'**
  String get discountDetailsIncrementalNetMetric;

  /// No description provided for @discountDetailsLiftUnavailable.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد خط أساس كاف'**
  String get discountDetailsLiftUnavailable;

  /// Estimated lift subtitle.
  ///
  /// In ar, this message translates to:
  /// **'رفع مقدر {rate}'**
  String discountDetailsLiftSubtitle(String rate);

  /// No description provided for @discountDetailsUsageLimitMetric.
  ///
  /// In ar, this message translates to:
  /// **'حد الاستخدام'**
  String get discountDetailsUsageLimitMetric;

  /// No description provided for @discountDetailsUnlimitedUsage.
  ///
  /// In ar, this message translates to:
  /// **'غير محدود'**
  String get discountDetailsUnlimitedUsage;

  /// No description provided for @discountDetailsNoUsageLimit.
  ///
  /// In ar, this message translates to:
  /// **'بدون حد استخدام'**
  String get discountDetailsNoUsageLimit;

  /// Remaining discount usage.
  ///
  /// In ar, this message translates to:
  /// **'متبقٍ {remaining} من {limit}'**
  String discountDetailsUsageRemaining(int remaining, int limit);

  /// No description provided for @discountDetailsImpactMethodNote.
  ///
  /// In ar, this message translates to:
  /// **'التقدير يقارن الاستخدام الفعلي بآخر 90 يومًا من المستندات التاريخية المطابقة لشروط الخصم، لذلك هو مؤشر عملي وليس تجربة عزل كاملة.'**
  String get discountDetailsImpactMethodNote;

  /// No description provided for @discountDetailsExpectedDocumentsLabel.
  ///
  /// In ar, this message translates to:
  /// **'مستندات متوقعة بدون الخصم'**
  String get discountDetailsExpectedDocumentsLabel;

  /// No description provided for @discountDetailsExpectedGrossLabel.
  ///
  /// In ar, this message translates to:
  /// **'قيمة متوقعة بدون الخصم'**
  String get discountDetailsExpectedGrossLabel;

  /// No description provided for @discountDetailsIncrementalDocumentsLabel.
  ///
  /// In ar, this message translates to:
  /// **'مستندات إضافية مقدرة'**
  String get discountDetailsIncrementalDocumentsLabel;

  /// No description provided for @discountDetailsIncrementalGrossLabel.
  ///
  /// In ar, this message translates to:
  /// **'قيمة إضافية مقدرة'**
  String get discountDetailsIncrementalGrossLabel;

  /// No description provided for @discountDetailsBaselinePeriodLabel.
  ///
  /// In ar, this message translates to:
  /// **'فترة الخط الأساسي'**
  String get discountDetailsBaselinePeriodLabel;

  /// No description provided for @discountDetailsBaselineDocumentsLabel.
  ///
  /// In ar, this message translates to:
  /// **'مستندات الخط الأساسي'**
  String get discountDetailsBaselineDocumentsLabel;

  /// Baseline document count and amount.
  ///
  /// In ar, this message translates to:
  /// **'{count} مستند • {amount}'**
  String discountDetailsBaselineDocumentsValue(int count, String amount);

  /// No description provided for @discountDetailsConfidenceLabel.
  ///
  /// In ar, this message translates to:
  /// **'ثقة التقدير'**
  String get discountDetailsConfidenceLabel;

  /// No description provided for @discountDetailsConfidenceHigh.
  ///
  /// In ar, this message translates to:
  /// **'عالية'**
  String get discountDetailsConfidenceHigh;

  /// No description provided for @discountDetailsConfidenceMedium.
  ///
  /// In ar, this message translates to:
  /// **'متوسطة'**
  String get discountDetailsConfidenceMedium;

  /// No description provided for @discountDetailsConfidenceLow.
  ///
  /// In ar, this message translates to:
  /// **'منخفضة'**
  String get discountDetailsConfidenceLow;

  /// No description provided for @discountDetailsConfidenceInsufficient.
  ///
  /// In ar, this message translates to:
  /// **'بيانات غير كافية'**
  String get discountDetailsConfidenceInsufficient;

  /// Date period value.
  ///
  /// In ar, this message translates to:
  /// **'{start} إلى {end}'**
  String discountDetailsPeriodValue(String start, String end);

  /// No description provided for @discountDetailsTrendEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد استخدامات شهرية لهذا الخصم بعد.'**
  String get discountDetailsTrendEmpty;

  /// No description provided for @discountDetailsTrendGrossHint.
  ///
  /// In ar, this message translates to:
  /// **'يعرض الشريط قيمة المستندات المتأثرة قبل الخصم.'**
  String get discountDetailsTrendGrossHint;

  /// Trend row value.
  ///
  /// In ar, this message translates to:
  /// **'{count} استخدام • {amount}'**
  String discountDetailsTrendValue(int count, String amount);

  /// No description provided for @discountDetailsChannelBreakdownEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد استخدامات موزعة حسب النطاق بعد.'**
  String get discountDetailsChannelBreakdownEmpty;

  /// Channel breakdown row value.
  ///
  /// In ar, this message translates to:
  /// **'{redemptions} استخدام • {documents} مستند • صافي {amount}'**
  String discountDetailsChannelBreakdownValue(
      int redemptions, int documents, String amount);

  /// No description provided for @discountDetailsBeneficiariesEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لم يستخدم أي عميل أو مورد هذا الخصم بعد.'**
  String get discountDetailsBeneficiariesEmpty;

  /// No description provided for @discountDetailsBeneficiariesLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل المستفيدين من الخصم.'**
  String get discountDetailsBeneficiariesLoadError;

  /// Beneficiary usage count.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{بدون استخدام} =1{استخدام واحد} =2{استخدامان} other{{count} استخدامات}}'**
  String discountDetailsUseCountValue(int count);

  /// Beneficiary document count.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{بدون مستندات} =1{مستند واحد} =2{مستندان} other{{count} مستندات}}'**
  String discountDetailsDocumentCountValue(int count);

  /// Beneficiary discount amount summary.
  ///
  /// In ar, this message translates to:
  /// **'خصم {amount}'**
  String discountDetailsBeneficiaryDiscountSummary(String amount);

  /// Beneficiary gross amount summary.
  ///
  /// In ar, this message translates to:
  /// **'قيمة {amount}'**
  String discountDetailsBeneficiaryGrossSummary(String amount);

  /// Beneficiary last usage summary.
  ///
  /// In ar, this message translates to:
  /// **'آخر استخدام {date}'**
  String discountDetailsLastUsedSummary(String date);

  /// Beneficiary first usage summary.
  ///
  /// In ar, this message translates to:
  /// **'أول استخدام {date}'**
  String discountDetailsFirstUsedSummary(String date);

  /// No description provided for @discountDetailsWalkInCustomer.
  ///
  /// In ar, this message translates to:
  /// **'عميل نقدي'**
  String get discountDetailsWalkInCustomer;

  /// No description provided for @discountDetailsUnknownSupplier.
  ///
  /// In ar, this message translates to:
  /// **'مورد غير محدد'**
  String get discountDetailsUnknownSupplier;

  /// Generic count value.
  ///
  /// In ar, this message translates to:
  /// **'{count}'**
  String discountDetailsCountValue(int count);

  /// No description provided for @printAuditButton.
  ///
  /// In ar, this message translates to:
  /// **'سجل الطباعة والمشاركة'**
  String get printAuditButton;

  /// Print/share audit sheet title.
  ///
  /// In ar, this message translates to:
  /// **'سجل الطباعة والمشاركة {documentNumber}'**
  String printAuditSheetTitle(String documentNumber);

  /// No description provided for @printAuditRefreshTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث سجل الطباعة والمشاركة'**
  String get printAuditRefreshTooltip;

  /// No description provided for @printAuditLoading.
  ///
  /// In ar, this message translates to:
  /// **'جار تحميل سجل الطباعة والمشاركة...'**
  String get printAuditLoading;

  /// No description provided for @printAuditLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل سجل الطباعة والمشاركة.'**
  String get printAuditLoadError;

  /// No description provided for @printAuditEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عمليات مسجلة'**
  String get printAuditEmptyTitle;

  /// No description provided for @printAuditEmptyMessage.
  ///
  /// In ar, this message translates to:
  /// **'ستظهر هنا عمليات الطباعة والمشاركة التي تمر عبر الخادم.'**
  String get printAuditEmptyMessage;

  /// Print audit event row title.
  ///
  /// In ar, this message translates to:
  /// **'{action} - {status}'**
  String printAuditEventTitle(String action, String status);

  /// No description provided for @printAuditActionPrint.
  ///
  /// In ar, this message translates to:
  /// **'طباعة'**
  String get printAuditActionPrint;

  /// No description provided for @printAuditActionShare.
  ///
  /// In ar, this message translates to:
  /// **'مشاركة PDF'**
  String get printAuditActionShare;

  /// No description provided for @printAuditStatusRequested.
  ///
  /// In ar, this message translates to:
  /// **'قيد الطلب'**
  String get printAuditStatusRequested;

  /// No description provided for @printAuditStatusCompleted.
  ///
  /// In ar, this message translates to:
  /// **'مكتمل'**
  String get printAuditStatusCompleted;

  /// No description provided for @printAuditStatusCanceled.
  ///
  /// In ar, this message translates to:
  /// **'ملغى'**
  String get printAuditStatusCanceled;

  /// No description provided for @printAuditStatusFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل'**
  String get printAuditStatusFailed;

  /// No description provided for @printAuditUnknownActor.
  ///
  /// In ar, this message translates to:
  /// **'مستخدم غير معروف'**
  String get printAuditUnknownActor;

  /// Print audit event time.
  ///
  /// In ar, this message translates to:
  /// **'الوقت {time}'**
  String printAuditTimeValue(String time);

  /// Print audit event actor.
  ///
  /// In ar, this message translates to:
  /// **'المنفذ {actor}'**
  String printAuditActorValue(String actor);

  /// Print audit event device.
  ///
  /// In ar, this message translates to:
  /// **'الجهاز {device}'**
  String printAuditDeviceValue(String device);

  /// Print audit event printer.
  ///
  /// In ar, this message translates to:
  /// **'الطابعة {printer}'**
  String printAuditPrinterValue(String printer);

  /// Print audit event delivery channel.
  ///
  /// In ar, this message translates to:
  /// **'القناة {channel}'**
  String printAuditChannelValue(String channel);

  /// Print audit event printer endpoint.
  ///
  /// In ar, this message translates to:
  /// **'نقطة الاتصال {endpoint}'**
  String printAuditEndpointValue(String endpoint);

  /// Print job id in audit event.
  ///
  /// In ar, this message translates to:
  /// **'مهمة الطباعة #{jobId}'**
  String printAuditJobValue(int jobId);

  /// Print audit event message.
  ///
  /// In ar, this message translates to:
  /// **'الرسالة {message}'**
  String printAuditMessageValue(String message);

  /// No description provided for @printAuditChannelNativeShare.
  ///
  /// In ar, this message translates to:
  /// **'ورقة المشاركة'**
  String get printAuditChannelNativeShare;

  /// No description provided for @printAuditChannelFileSave.
  ///
  /// In ar, this message translates to:
  /// **'حفظ ملف'**
  String get printAuditChannelFileSave;

  /// No description provided for @printAuditChannelBrowserDownload.
  ///
  /// In ar, this message translates to:
  /// **'تنزيل المتصفح'**
  String get printAuditChannelBrowserDownload;

  /// No description provided for @confirmButton.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد'**
  String get confirmButton;

  /// No description provided for @saveButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ'**
  String get saveButton;

  /// No description provided for @accountantRoleLabel.
  ///
  /// In ar, this message translates to:
  /// **'محاسب'**
  String get accountantRoleLabel;

  /// No description provided for @employeesDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'الموظفون والرواتب'**
  String get employeesDrawerLabel;

  /// No description provided for @employeePayrollTitle.
  ///
  /// In ar, this message translates to:
  /// **'الموظفون والرواتب'**
  String get employeePayrollTitle;

  /// No description provided for @refreshEmployeePayrollTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث الموظفين والرواتب'**
  String get refreshEmployeePayrollTooltip;

  /// No description provided for @employeePayrollOverviewTitle.
  ///
  /// In ar, this message translates to:
  /// **'إدارة الموظفين والرواتب'**
  String get employeePayrollOverviewTitle;

  /// No description provided for @employeePayrollOverviewSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'سجلات الموظفين وخطط الأجر ومسيرات الرواتب'**
  String get employeePayrollOverviewSubtitle;

  /// No description provided for @payrollHomeTabLabel.
  ///
  /// In ar, this message translates to:
  /// **'الرواتب'**
  String get payrollHomeTabLabel;

  /// Monthly payroll workflow card title.
  ///
  /// In ar, this message translates to:
  /// **'رواتب {month}'**
  String payrollMonthCardTitle(String month);

  /// No description provided for @payrollMonthStepPrepare.
  ///
  /// In ar, this message translates to:
  /// **'تجهيز'**
  String get payrollMonthStepPrepare;

  /// No description provided for @payrollMonthStepApprove.
  ///
  /// In ar, this message translates to:
  /// **'اعتماد'**
  String get payrollMonthStepApprove;

  /// No description provided for @payrollMonthStepPay.
  ///
  /// In ar, this message translates to:
  /// **'دفع'**
  String get payrollMonthStepPay;

  /// No description provided for @payrollMonthNoRunMessage.
  ///
  /// In ar, this message translates to:
  /// **'لم يتم تجهيز مسير رواتب هذا الشهر بعد.'**
  String get payrollMonthNoRunMessage;

  /// No description provided for @payrollMonthDraftMessage.
  ///
  /// In ar, this message translates to:
  /// **'المسير جاهز للمراجعة والاعتماد.'**
  String get payrollMonthDraftMessage;

  /// No description provided for @payrollMonthApprovedMessage.
  ///
  /// In ar, this message translates to:
  /// **'المسير معتمد وبانتظار تسجيل الدفع.'**
  String get payrollMonthApprovedMessage;

  /// No description provided for @payrollMonthPaidMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم دفع رواتب هذا الشهر.'**
  String get payrollMonthPaidMessage;

  /// No description provided for @payrollMonthOnboardingMessage.
  ///
  /// In ar, this message translates to:
  /// **'أضف موظفيك وحدد خطط رواتبهم لبدء تجهيز مسيرات الرواتب.'**
  String get payrollMonthOnboardingMessage;

  /// No description provided for @preparePayrollMonthButton.
  ///
  /// In ar, this message translates to:
  /// **'تجهيز رواتب الشهر'**
  String get preparePayrollMonthButton;

  /// No description provided for @reviewAndApprovePayrollButton.
  ///
  /// In ar, this message translates to:
  /// **'مراجعة واعتماد'**
  String get reviewAndApprovePayrollButton;

  /// No description provided for @recordPayrollPaymentButton.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الدفع'**
  String get recordPayrollPaymentButton;

  /// No description provided for @viewPayrollRunButton.
  ///
  /// In ar, this message translates to:
  /// **'عرض المسير'**
  String get viewPayrollRunButton;

  /// No description provided for @customPayrollRunButton.
  ///
  /// In ar, this message translates to:
  /// **'مسير مخصص'**
  String get customPayrollRunButton;

  /// No description provided for @payrollHistoryTitle.
  ///
  /// In ar, this message translates to:
  /// **'سجل المسيرات'**
  String get payrollHistoryTitle;

  /// No description provided for @pendingLoanRequestsTitle.
  ///
  /// In ar, this message translates to:
  /// **'طلبات سلف بانتظار قرارك'**
  String get pendingLoanRequestsTitle;

  /// No description provided for @employeeLoanApproveButton.
  ///
  /// In ar, this message translates to:
  /// **'موافقة'**
  String get employeeLoanApproveButton;

  /// No description provided for @employeeLoanRejectButton.
  ///
  /// In ar, this message translates to:
  /// **'رفض'**
  String get employeeLoanRejectButton;

  /// No description provided for @showAllLoansButton.
  ///
  /// In ar, this message translates to:
  /// **'عرض كل السلف'**
  String get showAllLoansButton;

  /// No description provided for @approvePayrollConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'اعتماد مسير الرواتب؟'**
  String get approvePayrollConfirmTitle;

  /// Approve payroll run confirmation body.
  ///
  /// In ar, this message translates to:
  /// **'سيتم اعتماد رواتب {employees} بإجمالي صافي {amount}. لا يمكن تعديل البنود بعد الاعتماد.'**
  String approvePayrollConfirmMessage(String employees, String amount);

  /// No description provided for @approvePayrollConfirmButton.
  ///
  /// In ar, this message translates to:
  /// **'اعتماد'**
  String get approvePayrollConfirmButton;

  /// No description provided for @markPayrollPaidConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل دفع الرواتب؟'**
  String get markPayrollPaidConfirmTitle;

  /// Mark payroll paid confirmation body.
  ///
  /// In ar, this message translates to:
  /// **'سيتم تسجيل المسير كمدفوع بإجمالي {amount}، وستُخصم أقساط السلف المرتبطة تلقائيًا.'**
  String markPayrollPaidConfirmMessage(String amount);

  /// No description provided for @markPayrollPaidConfirmButton.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الدفع'**
  String get markPayrollPaidConfirmButton;

  /// Payroll line additions chip.
  ///
  /// In ar, this message translates to:
  /// **'إضافات {amount}'**
  String payrollAdditionsChipLabel(String amount);

  /// Payroll line deductions chip.
  ///
  /// In ar, this message translates to:
  /// **'خصومات {amount}'**
  String payrollDeductionsChipLabel(String amount);

  /// Payroll line absence chip.
  ///
  /// In ar, this message translates to:
  /// **'غياب {days} يوم'**
  String payrollAbsenceChipLabel(String days);

  /// Payroll line overtime chip showing hours and pay.
  ///
  /// In ar, this message translates to:
  /// **'إضافي {hours} س ({amount})'**
  String payrollOvertimeChipLabel(String hours, String amount);

  /// No description provided for @payrollLineOvertimePayLabel.
  ///
  /// In ar, this message translates to:
  /// **'أجر العمل الإضافي'**
  String get payrollLineOvertimePayLabel;

  /// No description provided for @overtimeHoursField.
  ///
  /// In ar, this message translates to:
  /// **'ساعات العمل الإضافي'**
  String get overtimeHoursField;

  /// Helper under the overtime hours field showing hourly rate and multiplier.
  ///
  /// In ar, this message translates to:
  /// **'تُحتسب تلقائيًا: {rate} للساعة × {multiplier}'**
  String overtimeHoursHelper(String rate, String multiplier);

  /// No description provided for @overtimeMultiplierField.
  ///
  /// In ar, this message translates to:
  /// **'معامل الأجر الإضافي'**
  String get overtimeMultiplierField;

  /// No description provided for @overtimeMultiplierHelper.
  ///
  /// In ar, this message translates to:
  /// **'مثال: 1.50 يعني أجر الساعة الإضافية = 1.5 ضعف الأجر العادي'**
  String get overtimeMultiplierHelper;

  /// No description provided for @standardDailyHoursField.
  ///
  /// In ar, this message translates to:
  /// **'ساعات العمل اليومية'**
  String get standardDailyHoursField;

  /// No description provided for @standardDailyHoursHelper.
  ///
  /// In ar, this message translates to:
  /// **'تُستخدم لاحتساب أجر الساعة الواحدة'**
  String get standardDailyHoursHelper;

  /// No description provided for @payrollLineTapToAdjustHint.
  ///
  /// In ar, this message translates to:
  /// **'اضغط على موظف لتعديل غيابه وعمله الإضافي وإضافاته وخصوماته.'**
  String get payrollLineTapToAdjustHint;

  /// No description provided for @employeeNoPlanWarning.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد خطة راتب'**
  String get employeeNoPlanWarning;

  /// No description provided for @employeeCompensationButton.
  ///
  /// In ar, this message translates to:
  /// **'خطة الراتب'**
  String get employeeCompensationButton;

  /// No description provided for @addEmployeeButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة موظف'**
  String get addEmployeeButton;

  /// No description provided for @draftMonthlyPayrollButton.
  ///
  /// In ar, this message translates to:
  /// **'مسودة رواتب الشهر'**
  String get draftMonthlyPayrollButton;

  /// No description provided for @createPayrollRunButton.
  ///
  /// In ar, this message translates to:
  /// **'إنشاء مسير رواتب'**
  String get createPayrollRunButton;

  /// No description provided for @employeePayrollSaveError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ التغيير. راجع البيانات والصلاحيات ثم حاول مرة أخرى.'**
  String get employeePayrollSaveError;

  /// No description provided for @employeesTabLabel.
  ///
  /// In ar, this message translates to:
  /// **'الموظفون'**
  String get employeesTabLabel;

  /// No description provided for @payrollRunsTabLabel.
  ///
  /// In ar, this message translates to:
  /// **'مسيرات الرواتب'**
  String get payrollRunsTabLabel;

  /// No description provided for @employeeLoansTabLabel.
  ///
  /// In ar, this message translates to:
  /// **'طلبات السلفة'**
  String get employeeLoansTabLabel;

  /// No description provided for @employeesLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل الموظفين.'**
  String get employeesLoadError;

  /// No description provided for @emptyEmployees.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد سجلات موظفين بعد.'**
  String get emptyEmployees;

  /// Employee linked system user label.
  ///
  /// In ar, this message translates to:
  /// **'دخول للنظام: {username}'**
  String employeeSystemAccessLabel(String username);

  /// Active employee pay plan label.
  ///
  /// In ar, this message translates to:
  /// **'{payType} - {amount}'**
  String employeePayPlanLabel(String payType, String amount);

  /// Active employee pay plan label with sales commission.
  ///
  /// In ar, this message translates to:
  /// **'{baseLabel} + {percent}% مبيعات'**
  String employeePayPlanWithCommissionLabel(String baseLabel, String percent);

  /// Active employee monthly fixed salary label.
  ///
  /// In ar, this message translates to:
  /// **'راتب شهري ثابت - {amount}'**
  String employeeMonthlyFixedPlanLabel(String amount);

  /// Active employee commission-only salary label.
  ///
  /// In ar, this message translates to:
  /// **'عمولة مبيعات فقط - {percent}%'**
  String employeeCommissionOnlyPlanLabel(String percent);

  /// Active employee monthly fixed plus sales commission salary label.
  ///
  /// In ar, this message translates to:
  /// **'راتب شهري ثابت {amount} + {percent}% مبيعات'**
  String employeeMonthlyFixedPlusCommissionPlanLabel(
      String amount, String percent);

  /// Active employee unit-based compensation plan label.
  ///
  /// In ar, this message translates to:
  /// **'{salaryType} - {amount} × {units}'**
  String employeeUnitBasedPlanLabel(
      String salaryType, String amount, String units);

  /// No description provided for @employeeNoDetails.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد تفاصيل إضافية'**
  String get employeeNoDetails;

  /// No description provided for @addCompensationPlanTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إضافة خطة أجر'**
  String get addCompensationPlanTooltip;

  /// No description provided for @payrollRunsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل مسيرات الرواتب.'**
  String get payrollRunsLoadError;

  /// No description provided for @emptyPayrollRuns.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مسيرات رواتب بعد.'**
  String get emptyPayrollRuns;

  /// No description provided for @employeeLoansLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل طلبات السلفة.'**
  String get employeeLoansLoadError;

  /// No description provided for @emptyEmployeeLoans.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد طلبات سلفة بعد.'**
  String get emptyEmployeeLoans;

  /// No description provided for @employeeLoanStatusRequested.
  ///
  /// In ar, this message translates to:
  /// **'بانتظار الاعتماد'**
  String get employeeLoanStatusRequested;

  /// No description provided for @employeeLoanStatusApproved.
  ///
  /// In ar, this message translates to:
  /// **'معتمد'**
  String get employeeLoanStatusApproved;

  /// No description provided for @employeeLoanStatusRejected.
  ///
  /// In ar, this message translates to:
  /// **'مرفوض'**
  String get employeeLoanStatusRejected;

  /// No description provided for @employeeLoanStatusCancelled.
  ///
  /// In ar, this message translates to:
  /// **'ملغي'**
  String get employeeLoanStatusCancelled;

  /// No description provided for @employeeLoanStatusPaid.
  ///
  /// In ar, this message translates to:
  /// **'مسدد'**
  String get employeeLoanStatusPaid;

  /// Employee loan amount detail.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ {amount}'**
  String employeeLoanAmountDetail(String amount);

  /// Employee loan monthly deduction detail.
  ///
  /// In ar, this message translates to:
  /// **'شهريًا {amount}'**
  String employeeLoanMonthlyDeductionDetail(String amount);

  /// No description provided for @approveEmployeeLoanTooltip.
  ///
  /// In ar, this message translates to:
  /// **'اعتماد طلب السلفة'**
  String get approveEmployeeLoanTooltip;

  /// No description provided for @rejectEmployeeLoanTooltip.
  ///
  /// In ar, this message translates to:
  /// **'رفض طلب السلفة'**
  String get rejectEmployeeLoanTooltip;

  /// Payroll run employee line count.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا موظفين} =1{موظف واحد} =2{موظفان} other{{count} موظفين}}'**
  String payrollLineCount(num count);

  /// Payroll period range.
  ///
  /// In ar, this message translates to:
  /// **'{start} إلى {end}'**
  String payrollPeriodSubtitle(String start, String end);

  /// No description provided for @payrollRunDetailsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'عرض تفاصيل المسير'**
  String get payrollRunDetailsTooltip;

  /// Payroll run details sheet title.
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل مسير {runNumber}'**
  String payrollRunDetailsTitle(String runNumber);

  /// No description provided for @payrollRunDetailsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل تفاصيل مسير الرواتب.'**
  String get payrollRunDetailsLoadError;

  /// No description provided for @payrollRunSummarySection.
  ///
  /// In ar, this message translates to:
  /// **'ملخص المسير'**
  String get payrollRunSummarySection;

  /// No description provided for @payrollRunEmployeesSection.
  ///
  /// In ar, this message translates to:
  /// **'الموظفون في المسير'**
  String get payrollRunEmployeesSection;

  /// No description provided for @payrollRunGrossTotalLabel.
  ///
  /// In ar, this message translates to:
  /// **'الإجمالي الأساسي'**
  String get payrollRunGrossTotalLabel;

  /// No description provided for @payrollRunAdditionsTotalLabel.
  ///
  /// In ar, this message translates to:
  /// **'الإضافات'**
  String get payrollRunAdditionsTotalLabel;

  /// No description provided for @payrollRunDeductionsTotalLabel.
  ///
  /// In ar, this message translates to:
  /// **'الخصومات'**
  String get payrollRunDeductionsTotalLabel;

  /// No description provided for @payrollRunNetTotalLabel.
  ///
  /// In ar, this message translates to:
  /// **'الصافي'**
  String get payrollRunNetTotalLabel;

  /// No description provided for @payrollRunPeriodLabel.
  ///
  /// In ar, this message translates to:
  /// **'الفترة'**
  String get payrollRunPeriodLabel;

  /// No description provided for @payrollRunPaymentDateLabel.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الدفع'**
  String get payrollRunPaymentDateLabel;

  /// No description provided for @payrollRunNotesLabel.
  ///
  /// In ar, this message translates to:
  /// **'الملاحظات'**
  String get payrollRunNotesLabel;

  /// No description provided for @payrollRunNoNotes.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد ملاحظات'**
  String get payrollRunNoNotes;

  /// No description provided for @payrollRunCreatedAtLabel.
  ///
  /// In ar, this message translates to:
  /// **'أُنشئ في'**
  String get payrollRunCreatedAtLabel;

  /// No description provided for @payrollRunApprovedByLabel.
  ///
  /// In ar, this message translates to:
  /// **'اعتمده'**
  String get payrollRunApprovedByLabel;

  /// No description provided for @payrollRunPaidByLabel.
  ///
  /// In ar, this message translates to:
  /// **'سجله كمدفوع'**
  String get payrollRunPaidByLabel;

  /// Payroll actor and timestamp detail.
  ///
  /// In ar, this message translates to:
  /// **'{actor} - {date}'**
  String payrollRunActorWithDate(String actor, String date);

  /// No description provided for @payrollRunNoEmployees.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد بنود موظفين في هذا المسير.'**
  String get payrollRunNoEmployees;

  /// No description provided for @payrollBulkAdjustmentButton.
  ///
  /// In ar, this message translates to:
  /// **'تعديل جماعي للرواتب'**
  String get payrollBulkAdjustmentButton;

  /// No description provided for @payrollBulkAdjustmentTitle.
  ///
  /// In ar, this message translates to:
  /// **'تعديل جماعي للرواتب'**
  String get payrollBulkAdjustmentTitle;

  /// No description provided for @payrollBulkAdjustmentSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'اختر الموظفين وأدخل مبلغًا يطبق على كل موظف محدد.'**
  String get payrollBulkAdjustmentSubtitle;

  /// No description provided for @payrollBulkAdjustmentAmountLabel.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ لكل موظف'**
  String get payrollBulkAdjustmentAmountLabel;

  /// No description provided for @payrollBulkAdjustmentAmountHelper.
  ///
  /// In ar, this message translates to:
  /// **'سيطبق نفس المبلغ على كل موظف محدد.'**
  String get payrollBulkAdjustmentAmountHelper;

  /// No description provided for @payrollBulkAdjustmentNotesLabel.
  ///
  /// In ar, this message translates to:
  /// **'ملاحظات التعديل'**
  String get payrollBulkAdjustmentNotesLabel;

  /// No description provided for @payrollBulkSelectionSection.
  ///
  /// In ar, this message translates to:
  /// **'الموظفون المحددون'**
  String get payrollBulkSelectionSection;

  /// No description provided for @payrollBulkSelectAllEmployees.
  ///
  /// In ar, this message translates to:
  /// **'اختيار كل موظفي المسير'**
  String get payrollBulkSelectAllEmployees;

  /// Selected payroll line count in the bulk adjustment sheet.
  ///
  /// In ar, this message translates to:
  /// **'{selected} من {total} محددين'**
  String payrollBulkSelectedCount(int selected, int total);

  /// No description provided for @payrollBulkNoEmployeesSelected.
  ///
  /// In ar, this message translates to:
  /// **'اختر موظفًا واحدًا على الأقل.'**
  String get payrollBulkNoEmployeesSelected;

  /// No description provided for @payrollBulkPositiveAmountError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل مبلغًا أكبر من صفر.'**
  String get payrollBulkPositiveAmountError;

  /// No description provided for @payrollBulkSelectedEmployeesLabel.
  ///
  /// In ar, this message translates to:
  /// **'الموظفون'**
  String get payrollBulkSelectedEmployeesLabel;

  /// No description provided for @payrollBulkAmountPerEmployeeLabel.
  ///
  /// In ar, this message translates to:
  /// **'لكل موظف'**
  String get payrollBulkAmountPerEmployeeLabel;

  /// No description provided for @payrollBulkTotalAdditionLabel.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الإضافة'**
  String get payrollBulkTotalAdditionLabel;

  /// No description provided for @payrollBulkTotalDeductionLabel.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الخصم'**
  String get payrollBulkTotalDeductionLabel;

  /// No description provided for @payrollBulkAdjustmentSaveButton.
  ///
  /// In ar, this message translates to:
  /// **'تطبيق على المحددين'**
  String get payrollBulkAdjustmentSaveButton;

  /// No description provided for @payrollBulkAdjustmentSaveError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تطبيق التعديل الجماعي.'**
  String get payrollBulkAdjustmentSaveError;

  /// No description provided for @payrollLineManualPayLabel.
  ///
  /// In ar, this message translates to:
  /// **'أجر يدوي'**
  String get payrollLineManualPayLabel;

  /// No description provided for @editPayrollLineAdjustmentsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تعديل غياب وإضافات الموظف'**
  String get editPayrollLineAdjustmentsTooltip;

  /// Payroll line adjustment sheet title.
  ///
  /// In ar, this message translates to:
  /// **'تعديل راتب {employee}'**
  String payrollLineAdjustmentTitle(String employee);

  /// No description provided for @payrollLineAdjustmentSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'أدخل الغياب أو الزيادة أو أي إضافة وخصم يدوي لهذا المسير فقط.'**
  String get payrollLineAdjustmentSubtitle;

  /// No description provided for @absenceDaysField.
  ///
  /// In ar, this message translates to:
  /// **'أيام الغياب'**
  String get absenceDaysField;

  /// Absence days helper with calculated daily rate.
  ///
  /// In ar, this message translates to:
  /// **'يُحسب الخصم تلقائيًا حسب قيمة اليوم: {rate}'**
  String absenceDaysHelper(String rate);

  /// Shown when absence days exceed payroll period days.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكن أن تتجاوز أيام الغياب {days} يومًا.'**
  String absenceDaysExceedPeriodError(int days);

  /// No description provided for @raiseAmountField.
  ///
  /// In ar, this message translates to:
  /// **'زيادة هذا الشهر'**
  String get raiseAmountField;

  /// No description provided for @raiseAmountHelper.
  ///
  /// In ar, this message translates to:
  /// **'مبلغ إضافي مؤقت يُضاف لصافي هذا الموظف في هذا المسير.'**
  String get raiseAmountHelper;

  /// No description provided for @manualAdditionAmountField.
  ///
  /// In ar, this message translates to:
  /// **'إضافة يدوية'**
  String get manualAdditionAmountField;

  /// No description provided for @manualAdditionAmountHelper.
  ///
  /// In ar, this message translates to:
  /// **'أي مبلغ إضافي يقرره المدير لهذا الموظف.'**
  String get manualAdditionAmountHelper;

  /// No description provided for @manualDeductionAmountField.
  ///
  /// In ar, this message translates to:
  /// **'خصم يدوي'**
  String get manualDeductionAmountField;

  /// No description provided for @manualDeductionAmountHelper.
  ///
  /// In ar, this message translates to:
  /// **'أي مبلغ خصم إضافي يقرره المدير لهذا الموظف.'**
  String get manualDeductionAmountHelper;

  /// No description provided for @payrollAdjustmentPreviewSection.
  ///
  /// In ar, this message translates to:
  /// **'المجموع المتوقع'**
  String get payrollAdjustmentPreviewSection;

  /// No description provided for @payrollLineProjectedNetLabel.
  ///
  /// In ar, this message translates to:
  /// **'الصافي المتوقع'**
  String get payrollLineProjectedNetLabel;

  /// No description provided for @payrollLineAdjustmentSaveButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ التعديل'**
  String get payrollLineAdjustmentSaveButton;

  /// No description provided for @payrollLineAdjustmentSaveError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ تعديل راتب الموظف.'**
  String get payrollLineAdjustmentSaveError;

  /// No description provided for @negativeNetPayrollLineError.
  ///
  /// In ar, this message translates to:
  /// **'الصافي المتوقع لا يمكن أن يكون أقل من صفر.'**
  String get negativeNetPayrollLineError;

  /// Fallback payroll employee label.
  ///
  /// In ar, this message translates to:
  /// **'موظف #{id}'**
  String payrollEmployeeFallbackLabel(int id);

  /// No description provided for @payrollLineUnitsLabel.
  ///
  /// In ar, this message translates to:
  /// **'الوحدات'**
  String get payrollLineUnitsLabel;

  /// No description provided for @payrollLineRateLabel.
  ///
  /// In ar, this message translates to:
  /// **'الأجر'**
  String get payrollLineRateLabel;

  /// No description provided for @payrollLineGrossLabel.
  ///
  /// In ar, this message translates to:
  /// **'الأساسي'**
  String get payrollLineGrossLabel;

  /// No description provided for @payrollLineAbsenceDaysLabel.
  ///
  /// In ar, this message translates to:
  /// **'أيام الغياب'**
  String get payrollLineAbsenceDaysLabel;

  /// No description provided for @payrollLineAbsenceDeductionLabel.
  ///
  /// In ar, this message translates to:
  /// **'خصم الغياب'**
  String get payrollLineAbsenceDeductionLabel;

  /// No description provided for @payrollLineRaiseLabel.
  ///
  /// In ar, this message translates to:
  /// **'الزيادة'**
  String get payrollLineRaiseLabel;

  /// No description provided for @payrollLineAdditionsLabel.
  ///
  /// In ar, this message translates to:
  /// **'الإضافات'**
  String get payrollLineAdditionsLabel;

  /// No description provided for @payrollLineDeductionsLabel.
  ///
  /// In ar, this message translates to:
  /// **'الخصومات'**
  String get payrollLineDeductionsLabel;

  /// No description provided for @payrollLineNetLabel.
  ///
  /// In ar, this message translates to:
  /// **'الصافي'**
  String get payrollLineNetLabel;

  /// No description provided for @payrollLineDescriptionLabel.
  ///
  /// In ar, this message translates to:
  /// **'الوصف'**
  String get payrollLineDescriptionLabel;

  /// No description provided for @payrollLineNotesLabel.
  ///
  /// In ar, this message translates to:
  /// **'ملاحظات البند'**
  String get payrollLineNotesLabel;

  /// No description provided for @payrollLineAdjustmentsLabel.
  ///
  /// In ar, this message translates to:
  /// **'التعديلات'**
  String get payrollLineAdjustmentsLabel;

  /// Compact payroll line amount detail.
  ///
  /// In ar, this message translates to:
  /// **'{label}: {value}'**
  String payrollLineAmountDetail(String label, String value);

  /// Payroll adjustment direction and type label.
  ///
  /// In ar, this message translates to:
  /// **'{direction} - {type}'**
  String payrollAdjustmentDetailLabel(String direction, String type);

  /// Payroll adjustment amount with notes.
  ///
  /// In ar, this message translates to:
  /// **'{amount} - {notes}'**
  String payrollAdjustmentAmountWithNotes(String amount, String notes);

  /// No description provided for @payrollAdjustmentAddition.
  ///
  /// In ar, this message translates to:
  /// **'إضافة'**
  String get payrollAdjustmentAddition;

  /// No description provided for @payrollAdjustmentDeduction.
  ///
  /// In ar, this message translates to:
  /// **'خصم'**
  String get payrollAdjustmentDeduction;

  /// No description provided for @payrollAdjustmentBonus.
  ///
  /// In ar, this message translates to:
  /// **'مكافأة'**
  String get payrollAdjustmentBonus;

  /// No description provided for @payrollAdjustmentCommission.
  ///
  /// In ar, this message translates to:
  /// **'عمولة'**
  String get payrollAdjustmentCommission;

  /// No description provided for @payrollAdjustmentOvertime.
  ///
  /// In ar, this message translates to:
  /// **'وقت إضافي'**
  String get payrollAdjustmentOvertime;

  /// No description provided for @payrollAdjustmentReimbursement.
  ///
  /// In ar, this message translates to:
  /// **'تعويض'**
  String get payrollAdjustmentReimbursement;

  /// No description provided for @payrollAdjustmentAdvance.
  ///
  /// In ar, this message translates to:
  /// **'سلفة'**
  String get payrollAdjustmentAdvance;

  /// No description provided for @payrollAdjustmentLoan.
  ///
  /// In ar, this message translates to:
  /// **'خصم سلفة'**
  String get payrollAdjustmentLoan;

  /// No description provided for @payrollAdjustmentAbsence.
  ///
  /// In ar, this message translates to:
  /// **'غياب'**
  String get payrollAdjustmentAbsence;

  /// No description provided for @payrollAdjustmentPenalty.
  ///
  /// In ar, this message translates to:
  /// **'جزاء'**
  String get payrollAdjustmentPenalty;

  /// No description provided for @payrollAdjustmentOther.
  ///
  /// In ar, this message translates to:
  /// **'تعديل آخر'**
  String get payrollAdjustmentOther;

  /// No description provided for @approvePayrollRunTooltip.
  ///
  /// In ar, this message translates to:
  /// **'اعتماد مسير الرواتب'**
  String get approvePayrollRunTooltip;

  /// No description provided for @markPayrollRunPaidTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل المسير كمدفوع'**
  String get markPayrollRunPaidTooltip;

  /// No description provided for @missingDateLabel.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ غير محدد'**
  String get missingDateLabel;

  /// No description provided for @employeeNameField.
  ///
  /// In ar, this message translates to:
  /// **'اسم الموظف'**
  String get employeeNameField;

  /// No description provided for @employeeJobTitleField.
  ///
  /// In ar, this message translates to:
  /// **'المسمى الوظيفي'**
  String get employeeJobTitleField;

  /// No description provided for @employeeDepartmentField.
  ///
  /// In ar, this message translates to:
  /// **'القسم'**
  String get employeeDepartmentField;

  /// No description provided for @employeePhoneField.
  ///
  /// In ar, this message translates to:
  /// **'الهاتف'**
  String get employeePhoneField;

  /// No description provided for @employeeHireDateField.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ التعيين'**
  String get employeeHireDateField;

  /// No description provided for @employeeUserField.
  ///
  /// In ar, this message translates to:
  /// **'مستخدم نقطة البيع'**
  String get employeeUserField;

  /// No description provided for @employeeUserEmpty.
  ///
  /// In ar, this message translates to:
  /// **'غير مرتبط بمستخدم'**
  String get employeeUserEmpty;

  /// No description provided for @employeeUserHelper.
  ///
  /// In ar, this message translates to:
  /// **'اربط الموظف بمستخدم إذا كان يعمل على النظام مثل الكاشير.'**
  String get employeeUserHelper;

  /// No description provided for @employeeUserClearTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إزالة المستخدم المرتبط'**
  String get employeeUserClearTooltip;

  /// No description provided for @employeeUserOpenPickerTooltip.
  ///
  /// In ar, this message translates to:
  /// **'اختيار مستخدم'**
  String get employeeUserOpenPickerTooltip;

  /// No description provided for @employeeUserPickerTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختيار مستخدم'**
  String get employeeUserPickerTitle;

  /// No description provided for @employeeUserPickerSearchHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث باسم المستخدم أو البريد'**
  String get employeeUserPickerSearchHint;

  /// No description provided for @employeeUserPickerEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مستخدمون مطابقون.'**
  String get employeeUserPickerEmpty;

  /// No description provided for @employeeUserPickerClear.
  ///
  /// In ar, this message translates to:
  /// **'مسح الاختيار'**
  String get employeeUserPickerClear;

  /// No description provided for @employeeUserPickerLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل المستخدمين.'**
  String get employeeUserPickerLoadError;

  /// Fallback label for a user id when the username is not loaded.
  ///
  /// In ar, this message translates to:
  /// **'مستخدم #{id}'**
  String userFallbackLabel(int id);

  /// No description provided for @employeeTypeField.
  ///
  /// In ar, this message translates to:
  /// **'نوع التوظيف'**
  String get employeeTypeField;

  /// No description provided for @employeeStatusActive.
  ///
  /// In ar, this message translates to:
  /// **'نشط'**
  String get employeeStatusActive;

  /// No description provided for @employeeStatusOnLeave.
  ///
  /// In ar, this message translates to:
  /// **'في إجازة'**
  String get employeeStatusOnLeave;

  /// No description provided for @employeeStatusInactive.
  ///
  /// In ar, this message translates to:
  /// **'متوقف'**
  String get employeeStatusInactive;

  /// No description provided for @employeeStatusTerminated.
  ///
  /// In ar, this message translates to:
  /// **'منتهي الخدمة'**
  String get employeeStatusTerminated;

  /// No description provided for @employmentTypeFullTime.
  ///
  /// In ar, this message translates to:
  /// **'دوام كامل'**
  String get employmentTypeFullTime;

  /// No description provided for @employmentTypePartTime.
  ///
  /// In ar, this message translates to:
  /// **'دوام جزئي'**
  String get employmentTypePartTime;

  /// No description provided for @employmentTypeContractor.
  ///
  /// In ar, this message translates to:
  /// **'متعاقد'**
  String get employmentTypeContractor;

  /// No description provided for @employmentTypeSeasonal.
  ///
  /// In ar, this message translates to:
  /// **'موسمي'**
  String get employmentTypeSeasonal;

  /// No description provided for @employmentTypeIntern.
  ///
  /// In ar, this message translates to:
  /// **'متدرب'**
  String get employmentTypeIntern;

  /// No description provided for @employmentTypeOther.
  ///
  /// In ar, this message translates to:
  /// **'آخر'**
  String get employmentTypeOther;

  /// Compensation plan sheet title.
  ///
  /// In ar, this message translates to:
  /// **'خطة أجر {employee}'**
  String addCompensationPlanTitle(String employee);

  /// No description provided for @payTypeField.
  ///
  /// In ar, this message translates to:
  /// **'نوع الأجر'**
  String get payTypeField;

  /// No description provided for @payAmountField.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ'**
  String get payAmountField;

  /// No description provided for @payUnitsField.
  ///
  /// In ar, this message translates to:
  /// **'الوحدات'**
  String get payUnitsField;

  /// No description provided for @payEffectiveFromField.
  ///
  /// In ar, this message translates to:
  /// **'يبدأ من'**
  String get payEffectiveFromField;

  /// No description provided for @salaryTypeField.
  ///
  /// In ar, this message translates to:
  /// **'نوع الراتب'**
  String get salaryTypeField;

  /// No description provided for @salaryTypeMonthlyFixed.
  ///
  /// In ar, this message translates to:
  /// **'راتب شهري ثابت'**
  String get salaryTypeMonthlyFixed;

  /// No description provided for @salaryTypeWeeklyFixed.
  ///
  /// In ar, this message translates to:
  /// **'أجر أسبوعي ثابت'**
  String get salaryTypeWeeklyFixed;

  /// No description provided for @salaryTypeDailyRate.
  ///
  /// In ar, this message translates to:
  /// **'أجر يومي'**
  String get salaryTypeDailyRate;

  /// No description provided for @salaryTypeHourlyRate.
  ///
  /// In ar, this message translates to:
  /// **'أجر بالساعة'**
  String get salaryTypeHourlyRate;

  /// No description provided for @salaryTypePerShift.
  ///
  /// In ar, this message translates to:
  /// **'أجر بالوردية'**
  String get salaryTypePerShift;

  /// No description provided for @salaryTypeSalesCommissionOnly.
  ///
  /// In ar, this message translates to:
  /// **'عمولة مبيعات فقط'**
  String get salaryTypeSalesCommissionOnly;

  /// No description provided for @salaryTypeMonthlyFixedPlusSalesCommission.
  ///
  /// In ar, this message translates to:
  /// **'راتب شهري + عمولة مبيعات'**
  String get salaryTypeMonthlyFixedPlusSalesCommission;

  /// No description provided for @salaryTypeContractFixed.
  ///
  /// In ar, this message translates to:
  /// **'مبلغ عقد ثابت'**
  String get salaryTypeContractFixed;

  /// No description provided for @salaryTypeCustomFixed.
  ///
  /// In ar, this message translates to:
  /// **'نوع مخصص'**
  String get salaryTypeCustomFixed;

  /// No description provided for @salaryTypeMonthlyFixedHelper.
  ///
  /// In ar, this message translates to:
  /// **'يدفع مبلغًا ثابتًا كل شهر دون احتساب عمولة مبيعات.'**
  String get salaryTypeMonthlyFixedHelper;

  /// No description provided for @salaryTypeWeeklyFixedHelper.
  ///
  /// In ar, this message translates to:
  /// **'يدفع مبلغًا ثابتًا لكل أسبوع. أدخل عدد الأسابيع المتوقع في مسير الشهر.'**
  String get salaryTypeWeeklyFixedHelper;

  /// No description provided for @salaryTypeDailyRateHelper.
  ///
  /// In ar, this message translates to:
  /// **'يدفع أجرًا لكل يوم عمل. أدخل عدد الأيام المتوقع في مسير الشهر.'**
  String get salaryTypeDailyRateHelper;

  /// No description provided for @salaryTypeHourlyRateHelper.
  ///
  /// In ar, this message translates to:
  /// **'يدفع أجرًا لكل ساعة. أدخل عدد الساعات المتوقع في مسير الشهر.'**
  String get salaryTypeHourlyRateHelper;

  /// No description provided for @salaryTypePerShiftHelper.
  ///
  /// In ar, this message translates to:
  /// **'يدفع أجرًا لكل وردية. أدخل عدد الورديات المتوقع في مسير الشهر.'**
  String get salaryTypePerShiftHelper;

  /// No description provided for @salaryTypeSalesCommissionOnlyHelper.
  ///
  /// In ar, this message translates to:
  /// **'يدفع نسبة من المبيعات المدفوعة للمستخدم المرتبط بالموظف فقط.'**
  String get salaryTypeSalesCommissionOnlyHelper;

  /// No description provided for @salaryTypeMonthlyFixedPlusSalesCommissionHelper.
  ///
  /// In ar, this message translates to:
  /// **'يدفع الراتب الشهري الثابت ويضيف نسبة من مبيعات المستخدم المرتبط.'**
  String get salaryTypeMonthlyFixedPlusSalesCommissionHelper;

  /// No description provided for @salaryTypeContractFixedHelper.
  ///
  /// In ar, this message translates to:
  /// **'يدفع مبلغ عقد ثابت في كل مسير رواتب إلى أن يتم تعطيل الخطة.'**
  String get salaryTypeContractFixedHelper;

  /// No description provided for @salaryTypeCustomFixedHelper.
  ///
  /// In ar, this message translates to:
  /// **'استخدمه عندما لا يناسب الموظف أي نوع جاهز. أضف ملاحظة توضّح طريقة الدفع.'**
  String get salaryTypeCustomFixedHelper;

  /// No description provided for @monthlyBaseSalaryField.
  ///
  /// In ar, this message translates to:
  /// **'الراتب الشهري الثابت'**
  String get monthlyBaseSalaryField;

  /// No description provided for @monthlyBaseSalaryHelper.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ الأساسي الذي يستحقه الموظف كل شهر.'**
  String get monthlyBaseSalaryHelper;

  /// No description provided for @compensationAmountField.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ'**
  String get compensationAmountField;

  /// No description provided for @weeklyAmountField.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ الأسبوعي'**
  String get weeklyAmountField;

  /// No description provided for @dailyRateField.
  ///
  /// In ar, this message translates to:
  /// **'الأجر اليومي'**
  String get dailyRateField;

  /// No description provided for @hourlyRateField.
  ///
  /// In ar, this message translates to:
  /// **'أجر الساعة'**
  String get hourlyRateField;

  /// No description provided for @shiftRateField.
  ///
  /// In ar, this message translates to:
  /// **'أجر الوردية'**
  String get shiftRateField;

  /// No description provided for @contractAmountField.
  ///
  /// In ar, this message translates to:
  /// **'مبلغ العقد'**
  String get contractAmountField;

  /// No description provided for @customAmountField.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ المخصص'**
  String get customAmountField;

  /// No description provided for @expectedUnitsPerPeriodField.
  ///
  /// In ar, this message translates to:
  /// **'الوحدات المتوقعة في الشهر'**
  String get expectedUnitsPerPeriodField;

  /// No description provided for @expectedWeeksPerPeriodHelper.
  ///
  /// In ar, this message translates to:
  /// **'عدد الأسابيع التي تُحتسب عادة في مسير الشهر.'**
  String get expectedWeeksPerPeriodHelper;

  /// No description provided for @expectedDaysPerPeriodHelper.
  ///
  /// In ar, this message translates to:
  /// **'عدد أيام العمل المتوقع احتسابها في مسير الشهر.'**
  String get expectedDaysPerPeriodHelper;

  /// No description provided for @expectedHoursPerPeriodHelper.
  ///
  /// In ar, this message translates to:
  /// **'عدد الساعات المتوقع احتسابها في مسير الشهر.'**
  String get expectedHoursPerPeriodHelper;

  /// No description provided for @expectedShiftsPerPeriodHelper.
  ///
  /// In ar, this message translates to:
  /// **'عدد الورديات المتوقع احتسابها في مسير الشهر.'**
  String get expectedShiftsPerPeriodHelper;

  /// No description provided for @compensationNotesField.
  ///
  /// In ar, this message translates to:
  /// **'ملاحظات طريقة الدفع'**
  String get compensationNotesField;

  /// No description provided for @compensationNotesHelper.
  ///
  /// In ar, this message translates to:
  /// **'اختياري، لكنه مفيد للأنواع المخصصة أو العقود.'**
  String get compensationNotesHelper;

  /// No description provided for @salesCommissionPercentField.
  ///
  /// In ar, this message translates to:
  /// **'نسبة عمولة المبيعات'**
  String get salesCommissionPercentField;

  /// No description provided for @salesCommissionPercentHelper.
  ///
  /// In ar, this message translates to:
  /// **'تُحسب من المبيعات المدفوعة للمستخدم المرتبط بالموظف.'**
  String get salesCommissionPercentHelper;

  /// No description provided for @baseSalaryRequiredError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل مبلغًا أكبر من صفر.'**
  String get baseSalaryRequiredError;

  /// No description provided for @expectedUnitsRequiredError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل عدد وحدات أكبر من صفر.'**
  String get expectedUnitsRequiredError;

  /// No description provided for @commissionRequiredError.
  ///
  /// In ar, this message translates to:
  /// **'أدخل نسبة عمولة أكبر من صفر.'**
  String get commissionRequiredError;

  /// No description provided for @salesCommissionNeedsLinkedUserWarning.
  ///
  /// In ar, this message translates to:
  /// **'عمولة المبيعات تحتاج ربط الموظف بمستخدم نقطة بيع حتى تُحسب المبيعات تلقائيًا.'**
  String get salesCommissionNeedsLinkedUserWarning;

  /// No description provided for @compensationPlanActivationNote.
  ///
  /// In ar, this message translates to:
  /// **'ستصبح هذه الخطة هي الراتب الحالي للموظف، وسيتم تعطيل الخطط النشطة السابقة.'**
  String get compensationPlanActivationNote;

  /// No description provided for @payTypeMonthlySalary.
  ///
  /// In ar, this message translates to:
  /// **'راتب شهري'**
  String get payTypeMonthlySalary;

  /// No description provided for @payTypeWeeklySalary.
  ///
  /// In ar, this message translates to:
  /// **'راتب أسبوعي'**
  String get payTypeWeeklySalary;

  /// No description provided for @payTypeDailyRate.
  ///
  /// In ar, this message translates to:
  /// **'أجر يومي'**
  String get payTypeDailyRate;

  /// No description provided for @payTypeHourly.
  ///
  /// In ar, this message translates to:
  /// **'أجر بالساعة'**
  String get payTypeHourly;

  /// No description provided for @payTypePerShift.
  ///
  /// In ar, this message translates to:
  /// **'أجر بالوردية'**
  String get payTypePerShift;

  /// No description provided for @payTypeCommission.
  ///
  /// In ar, this message translates to:
  /// **'عمولة'**
  String get payTypeCommission;

  /// No description provided for @payTypeContract.
  ///
  /// In ar, this message translates to:
  /// **'عقد'**
  String get payTypeContract;

  /// No description provided for @payTypeOther.
  ///
  /// In ar, this message translates to:
  /// **'آخر'**
  String get payTypeOther;

  /// No description provided for @noEmployeesWithPayPlan.
  ///
  /// In ar, this message translates to:
  /// **'أضف خطة أجر لموظف واحد على الأقل قبل إنشاء مسير رواتب.'**
  String get noEmployeesWithPayPlan;

  /// No description provided for @payrollEmployeeField.
  ///
  /// In ar, this message translates to:
  /// **'الموظف'**
  String get payrollEmployeeField;

  /// No description provided for @payrollPeriodStartField.
  ///
  /// In ar, this message translates to:
  /// **'بداية الفترة'**
  String get payrollPeriodStartField;

  /// No description provided for @payrollPeriodEndField.
  ///
  /// In ar, this message translates to:
  /// **'نهاية الفترة'**
  String get payrollPeriodEndField;

  /// No description provided for @payrollStatusDraft.
  ///
  /// In ar, this message translates to:
  /// **'مسودة'**
  String get payrollStatusDraft;

  /// No description provided for @payrollStatusApproved.
  ///
  /// In ar, this message translates to:
  /// **'معتمد'**
  String get payrollStatusApproved;

  /// No description provided for @payrollStatusPaid.
  ///
  /// In ar, this message translates to:
  /// **'مدفوع'**
  String get payrollStatusPaid;

  /// No description provided for @payrollStatusVoid.
  ///
  /// In ar, this message translates to:
  /// **'ملغى'**
  String get payrollStatusVoid;

  /// No description provided for @dashboardPayrollSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'الرواتب'**
  String get dashboardPayrollSectionTitle;

  /// No description provided for @dashboardProfitabilitySectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'الربحية بعد المصاريف'**
  String get dashboardProfitabilitySectionTitle;

  /// No description provided for @dashboardSalaryExpenseMetric.
  ///
  /// In ar, this message translates to:
  /// **'مصروف الرواتب'**
  String get dashboardSalaryExpenseMetric;

  /// No description provided for @dashboardPayrollPaidMetric.
  ///
  /// In ar, this message translates to:
  /// **'الرواتب المدفوعة'**
  String get dashboardPayrollPaidMetric;

  /// No description provided for @dashboardPayrollPendingMetric.
  ///
  /// In ar, this message translates to:
  /// **'رواتب معتمدة غير مدفوعة'**
  String get dashboardPayrollPendingMetric;

  /// No description provided for @dashboardActiveEmployeesMetric.
  ///
  /// In ar, this message translates to:
  /// **'موظفون نشطون'**
  String get dashboardActiveEmployeesMetric;

  /// No description provided for @dashboardRecentPayrollRunsTitle.
  ///
  /// In ar, this message translates to:
  /// **'آخر مسيرات الرواتب'**
  String get dashboardRecentPayrollRunsTitle;

  /// No description provided for @dashboardPaymentCommissionsMetric.
  ///
  /// In ar, this message translates to:
  /// **'عمولات الدفع'**
  String get dashboardPaymentCommissionsMetric;

  /// No description provided for @dashboardNetOperatingProfitMetric.
  ///
  /// In ar, this message translates to:
  /// **'صافي الربح التشغيلي'**
  String get dashboardNetOperatingProfitMetric;

  /// No description provided for @dashboardProfitFromSalesMetric.
  ///
  /// In ar, this message translates to:
  /// **'ربح المبيعات'**
  String get dashboardProfitFromSalesMetric;

  /// No description provided for @dashboardNetProfitMetric.
  ///
  /// In ar, this message translates to:
  /// **'صافي الربح'**
  String get dashboardNetProfitMetric;

  /// No description provided for @dashboardAfterExpensesCaption.
  ///
  /// In ar, this message translates to:
  /// **'بعد المصاريف'**
  String get dashboardAfterExpensesCaption;

  /// No description provided for @dashboardTopProductsByProfitTitle.
  ///
  /// In ar, this message translates to:
  /// **'أفضل المنتجات ربحًا'**
  String get dashboardTopProductsByProfitTitle;

  /// No description provided for @dashboardVsPreviousPeriodLabel.
  ///
  /// In ar, this message translates to:
  /// **'مقارنة بالفترة السابقة'**
  String get dashboardVsPreviousPeriodLabel;

  /// No description provided for @dashboardActionCenterTitle.
  ///
  /// In ar, this message translates to:
  /// **'يحتاج انتباهك'**
  String get dashboardActionCenterTitle;

  /// No description provided for @dashboardAllClearMessage.
  ///
  /// In ar, this message translates to:
  /// **'كل شيء تحت السيطرة — لا يوجد ما يتطلب تدخلك الآن.'**
  String get dashboardAllClearMessage;

  /// No description provided for @dashboardAlertOutOfStock.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{منتج واحد نفد من المخزون} =2{منتجان نفدا من المخزون} other{{count} منتجات نفدت من المخزون}}'**
  String dashboardAlertOutOfStock(int count);

  /// No description provided for @dashboardAlertLowStock.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{منتج واحد تحت حد إعادة الطلب} =2{منتجان تحت حد إعادة الطلب} other{{count} منتجات تحت حد إعادة الطلب}}'**
  String dashboardAlertLowStock(int count);

  /// No description provided for @dashboardAlertOverduePurchases.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{أمر شراء واحد متأخر السداد} =2{أمرا شراء متأخران عن السداد} other{{count} أوامر شراء متأخرة السداد}}'**
  String dashboardAlertOverduePurchases(int count);

  /// No description provided for @dashboardAlertRegisterVariance.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{جلسة درج واحدة بفرق نقدي} =2{جلستا درج بفرق نقدي} other{{count} جلسات درج بفروق نقدية}}'**
  String dashboardAlertRegisterVariance(int count);

  /// No description provided for @dashboardAlertDraftPayroll.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{مسير رواتب بانتظار الاعتماد} =2{مسيرا رواتب بانتظار الاعتماد} other{{count} مسيرات رواتب بانتظار الاعتماد}}'**
  String dashboardAlertDraftPayroll(int count);

  /// No description provided for @dashboardAlertPendingPayroll.
  ///
  /// In ar, this message translates to:
  /// **'رواتب معتمدة بانتظار تسجيل الدفع'**
  String get dashboardAlertPendingPayroll;

  /// No description provided for @dashboardAlertPendingLoans.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{طلب سلفة واحد بانتظار قرارك} =2{طلبا سلفة بانتظار قرارك} other{{count} طلبات سلف بانتظار قرارك}}'**
  String dashboardAlertPendingLoans(int count);

  /// No description provided for @dashboardAlertExpiringDiscounts.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{عرض خصم واحد ينتهي قريبًا} =2{عرضا خصم ينتهيان قريبًا} other{{count} عروض خصم تنتهي قريبًا}}'**
  String dashboardAlertExpiringDiscounts(int count);

  /// No description provided for @dashboardAlertPrintFailures.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{مهمة طباعة واحدة فشلت} =2{مهمتا طباعة فشلتا} other{{count} مهام طباعة فشلت}}'**
  String dashboardAlertPrintFailures(int count);

  /// No description provided for @integrityMonitorTitle.
  ///
  /// In ar, this message translates to:
  /// **'مركز النزاهة'**
  String get integrityMonitorTitle;

  /// No description provided for @integrityMonitorRefreshTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث نتائج المراقبة'**
  String get integrityMonitorRefreshTooltip;

  /// No description provided for @integrityMonitorLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل نتائج المراقبة.'**
  String get integrityMonitorLoadError;

  /// No description provided for @integrityMonitorActionError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ الإجراء. حاول مرة أخرى.'**
  String get integrityMonitorActionError;

  /// No description provided for @integrityMonitorAllClearTitle.
  ///
  /// In ar, this message translates to:
  /// **'كل شيء سليم'**
  String get integrityMonitorAllClearTitle;

  /// No description provided for @integrityMonitorAttentionTitle.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{حالة واحدة تحتاج مراجعتك} =2{حالتان تحتاجان مراجعتك} other{{count} حالات تحتاج مراجعتك}}'**
  String integrityMonitorAttentionTitle(int count);

  /// No description provided for @integrityMonitorSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'محرك المراقبة يعمل بصمت في الخلفية: يتحقق من كل إلغاء وإرجاع وفرق نقدي، ويقارن كل كاشير بزملائه دون أن يشعر أحد.'**
  String get integrityMonitorSubtitle;

  /// No description provided for @integrityMonitorActiveSection.
  ///
  /// In ar, this message translates to:
  /// **'حالات بانتظار قرارك'**
  String get integrityMonitorActiveSection;

  /// No description provided for @integrityMonitorSettledSection.
  ///
  /// In ar, this message translates to:
  /// **'حالات سابقة'**
  String get integrityMonitorSettledSection;

  /// No description provided for @integrityRiskScoreCaption.
  ///
  /// In ar, this message translates to:
  /// **'خطورة'**
  String get integrityRiskScoreCaption;

  /// No description provided for @integrityFindingWindowLabel.
  ///
  /// In ar, this message translates to:
  /// **'فترة الرصد'**
  String get integrityFindingWindowLabel;

  /// No description provided for @integrityFindingPatternCountLabel.
  ///
  /// In ar, this message translates to:
  /// **'عدد الأنماط المرصودة'**
  String get integrityFindingPatternCountLabel;

  /// No description provided for @integrityPeerComparisonTitle.
  ///
  /// In ar, this message translates to:
  /// **'مقارنة بالزملاء'**
  String get integrityPeerComparisonTitle;

  /// No description provided for @integrityUserRateLabel.
  ///
  /// In ar, this message translates to:
  /// **'معدل هذا الكاشير'**
  String get integrityUserRateLabel;

  /// No description provided for @integrityPeerMedianLabel.
  ///
  /// In ar, this message translates to:
  /// **'وسيط الزملاء'**
  String get integrityPeerMedianLabel;

  /// No description provided for @integrityThresholdLabel.
  ///
  /// In ar, this message translates to:
  /// **'حد الاشتباه'**
  String get integrityThresholdLabel;

  /// No description provided for @integrityEvidenceTitle.
  ///
  /// In ar, this message translates to:
  /// **'الأدلة المرصودة'**
  String get integrityEvidenceTitle;

  /// No description provided for @integrityOpenActivityLogButton.
  ///
  /// In ar, this message translates to:
  /// **'فتح سجل النشاط للتحقيق'**
  String get integrityOpenActivityLogButton;

  /// No description provided for @integrityNoteFieldLabel.
  ///
  /// In ar, this message translates to:
  /// **'ملاحظة القرار'**
  String get integrityNoteFieldLabel;

  /// No description provided for @integrityNoteFieldHelper.
  ///
  /// In ar, this message translates to:
  /// **'وثّق ما وجدته بعد المراجعة — تُحفظ في سجل التدقيق.'**
  String get integrityNoteFieldHelper;

  /// No description provided for @integrityReviewButton.
  ///
  /// In ar, this message translates to:
  /// **'تمت المراجعة'**
  String get integrityReviewButton;

  /// No description provided for @integrityDismissButton.
  ///
  /// In ar, this message translates to:
  /// **'تجاهل كإنذار كاذب'**
  String get integrityDismissButton;

  /// No description provided for @integrityReopenButton.
  ///
  /// In ar, this message translates to:
  /// **'إعادة فتح الحالة'**
  String get integrityReopenButton;

  /// No description provided for @integrityStatusActive.
  ///
  /// In ar, this message translates to:
  /// **'بانتظار المراجعة'**
  String get integrityStatusActive;

  /// No description provided for @integrityStatusResolved.
  ///
  /// In ar, this message translates to:
  /// **'زال تلقائيًا'**
  String get integrityStatusResolved;

  /// No description provided for @integrityStatusReviewed.
  ///
  /// In ar, this message translates to:
  /// **'تمت مراجعتها'**
  String get integrityStatusReviewed;

  /// No description provided for @integrityStatusDismissed.
  ///
  /// In ar, this message translates to:
  /// **'تم تجاهلها'**
  String get integrityStatusDismissed;

  /// No description provided for @integrityFindingNoteLabel.
  ///
  /// In ar, this message translates to:
  /// **'ملاحظة {user}: {note}'**
  String integrityFindingNoteLabel(String user, String note);

  /// No description provided for @dashboardAlertFraudFindings.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{حالة اشتباه واحدة تحتاج مراجعتك} =2{حالتا اشتباه تحتاجان مراجعتك} other{{count} حالات اشتباه تحتاج مراجعتك}}'**
  String dashboardAlertFraudFindings(int count);

  /// No description provided for @dashboardIntegritySectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'النزاهة والمراقبة'**
  String get dashboardIntegritySectionTitle;

  /// No description provided for @dashboardIntegrityAllClear.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد حالات اشتباه نشطة — المراقبة تعمل بصمت.'**
  String get dashboardIntegrityAllClear;

  /// No description provided for @dashboardOpenIntegrityButton.
  ///
  /// In ar, this message translates to:
  /// **'فتح مركز النزاهة'**
  String get dashboardOpenIntegrityButton;

  /// No description provided for @dashboardBestSellersTitle.
  ///
  /// In ar, this message translates to:
  /// **'الأفضل أداءً'**
  String get dashboardBestSellersTitle;

  /// No description provided for @dashboardOperationsTitle.
  ///
  /// In ar, this message translates to:
  /// **'التشغيل اليومي'**
  String get dashboardOperationsTitle;

  /// No description provided for @dashboardApprovedAwaitingPaymentNote.
  ///
  /// In ar, this message translates to:
  /// **'منها {amount} رواتب معتمدة لم تُدفع بعد'**
  String dashboardApprovedAwaitingPaymentNote(Object amount);

  /// No description provided for @attendanceSettingsSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'الحضور والانصراف (BioTime)'**
  String get attendanceSettingsSectionTitle;

  /// No description provided for @attendanceSettingsSectionSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'ربط جهاز البصمة ZKTeco ومزامنة الحضور تلقائيًا'**
  String get attendanceSettingsSectionSubtitle;

  /// No description provided for @attendanceConnectionSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'الاتصال بخادم BioTime'**
  String get attendanceConnectionSectionTitle;

  /// No description provided for @attendanceConnectionSectionSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'أدخل عنوان خادم BioTime المحلي وبيانات حساب لديه صلاحية قراءة الحضور.'**
  String get attendanceConnectionSectionSubtitle;

  /// No description provided for @attendanceServerUrlLabel.
  ///
  /// In ar, this message translates to:
  /// **'عنوان خادم BioTime'**
  String get attendanceServerUrlLabel;

  /// No description provided for @attendanceServerUrlHint.
  ///
  /// In ar, this message translates to:
  /// **'http://192.168.1.50:8081'**
  String get attendanceServerUrlHint;

  /// No description provided for @attendanceUsernameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم المستخدم'**
  String get attendanceUsernameLabel;

  /// No description provided for @attendancePasswordLabel.
  ///
  /// In ar, this message translates to:
  /// **'كلمة المرور'**
  String get attendancePasswordLabel;

  /// No description provided for @attendancePasswordKeepHint.
  ///
  /// In ar, this message translates to:
  /// **'اتركها فارغة للإبقاء على كلمة المرور المحفوظة'**
  String get attendancePasswordKeepHint;

  /// No description provided for @attendanceEnableLabel.
  ///
  /// In ar, this message translates to:
  /// **'تفعيل مزامنة الحضور'**
  String get attendanceEnableLabel;

  /// No description provided for @attendanceEnableSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'عند التفعيل يمكن سحب البصمات وتطبيقها على الرواتب'**
  String get attendanceEnableSubtitle;

  /// No description provided for @attendanceTestConnectionButton.
  ///
  /// In ar, this message translates to:
  /// **'اختبار الاتصال'**
  String get attendanceTestConnectionButton;

  /// Snack message after a successful BioTime connection test.
  ///
  /// In ar, this message translates to:
  /// **'تم الاتصال بنجاح. عدد الموظفين في BioTime: {count}'**
  String attendanceTestSuccess(int count);

  /// No description provided for @attendanceTestFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذر الاتصال بخادم BioTime. تحقق من العنوان وبيانات الدخول.'**
  String get attendanceTestFailed;

  /// No description provided for @attendanceScheduleSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'جدول الدوام الافتراضي'**
  String get attendanceScheduleSectionTitle;

  /// No description provided for @attendanceScheduleSectionSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'يُستخدم لحساب التأخير والغياب والوقت الإضافي لكل الموظفين.'**
  String get attendanceScheduleSectionSubtitle;

  /// No description provided for @attendanceShiftStartLabel.
  ///
  /// In ar, this message translates to:
  /// **'بداية الدوام'**
  String get attendanceShiftStartLabel;

  /// No description provided for @attendanceShiftEndLabel.
  ///
  /// In ar, this message translates to:
  /// **'نهاية الدوام'**
  String get attendanceShiftEndLabel;

  /// No description provided for @attendanceGraceLabel.
  ///
  /// In ar, this message translates to:
  /// **'فترة السماح (دقائق)'**
  String get attendanceGraceLabel;

  /// No description provided for @attendanceWorkdaysLabel.
  ///
  /// In ar, this message translates to:
  /// **'أيام العمل'**
  String get attendanceWorkdaysLabel;

  /// No description provided for @attendanceSyncNowButton.
  ///
  /// In ar, this message translates to:
  /// **'مزامنة الآن'**
  String get attendanceSyncNowButton;

  /// No description provided for @attendanceSyncInProgressButton.
  ///
  /// In ar, this message translates to:
  /// **'جار المزامنة...'**
  String get attendanceSyncInProgressButton;

  /// Snack message after a successful BioTime sync.
  ///
  /// In ar, this message translates to:
  /// **'تمت المزامنة: {punches} بصمة جديدة، {matched} موظف مرتبط'**
  String attendanceSyncSuccess(int punches, int matched);

  /// No description provided for @attendanceSyncFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشلت المزامنة مع BioTime. تحقق من الاتصال ثم أعد المحاولة.'**
  String get attendanceSyncFailed;

  /// Shows when the last BioTime sync happened.
  ///
  /// In ar, this message translates to:
  /// **'آخر مزامنة: {date}'**
  String attendanceLastSyncLabel(String date);

  /// No description provided for @attendanceNeverSynced.
  ///
  /// In ar, this message translates to:
  /// **'لم تتم المزامنة بعد'**
  String get attendanceNeverSynced;

  /// Shows the last BioTime sync error message.
  ///
  /// In ar, this message translates to:
  /// **'خطأ آخر مزامنة: {error}'**
  String attendanceLastSyncErrorLabel(String error);

  /// No description provided for @attendanceMappingSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'ربط الموظفين بجهاز البصمة'**
  String get attendanceMappingSectionTitle;

  /// No description provided for @attendanceMappingSectionSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'اربط كل موظف برقمه في BioTime. الموظفون الذين يحمل رقمهم نفس رقم الموظف يُربطون تلقائيًا عند المزامنة.'**
  String get attendanceMappingSectionSubtitle;

  /// No description provided for @attendanceMappingCodeLabel.
  ///
  /// In ar, this message translates to:
  /// **'رقم BioTime'**
  String get attendanceMappingCodeLabel;

  /// No description provided for @attendanceMappingEmptyState.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد موظفون بعد. أضف الموظفين من شاشة الموظفين أولًا.'**
  String get attendanceMappingEmptyState;

  /// No description provided for @attendanceTrackedLabel.
  ///
  /// In ar, this message translates to:
  /// **'متابعة الحضور'**
  String get attendanceTrackedLabel;

  /// Header for BioTime people that matched no employee.
  ///
  /// In ar, this message translates to:
  /// **'في BioTime بدون ربط ({count})'**
  String attendanceUnmatchedTitle(int count);

  /// No description provided for @attendanceSettingsSaved.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ إعدادات الحضور.'**
  String get attendanceSettingsSaved;

  /// No description provided for @attendanceSettingsSaveError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ إعدادات الحضور.'**
  String get attendanceSettingsSaveError;

  /// No description provided for @attendanceSettingsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل إعدادات الحضور.'**
  String get attendanceSettingsLoadError;

  /// No description provided for @attendanceDisabledNotice.
  ///
  /// In ar, this message translates to:
  /// **'مزامنة الحضور غير مفعلة. فعّلها من إعدادات المتجر ← الحضور والانصراف.'**
  String get attendanceDisabledNotice;

  /// No description provided for @attendanceTabLabel.
  ///
  /// In ar, this message translates to:
  /// **'الحضور'**
  String get attendanceTabLabel;

  /// No description provided for @attendanceSelectEmployeeLabel.
  ///
  /// In ar, this message translates to:
  /// **'الموظف'**
  String get attendanceSelectEmployeeLabel;

  /// No description provided for @attendanceSelectEmployeeHint.
  ///
  /// In ar, this message translates to:
  /// **'اختر موظفًا لعرض حضوره'**
  String get attendanceSelectEmployeeHint;

  /// No description provided for @attendanceMonthLabel.
  ///
  /// In ar, this message translates to:
  /// **'الشهر'**
  String get attendanceMonthLabel;

  /// No description provided for @attendanceSummaryExpectedLabel.
  ///
  /// In ar, this message translates to:
  /// **'أيام العمل'**
  String get attendanceSummaryExpectedLabel;

  /// No description provided for @attendanceSummaryPresentLabel.
  ///
  /// In ar, this message translates to:
  /// **'أيام الحضور'**
  String get attendanceSummaryPresentLabel;

  /// No description provided for @attendanceSummaryAbsentLabel.
  ///
  /// In ar, this message translates to:
  /// **'أيام الغياب'**
  String get attendanceSummaryAbsentLabel;

  /// No description provided for @attendanceSummaryLateLabel.
  ///
  /// In ar, this message translates to:
  /// **'دقائق التأخير'**
  String get attendanceSummaryLateLabel;

  /// No description provided for @attendanceSummaryOvertimeLabel.
  ///
  /// In ar, this message translates to:
  /// **'دقائق إضافية'**
  String get attendanceSummaryOvertimeLabel;

  /// No description provided for @attendanceStatusPresent.
  ///
  /// In ar, this message translates to:
  /// **'حاضر'**
  String get attendanceStatusPresent;

  /// No description provided for @attendanceStatusLate.
  ///
  /// In ar, this message translates to:
  /// **'متأخر'**
  String get attendanceStatusLate;

  /// No description provided for @attendanceStatusPartial.
  ///
  /// In ar, this message translates to:
  /// **'بصمة ناقصة'**
  String get attendanceStatusPartial;

  /// No description provided for @attendanceStatusDayOff.
  ///
  /// In ar, this message translates to:
  /// **'يوم راحة'**
  String get attendanceStatusDayOff;

  /// No description provided for @attendanceNoDaysMessage.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد سجلات حضور في هذه الفترة.'**
  String get attendanceNoDaysMessage;

  /// No description provided for @attendanceLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل سجلات الحضور.'**
  String get attendanceLoadError;

  /// Per-day attendance metrics line.
  ///
  /// In ar, this message translates to:
  /// **'عمل {worked} • تأخير {late} د • إضافي {overtime} د'**
  String attendanceDayMetrics(String worked, int late, int overtime);

  /// First-in and last-out times for an attendance day.
  ///
  /// In ar, this message translates to:
  /// **'{firstIn} → {lastOut}'**
  String attendanceDayTimes(String firstIn, String lastOut);

  /// No description provided for @attendanceApplyToPayrollButton.
  ///
  /// In ar, this message translates to:
  /// **'تطبيق الحضور على الرواتب'**
  String get attendanceApplyToPayrollButton;

  /// No description provided for @attendanceApplyInProgressButton.
  ///
  /// In ar, this message translates to:
  /// **'جار التطبيق...'**
  String get attendanceApplyInProgressButton;

  /// No description provided for @attendanceApplyCardTitle.
  ///
  /// In ar, this message translates to:
  /// **'احتساب الحضور من BioTime'**
  String get attendanceApplyCardTitle;

  /// No description provided for @attendanceApplyCardSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'يحدّث أيام الغياب والوقت الإضافي لكل موظف مرتبط بجهاز البصمة قبل اعتماد المسير. يمكنك تعديل القيم يدويًا بعد ذلك.'**
  String get attendanceApplyCardSubtitle;

  /// No description provided for @attendanceApplySuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم تحديث الغياب والوقت الإضافي من سجلات الحضور.'**
  String get attendanceApplySuccess;

  /// No description provided for @attendanceApplyFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تطبيق الحضور على مسير الرواتب.'**
  String get attendanceApplyFailed;

  /// No description provided for @weekdayMonday.
  ///
  /// In ar, this message translates to:
  /// **'الاثنين'**
  String get weekdayMonday;

  /// No description provided for @weekdayTuesday.
  ///
  /// In ar, this message translates to:
  /// **'الثلاثاء'**
  String get weekdayTuesday;

  /// No description provided for @weekdayWednesday.
  ///
  /// In ar, this message translates to:
  /// **'الأربعاء'**
  String get weekdayWednesday;

  /// No description provided for @weekdayThursday.
  ///
  /// In ar, this message translates to:
  /// **'الخميس'**
  String get weekdayThursday;

  /// No description provided for @weekdayFriday.
  ///
  /// In ar, this message translates to:
  /// **'الجمعة'**
  String get weekdayFriday;

  /// No description provided for @weekdaySaturday.
  ///
  /// In ar, this message translates to:
  /// **'السبت'**
  String get weekdaySaturday;

  /// No description provided for @weekdaySunday.
  ///
  /// In ar, this message translates to:
  /// **'الأحد'**
  String get weekdaySunday;

  /// No description provided for @expensesTitle.
  ///
  /// In ar, this message translates to:
  /// **'المصروفات'**
  String get expensesTitle;

  /// No description provided for @expensesDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'المصروفات'**
  String get expensesDrawerLabel;

  /// No description provided for @expensesRefreshTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث'**
  String get expensesRefreshTooltip;

  /// No description provided for @expenseAddButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة مصروف'**
  String get expenseAddButton;

  /// No description provided for @expensesLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل المصروفات.'**
  String get expensesLoadError;

  /// No description provided for @expensesEmptyMessage.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مصروفات في هذه الفترة.'**
  String get expensesEmptyMessage;

  /// No description provided for @expensesNoMatchingMessage.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد بنود مطابقة للتصفية.'**
  String get expensesNoMatchingMessage;

  /// No description provided for @expensesPreviousMonth.
  ///
  /// In ar, this message translates to:
  /// **'الشهر السابق'**
  String get expensesPreviousMonth;

  /// No description provided for @expensesNextMonth.
  ///
  /// In ar, this message translates to:
  /// **'الشهر التالي'**
  String get expensesNextMonth;

  /// No description provided for @expensesPeriodTotal.
  ///
  /// In ar, this message translates to:
  /// **'الإجمالي: {total}'**
  String expensesPeriodTotal(Object total);

  /// No description provided for @expenseSourceAdHoc.
  ///
  /// In ar, this message translates to:
  /// **'مصروف'**
  String get expenseSourceAdHoc;

  /// No description provided for @expenseSourceRegisterPayout.
  ///
  /// In ar, this message translates to:
  /// **'سحب نقدي'**
  String get expenseSourceRegisterPayout;

  /// No description provided for @expenseSourcePurchase.
  ///
  /// In ar, this message translates to:
  /// **'مشتريات'**
  String get expenseSourcePurchase;

  /// No description provided for @expenseSourcePayroll.
  ///
  /// In ar, this message translates to:
  /// **'رواتب'**
  String get expenseSourcePayroll;

  /// No description provided for @expenseSourceCommission.
  ///
  /// In ar, this message translates to:
  /// **'عمولات'**
  String get expenseSourceCommission;

  /// No description provided for @expenseSourceOther.
  ///
  /// In ar, this message translates to:
  /// **'أخرى'**
  String get expenseSourceOther;

  /// No description provided for @expensePaymentCash.
  ///
  /// In ar, this message translates to:
  /// **'نقدًا'**
  String get expensePaymentCash;

  /// No description provided for @expensePaymentCard.
  ///
  /// In ar, this message translates to:
  /// **'بطاقة'**
  String get expensePaymentCard;

  /// No description provided for @expensePaymentTransfer.
  ///
  /// In ar, this message translates to:
  /// **'تحويل'**
  String get expensePaymentTransfer;

  /// No description provided for @expenseLoadDetailsError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل تفاصيل المصروف.'**
  String get expenseLoadDetailsError;

  /// No description provided for @expenseNeedsCategoryMessage.
  ///
  /// In ar, this message translates to:
  /// **'أضِف فئة واحدة على الأقل قبل تسجيل مصروف.'**
  String get expenseNeedsCategoryMessage;

  /// No description provided for @expenseSaveError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حفظ المصروف.'**
  String get expenseSaveError;

  /// No description provided for @expenseDeleteTitle.
  ///
  /// In ar, this message translates to:
  /// **'حذف المصروف؟'**
  String get expenseDeleteTitle;

  /// No description provided for @expenseDeleteMessage.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكن التراجع عن هذا الإجراء.'**
  String get expenseDeleteMessage;

  /// No description provided for @expenseDeleteError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حذف المصروف.'**
  String get expenseDeleteError;

  /// No description provided for @expenseEditTitle.
  ///
  /// In ar, this message translates to:
  /// **'تعديل المصروف'**
  String get expenseEditTitle;

  /// No description provided for @expenseCategoryLabel.
  ///
  /// In ar, this message translates to:
  /// **'الفئة'**
  String get expenseCategoryLabel;

  /// No description provided for @expenseDescriptionLabel.
  ///
  /// In ar, this message translates to:
  /// **'الوصف'**
  String get expenseDescriptionLabel;

  /// No description provided for @expenseAmountLabel.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ'**
  String get expenseAmountLabel;

  /// No description provided for @expensePaymentMethodLabel.
  ///
  /// In ar, this message translates to:
  /// **'طريقة الدفع'**
  String get expensePaymentMethodLabel;

  /// No description provided for @expenseDateLabel.
  ///
  /// In ar, this message translates to:
  /// **'التاريخ'**
  String get expenseDateLabel;

  /// No description provided for @expenseReferenceLabel.
  ///
  /// In ar, this message translates to:
  /// **'مرجع (اختياري)'**
  String get expenseReferenceLabel;

  /// No description provided for @expenseNotesLabel.
  ///
  /// In ar, this message translates to:
  /// **'ملاحظات (اختياري)'**
  String get expenseNotesLabel;

  /// No description provided for @expensePayFromRegisterLabel.
  ///
  /// In ar, this message translates to:
  /// **'الدفع من الصندوق'**
  String get expensePayFromRegisterLabel;

  /// No description provided for @expensePayFromRegisterHint.
  ///
  /// In ar, this message translates to:
  /// **'يُسجَّل سحبًا نقديًا من الوردية المفتوحة إن وُجدت.'**
  String get expensePayFromRegisterHint;

  /// No description provided for @expenseCategoriesSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'فئات المصروفات'**
  String get expenseCategoriesSectionTitle;

  /// No description provided for @expenseCategoryAddButton.
  ///
  /// In ar, this message translates to:
  /// **'إضافة فئة'**
  String get expenseCategoryAddButton;

  /// No description provided for @expenseCategoriesLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل الفئات.'**
  String get expenseCategoriesLoadError;

  /// No description provided for @expenseCategoriesEmptyMessage.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد فئات بعد.'**
  String get expenseCategoriesEmptyMessage;

  /// No description provided for @expenseCategorySaveError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حفظ الفئة.'**
  String get expenseCategorySaveError;

  /// No description provided for @expenseCategoryDeleteTitle.
  ///
  /// In ar, this message translates to:
  /// **'حذف الفئة؟'**
  String get expenseCategoryDeleteTitle;

  /// No description provided for @expenseCategoryDeleteMessage.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكن حذف فئة مرتبطة بمصروفات.'**
  String get expenseCategoryDeleteMessage;

  /// No description provided for @expenseCategoryDeleteError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حذف الفئة.'**
  String get expenseCategoryDeleteError;

  /// No description provided for @expenseCategoryInactiveBadge.
  ///
  /// In ar, this message translates to:
  /// **'غير مفعّلة'**
  String get expenseCategoryInactiveBadge;

  /// No description provided for @expenseCategoryNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم الفئة'**
  String get expenseCategoryNameLabel;

  /// No description provided for @expenseCategoryActiveLabel.
  ///
  /// In ar, this message translates to:
  /// **'مفعّلة'**
  String get expenseCategoryActiveLabel;

  /// No description provided for @dashboardAdHocExpensesMetric.
  ///
  /// In ar, this message translates to:
  /// **'مصاريف عامة'**
  String get dashboardAdHocExpensesMetric;

  /// No description provided for @jobAssignmentSection.
  ///
  /// In ar, this message translates to:
  /// **'الإسناد'**
  String get jobAssignmentSection;

  /// No description provided for @jobAssignedEmployeeHint.
  ///
  /// In ar, this message translates to:
  /// **'الموظف الذي تُحتسب له عمولة العمل على هذه المهمة.'**
  String get jobAssignedEmployeeHint;

  /// No description provided for @jobAssignButton.
  ///
  /// In ar, this message translates to:
  /// **'إسناد'**
  String get jobAssignButton;

  /// No description provided for @jobReassignButton.
  ///
  /// In ar, this message translates to:
  /// **'تغيير'**
  String get jobReassignButton;

  /// No description provided for @jobAssignLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل قائمة الموظفين.'**
  String get jobAssignLoadError;

  /// No description provided for @jobAssignedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم تحديث الإسناد.'**
  String get jobAssignedMessage;

  /// No description provided for @jobAssignSelectTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختر الموظف'**
  String get jobAssignSelectTitle;

  /// No description provided for @jobAssignNoEmployees.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد موظفون نشطون.'**
  String get jobAssignNoEmployees;

  /// No description provided for @jobUnassignOption.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء الإسناد'**
  String get jobUnassignOption;

  /// No description provided for @salaryTypeOperationsCommissionOnly.
  ///
  /// In ar, this message translates to:
  /// **'عمولة على الأعمال فقط'**
  String get salaryTypeOperationsCommissionOnly;

  /// No description provided for @salaryTypeOperationsCommissionOnlyHelper.
  ///
  /// In ar, this message translates to:
  /// **'تُحتسب نسبة على قيمة الأعمال (مثل الإصلاحات) التي أنجزها الموظف، بدون راتب ثابت.'**
  String get salaryTypeOperationsCommissionOnlyHelper;

  /// No description provided for @salaryTypeMonthlyFixedPlusOperationsCommission.
  ///
  /// In ar, this message translates to:
  /// **'راتب شهري + عمولة على الأعمال'**
  String get salaryTypeMonthlyFixedPlusOperationsCommission;

  /// No description provided for @salaryTypeMonthlyFixedPlusOperationsCommissionHelper.
  ///
  /// In ar, this message translates to:
  /// **'راتب شهري ثابت بالإضافة إلى نسبة على قيمة الأعمال التي أنجزها الموظف.'**
  String get salaryTypeMonthlyFixedPlusOperationsCommissionHelper;

  /// No description provided for @operationsCommissionPercentField.
  ///
  /// In ar, this message translates to:
  /// **'نسبة العمولة على الأعمال'**
  String get operationsCommissionPercentField;

  /// No description provided for @operationsCommissionPercentHelper.
  ///
  /// In ar, this message translates to:
  /// **'نسبة مئوية من قيمة الأعمال المنجزة (السعر المعتمد) تُضاف إلى المسير.'**
  String get operationsCommissionPercentHelper;

  /// No description provided for @operationsCommissionBaseField.
  ///
  /// In ar, this message translates to:
  /// **'أساس احتساب العمولة'**
  String get operationsCommissionBaseField;

  /// No description provided for @operationsCommissionBaseApprovedPrice.
  ///
  /// In ar, this message translates to:
  /// **'السعر المعتمد (قطع + أجور)'**
  String get operationsCommissionBaseApprovedPrice;

  /// No description provided for @operationsCommissionBaseApprovedPriceHelper.
  ///
  /// In ar, this message translates to:
  /// **'تُحتسب العمولة على كامل السعر المعتمد للمهمة.'**
  String get operationsCommissionBaseApprovedPriceHelper;

  /// No description provided for @operationsCommissionBaseLabor.
  ///
  /// In ar, this message translates to:
  /// **'الأجور فقط'**
  String get operationsCommissionBaseLabor;

  /// No description provided for @operationsCommissionBaseLaborHelper.
  ///
  /// In ar, this message translates to:
  /// **'تُحتسب العمولة على السعر المعتمد بعد خصم قيمة القطع المستهلكة.'**
  String get operationsCommissionBaseLaborHelper;

  /// No description provided for @operationsCommissionBaseOrderTotal.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الفاتورة'**
  String get operationsCommissionBaseOrderTotal;

  /// No description provided for @operationsCommissionBaseOrderTotalHelper.
  ///
  /// In ar, this message translates to:
  /// **'تُحتسب العمولة على إجمالي فاتورة المهمة (للمهام التي صدرت لها فاتورة).'**
  String get operationsCommissionBaseOrderTotalHelper;

  /// No description provided for @stockCountDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'جرد المخزون'**
  String get stockCountDrawerLabel;

  /// No description provided for @stockCountSessionsTitle.
  ///
  /// In ar, this message translates to:
  /// **'عمليات الجرد'**
  String get stockCountSessionsTitle;

  /// No description provided for @stockCountRefreshTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث عمليات الجرد'**
  String get stockCountRefreshTooltip;

  /// No description provided for @stockCountCountingTitle.
  ///
  /// In ar, this message translates to:
  /// **'الجرد'**
  String get stockCountCountingTitle;

  /// No description provided for @stockCountReconciliationTitle.
  ///
  /// In ar, this message translates to:
  /// **'مراجعة الفروقات'**
  String get stockCountReconciliationTitle;

  /// No description provided for @stockCountStartNew.
  ///
  /// In ar, this message translates to:
  /// **'بدء جرد جديد'**
  String get stockCountStartNew;

  /// No description provided for @stockCountResume.
  ///
  /// In ar, this message translates to:
  /// **'متابعة الجرد الحالي'**
  String get stockCountResume;

  /// No description provided for @stockCountStartTitle.
  ///
  /// In ar, this message translates to:
  /// **'جرد جديد'**
  String get stockCountStartTitle;

  /// No description provided for @stockCountScopeLabel.
  ///
  /// In ar, this message translates to:
  /// **'نطاق الجرد'**
  String get stockCountScopeLabel;

  /// No description provided for @stockCountScopeFull.
  ///
  /// In ar, this message translates to:
  /// **'كل المنتجات'**
  String get stockCountScopeFull;

  /// No description provided for @stockCountScopeCategory.
  ///
  /// In ar, this message translates to:
  /// **'تصنيف محدد'**
  String get stockCountScopeCategory;

  /// No description provided for @stockCountSelectCategory.
  ///
  /// In ar, this message translates to:
  /// **'اختر التصنيف'**
  String get stockCountSelectCategory;

  /// No description provided for @stockCountSelectCategoryError.
  ///
  /// In ar, this message translates to:
  /// **'اختر تصنيفًا للمتابعة.'**
  String get stockCountSelectCategoryError;

  /// No description provided for @stockCountNoteLabel.
  ///
  /// In ar, this message translates to:
  /// **'ملاحظة (اختياري)'**
  String get stockCountNoteLabel;

  /// No description provided for @stockCountStartButton.
  ///
  /// In ar, this message translates to:
  /// **'بدء الجرد'**
  String get stockCountStartButton;

  /// No description provided for @stockCountStartError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر بدء الجرد. حاول مرة أخرى.'**
  String get stockCountStartError;

  /// Counting progress, counted of total items.
  ///
  /// In ar, this message translates to:
  /// **'{counted} من {total}'**
  String stockCountProgress(int counted, int total);

  /// No description provided for @stockCountScanPrompt.
  ///
  /// In ar, this message translates to:
  /// **'امسح باركود الصنف للبدء'**
  String get stockCountScanPrompt;

  /// No description provided for @stockCountScanHint.
  ///
  /// In ar, this message translates to:
  /// **'امسح، أو ابحث، أو تصفّح المنتجات'**
  String get stockCountScanHint;

  /// No description provided for @stockCountCountLabel.
  ///
  /// In ar, this message translates to:
  /// **'الكمية المعدودة'**
  String get stockCountCountLabel;

  /// No description provided for @stockCountSaveAndNext.
  ///
  /// In ar, this message translates to:
  /// **'حفظ والتالي'**
  String get stockCountSaveAndNext;

  /// No description provided for @stockCountSearchItem.
  ///
  /// In ar, this message translates to:
  /// **'بحث عن صنف'**
  String get stockCountSearchItem;

  /// No description provided for @stockCountSearchHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث بالاسم أو الرمز'**
  String get stockCountSearchHint;

  /// No description provided for @stockCountBrowse.
  ///
  /// In ar, this message translates to:
  /// **'تصفّح المنتجات'**
  String get stockCountBrowse;

  /// No description provided for @stockCountScanMiss.
  ///
  /// In ar, this message translates to:
  /// **'لم يتم العثور على صنف بهذا الباركود.'**
  String get stockCountScanMiss;

  /// No description provided for @stockCountSaveError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حفظ العدّة. حاول مرة أخرى.'**
  String get stockCountSaveError;

  /// No description provided for @stockCountFinishButton.
  ///
  /// In ar, this message translates to:
  /// **'إنهاء ومراجعة'**
  String get stockCountFinishButton;

  /// No description provided for @stockCountSearchEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد أصناف مطابقة.'**
  String get stockCountSearchEmpty;

  /// Unit label on the counting item card.
  ///
  /// In ar, this message translates to:
  /// **'الوحدة: {unit}'**
  String stockCountItemUnit(String unit);

  /// No description provided for @stockCountReentryTitle.
  ///
  /// In ar, this message translates to:
  /// **'الصنف معدود مسبقًا'**
  String get stockCountReentryTitle;

  /// Add-or-replace prompt body, current counted quantity.
  ///
  /// In ar, this message translates to:
  /// **'لديك عدّة حالية {current} لهذا الصنف.'**
  String stockCountReentryBody(String current);

  /// No description provided for @stockCountReentryAdd.
  ///
  /// In ar, this message translates to:
  /// **'أضف إلى العدّة'**
  String get stockCountReentryAdd;

  /// No description provided for @stockCountReentryReplace.
  ///
  /// In ar, this message translates to:
  /// **'استبدل العدّة'**
  String get stockCountReentryReplace;

  /// No description provided for @stockCountVarianceTitle.
  ///
  /// In ar, this message translates to:
  /// **'تحقّق من العدّة'**
  String get stockCountVarianceTitle;

  /// Variance prompt comparing expected and counted quantities.
  ///
  /// In ar, this message translates to:
  /// **'النظام يُسجّل {expected}، وأنت أدخلت {counted}.'**
  String stockCountVarianceBody(String expected, String counted);

  /// No description provided for @stockCountRecount.
  ///
  /// In ar, this message translates to:
  /// **'إعادة العدّ'**
  String get stockCountRecount;

  /// No description provided for @stockCountConfirm.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد'**
  String get stockCountConfirm;

  /// Reconciliation summary of differing line count.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد فروقات} =1{صنف واحد لا يطابق} =2{صنفان لا يطابقان} other{{count} أصناف لا تطابق}}'**
  String stockCountMismatchCount(int count);

  /// No description provided for @stockCountColumnExpected.
  ///
  /// In ar, this message translates to:
  /// **'النظام'**
  String get stockCountColumnExpected;

  /// No description provided for @stockCountColumnCounted.
  ///
  /// In ar, this message translates to:
  /// **'المعدود'**
  String get stockCountColumnCounted;

  /// No description provided for @stockCountColumnGap.
  ///
  /// In ar, this message translates to:
  /// **'الفرق'**
  String get stockCountColumnGap;

  /// No description provided for @stockCountApply.
  ///
  /// In ar, this message translates to:
  /// **'تطبيق التعديلات'**
  String get stockCountApply;

  /// No description provided for @stockCountApplyConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'تطبيق الجرد؟'**
  String get stockCountApplyConfirmTitle;

  /// No description provided for @stockCountApplyConfirmBody.
  ///
  /// In ar, this message translates to:
  /// **'سيتم تعديل المخزون بمقدار الفروقات المعدودة. لا يمكن التراجع عن هذا الإجراء.'**
  String get stockCountApplyConfirmBody;

  /// No description provided for @stockCountApplyConfirm.
  ///
  /// In ar, this message translates to:
  /// **'تطبيق'**
  String get stockCountApplyConfirm;

  /// No description provided for @stockCountApplied.
  ///
  /// In ar, this message translates to:
  /// **'تم تطبيق الجرد'**
  String get stockCountApplied;

  /// No description provided for @stockCountApplyError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تطبيق الجرد. حاول مرة أخرى.'**
  String get stockCountApplyError;

  /// No description provided for @stockCountApplyManagerOnly.
  ///
  /// In ar, this message translates to:
  /// **'تطبيق التعديلات متاح للمدير فقط.'**
  String get stockCountApplyManagerOnly;

  /// No description provided for @stockCountNoVariances.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد فروقات. المخزون مطابق للمعدود.'**
  String get stockCountNoVariances;

  /// No description provided for @stockCountCancel.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء الجرد'**
  String get stockCountCancel;

  /// No description provided for @stockCountCancelConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء الجرد؟'**
  String get stockCountCancelConfirmTitle;

  /// No description provided for @stockCountCancelConfirmBody.
  ///
  /// In ar, this message translates to:
  /// **'سيتم تجاهل كل ما تم عدّه في هذه الجلسة.'**
  String get stockCountCancelConfirmBody;

  /// No description provided for @stockCountCancelConfirm.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء الجرد'**
  String get stockCountCancelConfirm;

  /// No description provided for @stockCountEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عمليات جرد بعد.'**
  String get stockCountEmpty;

  /// No description provided for @stockCountLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل عمليات الجرد.'**
  String get stockCountLoadError;

  /// No description provided for @stockCountHistoryTitle.
  ///
  /// In ar, this message translates to:
  /// **'سجل عمليات الجرد'**
  String get stockCountHistoryTitle;

  /// No description provided for @stockCountStatusInProgress.
  ///
  /// In ar, this message translates to:
  /// **'قيد التنفيذ'**
  String get stockCountStatusInProgress;

  /// No description provided for @stockCountStatusApplied.
  ///
  /// In ar, this message translates to:
  /// **'مطبّق'**
  String get stockCountStatusApplied;

  /// No description provided for @stockCountStatusCancelled.
  ///
  /// In ar, this message translates to:
  /// **'ملغى'**
  String get stockCountStatusCancelled;

  /// Category-scoped count label.
  ///
  /// In ar, this message translates to:
  /// **'تصنيف: {category}'**
  String stockCountScopeCategoryLabel(String category);

  /// Trailing 'of N' for the counted/total progress label.
  ///
  /// In ar, this message translates to:
  /// **'من {total}'**
  String stockCountOfTotal(int total);

  /// Remaining items still to count in the active session.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{اكتمل العدّ} =1{بقي صنف واحد} =2{بقي صنفان} other{بقي {count}}}'**
  String stockCountRemaining(int count);

  /// No description provided for @stockCountActiveTitle.
  ///
  /// In ar, this message translates to:
  /// **'جرد قيد التنفيذ'**
  String get stockCountActiveTitle;

  /// No description provided for @stockCountCameraScan.
  ///
  /// In ar, this message translates to:
  /// **'المسح بالكاميرا'**
  String get stockCountCameraScan;

  /// No description provided for @stockCountYourCount.
  ///
  /// In ar, this message translates to:
  /// **'عدّتك'**
  String get stockCountYourCount;

  /// No description provided for @stockCountReentryCurrentLabel.
  ///
  /// In ar, this message translates to:
  /// **'العدّة الحالية'**
  String get stockCountReentryCurrentLabel;

  /// No description provided for @stockCountReentryQuestion.
  ///
  /// In ar, this message translates to:
  /// **'هل تضيف الكمية الجديدة إلى عدّتك أم تستبدلها؟'**
  String get stockCountReentryQuestion;

  /// No description provided for @stockCountStartHeroTitle.
  ///
  /// In ar, this message translates to:
  /// **'ابدأ جردًا جديدًا'**
  String get stockCountStartHeroTitle;

  /// No description provided for @stockCountStartHeroBody.
  ///
  /// In ar, this message translates to:
  /// **'عُدّ مخزونك الفعلي وقارنه بالنظام لرصد الفروقات وتصحيحها.'**
  String get stockCountStartHeroBody;

  /// No description provided for @stockCountHistoryEmptyHint.
  ///
  /// In ar, this message translates to:
  /// **'ستظهر عمليات الجرد السابقة هنا.'**
  String get stockCountHistoryEmptyHint;

  /// No description provided for @stockCountMatched.
  ///
  /// In ar, this message translates to:
  /// **'مطابق'**
  String get stockCountMatched;

  /// No description provided for @stockCountAllMatched.
  ///
  /// In ar, this message translates to:
  /// **'كل شيء مطابق'**
  String get stockCountAllMatched;

  /// No description provided for @stockCountFinishCount.
  ///
  /// In ar, this message translates to:
  /// **'إنهاء الجرد'**
  String get stockCountFinishCount;

  /// No description provided for @stockCountShortage.
  ///
  /// In ar, this message translates to:
  /// **'نقص'**
  String get stockCountShortage;

  /// No description provided for @stockCountSurplus.
  ///
  /// In ar, this message translates to:
  /// **'زيادة'**
  String get stockCountSurplus;

  /// Footer summary above the apply button.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{سيتم تعديل صنف واحد} =2{سيتم تعديل صنفين} other{سيتم تعديل {count} أصناف}}'**
  String stockCountApplySummary(int count);

  /// Compact variance-count badge on a history row.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{فرق واحد} =2{فرقان} other{{count} فروق}}'**
  String stockCountVarianceShort(int count);

  /// No description provided for @priceCheckersSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'أجهزة فحص الأسعار'**
  String get priceCheckersSectionTitle;

  /// No description provided for @priceCheckersSectionSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'متابعة أجهزة فحص الأسعار المتصلة في المتجر وحالتها'**
  String get priceCheckersSectionSubtitle;

  /// No description provided for @priceCheckersHeroDescription.
  ///
  /// In ar, this message translates to:
  /// **'نظرة سريعة على كل جهاز متصل وآخر نشاط له.'**
  String get priceCheckersHeroDescription;

  /// No description provided for @priceCheckerDevicesUnit.
  ///
  /// In ar, this message translates to:
  /// **'جهاز فحص أسعار'**
  String get priceCheckerDevicesUnit;

  /// Hero pill: how many devices are actively serving lookups.
  ///
  /// In ar, this message translates to:
  /// **'{count} قيد الخدمة'**
  String priceCheckerServingPillLabel(int count);

  /// Hero pill: how many discovered devices await activation.
  ///
  /// In ar, this message translates to:
  /// **'{count} بانتظار التفعيل'**
  String priceCheckerDiscoveredPillLabel(int count);

  /// No description provided for @priceCheckerScanTooltip.
  ///
  /// In ar, this message translates to:
  /// **'البحث عن أجهزة في الشبكة'**
  String get priceCheckerScanTooltip;

  /// No description provided for @priceCheckerScanButton.
  ///
  /// In ar, this message translates to:
  /// **'بحث في الشبكة'**
  String get priceCheckerScanButton;

  /// No description provided for @priceCheckerRefreshTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث'**
  String get priceCheckerRefreshTooltip;

  /// No description provided for @priceCheckerDevicesListTitle.
  ///
  /// In ar, this message translates to:
  /// **'الأجهزة'**
  String get priceCheckerDevicesListTitle;

  /// Device-list section subtitle showing the device count.
  ///
  /// In ar, this message translates to:
  /// **'{count} جهاز'**
  String priceCheckerDevicesCountSubtitle(int count);

  /// No description provided for @priceCheckersEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد أجهزة بعد'**
  String get priceCheckersEmptyTitle;

  /// No description provided for @priceCheckersEmptyMessage.
  ///
  /// In ar, this message translates to:
  /// **'ابحث في الشبكة المحلية للعثور على أجهزة فحص الأسعار وتسجيلها تلقائيًا.'**
  String get priceCheckersEmptyMessage;

  /// No description provided for @priceCheckersLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل أجهزة فحص الأسعار'**
  String get priceCheckersLoadError;

  /// Snackbar after a network scan finds devices.
  ///
  /// In ar, this message translates to:
  /// **'تم العثور على {found} جهاز، وسُجِّل منها {registered}.'**
  String priceCheckerScanSuccess(int found, int registered);

  /// No description provided for @priceCheckerScanNone.
  ///
  /// In ar, this message translates to:
  /// **'لم يُعثر على أجهزة جديدة في الشبكة.'**
  String get priceCheckerScanNone;

  /// No description provided for @priceCheckerScanError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إجراء البحث في الشبكة. حاول مرة أخرى.'**
  String get priceCheckerScanError;

  /// Last-activity timestamp line for a device.
  ///
  /// In ar, this message translates to:
  /// **'آخر نشاط: {value}'**
  String priceCheckerLastSeen(String value);

  /// No description provided for @priceCheckerNeverSeen.
  ///
  /// In ar, this message translates to:
  /// **'لم يُسجَّل نشاط بعد'**
  String get priceCheckerNeverSeen;

  /// No description provided for @priceCheckerStatusActive.
  ///
  /// In ar, this message translates to:
  /// **'نشِط'**
  String get priceCheckerStatusActive;

  /// No description provided for @priceCheckerStatusDiscovered.
  ///
  /// In ar, this message translates to:
  /// **'مكتشَف'**
  String get priceCheckerStatusDiscovered;

  /// No description provided for @priceCheckerStatusDisabled.
  ///
  /// In ar, this message translates to:
  /// **'مُعطّل'**
  String get priceCheckerStatusDisabled;

  /// No description provided for @priceCheckerDiscoveryManual.
  ///
  /// In ar, this message translates to:
  /// **'إضافة يدوية'**
  String get priceCheckerDiscoveryManual;

  /// No description provided for @priceCheckerDiscoveryScan.
  ///
  /// In ar, this message translates to:
  /// **'فحص الشبكة'**
  String get priceCheckerDiscoveryScan;

  /// No description provided for @priceCheckerDiscoverySelf.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل ذاتي'**
  String get priceCheckerDiscoverySelf;

  /// No description provided for @priceCheckerArabicNone.
  ///
  /// In ar, this message translates to:
  /// **'غير مدعوم (لاتيني)'**
  String get priceCheckerArabicNone;

  /// No description provided for @priceCheckerArabicUnicode.
  ///
  /// In ar, this message translates to:
  /// **'يونيكود (الجهاز يُشكّل)'**
  String get priceCheckerArabicUnicode;

  /// No description provided for @priceCheckerArabicCp1256.
  ///
  /// In ar, this message translates to:
  /// **'CP1256 (الخادم يعيد الترتيب)'**
  String get priceCheckerArabicCp1256;

  /// No description provided for @priceCheckerArabicGlyphs.
  ///
  /// In ar, this message translates to:
  /// **'محارف مُشكّلة مسبقًا'**
  String get priceCheckerArabicGlyphs;

  /// No description provided for @priceCheckResultFound.
  ///
  /// In ar, this message translates to:
  /// **'موجود'**
  String get priceCheckResultFound;

  /// No description provided for @priceCheckResultNotFound.
  ///
  /// In ar, this message translates to:
  /// **'غير موجود'**
  String get priceCheckResultNotFound;

  /// No description provided for @priceCheckResultError.
  ///
  /// In ar, this message translates to:
  /// **'خطأ'**
  String get priceCheckResultError;

  /// No description provided for @priceCheckerConnectionServing.
  ///
  /// In ar, this message translates to:
  /// **'هذا الجهاز قيد الخدمة ويستقبل عمليات الفحص'**
  String get priceCheckerConnectionServing;

  /// No description provided for @priceCheckerConnectionDiscovered.
  ///
  /// In ar, this message translates to:
  /// **'تم اكتشاف هذا الجهاز وهو بانتظار التفعيل'**
  String get priceCheckerConnectionDiscovered;

  /// No description provided for @priceCheckerConnectionDisabled.
  ///
  /// In ar, this message translates to:
  /// **'هذا الجهاز مُعطّل ولا يستجيب لعمليات الفحص'**
  String get priceCheckerConnectionDisabled;

  /// No description provided for @priceCheckerNetworkSection.
  ///
  /// In ar, this message translates to:
  /// **'الشبكة'**
  String get priceCheckerNetworkSection;

  /// No description provided for @priceCheckerFieldIdentifier.
  ///
  /// In ar, this message translates to:
  /// **'المعرّف'**
  String get priceCheckerFieldIdentifier;

  /// No description provided for @priceCheckerFieldTransport.
  ///
  /// In ar, this message translates to:
  /// **'البروتوكول'**
  String get priceCheckerFieldTransport;

  /// No description provided for @priceCheckerFieldAddress.
  ///
  /// In ar, this message translates to:
  /// **'العنوان'**
  String get priceCheckerFieldAddress;

  /// No description provided for @priceCheckerFieldMac.
  ///
  /// In ar, this message translates to:
  /// **'عنوان MAC'**
  String get priceCheckerFieldMac;

  /// No description provided for @priceCheckerFieldDriver.
  ///
  /// In ar, this message translates to:
  /// **'المشغّل'**
  String get priceCheckerFieldDriver;

  /// No description provided for @priceCheckerFieldHardware.
  ///
  /// In ar, this message translates to:
  /// **'الطراز'**
  String get priceCheckerFieldHardware;

  /// No description provided for @priceCheckerFieldDiscovery.
  ///
  /// In ar, this message translates to:
  /// **'طريقة الاكتشاف'**
  String get priceCheckerFieldDiscovery;

  /// No description provided for @priceCheckerFieldLocation.
  ///
  /// In ar, this message translates to:
  /// **'الموقع'**
  String get priceCheckerFieldLocation;

  /// No description provided for @priceCheckerDisplaySection.
  ///
  /// In ar, this message translates to:
  /// **'الشاشة'**
  String get priceCheckerDisplaySection;

  /// No description provided for @priceCheckerFieldDisplaySize.
  ///
  /// In ar, this message translates to:
  /// **'أبعاد الشاشة'**
  String get priceCheckerFieldDisplaySize;

  /// Display grid dimensions, e.g. 5 × 20.
  ///
  /// In ar, this message translates to:
  /// **'{rows} × {cols}'**
  String priceCheckerDisplaySizeValue(int rows, int cols);

  /// No description provided for @priceCheckerFieldArabic.
  ///
  /// In ar, this message translates to:
  /// **'دعم العربية'**
  String get priceCheckerFieldArabic;

  /// No description provided for @priceCheckerFieldEncoding.
  ///
  /// In ar, this message translates to:
  /// **'الترميز'**
  String get priceCheckerFieldEncoding;

  /// No description provided for @priceCheckerActivitySection.
  ///
  /// In ar, this message translates to:
  /// **'أحدث عمليات الفحص'**
  String get priceCheckerActivitySection;

  /// No description provided for @priceCheckerActivityLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل عمليات الفحص'**
  String get priceCheckerActivityLoadError;

  /// No description provided for @priceCheckerActivityEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عمليات فحص بعد لهذا الجهاز.'**
  String get priceCheckerActivityEmpty;

  /// No description provided for @priceCheckerScanPrompt.
  ///
  /// In ar, this message translates to:
  /// **'امسح الباركود لعرض السعر'**
  String get priceCheckerScanPrompt;

  /// No description provided for @priceCheckerLoading.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ البحث…'**
  String get priceCheckerLoading;

  /// No description provided for @priceCheckerScanAnother.
  ///
  /// In ar, this message translates to:
  /// **'امسح منتجًا آخر'**
  String get priceCheckerScanAnother;

  /// No description provided for @priceCheckerNotFoundTitle.
  ///
  /// In ar, this message translates to:
  /// **'المنتج غير موجود'**
  String get priceCheckerNotFoundTitle;

  /// No description provided for @priceCheckerNotFoundBody.
  ///
  /// In ar, this message translates to:
  /// **'تحقّق من الباركود وحاول مرة أخرى'**
  String get priceCheckerNotFoundBody;

  /// Shows the scanned barcode when a product isn't found.
  ///
  /// In ar, this message translates to:
  /// **'الباركود: {barcode}'**
  String priceCheckerScannedCode(String barcode);

  /// No description provided for @priceCheckerDisconnectedTitle.
  ///
  /// In ar, this message translates to:
  /// **'غير متصل بالخادم'**
  String get priceCheckerDisconnectedTitle;

  /// No description provided for @priceCheckerDisconnectedBody.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ إعادة المحاولة…'**
  String get priceCheckerDisconnectedBody;

  /// No description provided for @priceCheckerInStock.
  ///
  /// In ar, this message translates to:
  /// **'متوفّر'**
  String get priceCheckerInStock;

  /// No description provided for @priceCheckerOutOfStock.
  ///
  /// In ar, this message translates to:
  /// **'غير متوفّر'**
  String get priceCheckerOutOfStock;

  /// Discount badge by percentage, e.g. وفّر 10٪.
  ///
  /// In ar, this message translates to:
  /// **'وفّر {value}٪'**
  String priceCheckerSavePercent(String value);

  /// Discount badge by fixed amount, e.g. وفّر 2.00 د.ل.
  ///
  /// In ar, this message translates to:
  /// **'وفّر {value}'**
  String priceCheckerSaveAmount(String value);

  /// No description provided for @priceCheckerManualEntry.
  ///
  /// In ar, this message translates to:
  /// **'إدخال يدوي'**
  String get priceCheckerManualEntry;

  /// No description provided for @priceCheckerManualEntryTitle.
  ///
  /// In ar, this message translates to:
  /// **'أدخل الباركود'**
  String get priceCheckerManualEntryTitle;

  /// No description provided for @priceCheckerCameraScanPrompt.
  ///
  /// In ar, this message translates to:
  /// **'قرّب الباركود من الكاميرا لعرض السعر'**
  String get priceCheckerCameraScanPrompt;

  /// No description provided for @priceCheckerCameraStarting.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ تشغيل الكاميرا…'**
  String get priceCheckerCameraStarting;

  /// No description provided for @priceCheckerCameraUnavailable.
  ///
  /// In ar, this message translates to:
  /// **'الكاميرا غير متاحة'**
  String get priceCheckerCameraUnavailable;

  /// No description provided for @priceCheckerExitTooltip.
  ///
  /// In ar, this message translates to:
  /// **'الخروج من وضع كاشف الأسعار'**
  String get priceCheckerExitTooltip;

  /// No description provided for @priceCheckerExitTitle.
  ///
  /// In ar, this message translates to:
  /// **'الخروج من وضع كاشف الأسعار'**
  String get priceCheckerExitTitle;

  /// No description provided for @priceCheckerExitSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'أدخل الرمز السري للخروج'**
  String get priceCheckerExitSubtitle;

  /// No description provided for @priceCheckerWrongPin.
  ///
  /// In ar, this message translates to:
  /// **'رمز غير صحيح، حاول مرة أخرى'**
  String get priceCheckerWrongPin;

  /// No description provided for @priceCheckerModeButton.
  ///
  /// In ar, this message translates to:
  /// **'وضع كاشف الأسعار'**
  String get priceCheckerModeButton;

  /// No description provided for @priceCheckerSetupTitle.
  ///
  /// In ar, this message translates to:
  /// **'إعداد وضع كاشف الأسعار'**
  String get priceCheckerSetupTitle;

  /// No description provided for @priceCheckerSetupSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'سيعرض هذا الجهاز الأسعار للزبائن عند مسح الباركود. اختر رمزًا سريًا للخروج من هذا الوضع لاحقًا.'**
  String get priceCheckerSetupSubtitle;

  /// No description provided for @priceCheckerDeviceNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم الجهاز'**
  String get priceCheckerDeviceNameLabel;

  /// No description provided for @priceCheckerDeviceNameHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: كاشف الأسعار - الممر 3'**
  String get priceCheckerDeviceNameHint;

  /// No description provided for @priceCheckerLocationLabel.
  ///
  /// In ar, this message translates to:
  /// **'الموقع'**
  String get priceCheckerLocationLabel;

  /// No description provided for @priceCheckerPinLabel.
  ///
  /// In ar, this message translates to:
  /// **'الرمز السري'**
  String get priceCheckerPinLabel;

  /// No description provided for @priceCheckerPinHint.
  ///
  /// In ar, this message translates to:
  /// **'من 4 إلى 6 أرقام'**
  String get priceCheckerPinHint;

  /// No description provided for @priceCheckerConfirmPinLabel.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد الرمز السري'**
  String get priceCheckerConfirmPinLabel;

  /// No description provided for @priceCheckerPinTooShort.
  ///
  /// In ar, this message translates to:
  /// **'يجب أن يتكوّن الرمز من 4 أرقام على الأقل'**
  String get priceCheckerPinTooShort;

  /// No description provided for @priceCheckerPinMismatch.
  ///
  /// In ar, this message translates to:
  /// **'الرمزان غير متطابقين'**
  String get priceCheckerPinMismatch;

  /// No description provided for @priceCheckerRunOnStartupLabel.
  ///
  /// In ar, this message translates to:
  /// **'التشغيل تلقائيًا عند بدء النظام'**
  String get priceCheckerRunOnStartupLabel;

  /// No description provided for @priceCheckerRunOnStartupHint.
  ///
  /// In ar, this message translates to:
  /// **'يفتح التطبيق تلقائيًا عند تشغيل الجهاز'**
  String get priceCheckerRunOnStartupHint;

  /// No description provided for @priceCheckerStartButton.
  ///
  /// In ar, this message translates to:
  /// **'بدء الوضع'**
  String get priceCheckerStartButton;

  /// No description provided for @priceCheckerModeButtonTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تشغيل وضع كاشف الأسعار على هذا الجهاز'**
  String get priceCheckerModeButtonTooltip;

  /// No description provided for @priceCheckerSettingsTitle.
  ///
  /// In ar, this message translates to:
  /// **'وضع كاشف الأسعار'**
  String get priceCheckerSettingsTitle;

  /// No description provided for @priceCheckerSettingsDescription.
  ///
  /// In ar, this message translates to:
  /// **'حوّل هذا الجهاز إلى شاشة لعرض الأسعار للزبائن. يعمل دون تسجيل دخول، ويُحمى الخروج منه برمز سري.'**
  String get priceCheckerSettingsDescription;

  /// No description provided for @priceCheckerSettingsSetupButton.
  ///
  /// In ar, this message translates to:
  /// **'إعداد كاشف الأسعار'**
  String get priceCheckerSettingsSetupButton;

  /// No description provided for @priceCheckerConfiguredStatus.
  ///
  /// In ar, this message translates to:
  /// **'هذا الجهاز مُعدّ ككاشف أسعار'**
  String get priceCheckerConfiguredStatus;

  /// No description provided for @priceCheckerNoNameSet.
  ///
  /// In ar, this message translates to:
  /// **'بدون اسم'**
  String get priceCheckerNoNameSet;

  /// No description provided for @priceCheckerEnterModeButton.
  ///
  /// In ar, this message translates to:
  /// **'الدخول إلى الوضع'**
  String get priceCheckerEnterModeButton;

  /// No description provided for @priceCheckerChangePinButton.
  ///
  /// In ar, this message translates to:
  /// **'تغيير الرمز السري'**
  String get priceCheckerChangePinButton;

  /// No description provided for @priceCheckerEditDetailsButton.
  ///
  /// In ar, this message translates to:
  /// **'تعديل البيانات'**
  String get priceCheckerEditDetailsButton;

  /// No description provided for @priceCheckerRemoveButton.
  ///
  /// In ar, this message translates to:
  /// **'إيقاف الوضع'**
  String get priceCheckerRemoveButton;

  /// No description provided for @priceCheckerScanSettingsTitle.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات المسح'**
  String get priceCheckerScanSettingsTitle;

  /// No description provided for @priceCheckerCameraToggleLabel.
  ///
  /// In ar, this message translates to:
  /// **'المسح بالكاميرا'**
  String get priceCheckerCameraToggleLabel;

  /// No description provided for @priceCheckerCameraToggleHint.
  ///
  /// In ar, this message translates to:
  /// **'قراءة الباركود بكاميرا الجهاز دون الحاجة إلى ماسح خارجي'**
  String get priceCheckerCameraToggleHint;

  /// No description provided for @priceCheckerCameraFacingLabel.
  ///
  /// In ar, this message translates to:
  /// **'الكاميرا المستخدمة'**
  String get priceCheckerCameraFacingLabel;

  /// No description provided for @priceCheckerCameraFront.
  ///
  /// In ar, this message translates to:
  /// **'الأمامية'**
  String get priceCheckerCameraFront;

  /// No description provided for @priceCheckerCameraBack.
  ///
  /// In ar, this message translates to:
  /// **'الخلفية'**
  String get priceCheckerCameraBack;

  /// No description provided for @editCustomerTitle.
  ///
  /// In ar, this message translates to:
  /// **'تعديل بيانات الزبون'**
  String get editCustomerTitle;

  /// No description provided for @editSupplierTitle.
  ///
  /// In ar, this message translates to:
  /// **'تعديل بيانات المورد'**
  String get editSupplierTitle;

  /// No description provided for @editContactTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تعديل البيانات'**
  String get editContactTooltip;

  /// No description provided for @customerUpdateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ بيانات الزبون. تحقق من الاتصال وحاول مجددًا.'**
  String get customerUpdateError;

  /// No description provided for @supplierUpdateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ بيانات المورد. تحقق من الاتصال وحاول مجددًا.'**
  String get supplierUpdateError;

  /// No description provided for @customerUpdatedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ بيانات الزبون.'**
  String get customerUpdatedMessage;

  /// No description provided for @supplierUpdatedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ بيانات المورد.'**
  String get supplierUpdatedMessage;

  /// No description provided for @supplierProfileTitle.
  ///
  /// In ar, this message translates to:
  /// **'بيانات المورد'**
  String get supplierProfileTitle;

  /// No description provided for @priceCheckerTorchToggleLabel.
  ///
  /// In ar, this message translates to:
  /// **'تشغيل الفلاش أثناء المسح'**
  String get priceCheckerTorchToggleLabel;

  /// No description provided for @priceCheckerTorchToggleHint.
  ///
  /// In ar, this message translates to:
  /// **'يحسّن قراءة الباركود في الإضاءة الضعيفة (يعمل مع الكاميرا الخلفية فقط)'**
  String get priceCheckerTorchToggleHint;

  /// No description provided for @priceCheckerTorchTooltip.
  ///
  /// In ar, this message translates to:
  /// **'الفلاش'**
  String get priceCheckerTorchTooltip;

  /// No description provided for @priceCheckerSpeakToggleLabel.
  ///
  /// In ar, this message translates to:
  /// **'نطق اسم المنتج والسعر'**
  String get priceCheckerSpeakToggleLabel;

  /// No description provided for @priceCheckerSpeakToggleHint.
  ///
  /// In ar, this message translates to:
  /// **'يقرأ الجهاز اسم المنتج وسعره بصوت مسموع عند العثور عليه'**
  String get priceCheckerSpeakToggleHint;

  /// Spoken aloud when a product is found on the kiosk: name then price in dinar.
  ///
  /// In ar, this message translates to:
  /// **'{product}، السعر {price} دينار'**
  String priceCheckerSpokenResult(String product, String price);

  /// No description provided for @priceCheckerDwellLabel.
  ///
  /// In ar, this message translates to:
  /// **'مدة عرض المنتج'**
  String get priceCheckerDwellLabel;

  /// No description provided for @priceCheckerDwellHint.
  ///
  /// In ar, this message translates to:
  /// **'المدة قبل العودة تلقائيًا إلى شاشة المسح'**
  String get priceCheckerDwellHint;

  /// How long a found product stays on the kiosk screen, e.g. 8 ثوانٍ.
  ///
  /// In ar, this message translates to:
  /// **'{seconds, plural, =1{ثانية واحدة} =2{ثانيتان} few{{seconds} ثوانٍ} many{{seconds} ثانية} other{{seconds} ثانية}}'**
  String priceCheckerDwellSecondsValue(int seconds);

  /// No description provided for @priceCheckerRemoveConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'إيقاف وضع كاشف الأسعار؟'**
  String get priceCheckerRemoveConfirmTitle;

  /// No description provided for @priceCheckerRemoveConfirmMessage.
  ///
  /// In ar, this message translates to:
  /// **'سيعود هذا الجهاز جهازًا عاديًا لنقطة البيع. يمكنك إعداده مجددًا في أي وقت.'**
  String get priceCheckerRemoveConfirmMessage;

  /// No description provided for @priceCheckerChangePinTitle.
  ///
  /// In ar, this message translates to:
  /// **'تغيير الرمز السري'**
  String get priceCheckerChangePinTitle;

  /// No description provided for @startupSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'بدء التشغيل'**
  String get startupSectionTitle;

  /// No description provided for @startupSectionSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'اجعل التطبيق يفتح تلقائيًا عند تشغيل الجهاز — مفيد لأجهزة الكاشير والكاشف.'**
  String get startupSectionSubtitle;

  /// No description provided for @clearCartConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'مسح السلة؟'**
  String get clearCartConfirmTitle;

  /// No description provided for @clearCartConfirmMessage.
  ///
  /// In ar, this message translates to:
  /// **'سيؤدي هذا إلى إزالة جميع العناصر من السلة الحالية، ولا يمكن التراجع عنه.'**
  String get clearCartConfirmMessage;

  /// No description provided for @discardSaleConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'تجاهل البيع المُعلّق؟'**
  String get discardSaleConfirmTitle;

  /// No description provided for @discardSaleConfirmMessage.
  ///
  /// In ar, this message translates to:
  /// **'سيتم حذف هذا البيع المُعلّق وجميع عناصره، ولا يمكن التراجع عنه.'**
  String get discardSaleConfirmMessage;

  /// No description provided for @discardSaleConfirmButton.
  ///
  /// In ar, this message translates to:
  /// **'تجاهل'**
  String get discardSaleConfirmButton;

  /// No description provided for @cartLineRemovedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم حذف العنصر'**
  String get cartLineRemovedMessage;

  /// No description provided for @undoButton.
  ///
  /// In ar, this message translates to:
  /// **'تراجع'**
  String get undoButton;

  /// No description provided for @clearPurchaseDraftConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'مسح مسودة الشراء؟'**
  String get clearPurchaseDraftConfirmTitle;

  /// No description provided for @clearPurchaseDraftConfirmMessage.
  ///
  /// In ar, this message translates to:
  /// **'سيؤدي هذا إلى إزالة جميع العناصر من المسودة الحالية، ولا يمكن التراجع عنه.'**
  String get clearPurchaseDraftConfirmMessage;

  /// No description provided for @submitPurchaseOrderConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'إرسال أمر الشراء؟'**
  String get submitPurchaseOrderConfirmTitle;

  /// No description provided for @submitPurchaseOrderConfirmMessage.
  ///
  /// In ar, this message translates to:
  /// **'سيتم إرسال أمر الشراء إلى المورّد للاعتماد.'**
  String get submitPurchaseOrderConfirmMessage;

  /// No description provided for @cancelPurchaseOrderConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء أمر الشراء؟'**
  String get cancelPurchaseOrderConfirmTitle;

  /// No description provided for @cancelPurchaseOrderConfirmMessage.
  ///
  /// In ar, this message translates to:
  /// **'سيؤدي إلغاء أمر الشراء إلى عكس أي مخزون تم استلامه منه، ولا يمكن التراجع عن هذا الإجراء.'**
  String get cancelPurchaseOrderConfirmMessage;

  /// No description provided for @cancelPurchaseOrderConfirmButton.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد الإلغاء'**
  String get cancelPurchaseOrderConfirmButton;

  /// No description provided for @unauthorizedAskManagerHint.
  ///
  /// In ar, this message translates to:
  /// **'اطلب من المدير منحك صلاحية الوصول إلى هذه الشاشة.'**
  String get unauthorizedAskManagerHint;

  /// No description provided for @backToHomeButton.
  ///
  /// In ar, this message translates to:
  /// **'العودة إلى الرئيسية'**
  String get backToHomeButton;

  /// No description provided for @unsavedChangesTitle.
  ///
  /// In ar, this message translates to:
  /// **'تجاهل التغييرات؟'**
  String get unsavedChangesTitle;

  /// No description provided for @unsavedChangesMessage.
  ///
  /// In ar, this message translates to:
  /// **'لديك تغييرات لم تُحفظ بعد. ستُفقد إذا غادرت الآن.'**
  String get unsavedChangesMessage;

  /// No description provided for @discardChangesButton.
  ///
  /// In ar, this message translates to:
  /// **'تجاهل التغييرات'**
  String get discardChangesButton;

  /// No description provided for @keepEditingButton.
  ///
  /// In ar, this message translates to:
  /// **'متابعة التعديل'**
  String get keepEditingButton;

  /// No description provided for @dashboardGetStartedTitle.
  ///
  /// In ar, this message translates to:
  /// **'لنبدأ'**
  String get dashboardGetStartedTitle;

  /// No description provided for @dashboardGetStartedSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'أكمل هذه الخطوات لتجهيز متجرك للعمل.'**
  String get dashboardGetStartedSubtitle;

  /// No description provided for @dashboardGetStartedAddProduct.
  ///
  /// In ar, this message translates to:
  /// **'أضف أول منتج'**
  String get dashboardGetStartedAddProduct;

  /// No description provided for @dashboardGetStartedAddCustomer.
  ///
  /// In ar, this message translates to:
  /// **'أضف أول عميل'**
  String get dashboardGetStartedAddCustomer;

  /// No description provided for @dashboardGetStartedFirstSale.
  ///
  /// In ar, this message translates to:
  /// **'سجّل أول عملية بيع'**
  String get dashboardGetStartedFirstSale;

  /// No description provided for @dashboardGetStartedDone.
  ///
  /// In ar, this message translates to:
  /// **'تم'**
  String get dashboardGetStartedDone;

  /// No description provided for @posCartRestoredMessage.
  ///
  /// In ar, this message translates to:
  /// **'تمت استعادة سلة بيع غير مكتملة'**
  String get posCartRestoredMessage;

  /// No description provided for @purchaseDraftRestoredMessage.
  ///
  /// In ar, this message translates to:
  /// **'تمت استعادة مسودة شراء محفوظة'**
  String get purchaseDraftRestoredMessage;

  /// No description provided for @aiAssistantDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'GPT'**
  String get aiAssistantDrawerLabel;

  /// No description provided for @aiAssistantTitle.
  ///
  /// In ar, this message translates to:
  /// **'GPT'**
  String get aiAssistantTitle;

  /// No description provided for @aiAssistantInputHint.
  ///
  /// In ar, this message translates to:
  /// **'اكتب رسالتك هنا…'**
  String get aiAssistantInputHint;

  /// No description provided for @aiAssistantDisclaimer.
  ///
  /// In ar, this message translates to:
  /// **'GPT قد يخطئ. تحقّق من المعلومات المهمة.'**
  String get aiAssistantDisclaimer;

  /// No description provided for @aiAssistantSendTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إرسال'**
  String get aiAssistantSendTooltip;

  /// No description provided for @aiAssistantNewChat.
  ///
  /// In ar, this message translates to:
  /// **'محادثة جديدة'**
  String get aiAssistantNewChat;

  /// No description provided for @aiAssistantHistoryTitle.
  ///
  /// In ar, this message translates to:
  /// **'المحادثات السابقة'**
  String get aiAssistantHistoryTitle;

  /// No description provided for @aiAssistantHistoryEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد محادثات بعد'**
  String get aiAssistantHistoryEmpty;

  /// No description provided for @aiAssistantDeleteConversation.
  ///
  /// In ar, this message translates to:
  /// **'حذف المحادثة'**
  String get aiAssistantDeleteConversation;

  /// No description provided for @aiAssistantEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'كيف يمكنني مساعدتك؟'**
  String get aiAssistantEmptyTitle;

  /// No description provided for @aiAssistantEmptySubtitle.
  ///
  /// In ar, this message translates to:
  /// **'اسأل GPT عن أي شيء يخص متجرك.'**
  String get aiAssistantEmptySubtitle;

  /// No description provided for @aiAssistantThinking.
  ///
  /// In ar, this message translates to:
  /// **'يكتب…'**
  String get aiAssistantThinking;

  /// No description provided for @aiAssistantThinkingLabel.
  ///
  /// In ar, this message translates to:
  /// **'طريقة التفكير'**
  String get aiAssistantThinkingLabel;

  /// No description provided for @aiAssistantSuggestion1.
  ///
  /// In ar, this message translates to:
  /// **'اكتب رسالة ترحيب لعملاء متجري'**
  String get aiAssistantSuggestion1;

  /// No description provided for @aiAssistantSuggestion2.
  ///
  /// In ar, this message translates to:
  /// **'اقترح أفكارًا لعرض ترويجي لهذا الأسبوع'**
  String get aiAssistantSuggestion2;

  /// No description provided for @aiAssistantSuggestion3.
  ///
  /// In ar, this message translates to:
  /// **'اكتب وصفًا جذابًا لمنتج جديد'**
  String get aiAssistantSuggestion3;

  /// No description provided for @aiAssistantErrorNotEntitled.
  ///
  /// In ar, this message translates to:
  /// **'GPT غير مفعّل لهذا المتجر.'**
  String get aiAssistantErrorNotEntitled;

  /// No description provided for @aiAssistantErrorNetwork.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر الاتصال بـ GPT. تحقق من الشبكة وحاول مجددًا.'**
  String get aiAssistantErrorNetwork;

  /// No description provided for @aiAssistantErrorGeneric.
  ///
  /// In ar, this message translates to:
  /// **'حدث خطأ أثناء معالجة طلبك. حاول مرة أخرى.'**
  String get aiAssistantErrorGeneric;

  /// No description provided for @aiAssistantErrorRateLimited.
  ///
  /// In ar, this message translates to:
  /// **'لقد بلغت حدّ الاستخدام. حاول مرة أخرى لاحقًا.'**
  String get aiAssistantErrorRateLimited;

  /// No description provided for @aiAssistantErrorTooManyImages.
  ///
  /// In ar, this message translates to:
  /// **'عدد الصور كبير جدًا. الحد الأقصى ٥ صور.'**
  String get aiAssistantErrorTooManyImages;

  /// No description provided for @aiAssistantAttachTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إرفاق'**
  String get aiAssistantAttachTooltip;

  /// No description provided for @aiAssistantAttachImage.
  ///
  /// In ar, this message translates to:
  /// **'صورة من المعرض'**
  String get aiAssistantAttachImage;

  /// No description provided for @aiAssistantAttachCamera.
  ///
  /// In ar, this message translates to:
  /// **'التقاط صورة'**
  String get aiAssistantAttachCamera;

  /// No description provided for @aiAssistantAttachFile.
  ///
  /// In ar, this message translates to:
  /// **'ملف'**
  String get aiAssistantAttachFile;

  /// No description provided for @aiAssistantRemoveAttachment.
  ///
  /// In ar, this message translates to:
  /// **'إزالة المرفق'**
  String get aiAssistantRemoveAttachment;

  /// No description provided for @aiAssistantAttachmentImage.
  ///
  /// In ar, this message translates to:
  /// **'صورة'**
  String get aiAssistantAttachmentImage;

  /// No description provided for @aiAssistantRecordTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل رسالة صوتية'**
  String get aiAssistantRecordTooltip;

  /// No description provided for @aiAssistantRecordCancelTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء التسجيل'**
  String get aiAssistantRecordCancelTooltip;

  /// No description provided for @aiAssistantVoiceMessage.
  ///
  /// In ar, this message translates to:
  /// **'رسالة صوتية'**
  String get aiAssistantVoiceMessage;

  /// No description provided for @aiAssistantRecording.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ التسجيل…'**
  String get aiAssistantRecording;

  /// No description provided for @aiAssistantMicPermissionDenied.
  ///
  /// In ar, this message translates to:
  /// **'يلزم إذن الميكروفون لتسجيل الرسائل الصوتية. فعّله من إعدادات الجهاز.'**
  String get aiAssistantMicPermissionDenied;

  /// No description provided for @aiAssistantImageLimit.
  ///
  /// In ar, this message translates to:
  /// **'يمكنك إرفاق {count} صور كحد أقصى'**
  String aiAssistantImageLimit(int count);

  /// No description provided for @aiAssistantUsageTitle.
  ///
  /// In ar, this message translates to:
  /// **'حدود الاستخدام'**
  String get aiAssistantUsageTitle;

  /// No description provided for @aiAssistantUsageFiveHour.
  ///
  /// In ar, this message translates to:
  /// **'آخر ٥ ساعات'**
  String get aiAssistantUsageFiveHour;

  /// No description provided for @aiAssistantUsageWeekly.
  ///
  /// In ar, this message translates to:
  /// **'هذا الأسبوع'**
  String get aiAssistantUsageWeekly;

  /// No description provided for @aiAssistantUsageUnlimited.
  ///
  /// In ar, this message translates to:
  /// **'غير محدود'**
  String get aiAssistantUsageUnlimited;

  /// No description provided for @aiAssistantUsageRemaining.
  ///
  /// In ar, this message translates to:
  /// **'متبقٍ {count}'**
  String aiAssistantUsageRemaining(int count);

  /// No description provided for @aiAssistantUsageUsedOfLimit.
  ///
  /// In ar, this message translates to:
  /// **'{used} من {limit}'**
  String aiAssistantUsageUsedOfLimit(int used, int limit);

  /// No description provided for @aiAssistantUsageResets.
  ///
  /// In ar, this message translates to:
  /// **'يتجدد {time}'**
  String aiAssistantUsageResets(String time);

  /// No description provided for @aiAssistantActionEdit.
  ///
  /// In ar, this message translates to:
  /// **'تعديل الرسالة'**
  String get aiAssistantActionEdit;

  /// No description provided for @aiAssistantActionRetry.
  ///
  /// In ar, this message translates to:
  /// **'إعادة المحاولة'**
  String get aiAssistantActionRetry;

  /// No description provided for @aiAssistantActionCopy.
  ///
  /// In ar, this message translates to:
  /// **'نسخ'**
  String get aiAssistantActionCopy;

  /// No description provided for @aiAssistantCopied.
  ///
  /// In ar, this message translates to:
  /// **'تم نسخ الرد'**
  String get aiAssistantCopied;

  /// No description provided for @aiAssistantToolQuerying.
  ///
  /// In ar, this message translates to:
  /// **'يستعلم عن {label}'**
  String aiAssistantToolQuerying(String label);

  /// No description provided for @aiAssistantToolWorking.
  ///
  /// In ar, this message translates to:
  /// **'يجمع البيانات'**
  String get aiAssistantToolWorking;

  /// No description provided for @aiAssistantToolDetailsTitle.
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل الأداة'**
  String get aiAssistantToolDetailsTitle;

  /// No description provided for @aiAssistantToolInputs.
  ///
  /// In ar, this message translates to:
  /// **'المدخلات'**
  String get aiAssistantToolInputs;

  /// No description provided for @aiAssistantToolResult.
  ///
  /// In ar, this message translates to:
  /// **'النتيجة'**
  String get aiAssistantToolResult;

  /// No description provided for @aiAssistantToolNoOutput.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد نتيجة'**
  String get aiAssistantToolNoOutput;

  /// No description provided for @aiAssistantToolStatusOk.
  ///
  /// In ar, this message translates to:
  /// **'نجحت'**
  String get aiAssistantToolStatusOk;

  /// No description provided for @aiAssistantToolStatusFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشلت'**
  String get aiAssistantToolStatusFailed;

  /// No description provided for @aiAssistantAskUserSubmit.
  ///
  /// In ar, this message translates to:
  /// **'إرسال الإجابة'**
  String get aiAssistantAskUserSubmit;

  /// No description provided for @aiAssistantAskUserSkip.
  ///
  /// In ar, this message translates to:
  /// **'تخطّي'**
  String get aiAssistantAskUserSkip;

  /// No description provided for @aiAssistantAskUserOther.
  ///
  /// In ar, this message translates to:
  /// **'أخرى…'**
  String get aiAssistantAskUserOther;

  /// No description provided for @aiAssistantAskUserOtherHint.
  ///
  /// In ar, this message translates to:
  /// **'اكتب إجابتك هنا'**
  String get aiAssistantAskUserOtherHint;

  /// No description provided for @aiAssistantAskUserTextHint.
  ///
  /// In ar, this message translates to:
  /// **'اكتب إجابتك'**
  String get aiAssistantAskUserTextHint;

  /// No description provided for @aiAssistantAskUserAnswered.
  ///
  /// In ar, this message translates to:
  /// **'تم إرسال إجابتك'**
  String get aiAssistantAskUserAnswered;

  /// No description provided for @aiAssistantAskUserSkipped.
  ///
  /// In ar, this message translates to:
  /// **'تم تخطّي السؤال'**
  String get aiAssistantAskUserSkipped;

  /// No description provided for @aiAssistantAskUserConfirmYes.
  ///
  /// In ar, this message translates to:
  /// **'نعم'**
  String get aiAssistantAskUserConfirmYes;

  /// No description provided for @aiAssistantAskUserConfirmNo.
  ///
  /// In ar, this message translates to:
  /// **'لا'**
  String get aiAssistantAskUserConfirmNo;

  /// No description provided for @aiAssistantProductPickerChoose.
  ///
  /// In ar, this message translates to:
  /// **'ابحث واختر منتجًا'**
  String get aiAssistantProductPickerChoose;

  /// No description provided for @aiAssistantProductPickerChooseOther.
  ///
  /// In ar, this message translates to:
  /// **'ابحث عن منتج آخر…'**
  String get aiAssistantProductPickerChooseOther;

  /// No description provided for @aiAssistantProductPickerCreateNew.
  ///
  /// In ar, this message translates to:
  /// **'إنشاء منتج جديد'**
  String get aiAssistantProductPickerCreateNew;

  /// No description provided for @aiAssistantProductPickerCreateNewChosen.
  ///
  /// In ar, this message translates to:
  /// **'سيُنشأ منتج جديد'**
  String get aiAssistantProductPickerCreateNewChosen;

  /// No description provided for @aiAssistantProductPickerTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختر المنتج'**
  String get aiAssistantProductPickerTitle;

  /// No description provided for @aiAssistantProductPickerSearchHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث بالاسم أو الباركود'**
  String get aiAssistantProductPickerSearchHint;

  /// No description provided for @aiAssistantProductPickerEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد منتجات مطابقة'**
  String get aiAssistantProductPickerEmpty;

  /// No description provided for @aiAssistantProductPickerLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل المنتجات'**
  String get aiAssistantProductPickerLoadError;

  /// No description provided for @aiAssistantLinkUnavailable.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر فتح الصفحة المطلوبة.'**
  String get aiAssistantLinkUnavailable;

  /// No description provided for @aiAssistantLinkCopied.
  ///
  /// In ar, this message translates to:
  /// **'تم نسخ الرابط'**
  String get aiAssistantLinkCopied;

  /// No description provided for @aiAssistantSearchedWeb.
  ///
  /// In ar, this message translates to:
  /// **'بحث في الويب'**
  String get aiAssistantSearchedWeb;

  /// No description provided for @aiAssistantSourcesTitle.
  ///
  /// In ar, this message translates to:
  /// **'المصادر'**
  String get aiAssistantSourcesTitle;

  /// No description provided for @aiAssistantAskUserRequired.
  ///
  /// In ar, this message translates to:
  /// **'هذا السؤال مطلوب'**
  String get aiAssistantAskUserRequired;

  /// No description provided for @aiAssistantAskUserNumberInvalid.
  ///
  /// In ar, this message translates to:
  /// **'أدخل رقمًا صحيحًا'**
  String get aiAssistantAskUserNumberInvalid;

  /// No description provided for @aiAssistantAskUserNumberMin.
  ///
  /// In ar, this message translates to:
  /// **'الحد الأدنى {value}'**
  String aiAssistantAskUserNumberMin(String value);

  /// No description provided for @aiAssistantAskUserNumberMax.
  ///
  /// In ar, this message translates to:
  /// **'الحد الأقصى {value}'**
  String aiAssistantAskUserNumberMax(String value);

  /// No description provided for @aiAssistantAskUserSelectRange.
  ///
  /// In ar, this message translates to:
  /// **'اختر من {min} إلى {max}'**
  String aiAssistantAskUserSelectRange(int min, int max);

  /// No description provided for @aiAssistantAskUserSelectAtLeast.
  ///
  /// In ar, this message translates to:
  /// **'اختر {min} على الأقل'**
  String aiAssistantAskUserSelectAtLeast(int min);

  /// No description provided for @aiAssistantAskUserPendingComposer.
  ///
  /// In ar, this message translates to:
  /// **'أجب عن السؤال أعلاه للمتابعة'**
  String get aiAssistantAskUserPendingComposer;

  /// No description provided for @migrationTitle.
  ///
  /// In ar, this message translates to:
  /// **'نقل البيانات'**
  String get migrationTitle;

  /// No description provided for @migrationSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'استيراد بياناتك من نظام نقاط البيع القديم'**
  String get migrationSubtitle;

  /// No description provided for @migrationHeroDescription.
  ///
  /// In ar, this message translates to:
  /// **'انقل منتجاتك وفئاتك وعملاءك ومورّديك ومخزونك من نظامك القديم إلى دفتر.'**
  String get migrationHeroDescription;

  /// No description provided for @migrationLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل أدوات النقل'**
  String get migrationLoadError;

  /// No description provided for @migrationConnectionSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'الاتصال بقاعدة البيانات القديمة'**
  String get migrationConnectionSectionTitle;

  /// No description provided for @migrationConnectionSectionSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'اختر نظامك القديم وأدخل بيانات الاتصال بقاعدة بياناته.'**
  String get migrationConnectionSectionSubtitle;

  /// No description provided for @migrationSourceNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم مصدر البيانات'**
  String get migrationSourceNameLabel;

  /// No description provided for @migrationSystemLabel.
  ///
  /// In ar, this message translates to:
  /// **'النظام القديم'**
  String get migrationSystemLabel;

  /// No description provided for @migrationStubSystemNotice.
  ///
  /// In ar, this message translates to:
  /// **'هذا النظام متاح لفحص التوافق فقط حاليًا؛ سيُفعَّل الاستيراد لاحقًا.'**
  String get migrationStubSystemNotice;

  /// No description provided for @migrationDatabaseFileLabel.
  ///
  /// In ar, this message translates to:
  /// **'مسار ملف قاعدة البيانات'**
  String get migrationDatabaseFileLabel;

  /// No description provided for @migrationHostLabel.
  ///
  /// In ar, this message translates to:
  /// **'المضيف'**
  String get migrationHostLabel;

  /// No description provided for @migrationPortLabel.
  ///
  /// In ar, this message translates to:
  /// **'المنفذ'**
  String get migrationPortLabel;

  /// No description provided for @migrationDatabaseLabel.
  ///
  /// In ar, this message translates to:
  /// **'قاعدة البيانات'**
  String get migrationDatabaseLabel;

  /// No description provided for @migrationUsernameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم المستخدم'**
  String get migrationUsernameLabel;

  /// No description provided for @migrationPasswordLabel.
  ///
  /// In ar, this message translates to:
  /// **'كلمة المرور'**
  String get migrationPasswordLabel;

  /// No description provided for @migrationPasswordKeepHint.
  ///
  /// In ar, this message translates to:
  /// **'اتركها فارغة للإبقاء على كلمة المرور المحفوظة'**
  String get migrationPasswordKeepHint;

  /// No description provided for @migrationAdvancedSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'خيارات متقدمة (اختياري)'**
  String get migrationAdvancedSectionTitle;

  /// No description provided for @migrationAdvancedSectionSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'لازمة للأنظمة القديمة جدًا (مثل SQL Server 2000 الذي يحتاج مُشغّل FreeTDS).'**
  String get migrationAdvancedSectionSubtitle;

  /// No description provided for @migrationOdbcDriverLabel.
  ///
  /// In ar, this message translates to:
  /// **'مُشغّل ODBC'**
  String get migrationOdbcDriverLabel;

  /// No description provided for @migrationOdbcDriverHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: FreeTDS أو ODBC Driver 18 for SQL Server'**
  String get migrationOdbcDriverHint;

  /// No description provided for @migrationTdsVersionLabel.
  ///
  /// In ar, this message translates to:
  /// **'إصدار TDS'**
  String get migrationTdsVersionLabel;

  /// No description provided for @migrationTdsVersionHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: 7.0 لـ SQL Server 2000'**
  String get migrationTdsVersionHint;

  /// No description provided for @migrationEncodingLabel.
  ///
  /// In ar, this message translates to:
  /// **'ترميز النص'**
  String get migrationEncodingLabel;

  /// No description provided for @migrationEncodingHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: cp1256 للنصوص العربية القديمة'**
  String get migrationEncodingHint;

  /// No description provided for @migrationScanButton.
  ///
  /// In ar, this message translates to:
  /// **'بحث في الشبكة'**
  String get migrationScanButton;

  /// No description provided for @migrationScanTitle.
  ///
  /// In ar, this message translates to:
  /// **'خوادم SQL Server في الشبكة'**
  String get migrationScanTitle;

  /// No description provided for @migrationScanSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'اختر خادم نظام نقاط البيع الخاص بالعميل لتعبئة المضيف والمنفذ.'**
  String get migrationScanSubtitle;

  /// No description provided for @migrationScanEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لم يُعثر على أي خادم. تأكد من تشغيل الجهاز على نفس الشبكة، أو أدخل المضيف يدويًا.'**
  String get migrationScanEmpty;

  /// No description provided for @migrationScanFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر البحث في الشبكة'**
  String get migrationScanFailed;

  /// No description provided for @migrationScanSelected.
  ///
  /// In ar, this message translates to:
  /// **'تم اختيار {server}'**
  String migrationScanSelected(String server);

  /// No description provided for @migrationSaveSourceButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ المصدر'**
  String get migrationSaveSourceButton;

  /// No description provided for @migrationTestButton.
  ///
  /// In ar, this message translates to:
  /// **'اختبار الاتصال'**
  String get migrationTestButton;

  /// No description provided for @migrationCheckButton.
  ///
  /// In ar, this message translates to:
  /// **'فحص التوافق'**
  String get migrationCheckButton;

  /// No description provided for @migrationTestSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم الاتصال — {count} جدول'**
  String migrationTestSuccess(int count);

  /// No description provided for @migrationTestFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل الاتصال بقاعدة البيانات'**
  String get migrationTestFailed;

  /// No description provided for @migrationCompatTitle.
  ///
  /// In ar, this message translates to:
  /// **'التوافق'**
  String get migrationCompatTitle;

  /// No description provided for @migrationNotChecked.
  ///
  /// In ar, this message translates to:
  /// **'لم يتم فحص التوافق بعد'**
  String get migrationNotChecked;

  /// No description provided for @migrationCompatibleMessage.
  ///
  /// In ar, this message translates to:
  /// **'قاعدة البيانات متوافقة وجاهزة للنقل.'**
  String get migrationCompatibleMessage;

  /// No description provided for @migrationIncompatibleMessage.
  ///
  /// In ar, this message translates to:
  /// **'قاعدة البيانات غير متوافقة مع هذا النظام.'**
  String get migrationIncompatibleMessage;

  /// No description provided for @migrationDetectedVersion.
  ///
  /// In ar, this message translates to:
  /// **'الإصدار المكتشف: {version}'**
  String migrationDetectedVersion(String version);

  /// No description provided for @migrationCompatible.
  ///
  /// In ar, this message translates to:
  /// **'متوافق'**
  String get migrationCompatible;

  /// No description provided for @migrationIncompatible.
  ///
  /// In ar, this message translates to:
  /// **'غير متوافق'**
  String get migrationIncompatible;

  /// No description provided for @migrationMissingTables.
  ///
  /// In ar, this message translates to:
  /// **'جداول مفقودة'**
  String get migrationMissingTables;

  /// No description provided for @migrationEntitiesSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'البيانات المراد نقلها'**
  String get migrationEntitiesSectionTitle;

  /// No description provided for @migrationEntitiesSectionSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'اختر أنواع البيانات التي تريد نقلها.'**
  String get migrationEntitiesSectionSubtitle;

  /// No description provided for @migrationWithoutQuantitiesLabel.
  ///
  /// In ar, this message translates to:
  /// **'نقل المنتجات بدون كميات'**
  String get migrationWithoutQuantitiesLabel;

  /// No description provided for @migrationWithoutQuantitiesSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'استورد المنتجات فقط دون كميات المخزون، وابدأ الجرد من جديد في دفتر.'**
  String get migrationWithoutQuantitiesSubtitle;

  /// No description provided for @migrationStockSourceSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'كميات المخزون'**
  String get migrationStockSourceSectionTitle;

  /// No description provided for @migrationStockSourceSnapshotLabel.
  ///
  /// In ar, this message translates to:
  /// **'نقل الكميات كما هي'**
  String get migrationStockSourceSnapshotLabel;

  /// No description provided for @migrationStockSourceSnapshotSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'تُنقل كميات المخزون الحالية من النظام القديم كما هي.'**
  String get migrationStockSourceSnapshotSubtitle;

  /// No description provided for @migrationStockSourceReconstructLabel.
  ///
  /// In ar, this message translates to:
  /// **'احتساب الكميات من الفواتير'**
  String get migrationStockSourceReconstructLabel;

  /// No description provided for @migrationStockSourceReconstructSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'تُحتسب كمية كل صنف من فواتير الشراء ناقص فواتير البيع. مناسب عندما تكون كميات النظام القديم غير موثوقة لكن فواتيره سليمة. يتطلّب نقل فواتير الشراء والبيع، وسيُنبّهك إن بِيع صنف بكمية أكبر مما اشتُري.'**
  String get migrationStockSourceReconstructSubtitle;

  /// No description provided for @migrationStockSourceNoneLabel.
  ///
  /// In ar, this message translates to:
  /// **'بدون كميات'**
  String get migrationStockSourceNoneLabel;

  /// No description provided for @migrationStockSourceNoneSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'تُنقل المنتجات دون أي كميات، ويُبدأ الجرد من جديد في دفتر.'**
  String get migrationStockSourceNoneSubtitle;

  /// No description provided for @migrationEntityUnit.
  ///
  /// In ar, this message translates to:
  /// **'وحدات القياس'**
  String get migrationEntityUnit;

  /// No description provided for @migrationEntityCategory.
  ///
  /// In ar, this message translates to:
  /// **'الفئات'**
  String get migrationEntityCategory;

  /// No description provided for @migrationEntityProduct.
  ///
  /// In ar, this message translates to:
  /// **'المنتجات'**
  String get migrationEntityProduct;

  /// No description provided for @migrationEntityVariant.
  ///
  /// In ar, this message translates to:
  /// **'المتغيرات'**
  String get migrationEntityVariant;

  /// No description provided for @migrationEntityProductUnit.
  ///
  /// In ar, this message translates to:
  /// **'وحدات المنتج'**
  String get migrationEntityProductUnit;

  /// No description provided for @migrationEntityStock.
  ///
  /// In ar, this message translates to:
  /// **'المخزون'**
  String get migrationEntityStock;

  /// No description provided for @migrationEntityCustomer.
  ///
  /// In ar, this message translates to:
  /// **'العملاء'**
  String get migrationEntityCustomer;

  /// No description provided for @migrationEntitySupplier.
  ///
  /// In ar, this message translates to:
  /// **'المورّدون'**
  String get migrationEntitySupplier;

  /// No description provided for @migrationEntityPurchaseOrder.
  ///
  /// In ar, this message translates to:
  /// **'فواتير الشراء'**
  String get migrationEntityPurchaseOrder;

  /// No description provided for @migrationEntitySupplierPayment.
  ///
  /// In ar, this message translates to:
  /// **'مدفوعات الموردين'**
  String get migrationEntitySupplierPayment;

  /// No description provided for @migrationEntitySale.
  ///
  /// In ar, this message translates to:
  /// **'فواتير البيع'**
  String get migrationEntitySale;

  /// No description provided for @migrationEntityPayment.
  ///
  /// In ar, this message translates to:
  /// **'المدفوعات'**
  String get migrationEntityPayment;

  /// No description provided for @migrationEntityEmployee.
  ///
  /// In ar, this message translates to:
  /// **'الموظفون'**
  String get migrationEntityEmployee;

  /// No description provided for @migrationEntityExpenseCategory.
  ///
  /// In ar, this message translates to:
  /// **'فئات المصروفات'**
  String get migrationEntityExpenseCategory;

  /// No description provided for @migrationEntityExpense.
  ///
  /// In ar, this message translates to:
  /// **'المصروفات'**
  String get migrationEntityExpense;

  /// No description provided for @migrationRunSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'النقل'**
  String get migrationRunSectionTitle;

  /// No description provided for @migrationRunningLabel.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ التنفيذ…'**
  String get migrationRunningLabel;

  /// No description provided for @migrationDryRunHint.
  ///
  /// In ar, this message translates to:
  /// **'نفّذ تشغيلًا تجريبيًا أولًا للتحقق من البيانات قبل النقل الفعلي.'**
  String get migrationDryRunHint;

  /// No description provided for @migrationRunSucceeded.
  ///
  /// In ar, this message translates to:
  /// **'اكتمل بنجاح'**
  String get migrationRunSucceeded;

  /// No description provided for @migrationRunPartial.
  ///
  /// In ar, this message translates to:
  /// **'اكتمل مع وجود مشكلات'**
  String get migrationRunPartial;

  /// No description provided for @migrationRunFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل'**
  String get migrationRunFailed;

  /// No description provided for @migrationSummaryCreated.
  ///
  /// In ar, this message translates to:
  /// **'جديد'**
  String get migrationSummaryCreated;

  /// No description provided for @migrationSummaryUpdated.
  ///
  /// In ar, this message translates to:
  /// **'محدّث'**
  String get migrationSummaryUpdated;

  /// No description provided for @migrationSummaryFailed.
  ///
  /// In ar, this message translates to:
  /// **'فاشل'**
  String get migrationSummaryFailed;

  /// No description provided for @migrationViewIssuesButton.
  ///
  /// In ar, this message translates to:
  /// **'عرض المشكلات'**
  String get migrationViewIssuesButton;

  /// No description provided for @migrationImportGatedHint.
  ///
  /// In ar, this message translates to:
  /// **'أكمِل تشغيلًا تجريبيًا ناجحًا بلا أخطاء لتفعيل النقل.'**
  String get migrationImportGatedHint;

  /// No description provided for @migrationImportButton.
  ///
  /// In ar, this message translates to:
  /// **'بدء النقل'**
  String get migrationImportButton;

  /// No description provided for @migrationDryRunButton.
  ///
  /// In ar, this message translates to:
  /// **'تشغيل تجريبي'**
  String get migrationDryRunButton;

  /// No description provided for @migrationSourceSaved.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ المصدر'**
  String get migrationSourceSaved;

  /// No description provided for @migrationSourceSaveError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حفظ المصدر'**
  String get migrationSourceSaveError;

  /// No description provided for @migrationRunStartError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر بدء العملية'**
  String get migrationRunStartError;

  /// No description provided for @migrationDryRunStarted.
  ///
  /// In ar, this message translates to:
  /// **'بدأ التشغيل التجريبي'**
  String get migrationDryRunStarted;

  /// No description provided for @migrationImportStarted.
  ///
  /// In ar, this message translates to:
  /// **'بدأ النقل'**
  String get migrationImportStarted;

  /// No description provided for @paymentsHubDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'الخزينة'**
  String get paymentsHubDrawerLabel;

  /// No description provided for @paymentsHubTitle.
  ///
  /// In ar, this message translates to:
  /// **'الخزينة'**
  String get paymentsHubTitle;

  /// No description provided for @paymentsHubRefreshTooltip.
  ///
  /// In ar, this message translates to:
  /// **'تحديث المدفوعات'**
  String get paymentsHubRefreshTooltip;

  /// No description provided for @paymentsHubSegmentCustomer.
  ///
  /// In ar, this message translates to:
  /// **'مدفوعات العملاء (وارد)'**
  String get paymentsHubSegmentCustomer;

  /// No description provided for @paymentsHubSegmentSupplier.
  ///
  /// In ar, this message translates to:
  /// **'مدفوعات الموردين (صادر)'**
  String get paymentsHubSegmentSupplier;

  /// No description provided for @paymentsHubFilterAllMethods.
  ///
  /// In ar, this message translates to:
  /// **'كل الطرق'**
  String get paymentsHubFilterAllMethods;

  /// No description provided for @paymentsHubFilterDateRange.
  ///
  /// In ar, this message translates to:
  /// **'نطاق التاريخ'**
  String get paymentsHubFilterDateRange;

  /// Selected payments date-range chip label.
  ///
  /// In ar, this message translates to:
  /// **'{start} - {end}'**
  String paymentsHubFilterDateRangeValue(String start, String end);

  /// No description provided for @paymentsHubClearFilters.
  ///
  /// In ar, this message translates to:
  /// **'مسح عوامل التصفية'**
  String get paymentsHubClearFilters;

  /// No description provided for @paymentsHubCustomerEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مدفوعات عملاء'**
  String get paymentsHubCustomerEmptyTitle;

  /// No description provided for @paymentsHubCustomerEmptyMessage.
  ///
  /// In ar, this message translates to:
  /// **'ستظهر هنا المبالغ المحصّلة من العملاء.'**
  String get paymentsHubCustomerEmptyMessage;

  /// No description provided for @paymentsHubSupplierEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مدفوعات موردين'**
  String get paymentsHubSupplierEmptyTitle;

  /// No description provided for @paymentsHubSupplierEmptyMessage.
  ///
  /// In ar, this message translates to:
  /// **'ستظهر هنا المبالغ المدفوعة للموردين.'**
  String get paymentsHubSupplierEmptyMessage;

  /// No description provided for @paymentsHubLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل المدفوعات'**
  String get paymentsHubLoadError;

  /// No description provided for @paymentsHubWalkInCustomer.
  ///
  /// In ar, this message translates to:
  /// **'عميل نقدي'**
  String get paymentsHubWalkInCustomer;

  /// No description provided for @paymentsHubUnknownSupplier.
  ///
  /// In ar, this message translates to:
  /// **'مورد غير محدد'**
  String get paymentsHubUnknownSupplier;

  /// Linked customer invoice number on a payment row.
  ///
  /// In ar, this message translates to:
  /// **'فاتورة {number}'**
  String paymentsHubInvoiceValue(String number);

  /// Linked purchase order number on a supplier payment row.
  ///
  /// In ar, this message translates to:
  /// **'أمر شراء {number}'**
  String paymentsHubPurchaseOrderValue(String number);

  /// Commission charged on a payment.
  ///
  /// In ar, this message translates to:
  /// **'عمولة {amount}'**
  String paymentsHubCommissionValue(String amount);

  /// External reference on a payment row.
  ///
  /// In ar, this message translates to:
  /// **'مرجع: {reference}'**
  String paymentsHubReferenceValue(String reference);

  /// Who recorded the payment.
  ///
  /// In ar, this message translates to:
  /// **'سجّلها {username}'**
  String paymentsHubRecordedByValue(String username);

  /// No description provided for @paymentsHubReprintProofAction.
  ///
  /// In ar, this message translates to:
  /// **'إعادة طباعة سند'**
  String get paymentsHubReprintProofAction;

  /// No description provided for @paymentsHubPrintLogAction.
  ///
  /// In ar, this message translates to:
  /// **'سجل الطباعة'**
  String get paymentsHubPrintLogAction;

  /// No description provided for @paymentsHubReprintSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تمت إعادة طباعة السند'**
  String get paymentsHubReprintSuccess;

  /// No description provided for @paymentsHubReprintError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّرت إعادة طباعة السند'**
  String get paymentsHubReprintError;

  /// No description provided for @convertQuotationButton.
  ///
  /// In ar, this message translates to:
  /// **'تحويل إلى بيع'**
  String get convertQuotationButton;

  /// No description provided for @convertQuotationDialogTitle.
  ///
  /// In ar, this message translates to:
  /// **'تحويل عرض السعر إلى بيع'**
  String get convertQuotationDialogTitle;

  /// No description provided for @convertQuotationSaleTypeLabel.
  ///
  /// In ar, this message translates to:
  /// **'نوع البيع'**
  String get convertQuotationSaleTypeLabel;

  /// No description provided for @convertQuotationSaleTypeStandard.
  ///
  /// In ar, this message translates to:
  /// **'عادي'**
  String get convertQuotationSaleTypeStandard;

  /// No description provided for @convertQuotationSaleTypeCredit.
  ///
  /// In ar, this message translates to:
  /// **'آجل'**
  String get convertQuotationSaleTypeCredit;

  /// No description provided for @convertQuotationDownPaymentLabel.
  ///
  /// In ar, this message translates to:
  /// **'الدفعة المقدمة'**
  String get convertQuotationDownPaymentLabel;

  /// No description provided for @convertQuotationDownPaymentHelper.
  ///
  /// In ar, this message translates to:
  /// **'اختياري — المبلغ المحصّل عند التحويل.'**
  String get convertQuotationDownPaymentHelper;

  /// Hint shown when converting to a standard (paid-in-full) sale.
  ///
  /// In ar, this message translates to:
  /// **'يتطلب البيع العادي سداد كامل المبلغ ({total}).'**
  String convertQuotationStandardHint(String total);

  /// No description provided for @convertQuotationConfirm.
  ///
  /// In ar, this message translates to:
  /// **'تحويل'**
  String get convertQuotationConfirm;

  /// No description provided for @convertQuotationSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم تحويل عرض السعر إلى بيع'**
  String get convertQuotationSuccess;

  /// No description provided for @convertQuotationError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحويل عرض السعر'**
  String get convertQuotationError;

  /// Title for the subscription/relay status section and its page.
  ///
  /// In ar, this message translates to:
  /// **'الاشتراك والوصول عن بُعد'**
  String get subscriptionSectionTitle;

  /// Subtitle shown on the subscription tile in the settings hub.
  ///
  /// In ar, this message translates to:
  /// **'معرّف التثبيت وحالة اشتراكاتك'**
  String get subscriptionSectionSubtitle;

  /// Error state shown when the relay installation status fails to load.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل حالة الاشتراك.'**
  String get subscriptionStatusLoadError;

  /// Tooltip for the button that re-syncs subscription state from the relay server.
  ///
  /// In ar, this message translates to:
  /// **'تحديث من الخادم'**
  String get subscriptionRefreshTooltip;

  /// Snackbar shown when a relay sync fails; the cached snapshot is kept.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر الاتصال بالخادم لتحديث الحالة. يتم عرض آخر حالة محفوظة.'**
  String get subscriptionSyncFailedMessage;

  /// Snackbar shown after a successful relay sync.
  ///
  /// In ar, this message translates to:
  /// **'تم تحديث حالة الاشتراك.'**
  String get subscriptionSyncedMessage;

  /// Hero title used when the shop name is unknown.
  ///
  /// In ar, this message translates to:
  /// **'اشتراك دفتر'**
  String get subscriptionHeroFallbackTitle;

  /// Label for an active, unexpired subscription.
  ///
  /// In ar, this message translates to:
  /// **'نشط'**
  String get subscriptionStatusActive;

  /// Label for an expired subscription.
  ///
  /// In ar, this message translates to:
  /// **'منتهٍ'**
  String get subscriptionStatusExpired;

  /// Label for a subscription that has never been activated.
  ///
  /// In ar, this message translates to:
  /// **'غير مُفعّل'**
  String get subscriptionStatusInactive;

  /// Short on/enabled state used in status pills and rows.
  ///
  /// In ar, this message translates to:
  /// **'مُفعّل'**
  String get subscriptionStateOn;

  /// Short off/disabled state used in status pills and rows.
  ///
  /// In ar, this message translates to:
  /// **'متوقّف'**
  String get subscriptionStateOff;

  /// Hero subtitle showing the subscription end date.
  ///
  /// In ar, this message translates to:
  /// **'حتى {date}'**
  String subscriptionUntilDate(String date);

  /// Hero pill summarising remote-access state.
  ///
  /// In ar, this message translates to:
  /// **'الوصول عن بُعد · {state}'**
  String subscriptionRemoteAccessPill(String state);

  /// Hero pill summarising AI-assistant state.
  ///
  /// In ar, this message translates to:
  /// **'الذكاء الاصطناعي · {state}'**
  String subscriptionAiPill(String state);

  /// Section title for the relay installation identifier.
  ///
  /// In ar, this message translates to:
  /// **'معرّف التثبيت'**
  String get subscriptionInstallationIdTitle;

  /// Explains what the installation ID is for.
  ///
  /// In ar, this message translates to:
  /// **'أرسل هذا المعرّف للدعم لتفعيل اشتراكك أو تجديده.'**
  String get subscriptionInstallationIdHelper;

  /// Label for the copy-installation-ID button.
  ///
  /// In ar, this message translates to:
  /// **'نسخ'**
  String get subscriptionInstallationIdCopy;

  /// Snackbar confirming the installation ID was copied.
  ///
  /// In ar, this message translates to:
  /// **'تم نسخ معرّف التثبيت.'**
  String get subscriptionInstallationIdCopied;

  /// Callout title when the shop has no relay installation yet.
  ///
  /// In ar, this message translates to:
  /// **'لم يتم الربط بالخادم بعد'**
  String get subscriptionNotConfiguredTitle;

  /// Callout body when the shop has no relay installation yet.
  ///
  /// In ar, this message translates to:
  /// **'تواصل مع الدعم لتفعيل الوصول عن بُعد ومساعد الذكاء الاصطناعي.'**
  String get subscriptionNotConfiguredMessage;

  /// Section title for remote-access subscription state.
  ///
  /// In ar, this message translates to:
  /// **'الوصول عن بُعد'**
  String get subscriptionRemoteAccessTitle;

  /// Callout title when remote access is available.
  ///
  /// In ar, this message translates to:
  /// **'الوصول عن بُعد مُفعّل'**
  String get subscriptionRemoteAccessActiveTitle;

  /// Callout body when remote access is available.
  ///
  /// In ar, this message translates to:
  /// **'يمكنك استخدام التطبيق خارج المتجر عبر خادم دفتر.'**
  String get subscriptionRemoteAccessActiveMessage;

  /// Callout title when remote access is unavailable.
  ///
  /// In ar, this message translates to:
  /// **'الوصول عن بُعد غير مُفعّل'**
  String get subscriptionRemoteAccessInactiveTitle;

  /// Callout body when remote access is unavailable.
  ///
  /// In ar, this message translates to:
  /// **'تتطلب هذه الميزة اشتراكًا فعّالًا. تواصل مع الدعم لتفعيلها.'**
  String get subscriptionRemoteAccessInactiveMessage;

  /// Summary row label for the feature on/off state.
  ///
  /// In ar, this message translates to:
  /// **'الحالة'**
  String get subscriptionFieldStatus;

  /// Summary row label for the subscription state.
  ///
  /// In ar, this message translates to:
  /// **'الاشتراك'**
  String get subscriptionFieldSubscription;

  /// Summary row label for the subscription end date.
  ///
  /// In ar, this message translates to:
  /// **'ينتهي في'**
  String get subscriptionFieldExpiresOn;

  /// Summary row label for time left on the subscription.
  ///
  /// In ar, this message translates to:
  /// **'المدة المتبقية'**
  String get subscriptionFieldRemaining;

  /// Summary row label for the last connector check-in.
  ///
  /// In ar, this message translates to:
  /// **'آخر اتصال بالخادم'**
  String get subscriptionFieldLastConnected;

  /// Shown for an active subscription with no expiry date.
  ///
  /// In ar, this message translates to:
  /// **'بدون تاريخ انتهاء'**
  String get subscriptionExpiryNever;

  /// Days remaining until the subscription lapses.
  ///
  /// In ar, this message translates to:
  /// **'متبقّي {days} يوم'**
  String subscriptionDaysLeft(int days);

  /// Shown when the remote-access connector has never checked in.
  ///
  /// In ar, this message translates to:
  /// **'لم يتصل بعد'**
  String get subscriptionNeverConnected;

  /// Section title for the AI-assistant subscription state.
  ///
  /// In ar, this message translates to:
  /// **'مساعد الذكاء الاصطناعي'**
  String get subscriptionAiTitle;

  /// Callout title when AI is available.
  ///
  /// In ar, this message translates to:
  /// **'مساعد الذكاء الاصطناعي مُفعّل'**
  String get subscriptionAiActiveTitle;

  /// Callout body when AI is available.
  ///
  /// In ar, this message translates to:
  /// **'اشتراكك يشمل GPT. هذا هو استهلاكك الحالي.'**
  String get subscriptionAiActiveMessage;

  /// Callout title when AI is unavailable.
  ///
  /// In ar, this message translates to:
  /// **'مساعد الذكاء الاصطناعي غير مُفعّل'**
  String get subscriptionAiInactiveTitle;

  /// Callout body when AI is unavailable.
  ///
  /// In ar, this message translates to:
  /// **'أضِف GPT إلى اشتراكك للاستفادة منه. تواصل مع الدعم.'**
  String get subscriptionAiInactiveMessage;

  /// Shown when AI usage data could not be fetched.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل بيانات الاستهلاك حاليًا.'**
  String get subscriptionAiUsageUnavailable;

  /// Caption showing when the snapshot was last refreshed from the relay.
  ///
  /// In ar, this message translates to:
  /// **'آخر تحديث للحالة: {time}'**
  String subscriptionLastSynced(String time);

  /// No description provided for @clientUpdatesTitle.
  ///
  /// In ar, this message translates to:
  /// **'تحديثات التطبيق'**
  String get clientUpdatesTitle;

  /// No description provided for @clientUpdatesSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'تحقّق من وجود تحديث وثبّته'**
  String get clientUpdatesSubtitle;

  /// No description provided for @getAppsTitle.
  ///
  /// In ar, this message translates to:
  /// **'تنزيل التطبيق على جهاز جديد'**
  String get getAppsTitle;

  /// No description provided for @getAppsSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'رمز QR ورابط للتنزيل عبر الشبكة المحلية'**
  String get getAppsSubtitle;

  /// No description provided for @appUpdatesPageTitle.
  ///
  /// In ar, this message translates to:
  /// **'تحديثات التطبيق'**
  String get appUpdatesPageTitle;

  /// No description provided for @appUpdatesCurrentVersionLabel.
  ///
  /// In ar, this message translates to:
  /// **'الإصدار الحالي'**
  String get appUpdatesCurrentVersionLabel;

  /// No description provided for @appUpdatesChecking.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ التحقق من التحديثات…'**
  String get appUpdatesChecking;

  /// No description provided for @appUpdatesUpToDate.
  ///
  /// In ar, this message translates to:
  /// **'أنت تستخدم أحدث إصدار.'**
  String get appUpdatesUpToDate;

  /// No description provided for @appUpdatesAvailableLabel.
  ///
  /// In ar, this message translates to:
  /// **'يتوفّر إصدار جديد'**
  String get appUpdatesAvailableLabel;

  /// No description provided for @appUpdatesInstall.
  ///
  /// In ar, this message translates to:
  /// **'تحديث الآن'**
  String get appUpdatesInstall;

  /// No description provided for @appUpdatesDownloading.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ التنزيل…'**
  String get appUpdatesDownloading;

  /// No description provided for @appUpdatesFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر التحديث. حاول مرة أخرى.'**
  String get appUpdatesFailed;

  /// No description provided for @appUpdatesUnsupportedWeb.
  ///
  /// In ar, this message translates to:
  /// **'تتم إدارة تحديثات نسخة الويب من الخادم.'**
  String get appUpdatesUnsupportedWeb;

  /// No description provided for @appUpdatesRecheck.
  ///
  /// In ar, this message translates to:
  /// **'إعادة التحقق'**
  String get appUpdatesRecheck;

  /// No description provided for @getAppsDialogTitle.
  ///
  /// In ar, this message translates to:
  /// **'تنزيل تطبيقات دفتر'**
  String get getAppsDialogTitle;

  /// No description provided for @getAppsInstructions.
  ///
  /// In ar, this message translates to:
  /// **'امسح الرمز أو افتح الرابط على الجهاز الجديد (على نفس الشبكة) للتنزيل.'**
  String get getAppsInstructions;

  /// No description provided for @getAppsCopyLink.
  ///
  /// In ar, this message translates to:
  /// **'نسخ الرابط'**
  String get getAppsCopyLink;

  /// No description provided for @getAppsLinkCopied.
  ///
  /// In ar, this message translates to:
  /// **'تم نسخ الرابط'**
  String get getAppsLinkCopied;

  /// Small eyebrow label above the dashboard's AI daily-brief headline.
  ///
  /// In ar, this message translates to:
  /// **'ملخص اليوم من GPT'**
  String get aiDailyBriefLabel;

  /// Prompt auto-sent to the AI chat when the dashboard AI daily-brief headline is tapped.
  ///
  /// In ar, this message translates to:
  /// **'أعطني ملخصًا سريعًا لمتجري: كيف كان أداء المبيعات في الفترة، وما الذي يحتاج انتباهي اليوم، وأي شيء غير معتاد يجب أن أنتبه له.'**
  String get aiDailyBriefSeed;

  /// Prompt pre-filled in the AI chat when a dashboard card's AI explainer line is tapped; topic is the card's title.
  ///
  /// In ar, this message translates to:
  /// **'حدّثني أكثر عن {topic} في متجري.'**
  String aiDigestElaborate(String topic);

  /// Label of the AppBar Smart Reorder action on the purchase orders and products screens.
  ///
  /// In ar, this message translates to:
  /// **'إعادة طلب ذكية'**
  String get smartReorderButton;

  /// Tooltip on the AppBar Smart Reorder action on the purchase orders and products screens.
  ///
  /// In ar, this message translates to:
  /// **'اقتراح أوامر شراء ذكية للأصناف الناقصة بالذكاء الاصطناعي'**
  String get smartReorderTooltip;

  /// Prompt auto-sent to the AI chat when the user confirms Smart Reorder; drives the reorder_plan tool flow.
  ///
  /// In ar, this message translates to:
  /// **'راجع مخزوني وأنشئ أوامر شراء ذكية للأصناف التي تحتاج إعادة طلب. تجاهل الأصناف البطيئة والراكدة حتى لا أُجمّد رأس مالي، واحسب الكميات من سرعة البيع الفعلية مقرّبةً لوحدات الشراء. لكل صنف اختر المورّد الأنسب من سجلّ الشراء، وأنشئ أمر شراء منفصلًا لكل مورّد. اعرض لي ملخصًا بعدد الأوامر والموردين وإجمالي رأس المال المقدَّر وخُذ تأكيدي قبل الإنشاء.'**
  String get smartReorderSeed;

  /// No description provided for @messagingSettingsTitle.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات الرسائل'**
  String get messagingSettingsTitle;

  /// No description provided for @messagingSettingsSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'بوابة الإرسال (هاتف SMS Gate) وحدود الإرسال ورسالة اختبار'**
  String get messagingSettingsSubtitle;

  /// No description provided for @messagingHeroTitle.
  ///
  /// In ar, this message translates to:
  /// **'بوابة الرسائل'**
  String get messagingHeroTitle;

  /// No description provided for @messagingStatusActive.
  ///
  /// In ar, this message translates to:
  /// **'جاهزة للإرسال'**
  String get messagingStatusActive;

  /// No description provided for @messagingStatusInactive.
  ///
  /// In ar, this message translates to:
  /// **'غير مُهيّأة'**
  String get messagingStatusInactive;

  /// No description provided for @messagingHasRecentError.
  ///
  /// In ar, this message translates to:
  /// **'خطأ حديث'**
  String get messagingHasRecentError;

  /// No description provided for @messagingNotConfiguredTitle.
  ///
  /// In ar, this message translates to:
  /// **'لم تُهيّأ البوابة بعد'**
  String get messagingNotConfiguredTitle;

  /// No description provided for @messagingNotConfiguredMessage.
  ///
  /// In ar, this message translates to:
  /// **'أدخل عنوان هاتف SMS Gate على الشبكة واسم المستخدم وكلمة المرور، ثم احفظ.'**
  String get messagingNotConfiguredMessage;

  /// No description provided for @messagingConnectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'الاتصال بالجهاز'**
  String get messagingConnectionTitle;

  /// No description provided for @messagingBaseUrlLabel.
  ///
  /// In ar, this message translates to:
  /// **'عنوان الجهاز (Base URL)'**
  String get messagingBaseUrlLabel;

  /// No description provided for @messagingUsernameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم المستخدم'**
  String get messagingUsernameLabel;

  /// No description provided for @messagingPasswordLabel.
  ///
  /// In ar, this message translates to:
  /// **'كلمة المرور'**
  String get messagingPasswordLabel;

  /// No description provided for @messagingPasswordKeepHint.
  ///
  /// In ar, this message translates to:
  /// **'اتركه فارغًا للإبقاء على كلمة المرور الحالية'**
  String get messagingPasswordKeepHint;

  /// No description provided for @messagingRateLabel.
  ///
  /// In ar, this message translates to:
  /// **'رسائل/الدقيقة'**
  String get messagingRateLabel;

  /// No description provided for @messagingDailyCapLabel.
  ///
  /// In ar, this message translates to:
  /// **'الحد اليومي (0 = بلا حد)'**
  String get messagingDailyCapLabel;

  /// No description provided for @messagingSaveButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ'**
  String get messagingSaveButton;

  /// No description provided for @messagingSavedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ إعدادات البوابة'**
  String get messagingSavedMessage;

  /// No description provided for @messagingSaveError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حفظ الإعدادات'**
  String get messagingSaveError;

  /// No description provided for @messagingLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل إعدادات الرسائل'**
  String get messagingLoadError;

  /// No description provided for @messagingTestTitle.
  ///
  /// In ar, this message translates to:
  /// **'إرسال رسالة اختبار'**
  String get messagingTestTitle;

  /// No description provided for @messagingTestNeedsSaveTitle.
  ///
  /// In ar, this message translates to:
  /// **'احفظ البوابة أولًا'**
  String get messagingTestNeedsSaveTitle;

  /// No description provided for @messagingTestNeedsSaveMessage.
  ///
  /// In ar, this message translates to:
  /// **'أدخل إعدادات الاتصال واحفظها قبل إرسال رسالة اختبار.'**
  String get messagingTestNeedsSaveMessage;

  /// No description provided for @messagingTestPhoneLabel.
  ///
  /// In ar, this message translates to:
  /// **'رقم الهاتف'**
  String get messagingTestPhoneLabel;

  /// No description provided for @messagingTestSendButton.
  ///
  /// In ar, this message translates to:
  /// **'إرسال اختبار'**
  String get messagingTestSendButton;

  /// No description provided for @messagingTestSentTitle.
  ///
  /// In ar, this message translates to:
  /// **'تم الإرسال'**
  String get messagingTestSentTitle;

  /// No description provided for @messagingTestSentMessage.
  ///
  /// In ar, this message translates to:
  /// **'غادرت رسالة الاختبار البوابة بنجاح.'**
  String get messagingTestSentMessage;

  /// No description provided for @messagingTestFailedTitle.
  ///
  /// In ar, this message translates to:
  /// **'فشل الإرسال'**
  String get messagingTestFailedTitle;

  /// No description provided for @messagingTestFailedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر إرسال رسالة الاختبار. تأكد من عنوان الجهاز وبيانات الدخول.'**
  String get messagingTestFailedMessage;

  /// No description provided for @messagingActivateButton.
  ///
  /// In ar, this message translates to:
  /// **'تفعيل تلقائي وضبط الروابط'**
  String get messagingActivateButton;

  /// No description provided for @messagingActivateHint.
  ///
  /// In ar, this message translates to:
  /// **'يضبط الجهاز تلقائيًا لاستقبال الرسائل الواردة وتقارير التسليم دون أي إعداد يدوي.'**
  String get messagingActivateHint;

  /// No description provided for @messagingActivateError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر التفعيل التلقائي — تأكد من الاتصال بالجهاز.'**
  String get messagingActivateError;

  /// No description provided for @messagingActivatedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم التفعيل — سُجّلت {count} روابط تلقائيًا.'**
  String messagingActivatedMessage(int count);

  /// No description provided for @conversationsTitle.
  ///
  /// In ar, this message translates to:
  /// **'المحادثات'**
  String get conversationsTitle;

  /// No description provided for @conversationsDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'المحادثات'**
  String get conversationsDrawerLabel;

  /// No description provided for @conversationsEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد محادثات بعد'**
  String get conversationsEmpty;

  /// No description provided for @conversationsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل المحادثات'**
  String get conversationsLoadError;

  /// No description provided for @conversationsUnreadBadge.
  ///
  /// In ar, this message translates to:
  /// **'{count} جديدة'**
  String conversationsUnreadBadge(int count);

  /// No description provided for @conversationThreadEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد رسائل في هذه المحادثة'**
  String get conversationThreadEmpty;

  /// No description provided for @conversationReplyHint.
  ///
  /// In ar, this message translates to:
  /// **'اكتب ردًا…'**
  String get conversationReplyHint;

  /// No description provided for @conversationSendTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إرسال'**
  String get conversationSendTooltip;

  /// No description provided for @conversationSendError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر إرسال الرسالة'**
  String get conversationSendError;

  /// No description provided for @conversationReadOnly.
  ///
  /// In ar, this message translates to:
  /// **'ليس لديك صلاحية الرد على المحادثات'**
  String get conversationReadOnly;

  /// No description provided for @newConversationTitle.
  ///
  /// In ar, this message translates to:
  /// **'محادثة جديدة'**
  String get newConversationTitle;

  /// No description provided for @newConversationCustomerLabel.
  ///
  /// In ar, this message translates to:
  /// **'العميل'**
  String get newConversationCustomerLabel;

  /// No description provided for @newConversationSelectCustomer.
  ///
  /// In ar, this message translates to:
  /// **'اختر عميلاً'**
  String get newConversationSelectCustomer;

  /// No description provided for @newConversationNoPhoneWarning.
  ///
  /// In ar, this message translates to:
  /// **'هذا العميل لا يملك رقم هاتف. أضِف رقمًا لبدء المحادثة.'**
  String get newConversationNoPhoneWarning;

  /// No description provided for @newConversationStartButton.
  ///
  /// In ar, this message translates to:
  /// **'بدء المحادثة'**
  String get newConversationStartButton;

  /// No description provided for @newConversationError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر بدء المحادثة.'**
  String get newConversationError;

  /// No description provided for @customerConsentTitle.
  ///
  /// In ar, this message translates to:
  /// **'تفضيلات التواصل'**
  String get customerConsentTitle;

  /// No description provided for @customerMarketingAllowedLabel.
  ///
  /// In ar, this message translates to:
  /// **'السماح بالرسائل التسويقية'**
  String get customerMarketingAllowedLabel;

  /// No description provided for @customerMarketingAllowedHelp.
  ///
  /// In ar, this message translates to:
  /// **'إرسال العروض والحملات عبر SMS. يمكن للعميل الإيقاف بإرسال STOP.'**
  String get customerMarketingAllowedHelp;

  /// No description provided for @customerDoNotContactLabel.
  ///
  /// In ar, this message translates to:
  /// **'عدم الإزعاج'**
  String get customerDoNotContactLabel;

  /// No description provided for @customerDoNotContactHelp.
  ///
  /// In ar, this message translates to:
  /// **'إيقاف كل الرسائل التسويقية لهذا العميل (تبقى الرسائل المتعلقة بالفواتير مسموحة).'**
  String get customerDoNotContactHelp;

  /// No description provided for @customerConsentError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحديث تفضيلات التواصل'**
  String get customerConsentError;

  /// No description provided for @invoiceSendSmsTooltip.
  ///
  /// In ar, this message translates to:
  /// **'إرسال الفاتورة كرسالة نصية'**
  String get invoiceSendSmsTooltip;

  /// No description provided for @invoiceSendSmsSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم إرسال الفاتورة برسالة نصية'**
  String get invoiceSendSmsSuccess;

  /// No description provided for @invoiceSendSmsError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر إرسال الفاتورة برسالة نصية'**
  String get invoiceSendSmsError;

  /// No description provided for @campaignsTitle.
  ///
  /// In ar, this message translates to:
  /// **'الحملات'**
  String get campaignsTitle;

  /// No description provided for @campaignsDrawerLabel.
  ///
  /// In ar, this message translates to:
  /// **'الحملات'**
  String get campaignsDrawerLabel;

  /// No description provided for @campaignsEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد حملات بعد'**
  String get campaignsEmpty;

  /// No description provided for @campaignsLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل الحملات'**
  String get campaignsLoadError;

  /// No description provided for @campaignNewButton.
  ///
  /// In ar, this message translates to:
  /// **'حملة جديدة'**
  String get campaignNewButton;

  /// No description provided for @campaignNewTitle.
  ///
  /// In ar, this message translates to:
  /// **'حملة جديدة'**
  String get campaignNewTitle;

  /// No description provided for @campaignEditTitle.
  ///
  /// In ar, this message translates to:
  /// **'تعديل الحملة'**
  String get campaignEditTitle;

  /// No description provided for @campaignStatusLabel.
  ///
  /// In ar, this message translates to:
  /// **'الحالة'**
  String get campaignStatusLabel;

  /// No description provided for @campaignStatusDraft.
  ///
  /// In ar, this message translates to:
  /// **'مسودة'**
  String get campaignStatusDraft;

  /// No description provided for @campaignStatusSending.
  ///
  /// In ar, this message translates to:
  /// **'قيد الإرسال'**
  String get campaignStatusSending;

  /// No description provided for @campaignStatusSent.
  ///
  /// In ar, this message translates to:
  /// **'مُرسَلة'**
  String get campaignStatusSent;

  /// No description provided for @campaignStatusCancelled.
  ///
  /// In ar, this message translates to:
  /// **'ملغاة'**
  String get campaignStatusCancelled;

  /// No description provided for @campaignStatusFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشلت'**
  String get campaignStatusFailed;

  /// No description provided for @campaignAiBadge.
  ///
  /// In ar, this message translates to:
  /// **'اقتراح الذكاء الاصطناعي'**
  String get campaignAiBadge;

  /// No description provided for @campaignRecipientsSummary.
  ///
  /// In ar, this message translates to:
  /// **'{sent} من {total} مُرسَلة'**
  String campaignRecipientsSummary(int sent, int total);

  /// No description provided for @campaignNameLabel.
  ///
  /// In ar, this message translates to:
  /// **'اسم الحملة'**
  String get campaignNameLabel;

  /// No description provided for @campaignBodyLabel.
  ///
  /// In ar, this message translates to:
  /// **'نص الرسالة'**
  String get campaignBodyLabel;

  /// No description provided for @campaignBodyHelp.
  ///
  /// In ar, this message translates to:
  /// **'يمكن تضمين اسم العميل واسم المتجر في النص تلقائيًا.'**
  String get campaignBodyHelp;

  /// No description provided for @campaignSegmentsCounter.
  ///
  /// In ar, this message translates to:
  /// **'≈ {count} مقطع'**
  String campaignSegmentsCounter(int count);

  /// No description provided for @campaignAudienceTitle.
  ///
  /// In ar, this message translates to:
  /// **'الفئة المستهدفة'**
  String get campaignAudienceTitle;

  /// No description provided for @campaignSaveButton.
  ///
  /// In ar, this message translates to:
  /// **'حفظ المسودة'**
  String get campaignSaveButton;

  /// No description provided for @campaignSavedMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ المسودة'**
  String get campaignSavedMessage;

  /// No description provided for @campaignSaveError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حفظ المسودة'**
  String get campaignSaveError;

  /// No description provided for @campaignSaveFirstTitle.
  ///
  /// In ar, this message translates to:
  /// **'احفظ المسودة أولًا'**
  String get campaignSaveFirstTitle;

  /// No description provided for @campaignSaveFirstHint.
  ///
  /// In ar, this message translates to:
  /// **'احفظ الحملة كمسودة لتتمكن من معاينتها وإرسالها.'**
  String get campaignSaveFirstHint;

  /// No description provided for @campaignPreviewTitle.
  ///
  /// In ar, this message translates to:
  /// **'المعاينة والإرسال'**
  String get campaignPreviewTitle;

  /// No description provided for @campaignPreviewButton.
  ///
  /// In ar, this message translates to:
  /// **'معاينة الفئة'**
  String get campaignPreviewButton;

  /// No description provided for @campaignPreviewAudience.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الفئة'**
  String get campaignPreviewAudience;

  /// No description provided for @campaignPreviewSendable.
  ///
  /// In ar, this message translates to:
  /// **'القابلون للإرسال'**
  String get campaignPreviewSendable;

  /// No description provided for @campaignPreviewSkipped.
  ///
  /// In ar, this message translates to:
  /// **'مستبعدون (رفضوا التسويق)'**
  String get campaignPreviewSkipped;

  /// No description provided for @campaignPreviewSegments.
  ///
  /// In ar, this message translates to:
  /// **'عدد المقاطع'**
  String get campaignPreviewSegments;

  /// No description provided for @campaignPreviewDurationLabel.
  ///
  /// In ar, this message translates to:
  /// **'المدة التقديرية'**
  String get campaignPreviewDurationLabel;

  /// No description provided for @campaignPreviewDuration.
  ///
  /// In ar, this message translates to:
  /// **'≈ {minutes} دقيقة'**
  String campaignPreviewDuration(int minutes);

  /// No description provided for @campaignSampleTitle.
  ///
  /// In ar, this message translates to:
  /// **'نموذج الرسالة'**
  String get campaignSampleTitle;

  /// No description provided for @campaignSendButton.
  ///
  /// In ar, this message translates to:
  /// **'موافقة وإرسال'**
  String get campaignSendButton;

  /// No description provided for @campaignSentMessage.
  ///
  /// In ar, this message translates to:
  /// **'بدأ إرسال الحملة'**
  String get campaignSentMessage;

  /// No description provided for @campaignSendError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر إرسال الحملة'**
  String get campaignSendError;

  /// No description provided for @campaignNoSendPermission.
  ///
  /// In ar, this message translates to:
  /// **'ليس لديك صلاحية إرسال الحملات'**
  String get campaignNoSendPermission;

  /// Label for the purchase draft line quantity entry dialog.
  ///
  /// In ar, this message translates to:
  /// **'الكمية'**
  String get purchaseLineQuantityLabel;

  /// Label for the one-off manual discount amount on a purchase order.
  ///
  /// In ar, this message translates to:
  /// **'خصم على أمر الشراء'**
  String get purchaseExtraDiscountLabel;

  /// Hint for the one-off purchase order discount field.
  ///
  /// In ar, this message translates to:
  /// **'مبلغ يُخصم من إجمالي هذا الأمر (مثلاً لإزالة الكسور)'**
  String get purchaseExtraDiscountHint;
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
      'that was used.');
}
