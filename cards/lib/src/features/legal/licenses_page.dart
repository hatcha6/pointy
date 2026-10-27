import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../design/cards_tokens.dart';
import '../../shared/grouped.dart';
import '../../shared/reading_page.dart';
import '../../shared/skeleton.dart';
import '../../core/analytics/analytics.dart';

/// One package and the licenses it ships under.
@immutable
class LicensedPackage {
  const LicensedPackage(this.name, this.licenses);

  final String name;
  final List<LicenseEntry> licenses;
}

/// The open-source licenses the app is built on, in the app's own look: the
/// packages as a list, each license on its own page, as written (English,
/// left to right) in a column that reads comfortably on any width.
class LicensesPage extends StatefulWidget {
  const LicensesPage({super.key, this.packages});

  /// The packages to show; the app's registered licenses when null.
  final Future<List<LicensedPackage>>? packages;

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: screenSettings('licenses'),
      builder: (_) => const LicensesPage(),
    ),
  );

  /// Every registered license, grouped by package, A to Z.
  static Future<List<LicensedPackage>> load() async {
    final byPackage = <String, List<LicenseEntry>>{};
    await for (final entry in LicenseRegistry.licenses) {
      for (final package in entry.packages) {
        (byPackage[package] ??= []).add(entry);
      }
    }
    final names = byPackage.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return [for (final name in names) LicensedPackage(name, byPackage[name]!)];
  }

  @override
  State<LicensesPage> createState() => _LicensesPageState();
}

class _LicensesPageState extends State<LicensesPage> {
  late final _packages = widget.packages ?? LicensesPage.load();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final material = MaterialLocalizations.of(context);
    return ReadingPage(
      title: l10n.openSourceLicenses,
      subtitle: l10n.licensesIntro,
      body: SliverToBoxAdapter(
        child: FutureBuilder(
          future: _packages,
          builder: (context, snapshot) {
            final packages = snapshot.data;
            if (packages == null) {
              return Column(
                children: [
                  for (var i = 0; i < 6; i++)
                    const Padding(
                      padding: EdgeInsets.only(bottom: CardsSpace.sm),
                      child: Skeleton(height: 56, radius: CardsRadii.tile),
                    ),
                ],
              );
            }
            return Grouped(
              children: [
                for (final package in packages)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: CardsSpace.lg,
                    ),
                    title: Text(
                      package.name,
                      textDirection: TextDirection.ltr,
                      style: theme.textTheme.titleSmall,
                    ),
                    subtitle: Text(
                      material.licensesPackageDetailText(
                        package.licenses.length,
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => _PackageLicensesPage(package: package),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One package's licenses, paragraph by paragraph, as written: English,
/// left to right, in the same middle column.
class _PackageLicensesPage extends StatelessWidget {
  const _PackageLicensesPage({required this.package});

  final LicensedPackage package;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Every paragraph of every license, with a gap between licenses.
    final rows = <LicenseParagraph?>[
      for (final (index, license) in package.licenses.indexed) ...[
        if (index > 0) null,
        ...license.paragraphs,
      ],
    ];
    final text = theme.textTheme.bodySmall?.copyWith(
      height: 1.6,
      color: theme.colorScheme.onSurface,
    );
    return ReadingPage(
      title: package.name,
      titleDirection: TextDirection.ltr,
      subtitle: MaterialLocalizations.of(context)
          .licensesPackageDetailText(package.licenses.length),
      body: SliverList.builder(
        itemCount: rows.length,
        itemBuilder: (context, index) {
          final paragraph = rows[index];
          if (paragraph == null) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: CardsSpace.xl),
              child: Divider(height: 1),
            );
          }
          final centred = paragraph.indent == LicenseParagraph.centeredIndent;
          return Padding(
            padding: EdgeInsets.only(
              left: centred ? 0 : CardsSpace.lg * paragraph.indent,
              bottom: CardsSpace.sm,
            ),
            child: Text(
              paragraph.text,
              textDirection: TextDirection.ltr,
              textAlign: centred ? TextAlign.center : TextAlign.left,
              style: centred
                  ? text?.copyWith(fontWeight: FontWeight.w700)
                  : text,
            ),
          );
        },
      ),
    );
  }
}
