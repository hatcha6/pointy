import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../data/models/catalog.dart';
import '../../data/models/esim.dart';
import '../../data/models/order.dart';
import '../../shared/esim_card_art.dart';
import '../checkout/checkout_sheet.dart';
import '../sign_in/sign_in_sheet.dart';
import 'esim_format.dart';

/// The "brand" an eSIM order wears on the shared checkout and order pages: its
/// destination's name, drawn as [EsimCardArt] with the flag.
CardBrand esimBrand(String name, String country) => CardBrand(
  key: 'esim',
  name: name,
  aliases: const [],
  category: esimCategory,
  rank: 0,
  featured: false,
  badge: '',
  redeemHint: '',
  logo: '',
  items: const [],
  flagCountry: country,
);

/// The same for an order the app only has the words of (from «كروتي», a
/// notification): the destination is the first part of its name.
CardBrand esimBrandOfOrder(CardOrder order) =>
    esimBrand(order.name.split(' · ').first, order.esimCountry);

/// An eSIM plan goes through the same checkout as any card: the same methods,
/// credit, fee and order page. Only the card on it is the plan's.
Future<void> checkoutEsimPlan(
  BuildContext context, {
  required String destinationName,
  required EsimPlan plan,
  String country = '',
  Map<String, String> orderAccount = const {},
}) async {
  if (!await ensureSignedIn(context) || !context.mounted) {
    return;
  }
  await showCheckout(
    context,
    brand: esimBrand(destinationName, country),
    item: CardItem(
      key: plan.item,
      country: '',
      label: esimPlanText(
        AppLocalizations.of(context),
        data: plan.data,
        days: plan.days,
        unlimited: plan.unlimited,
      ),
      faceValue: '',
      faceCurrency: '',
      price: plan.price,
      regularPrice: plan.price,
      promoBadge: '',
      available: true,
      rank: 0,
    ),
    orderAccount: orderAccount,
  );
}
