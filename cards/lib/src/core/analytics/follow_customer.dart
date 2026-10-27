import '../../dependencies.dart';

/// Joins analytics to the signed-in customer: their customer id once they
/// sign in (or at launch, already signed in), and a fresh nobody once they
/// sign out. Only a sign-out starts over, not a launch signed out, so a
/// visitor stays one visitor.
void followCustomer(CardsDependencies dependencies) {
  final session = dependencies.auth.session;
  final analytics = dependencies.analytics;
  // And it shares only while the customer lets it.
  final settings = dependencies.settings;
  var sharing = settings.shareUsage;
  analytics.share(sharing);
  settings.addListener(() {
    if (settings.shareUsage != sharing) {
      sharing = settings.shareUsage;
      analytics.share(sharing);
    }
  });
  var known = session.value?.customerId;
  if (known != null) {
    analytics.identify(known);
  }
  session.addListener(() {
    final customer = session.value?.customerId;
    if (customer == known) {
      return;
    }
    if (customer == null) {
      analytics.reset();
    } else {
      analytics.identify(customer);
    }
    known = customer;
  });
}
