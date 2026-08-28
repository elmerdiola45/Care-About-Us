import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class BottomNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<BottomNavigationBarItem>? items;

  /// Pending cross-pharmacy request count shown as a badge on the admin
  /// "Requests" tab (index [adminRequestsIndex]). 0 hides the badge.
  /// Ignored when a custom [items] list is supplied.
  final int requestBadgeCount;

  const BottomNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.items,
    this.requestBadgeCount = 0,
  });

  static const int adminRequestsIndex = 2;

  static const List<BottomNavigationBarItem> adminItems = [
    BottomNavigationBarItem(
      icon: Icon(Icons.bar_chart_outlined),
      label: 'Dashboard',
    ),
    BottomNavigationBarItem(
      icon: Icon(Icons.description_outlined),
      label: 'Records',
    ),
    BottomNavigationBarItem(
      icon: Icon(Icons.notifications_none_rounded),
      label: 'Requests',
    ),
    BottomNavigationBarItem(
      icon: Icon(Icons.groups_outlined),
      label: 'Patients',
    ),
  ];

  /// [adminItems] with a count badge overlaid on the Requests tab.
  static List<BottomNavigationBarItem> adminItemsWithBadge(int requestCount) {
    if (requestCount <= 0) return adminItems;
    return [
      for (var i = 0; i < adminItems.length; i++)
        if (i == adminRequestsIndex)
          BottomNavigationBarItem(
            icon: Badge(
              label: Text(requestCount > 99 ? '99+' : '$requestCount'),
              child: adminItems[i].icon,
            ),
            label: adminItems[i].label,
          )
        else
          adminItems[i],
    ];
  }

  /// Single source of truth for the pharmacist shell's 5 tabs. Every screen
  /// that shows this nav bar (the home shell itself, and any screen pushed
  /// on top of it that still wants to show it) must reference this list
  /// instead of retyping its own — that drift is what previously made the
  /// nav bar show a different set of tabs (and a different item count) on
  /// different screens.
  static const List<BottomNavigationBarItem> pharmacistItems = [
    BottomNavigationBarItem(icon: Icon(Icons.home_outlined), label: 'Home'),
    BottomNavigationBarItem(
      icon: Icon(Icons.qr_code_scanner_outlined),
      label: 'Home Scan',
    ),
    BottomNavigationBarItem(
      icon: Icon(Icons.receipt_long_outlined),
      label: 'Saved Rx',
    ),
    BottomNavigationBarItem(
      icon: Icon(Icons.local_pharmacy_rounded),
      label: 'Dispense',
    ),
    BottomNavigationBarItem(
      icon: Icon(Icons.groups_outlined),
      label: 'Patients',
    ),
  ];
  static const int pharmacistHomeIndex = 0;
  static const int pharmacistHomeScanIndex = 1;
  static const int pharmacistSavedRxIndex = 2;
  static const int pharmacistDispenseIndex = 3;
  static const int pharmacistPatientsIndex = 4;

  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      currentIndex: currentIndex,
      onTap: onTap,
      type: BottomNavigationBarType.fixed,
      selectedItemColor: AppColors.teal,
      unselectedItemColor: Colors.grey.shade400,
      showUnselectedLabels: true,
      items: items ?? adminItemsWithBadge(requestBadgeCount),
    );
  }
}
