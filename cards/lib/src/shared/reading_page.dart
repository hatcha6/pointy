import 'package:flutter/material.dart';

import '../design/cards_layout.dart';
import '../design/cards_tokens.dart';
import 'side_back.dart';

/// A page to read (the privacy policy, the terms, the licenses): one column
/// in the middle of the screen, its title centred at the top of it, the
/// same title appearing centred in a slim bar once it has scrolled away.
/// Title and text always share the same middle, on a phone or wide open.
class ReadingPage extends StatefulWidget {
  const ReadingPage({
    super.key,
    required this.title,
    required this.body,
    this.subtitle,
    this.titleDirection,
  });

  final String title;

  /// A line under the title (the page's purpose, a count).
  final String? subtitle;

  /// The title's own direction where it is not the app's language (a
  /// package name).
  final TextDirection? titleDirection;

  /// The page's content as a sliver; the column's padding is added here.
  final Widget body;

  @override
  State<ReadingPage> createState() => _ReadingPageState();
}

class _ReadingPageState extends State<ReadingPage> {
  /// Whether the large title has scrolled under the bar.
  final _titleGone = ValueNotifier(false);

  @override
  void dispose() {
    _titleGone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom + CardsSpace.huge;
    // Asked here, outside the side column's room: inside it the column is
    // already set aside and cannot be seen.
    final sideBack = SideBack.active(context);
    return SideBack(
      child: Scaffold(
        body: NotificationListener<ScrollNotification>(
          onNotification: (note) {
            if (note.depth == 0) {
              _titleGone.value = note.metrics.pixels > 56;
            }
            return false;
          },
          // The column is measured in the room the page really has, after
          // any side column has been set aside.
          child: LayoutBuilder(
            builder: (context, constraints) => CustomScrollView(
              slivers: [
                SliverAppBar(
                  pinned: true,
                  centerTitle: true,
                  automaticallyImplyLeading: !sideBack,
                  title: ValueListenableBuilder<bool>(
                    valueListenable: _titleGone,
                    builder: (context, gone, child) => AnimatedOpacity(
                      duration: CardsMotion.fast,
                      opacity: gone ? 1 : 0,
                      child: child,
                    ),
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textDirection: widget.titleDirection,
                    ),
                  ),
                ),
                SliverPadding(
                  padding: CardsLayout.column(
                    constraints.maxWidth,
                    top: CardsSpace.sm,
                    bottom: CardsSpace.xl,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      children: [
                        Text(
                          widget.title,
                          textAlign: TextAlign.center,
                          textDirection: widget.titleDirection,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (widget.subtitle case final subtitle?) ...[
                          const SizedBox(height: CardsSpace.sm),
                          Text(
                            subtitle,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              height: 1.6,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: CardsLayout.column(
                    constraints.maxWidth,
                    bottom: bottom,
                  ),
                  sliver: widget.body,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
