import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../design/cards_tokens.dart';

/// The success mark: a teal disc with a check, landing with a little spring
/// as [animation] runs (a revealed card, a top-up that arrived).
class SuccessSeal extends StatelessWidget {
  const SuccessSeal({super.key, required this.animation});

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: CurvedAnimation(parent: animation, curve: CardsMotion.spring),
      child: Center(
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: PointyColors.primary,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: PointyColors.primary.withValues(alpha: 0.35),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: const Icon(Icons.check_rounded, color: Colors.white, size: 36),
        ),
      ),
    );
  }
}
