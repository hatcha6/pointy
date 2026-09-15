import '../../engine/lesson.dart';
import '../sandbox_shop.dart';
import 'grocery_morning.dart';

export 'grocery_morning.dart';

/// Builds the practice shop a lesson asks for.
///
/// One switch, shared by the runner screen and the CI runner. Two copies of it
/// is how a lesson comes to pass in CI against a shop the learner never sees.
SandboxShop buildSandboxShop(SandboxSeed seed) {
  return switch (seed) {
    SandboxSeed.groceryMorning => groceryMorningSeed(),
    SandboxSeed.groceryBackOffice => groceryBackOfficeSeed(),
    SandboxSeed.groceryBackOfficeWithOrder => groceryBackOfficeWithOrderSeed(),
    SandboxSeed.groceryBackOfficeWithDelivery =>
      groceryBackOfficeWithDeliverySeed(),
  };
}
