import 'package:flutter/material.dart';

/// Wraps a custom (non-Material) tappable widget so it gets the three
/// things a bare `GestureDetector` doesn't provide for free: a ripple/
/// highlight on press, a screen-reader label, and a tap area of at least
/// 44x44 — Apple's and Material's touch-target minimum. [child] is kept at
/// its original visual size and centered inside the (invisible, if larger)
/// tap area, so nothing on screen changes at rest.
class TapTarget extends StatelessWidget {
  const TapTarget({
    super.key,
    required this.child,
    required this.onTap,
    required this.semanticLabel,
    this.borderRadius,
    this.minSize = 44,
  });

  final Widget child;
  final VoidCallback onTap;
  final String semanticLabel;
  final BorderRadius? borderRadius;
  final double minSize;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: semanticLabel,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: borderRadius,
          child: Container(
            constraints: BoxConstraints(minWidth: minSize, minHeight: minSize),
            alignment: Alignment.center,
            child: child,
          ),
        ),
      ),
    );
  }
}
