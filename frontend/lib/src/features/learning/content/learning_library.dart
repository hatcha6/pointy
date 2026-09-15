import '../models/learning_guide.dart';
import '../search/learning_search.dart';
import 'catalog_guides.dart';
import 'contacts_guides.dart';
import 'devices_guides.dart';
import 'getting_started_guides.dart';
import 'inventory_guides.dart';
import 'money_guides.dart';
import 'operations_guides.dart';
import 'people_guides.dart';
import 'purchasing_guides.dart';
import 'register_guides.dart';
import 'returns_guides.dart';
import 'reports_guides.dart';
import 'selling_guides.dart';
import 'setup_guides.dart';

/// The whole learning library, in the order a shop learns it.
///
/// **Why the Arabic lives here and not in `app_ar.arb`.** The house rule is
/// that visible copy belongs in the ARB, and every label in the learning
/// *screens* obeys it. Guide bodies do not, deliberately: a guide is a
/// structured document (sections → steps → notes), and flattening it into
/// hundreds of unrelated ARB keys would lose that structure, put a step's text
/// a thousand lines from the note that qualifies it, and roughly double a file
/// that already carries 5,800 keys — all to serve a translation matrix that
/// does not exist, since the app pins `Locale('ar')` and ships one ARB.
///
/// The properties the rule protects are kept instead by keeping every word of
/// content inside this one directory: it is greppable, reviewable as prose, and
/// no widget anywhere hardcodes a sentence.
const learningLibrary = <LearningGuide>[
  ...gettingStartedGuides,
  ...sellingGuides,
  ...moneyGuides,
  ...returnsGuides,
  ...registerGuides,
  ...catalogGuides,
  ...inventoryGuides,
  ...purchasingGuides,
  ...contactsGuides,
  ...reportsGuides,
  ...operationsGuides,
  ...peopleGuides,
  ...devicesGuides,
  ...setupGuides,
];

/// Guides keyed by id, for cross-links and deep links.
final Map<String, LearningGuide> learningGuidesById = {
  for (final guide in learningLibrary) guide.id: guide,
};

/// Search indexes keyed by guide id. Built once at first use — normalizing the
/// whole library on every keystroke is exactly the kind of work that makes a
/// search box feel broken on the hardware these shops run.
final Map<String, LearningSearchIndex> learningSearchIndexes = {
  for (final guide in learningLibrary) guide.id: LearningSearchIndex.of(guide),
};

/// Position of each guide in [learningLibrary], so the "recommended" sort can
/// restore the library's curated order after any filtering.
final Map<String, int> learningGuideOrder = {
  for (final (index, guide) in learningLibrary.indexed) guide.id: index,
};
