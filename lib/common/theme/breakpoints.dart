/// Width-based breakpoints, keyed to actual observed device classes rather
/// than a single OS's guidelines. Values are lower-bounds (>=).
///
/// `tablet` (600) matches the breakpoint [LoginScreen] already used before
/// this file existed — kept identical so adopting these constants app-wide
/// costs zero visual change on the login screen itself.
class AppBreakpoints {
  AppBreakpoints._();

  static const double phone = 360;
  static const double tablet = 600;
  static const double desktop = 1024;
  static const double wide = 1440;
}

enum DeviceClass { smallPhone, phone, tablet, desktop, wide }

DeviceClass deviceClassOf(double width) {
  if (width >= AppBreakpoints.wide) return DeviceClass.wide;
  if (width >= AppBreakpoints.desktop) return DeviceClass.desktop;
  if (width >= AppBreakpoints.tablet) return DeviceClass.tablet;
  if (width >= AppBreakpoints.phone) return DeviceClass.phone;
  return DeviceClass.smallPhone;
}
