import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../data/models/catalog.dart';
import '../../design/cards_tokens.dart';
import '../../shared/card_art.dart';
import '../../shared/column_bleed.dart';
import '../shell/cards_sidebar.dart';
import 'brand_tile.dart';

/// Brands in one swipeable row of tiles; on a desktop, one row of as many
/// as fit.
class BrandShelf extends StatelessWidget {
  const BrandShelf({super.key, required this.brands, this.scope = ''});

  final List<CardBrand> brands;
  final String scope;

  /// About how wide a desktop's shelf tiles are.
  static const double _desktopTile = 200;

  @override
  Widget build(BuildContext context) {
    // A mouse cannot swipe: on a desktop the shelf is one row of as many as
    // fit, and «عرض الكل» shows the rest.
    if (CardsSidebarScope.of(context)) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final columns = math.max(
            2,
            ((constraints.maxWidth - CardsSpace.gutter * 2 + CardsSpace.md) /
                    (_desktopTile + CardsSpace.md))
                .floor(),
          );
          return TileRows(
            columns: columns,
            children: [
              for (final brand in brands.take(columns)) BrandTile(brand: brand),
            ],
          );
        },
      );
    }
    final width = MediaQuery.sizeOf(context).width;
    final tileWidth = width < 600 ? 164.0 : 200.0;
    return SizedBox(
      height: tileWidth / kCardAspect + 58 + tileTextGrowth(context),
      child: ColumnBleed(
        builder: (extra) => ListView.separated(
          scrollDirection: Axis.horizontal,
          scrollCacheExtent: const ScrollCacheExtent.pixels(900),
          padding:
              const EdgeInsets.symmetric(horizontal: CardsSpace.gutter) + extra,
          itemCount: brands.length,
          separatorBuilder: (_, _) => const SizedBox(width: CardsSpace.md),
          itemBuilder: (context, index) => SizedBox(
            width: tileWidth,
            child: BrandTile(brand: brands[index]),
          ),
        ),
      ),
    );
  }
}

/// How much taller a tile's name and price have grown at the phone's text size,
/// for a shelf that has to be told its height.
double tileTextGrowth(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  double grown(double fontSize) => (scaler.scale(fontSize) - fontSize) * 1.5;
  return grown(16) + grown(12);
}

/// Tiles in rows of [columns], each the same width: a desktop's shelf,
/// which a mouse reads without swiping. A short last row keeps the width.
class TileRows extends StatelessWidget {
  const TileRows({super.key, required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: CardsSpace.gutter),
      child: Column(
        children: [
          for (var start = 0; start < children.length; start += columns)
            Padding(
              padding: EdgeInsets.only(top: start == 0 ? 0 : CardsSpace.xl),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = start; i < start + columns; i++) ...[
                    if (i > start) const SizedBox(width: CardsSpace.md),
                    Expanded(
                      child: i < children.length
                          ? children[i]
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}
