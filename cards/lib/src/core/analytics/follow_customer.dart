import '../../dependencies.dart';
import 'events.dart';

/// Joins analytics to the signed-in customer: their customer id once they
/// sign in (or at launch, already signed in), and a fresh nobody once they
/// sign out. Only a sign-out starts over, not a launch signed out, so a
/// visitor stays one visitor. Where they heard of the app goes with them.
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
  final attribution = dependencies.attribution;
  void join(String customer) {
    analytics.identify(customer);
    if (attribution.heardFrom.isNotEmpty) {
      analytics.heardFrom(attribution.heardFrom);
    }
  }

  var known = session.value?.customerId;
  if (known != null) {
    join(known);
  }
  session.addListener(() {
    final customer = session.value?.customerId;
    if (customer == known) {
      return;
    }
    if (customer == null) {
      analytics.reset();
      attribution.signedOut();
    } else {
      join(customer);
    }
    known = customer;
  });
}
