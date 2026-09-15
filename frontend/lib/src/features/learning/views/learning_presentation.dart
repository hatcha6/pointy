import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../models/learning_guide.dart';
import '../models/learning_query.dart';

/// Labels and icons for the learning enums.
///
/// One place, so the filter sheet, the catalogue card and the guide header can
/// never disagree about what a track is called.
String learningTrackLabel(AppLocalizations l10n, LearningTrack track) {
  return switch (track) {
    LearningTrack.gettingStarted => l10n.learningTrackGettingStarted,
    LearningTrack.selling => l10n.learningTrackSelling,
    LearningTrack.money => l10n.learningTrackMoney,
    LearningTrack.returns => l10n.learningTrackReturns,
    LearningTrack.register => l10n.learningTrackRegister,
    LearningTrack.catalog => l10n.learningTrackCatalog,
    LearningTrack.inventory => l10n.learningTrackInventory,
    LearningTrack.purchasing => l10n.learningTrackPurchasing,
    LearningTrack.contacts => l10n.learningTrackContacts,
    LearningTrack.reports => l10n.learningTrackReports,
    LearningTrack.operations => l10n.learningTrackOperations,
    LearningTrack.people => l10n.learningTrackPeople,
    LearningTrack.devices => l10n.learningTrackDevices,
    LearningTrack.setup => l10n.learningTrackSetup,
  };
}

IconData learningTrackIcon(LearningTrack track) {
  return switch (track) {
    LearningTrack.gettingStarted => Icons.flag_outlined,
    LearningTrack.selling => Icons.point_of_sale_outlined,
    LearningTrack.money => Icons.payments_outlined,
    LearningTrack.returns => Icons.assignment_return_outlined,
    LearningTrack.register => Icons.inbox_outlined,
    LearningTrack.catalog => Icons.inventory_2_outlined,
    LearningTrack.inventory => Icons.warehouse_outlined,
    LearningTrack.purchasing => Icons.local_shipping_outlined,
    LearningTrack.contacts => Icons.people_outline,
    LearningTrack.reports => Icons.insights_outlined,
    LearningTrack.operations => Icons.handyman_outlined,
    LearningTrack.people => Icons.badge_outlined,
    LearningTrack.devices => Icons.print_outlined,
    LearningTrack.setup => Icons.tune_outlined,
  };
}

String learningLevelLabel(AppLocalizations l10n, LearningLevel level) {
  return switch (level) {
    LearningLevel.beginner => l10n.learningLevelBeginner,
    LearningLevel.intermediate => l10n.learningLevelIntermediate,
    LearningLevel.advanced => l10n.learningLevelAdvanced,
  };
}

String learningKindLabel(AppLocalizations l10n, LearningKind kind) {
  return switch (kind) {
    LearningKind.walkthrough => l10n.learningKindWalkthrough,
    LearningKind.concept => l10n.learningKindConcept,
    LearningKind.reference => l10n.learningKindReference,
  };
}

IconData learningKindIcon(LearningKind kind) {
  return switch (kind) {
    LearningKind.walkthrough => Icons.format_list_numbered,
    LearningKind.concept => Icons.lightbulb_outline,
    LearningKind.reference => Icons.menu_book_outlined,
  };
}

String learningLevelFilterLabel(
  AppLocalizations l10n,
  LearningLevelFilter filter,
) {
  return switch (filter) {
    LearningLevelFilter.all => l10n.learningFilterAll,
    LearningLevelFilter.beginner => l10n.learningLevelBeginner,
    LearningLevelFilter.intermediate => l10n.learningLevelIntermediate,
    LearningLevelFilter.advanced => l10n.learningLevelAdvanced,
  };
}

IconData learningLevelFilterIcon(LearningLevelFilter filter) {
  return switch (filter) {
    LearningLevelFilter.all => Icons.all_inclusive,
    LearningLevelFilter.beginner => Icons.looks_one_outlined,
    LearningLevelFilter.intermediate => Icons.looks_two_outlined,
    LearningLevelFilter.advanced => Icons.looks_3_outlined,
  };
}

String learningKindFilterLabel(
  AppLocalizations l10n,
  LearningKindFilter filter,
) {
  return switch (filter) {
    LearningKindFilter.all => l10n.learningFilterAll,
    LearningKindFilter.walkthrough => l10n.learningKindWalkthrough,
    LearningKindFilter.concept => l10n.learningKindConcept,
    LearningKindFilter.reference => l10n.learningKindReference,
  };
}

IconData learningKindFilterIcon(LearningKindFilter filter) {
  return switch (filter) {
    LearningKindFilter.all => Icons.all_inclusive,
    LearningKindFilter.walkthrough => Icons.format_list_numbered,
    LearningKindFilter.concept => Icons.lightbulb_outline,
    LearningKindFilter.reference => Icons.menu_book_outlined,
  };
}

String learningAudienceFilterLabel(
  AppLocalizations l10n,
  LearningAudienceFilter filter,
) {
  return switch (filter) {
    LearningAudienceFilter.all => l10n.learningAudienceAll,
    LearningAudienceFilter.myPermissions => l10n.learningAudienceMyPermissions,
  };
}

IconData learningAudienceFilterIcon(LearningAudienceFilter filter) {
  return switch (filter) {
    LearningAudienceFilter.all => Icons.public,
    LearningAudienceFilter.myPermissions => Icons.verified_user_outlined,
  };
}

String learningProgressFilterLabel(
  AppLocalizations l10n,
  LearningProgressFilter filter,
) {
  return switch (filter) {
    LearningProgressFilter.all => l10n.learningProgressAll,
    LearningProgressFilter.unfinished => l10n.learningProgressUnfinished,
    LearningProgressFilter.finished => l10n.learningProgressFinished,
  };
}

IconData learningProgressFilterIcon(LearningProgressFilter filter) {
  return switch (filter) {
    LearningProgressFilter.all => Icons.all_inclusive,
    LearningProgressFilter.unfinished => Icons.radio_button_unchecked,
    LearningProgressFilter.finished => Icons.check_circle_outline,
  };
}

String learningSortLabel(AppLocalizations l10n, LearningSort sort) {
  return switch (sort) {
    LearningSort.recommended => l10n.learningSortRecommended,
    LearningSort.level => l10n.learningSortLevel,
    LearningSort.shortest => l10n.learningSortShortest,
    LearningSort.alphabetical => l10n.learningSortAlphabetical,
  };
}

IconData learningSortIcon(LearningSort sort) {
  return switch (sort) {
    LearningSort.recommended => Icons.auto_awesome_outlined,
    LearningSort.level => Icons.stairs_outlined,
    LearningSort.shortest => Icons.timer_outlined,
    LearningSort.alphabetical => Icons.sort_by_alpha,
  };
}
