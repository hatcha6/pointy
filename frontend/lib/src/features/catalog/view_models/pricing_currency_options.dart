import '../../../core/result.dart';
import '../../../data/models/exchange_rate.dart';
import '../../../data/repositories/fx_repository.dart';
import '../../../shared/formatters.dart';

/// The currency choices a product form offers, and the rates behind its preview.
///
/// Shared by the create form's view model and the edit sheet's, because both ask
/// the same question and neither should own the answer. Deliberately not a
/// [ChangeNotifier]: the owning view model notifies once the load completes, so
/// there is one notification path rather than two.
///
/// Failure is silent by design. Not reaching the rate endpoint is not a reason
/// to stop someone creating or editing a product — the picker simply does not
/// appear and the product is priced in the shop's own currency, which is exactly
/// what happened before this feature existed.
class PricingCurrencyOptions {
  PricingCurrencyOptions(this._repository);

  final FxRepository? _repository;

  List<Currency> _currencies = const <Currency>[];
  CurrentRates _rates = CurrentRates.empty;
  bool _hasLoaded = false;

  /// Enabled currencies other than the shop's own. Empty until [load] has run,
  /// and empty forever on a shop with no FX feed — which keeps the picker
  /// hidden rather than showing an empty dropdown.
  List<Currency> get currencies => _currencies;

  CurrentRates get rates => _rates;

  String get baseCode => _rates.baseCode;

  /// The rate converting [currencyCode] into the shop's own currency, or null
  /// when none is known — in which case the form says so rather than showing a
  /// converted number it cannot stand behind.
  ResolvedRate? rateFor(String currencyCode) => _rates.rateFor(currencyCode);

  /// Loads once per instance. Returns true when anything changed, so the caller
  /// knows whether a rebuild is worth notifying for.
  Future<bool> load() async {
    if (_hasLoaded || _repository == null) {
      return false;
    }
    _hasLoaded = true;

    final ratesResult = await _repository.loadCurrentRates();
    if (ratesResult case Ok<CurrentRates>(value: final loaded)) {
      _rates = loaded;
    }
    // The shop's master switch. A single-currency shop stops here: the
    // registry is seeded for every install, so without this gate every shop
    // would be offered eight currencies it has no use for.
    if (!_rates.fxEnabled) {
      return true;
    }

    final currenciesResult = await _repository.loadCurrencies();
    if (currenciesResult case Ok<List<Currency>>(value: final loaded)) {
      // Teach the formatters every symbol so a foreign price renders as "$"
      // rather than a bare code the user has to decode.
      configureForeignCurrencySymbols(<String, String>{
        for (final currency in loaded) currency.code: currency.symbol,
      });
      _currencies = loaded
          .where((c) => c.isEnabled && c.code != _rates.baseCode)
          .toList();
    }
    return true;
  }
}
