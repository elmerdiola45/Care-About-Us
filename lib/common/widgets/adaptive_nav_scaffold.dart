import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/responsive_context.dart';
import 'bottom_nav_bar.dart';

/// Shell scaffold for the two tabbed dashboards (pharmacist + admin).
///
/// Phones keep the familiar [BottomNavBar]. From tablet width up the same
/// destinations move into a [NavigationRail] on the left — a bottom bar
/// stretched across a 1400px browser window puts five tiny targets far
/// from the content and wastes vertical space, which is the main reason the
/// dashboards felt "mobile-only" on the web build. On desktop the rail is
/// extended so labels sit next to the icons.
///
/// [items] is the same `BottomNavigationBarItem` list the bottom bar already
/// uses (e.g. [BottomNavBar.pharmacistItems]), so both layouts can never
/// drift to a different set of tabs.
class AdaptiveNavScaffold extends StatelessWidget {
  const AdaptiveNavScaffold({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
    required this.body,
  });

  final List<BottomNavigationBarItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    if (!context.isTabletUp) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: SafeArea(child: body),
        bottomNavigationBar: BottomNavBar(
          currentIndex: currentIndex,
          onTap: onTap,
          items: items,
        ),
      );
    }

    final extended = context.isDesktopUp;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Row(
          children: [
            NavigationRail(
              selectedIndex: currentIndex,
              onDestinationSelected: onTap,
              extended: extended,
              minExtendedWidth: 220,
              backgroundColor: AppColors.surface,
              labelType: extended
                  ? NavigationRailLabelType.none
                  : NavigationRailLabelType.all,
              leading: _RailBrand(extended: extended),
              destinations: [
                for (final item in items)
                  NavigationRailDestination(
                    icon: item.icon,
                    selectedIcon: item.activeIcon,
                    label: Text(item.label ?? ''),
                  ),
              ],
            ),
            const VerticalDivider(
              width: 1,
              thickness: 1,
              color: AppColors.border,
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

class _RailBrand extends StatelessWidget {
  const _RailBrand({required this.extended});

  final bool extended;

  @override
  Widget build(BuildContext context) {
    final mark = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.tealLight, AppColors.teal],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(
        Icons.local_pharmacy_rounded,
        color: Colors.white,
        size: 22,
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 20),
      child: extended
          ? SizedBox(
              width: 188,
              child: Row(
                children: [
                  mark,
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Care About Us',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          'Pharmacy',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            )
          : mark,
    );
  }
}
