import 'package:flutter/material.dart';

/// The icon of a catalog category in the category bar.
IconData categoryIcon(String? key) => switch (key) {
  null => Icons.auto_awesome_rounded,
  'telecom' => Icons.sim_card_rounded,
  'intl_topup' => Icons.public_rounded,
  'internet' => Icons.wifi_rounded,
  'gaming' => Icons.sports_esports_rounded,
  'gift_cards' => Icons.redeem_rounded,
  'tv' => Icons.live_tv_rounded,
  'services' => Icons.school_rounded,
  _ => Icons.style_rounded,
};
