/// The PostHog experiments the app runs: each key is a multivariate feature
/// flag with a `control` arm, set up as an experiment in PostHog. The app only
/// asks which arm a customer is in where the arms part ways; PostHog splits
/// the customers and reads the results from the events in `events.dart`.
abstract final class Experiments {
  /// How a bank card (Moamalat) pays. `control`: the app's own card form,
  /// with cards saved on the phone. `hosted`: Dafa's payment page in the
  /// in-app browser, with nothing saved. The phone apps only: the web build
  /// always uses Dafa's page.
  static const cardPaymentForm = 'card-payment-form';

  /// [cardPaymentForm]'s arm that pays on Dafa's page.
  static const hostedPaymentPage = 'hosted';
}
