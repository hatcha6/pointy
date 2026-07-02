// Dev-only preview harness for the customer-facing price-checker kiosk.
//
// Renders [PriceCheckerKioskView] full-viewport with seeded data and no backend.
// Pick a state with `?state=` and the theme with `?theme=dark`, then resize the
// browser to test responsiveness (price checkers come in many sizes). Add
// `?camera=1` to preview the camera-scanning layout (a fake feed stands in for
// the live preview so the design reviews without camera hardware). Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/price_checker_kiosk_preview.dart
//
// States: idle | loading | found | plain | nophoto | outofstock | notfound |
//         disconnected
//
// See AGENTS.md ("UI preview harness") for the pattern. Not shipped. Safe to
// delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/price_lookup_result.dart';
import 'package:pointy_frontend/src/features/price_checker/views/price_checker_kiosk_view.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

void main() => runApp(const _PreviewApp());

const _photoUrl = 'https://picsum.photos/seed/pointy/600/600';

String _query(String key, String fallback) {
  final uri = Uri.base;
  final direct = uri.queryParameters[key];
  if (direct != null) return direct;
  final parsed = Uri.tryParse(
    uri.fragment.startsWith('/') ? uri.fragment.substring(1) : uri.fragment,
  );
  return parsed?.queryParameters[key] ?? fallback;
}

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    final dark = _query('theme', 'light') == 'dark';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: dark ? PointyTheme.dark() : PointyTheme.light(),
      home: _build(_query('state', 'idle')),
    );
  }

  Widget _build(String state) {
    PriceCheckerKioskStatus status;
    PriceLookupResult? result;
    var barcode = '';

    switch (state) {
      case 'loading':
        status = PriceCheckerKioskStatus.loading;
      case 'found':
        status = PriceCheckerKioskStatus.found;
        result = _discounted(image: true);
      case 'plain':
        status = PriceCheckerKioskStatus.found;
        result = _plain(image: true);
      case 'nophoto':
        status = PriceCheckerKioskStatus.found;
        result = _discounted(image: false);
      case 'outofstock':
        status = PriceCheckerKioskStatus.found;
        result = _outOfStock();
      case 'notfound':
        status = PriceCheckerKioskStatus.notFound;
        barcode = '6001234599999';
      case 'disconnected':
        status = PriceCheckerKioskStatus.disconnected;
      default:
        status = PriceCheckerKioskStatus.idle;
    }

    return PriceCheckerKioskView(
      status: status,
      result: result,
      barcode: barcode,
      shopName: 'بقالة الأمل',
      cameraPreview: _query('camera', '0') == '1'
          ? const _FakeCameraFeed()
          : null,
      onManualEntry: () {},
      onExitRequested: () {},
    );
  }

  PriceLookupResult _discounted({required bool image}) {
    return PriceLookupResult(
      found: true,
      barcode: '6001234500001',
      inStock: true,
      currency: 'د.ل',
      productName: 'قميص قطني كلاسيكي',
      variantName: 'مقاس L · أزرق',
      sku: 'TEE-105',
      unit: 'PCS',
      originalPrice: '20.00',
      finalPrice: '18.00',
      discountTotal: '2.00',
      discountPercent: 10,
      hasDiscount: true,
      originalPriceDisplay: '20.00 د.ل',
      finalPriceDisplay: '18.00 د.ل',
      imageUrl: image ? _photoUrl : '',
      discounts: const [
        PriceLookupDiscount(
          name: 'خصم 10%',
          valueType: 'percentage',
          value: '10.00',
          amount: '2.00',
        ),
      ],
    );
  }

  PriceLookupResult _plain({required bool image}) {
    return PriceLookupResult(
      found: true,
      barcode: '6009876500002',
      inStock: true,
      currency: 'د.ل',
      productName: 'زيت زيتون بكر ممتاز ١ لتر',
      sku: 'OIL-1L',
      unit: 'PCS',
      originalPrice: '35.00',
      finalPrice: '35.00',
      discountTotal: '0.00',
      finalPriceDisplay: '35.00 د.ل',
      originalPriceDisplay: '35.00 د.ل',
      imageUrl: image ? _photoUrl : '',
    );
  }

  PriceLookupResult _outOfStock() {
    return const PriceLookupResult(
      found: true,
      barcode: '6001112223334',
      inStock: false,
      currency: 'د.ل',
      productName: 'علبة شوكولاتة فاخرة',
      sku: 'CHO-22',
      unit: 'PCS',
      originalPrice: '12.50',
      finalPrice: '12.50',
      finalPriceDisplay: '12.50 د.ل',
      originalPriceDisplay: '12.50 د.ل',
      imageUrl: _photoUrl,
    );
  }
}

/// Stands in for the live camera feed inside the viewfinder card so the
/// camera layout can be reviewed in a browser without camera hardware.
class _FakeCameraFeed extends StatelessWidget {
  const _FakeCameraFeed();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2A2F36), Color(0xFF12151A)],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.photo_camera_outlined,
          color: Colors.white24,
          size: 64,
        ),
      ),
    );
  }
}
