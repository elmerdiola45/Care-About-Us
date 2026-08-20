import 'package:flutter/material.dart';

import '../theme/responsive_context.dart';

/// Caps and centers page content on wide (tablet/desktop/"Desktop Site")
/// viewports, generalizing the `Center > ConstrainedBox(maxWidth: ...)`
/// pattern [LoginScreen] already used for its auth form.
///
/// Meant to be placed *inside* a screen's existing scrollable (`ListView`,
/// `Column` in a `SingleChildScrollView`, etc.) — it does not add its own
/// scroll view, so it never causes double-scroll-view nesting.
class ResponsiveCenter extends StatelessWidget {
  const ResponsiveCenter({
    super.key,
    required this.child,
    this.maxWidth = 1100,
    this.padding,
  });

  /// Preset for dashboard/list/detail pages — the majority of screens.
  const ResponsiveCenter.dashboard({
    super.key,
    required this.child,
    this.padding,
  }) : maxWidth = 1100;

  /// Preset for auth-style forms and bottom sheets.
  const ResponsiveCenter.form({super.key, required this.child, this.padding})
    : maxWidth = 560;

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(padding: padding ?? context.pagePadding, child: child),
      ),
    );
  }
}
