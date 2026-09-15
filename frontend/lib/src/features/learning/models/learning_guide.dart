import '../../../core/authorization.dart';
import '../../../shared/navigation/app_navigation.dart';

/// The subject a guide belongs to. Doubles as the catalogue's grouping and as
/// the primary filter, so the list of tracks is deliberately short enough to
/// scan in one bottom sheet.
enum LearningTrack {
  gettingStarted,
  selling,
  money,
  returns,
  register,
  catalog,
  inventory,
  purchasing,
  contacts,
  reports,
  operations,
  people,
  devices,
  setup,
}

/// How hard the guide is, not how long it is. A cashier filters to
/// [LearningLevel.beginner] on their first day; an owner setting the shop up
/// reads [LearningLevel.advanced] once and never again.
enum LearningLevel { beginner, intermediate, advanced }

/// What kind of reading this is.
///
/// The distinction is load-bearing for search: someone who types "آجل" may want
/// either the *explanation* of what a credit sale is or the *steps* to ring one
/// up, and the two are separate guides rather than one document that tries to
/// be both.
enum LearningKind {
  /// Numbered steps for one task, start to finish.
  walkthrough,

  /// What a thing is, why it exists, and when to reach for it.
  concept,

  /// A table or list to come back to — shortcuts, fields, statuses.
  reference,
}

/// One block of guide body copy. A closed set, so rendering is a `switch` and a
/// new kind of block is a deliberate, reviewable addition rather than a stray
/// `Text` widget in a content file.
sealed class LearningBlock {
  const LearningBlock();
}

/// A plain paragraph.
class LearningParagraph extends LearningBlock {
  const LearningParagraph(this.text);

  final String text;
}

/// An ordered list of actions the reader performs, in order.
class LearningSteps extends LearningBlock {
  const LearningSteps(this.steps);

  final List<LearningStep> steps;
}

class LearningStep {
  const LearningStep(this.text, {this.detail});

  /// The action itself — one sentence, imperative.
  final String text;

  /// Optional supporting line: what the screen does in response, or the trap
  /// to avoid at this step.
  final String? detail;
}

/// An unordered list. Use for "any of these", never for a sequence.
class LearningBullets extends LearningBlock {
  const LearningBullets(this.items);

  final List<String> items;
}

/// Term-and-meaning pairs: what each field on a screen means, what each status
/// tells you.
class LearningDefinitions extends LearningBlock {
  const LearningDefinitions(this.entries);

  final List<LearningDefinition> entries;
}

class LearningDefinition {
  const LearningDefinition(this.term, this.meaning);

  final String term;
  final String meaning;
}

/// Tone of a [LearningNote], mapped to the shared callout tones at render time.
enum LearningNoteTone { tip, warning, danger, info }

/// A highlighted aside — the thing that costs money if it is missed.
class LearningNote extends LearningBlock {
  const LearningNote({required this.tone, required this.title, this.message});

  final LearningNoteTone tone;
  final String title;
  final String? message;
}

/// A titled group of blocks. Sections are what the reader skims, so every guide
/// has at least one and no section is a single paragraph long by accident.
class LearningSection {
  const LearningSection({required this.title, required this.blocks});

  final String title;
  final List<LearningBlock> blocks;
}

/// One guide in the learning library.
///
/// Guides are data, not screens: the catalogue, the search index, the filters
/// and the reader all consume this one object, so adding a guide is a content
/// change and never a UI change.
class LearningGuide {
  const LearningGuide({
    required this.id,
    required this.title,
    required this.summary,
    required this.track,
    required this.level,
    required this.kind,
    required this.minutes,
    required this.sections,
    this.capability,
    this.keywords = const [],
    this.related = const [],
    this.opens,
  });

  /// Stable identifier. Used for progress, cross-links and deep links, so it
  /// must not change once shipped even if the title is reworded.
  final String id;

  final String title;

  /// One line, shown on the catalogue card. Says what the reader will be able
  /// to do afterwards — not "about credit sales" but "ring up a sale the
  /// customer pays for later".
  final String summary;

  final LearningTrack track;
  final LearningLevel level;
  final LearningKind kind;

  /// Rough reading time in minutes, shown on the card so nobody opens a
  /// ten-minute read between two customers.
  final int minutes;

  final List<LearningSection> sections;

  /// The capability the guide's subject needs. Null means "everyone" (the
  /// concepts every role benefits from). Used by the "matches my permissions"
  /// filter, never to *hide* a guide outright: an owner training a new hire
  /// must be able to read the cashier's guides, and a cashier reading about a
  /// screen they cannot open learns why they cannot open it.
  final AppCapability? capability;

  /// Extra search terms — synonyms, Latin transliterations, the words a user
  /// actually types. Never shown.
  final List<String> keywords;

  /// Ids of guides worth reading next.
  final List<String> related;

  /// The screen this guide teaches, offered as "open it" at the end of the
  /// read. Null for guides with no single home screen.
  final AppNavigationDestination? opens;

  /// Every word the search index should see, most important first. The order
  /// matters: the matcher scores a title hit above a keyword hit above a body
  /// hit, so a guide about credit wins the query "آجل" over one that merely
  /// mentions it.
  Iterable<String> get bodyText sync* {
    for (final section in sections) {
      yield section.title;
      for (final block in section.blocks) {
        switch (block) {
          case LearningParagraph(:final text):
            yield text;
          case LearningSteps(:final steps):
            for (final step in steps) {
              yield step.text;
              if (step.detail case final detail?) {
                yield detail;
              }
            }
          case LearningBullets(:final items):
            yield* items;
          case LearningDefinitions(:final entries):
            for (final entry in entries) {
              yield entry.term;
              yield entry.meaning;
            }
          case LearningNote(:final title, :final message):
            yield title;
            if (message case final message?) {
              yield message;
            }
        }
      }
    }
  }
}
