import 'package:flutter/material.dart';

import 'breakpoints.dart';

/// Breakpoint-aware queries for the current viewport, shared across every
/// screen so "wide" means the same thing everywhere it's used.
///
/// Uses `MediaQuery.sizeOf`/`.orientationOf` (scoped rebuilds) rather than
/// the wholesale `MediaQuery.of(context)` — this extension is called from
/// most screens in the app, some very large, so keeping each caller's
/// rebuild scope limited to the field it actually reads matters here.
extension ResponsiveContext on BuildContext {
  double get screenWidth => MediaQuery.sizeOf(this).width;

  DeviceClass get deviceClass => deviceClassOf(screenWidth);

  bool get isSmallPhone => screenWidth < AppBreakpoints.phone;

  bool get isTabletUp => screenWidth >= AppBreakpoints.tablet;

  bool get isDesktopUp => screenWidth >= AppBreakpoints.desktop;

  Orientation get orientation => MediaQuery.orientationOf(this);

  /// Outer page padding, replacing ad-hoc `EdgeInsets.all(16)` etc. at the
  /// top level of a screen's scrollable content.
  EdgeInsets get pagePadding => EdgeInsets.symmetric(
    horizontal: isDesktopUp
        ? 32
        : (isTabletUp ? 24 : (isSmallPhone ? 12 : 16)),
    vertical: isTabletUp ? 20 : 16,
  );
}
