import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/service_country_detail.dart';
import '../../../../data/models/services_directory.dart';
import '../../../../shared/catalog/catalog.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../../view_models/airtime_view_model.dart';
import 'service_dial_choices.dart';
import 'service_dial_hint.dart';
import 'service_phone_field.dart';

/// The currency as a cashier says it next to an amount, always in Arabic: the
/// country's own short name when it is that country's money, the world's
/// common ones (the dollar, the euro) by name, any other the directory knows
/// by the name the countries that use it give — and only a currency nobody
/// names is the ISO code, held left to right.
String serviceCurrencyLabel(
  AppLocalizations l10n,
  ServiceCountry? country,
  String code, {
  ServicesDirectory? directory,
}) {
  final upper = code.trim().toUpperCase();
  if (upper.isEmpty) {
    return '';
  }
  if (country != null && country.currency == upper) {
    return country.currencyLabel;
  }
  return switch (upper) {
    'USD' => l10n.posServicesCurrencyUsd,
    'EUR' => l10n.posServicesCurrencyEur,
    _ => directory?.currencyName(upper) ?? '\u{2066}$upper\u{2069}',
  };
}

/// Step two of the airtime form: the number, what the relay made of it, and
/// the country's networks — always on screen, so the cashier can pick one at
/// once without waiting for the relay, or after it could not tell.
class AirtimePhoneStep extends StatelessWidget {
  const AirtimePhoneStep({
    super.key,
    required this.viewModel,
    required this.onChangeCountry,
    this.onSubmitted,
    this.autofocus = false,
  });

  final AirtimeViewModel viewModel;
  final VoidCallback onChangeCountry;
  final VoidCallback? onSubmitted;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final country = viewModel.country;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ServicePhoneField(
          dial: country?.primaryDial ?? '',
          national: viewModel.national,
          revision: viewModel.phoneRevision,
          focusRevision: viewModel.focusRevision,
          label: l10n.posAirtimePhoneLabel,
          hint: l10n.posAirtimePhoneExample,
          autofocus: autofocus,
          onDialTap: onChangeCountry,
          onChanged: (raw, {required pasted}) =>
              viewModel.onPhoneInput(raw, pasted: pasted),
          onSubmitted: onSubmitted,
        ),
        if (viewModel.dialCodeCorrection case final fix?) ...[
          const SizedBox(height: 8),
          ServiceDialCodeHint(
            correction: fix,
            onFix: viewModel.applyDialCodeCorrection,
          ),
        ],
        const SizedBox(height: 8),
        if (viewModel.dialChoices.isNotEmpty)
          ServiceDialChoices(
            dial: viewModel.sharedDial ?? '',
            countries: viewModel.dialChoices,
            onChosen: viewModel.chooseDialCountry,
          )
        else
          _DetectionLine(viewModel: viewModel),
        const SizedBox(height: 10),
        _Networks(viewModel: viewModel),
      ],
    );
  }
}

class _DetectionLine extends StatelessWidget {
  const _DetectionLine({required this.viewModel});

  final AirtimeViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final detected = viewModel.detectedOperator;

    Widget line({
      required Widget icon,
      required String text,
      required Color color,
      Widget? trailing,
      Key? key,
    }) => Row(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: icon),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
        ),
        ?trailing,
      ],
    );

    Icon icon(IconData data, Color color) => Icon(data, size: 17, color: color);

    if (viewModel.hasUnknownPrefix) {
      return line(
        key: const ValueKey('service_phone_status'),
        icon: icon(Icons.public_off_rounded, colors.warning),
        text: l10n.posAirtimePhoneUnknownCode,
        color: colors.warning,
      );
    }
    switch (viewModel.detectionStatus) {
      case AirtimeDetectionStatus.detecting:
        return line(
          key: const ValueKey('service_phone_status'),
          icon: const SizedBox.square(
            dimension: 15,
            child: PointySpinner(strokeWidth: 2),
          ),
          text: l10n.posAirtimeDetecting,
          color: colors.mutedInk,
        );
      case AirtimeDetectionStatus.detected:
        final name = detected?.label ?? '';
        if (viewModel.detectionDisagrees) {
          return line(
            key: const ValueKey('service_phone_status'),
            icon: icon(Icons.swap_horiz_rounded, colors.warning),
            text: l10n.posAirtimeDetectDisagrees(name),
            color: colors.warning,
            trailing: TextButton(
              key: const ValueKey('service_use_detected'),
              onPressed: viewModel.useDetectedOperator,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(l10n.posAirtimeUseDetected(name)),
            ),
          );
        }
        return line(
          key: const ValueKey('service_phone_status'),
          icon: icon(Icons.check_circle_rounded, colors.success),
          text: l10n.posAirtimeDetected(name),
          color: colors.success,
        );
      case AirtimeDetectionStatus.notDetected:
        return line(
          key: const ValueKey('service_phone_status'),
          icon: icon(Icons.help_outline_rounded, colors.warning),
          text: l10n.posAirtimeNotDetected,
          color: colors.warning,
        );
      case AirtimeDetectionStatus.unavailable:
        return line(
          key: const ValueKey('service_phone_status'),
          icon: icon(Icons.cloud_off_rounded, colors.warning),
          text: l10n.posAirtimeDetectUnavailable,
          color: colors.warning,
        );
      case AirtimeDetectionStatus.failed:
        return line(
          key: const ValueKey('service_phone_status'),
          icon: icon(Icons.cloud_off_rounded, colors.warning),
          text: l10n.posAirtimeDetectFailed,
          color: colors.warning,
        );
      case AirtimeDetectionStatus.invalidNumber:
        return line(
          key: const ValueKey('service_phone_status'),
          icon: icon(Icons.error_outline_rounded, colors.danger),
          text: l10n.posAirtimeDetectInvalid,
          color: colors.danger,
        );
      case AirtimeDetectionStatus.idle:
        return line(
          key: const ValueKey('service_phone_status'),
          icon: icon(Icons.info_outline_rounded, colors.mutedInk),
          text: viewModel.national.isEmpty
              ? l10n.posAirtimePhoneHelp
              : l10n.posAirtimePhoneKeepTyping,
          color: colors.mutedInk,
        );
    }
  }
}

class _Networks extends StatelessWidget {
  const _Networks({required this.viewModel});

  final AirtimeViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final country = viewModel.country;
    if (country == null) {
      return const SizedBox.shrink();
    }
    if (viewModel.isLoadingCountry) {
      return Row(
        children: [
          const SizedBox.square(
            dimension: 16,
            child: PointySpinner(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            l10n.posAirtimeCountryLoading,
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ],
      );
    }
    if (viewModel.hasCountryError) {
      return PointyInlineMessage.error(
        key: const ValueKey('service_country_error'),
        message: l10n.posAirtimeCountryFailed,
        compact: true,
        trailing: TextButton(
          onPressed: viewModel.retryCountry,
          child: Text(l10n.retryButton),
        ),
      );
    }
    final networks = viewModel.networks;
    if (networks.isEmpty) {
      return Text(
        l10n.posAirtimeNetworksNone,
        style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        for (final operator in networks)
          ServiceNetworkChip(
            key: ValueKey('service_network_${operator.id}'),
            operator: operator,
            selected: viewModel.operator?.id == operator.id,
            detected:
                viewModel.detectionStatus == AirtimeDetectionStatus.detected &&
                viewModel.detectedOperator?.id == operator.id,
            onTap: () => viewModel.selectOperator(operator),
          ),
      ],
    );
  }
}

/// One network the cashier can pick: its logo (its initial when it has none)
/// and its Arabic name. The one the relay recognised wears a check.
class ServiceNetworkChip extends StatelessWidget {
  const ServiceNetworkChip({
    super.key,
    required this.operator,
    required this.selected,
    required this.onTap,
    this.detected = false,
  });

  final AirtimeOperator operator;
  final bool selected;
  final bool detected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final name = operator.label;
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      child: ExcludeSemantics(
        child: Material(
          color: selected ? colors.primaryContainer : colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PointyRadii.input),
            side: BorderSide(
              color: selected ? colors.primaryStrong : colors.line,
              width: selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 42),
              padding: const EdgeInsetsDirectional.fromSTEB(8, 5, 12, 5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ServiceNetworkLogo(operator: operator),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium?.copyWith(
                        color: selected ? colors.primaryDark : colors.ink,
                        fontWeight: selected
                            ? FontWeight.w800
                            : FontWeight.w600,
                      ),
                    ),
                  ),
                  if (detected) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.check_circle_rounded,
                      size: 17,
                      color: colors.success,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A network's mark: its logo when the relay sent one, else its initial in a
/// circle. One size for the chips, a smaller one under the read-back.
class ServiceNetworkLogo extends StatelessWidget {
  const ServiceNetworkLogo({super.key, required this.operator, this.size = 28});

  final AirtimeOperator operator;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final name = operator.name.trim();
    final initial = name.isEmpty ? '#' : name.characters.first;
    final fallback = Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.subtleFill,
        shape: BoxShape.circle,
        border: Border.all(color: colors.line),
      ),
      child: Text(
        initial,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: colors.primaryStrong,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.5,
          height: 1.1,
        ),
      ),
    );
    return SizedBox.square(
      dimension: size,
      child: operator.logo.isEmpty
          ? fallback
          : ClipOval(
              child: PointyProductImageFrame(
                imageUrl: operator.logo,
                fallbackText: operator.name,
                width: size,
                height: size,
                borderRadius: size / 2,
                padding: EdgeInsets.all(size / 9),
                backgroundColor: Colors.white,
                fallback: fallback,
              ),
            ),
    );
  }
}
