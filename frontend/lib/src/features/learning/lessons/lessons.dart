import '../engine/lesson.dart';
import 'catalog_lessons.dart';
import 'contacts_lessons.dart';
import 'money_lessons.dart';
import 'purchasing_lessons.dart';
import 'register_lessons.dart';
import 'till_lessons.dart';

export 'catalog_lessons.dart';
export 'contacts_lessons.dart';
export 'money_lessons.dart';
export 'purchasing_lessons.dart';
export 'register_lessons.dart';
export 'till_lessons.dart';

/// Every lesson the module knows about.
///
/// Breadth here is content, not engineering: the spine was built once, and a
/// new lesson is a `const` in one of the files above plus, when it needs one, a
/// new anchor. `test/learning/` runs every entry in this list through the real
/// screens, so the list is also the coverage report.
const allLessons = <TutorLesson>[
  ...tillLessons,
  ...registerLessons,
  ...catalogLessons,
  ...purchasingLessons,
  ...contactsLessons,
  ...moneyLessons,
];

/// The practice lesson attached to a written guide, if there is one.
///
/// Guides outnumber lessons by an order of magnitude and will for a long time,
/// so this returns null more often than not — the reader simply shows no
/// practice button.
TutorLesson? lessonForGuide(String guideId) {
  for (final lesson in allLessons) {
    if (lesson.guideId == guideId) {
      return lesson;
    }
  }
  return null;
}

/// The lessons a learner is asked to do first. Not a gate — the catalogue
/// offers everything — but the reader says so.
List<TutorLesson> prerequisitesOf(TutorLesson lesson) {
  return [
    for (final id in lesson.requires)
      for (final candidate in allLessons)
        if (candidate.id == id) candidate,
  ];
}
