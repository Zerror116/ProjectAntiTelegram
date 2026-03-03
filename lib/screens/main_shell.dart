// lib/screens/main_shell.dart
import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';
import '../services/auth_service.dart';
import '../widgets/phoenix_loader.dart';
import 'admin_panel.dart';
import 'auth_screen.dart';
import 'cart_screen.dart';
import 'chats_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';
import 'system_tests_screen.dart';
import 'worker_panel.dart';

class _ShellDestination {
  const _ShellDestination({
    required this.id,
    required this.label,
    required this.icon,
    required this.page,
    this.priority = 0,
  });

  final String id;
  final String label;
  final IconData icon;
  final Widget page;
  final int priority;
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  bool _loading = true;
  StreamSubscription<User?>? _authSub;

  @override
  void initState() {
    super.initState();
    _authSub = authService.authStream.listen((_) {
      if (_loading) {
        setState(() => _loading = false);
      } else {
        setState(() {});
      }
    });

    if (authService.currentUser != null) {
      _loading = false;
    } else {
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted && _loading) setState(() => _loading = false);
      });
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  String _effectiveRole() => authService.effectiveRole;

  bool _hasAdminTab() {
    const roles = {'admin', 'creator'};
    return roles.contains(_effectiveRole());
  }

  bool _hasWorkerTab() {
    const roles = {'worker', 'creator'};
    return roles.contains(_effectiveRole());
  }

  bool _hasTestsTab() {
    return (authService.currentUser?.role ?? '').toLowerCase().trim() ==
        'creator';
  }

  bool _useCompactNavigation(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final platform = Theme.of(context).platform;
    final isIosLike =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
    return isIosLike && width < 700;
  }

  List<_ShellDestination> _buildDestinations({
    required bool showAdmin,
    required bool showWorker,
    required bool showTests,
  }) {
    return <_ShellDestination>[
      const _ShellDestination(
        id: 'chats',
        label: 'Чаты',
        icon: Icons.chat_bubble_outline_rounded,
        page: ChatsScreen(),
        priority: 100,
      ),
      const _ShellDestination(
        id: 'cart',
        label: 'Корзина',
        icon: Icons.shopping_bag_outlined,
        page: CartScreen(),
        priority: 95,
      ),
      if (showAdmin)
        const _ShellDestination(
          id: 'admin',
          label: 'Админ',
          icon: Icons.admin_panel_settings_outlined,
          page: AdminPanel(),
          priority: 85,
        ),
      if (showWorker)
        const _ShellDestination(
          id: 'worker',
          label: 'Рабочий',
          icon: Icons.inventory_2_outlined,
          page: WorkerPanel(),
          priority: 70,
        ),
      const _ShellDestination(
        id: 'profile',
        label: 'Профиль',
        icon: Icons.person_outline_rounded,
        page: ProfileScreen(),
        priority: 90,
      ),
      const _ShellDestination(
        id: 'settings',
        label: 'Настройки',
        icon: Icons.tune_rounded,
        page: SettingsScreen(),
        priority: 40,
      ),
      if (showTests)
        const _ShellDestination(
          id: 'tests',
          label: 'Тесты',
          icon: Icons.science_outlined,
          page: SystemTestsScreen(),
          priority: 20,
        ),
    ];
  }

  Future<void> _openMoreSheet(
    BuildContext context,
    List<_ShellDestination> hiddenDestinations,
    List<_ShellDestination> allDestinations,
  ) async {
    if (hiddenDestinations.isEmpty) return;
    final selectedId = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Row(
                    children: [
                      Text(
                        'Еще',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                ...hiddenDestinations.map((destination) {
                  final isSelected =
                      allDestinations[_index].id == destination.id;
                  return ListTile(
                    leading: Icon(destination.icon),
                    title: Text(destination.label),
                    trailing: isSelected
                        ? Icon(
                            Icons.check_circle,
                            color: theme.colorScheme.primary,
                          )
                        : null,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    onTap: () => Navigator.of(sheetContext).pop(destination.id),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || selectedId == null) return;
    final nextIndex = allDestinations.indexWhere((d) => d.id == selectedId);
    if (nextIndex < 0) return;
    setState(() => _index = nextIndex);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: authService.authStream,
      initialData: authService.currentUser,
      builder: (context, _) {
        if (_loading) {
          return const Scaffold(
            body: SafeArea(
              child: PhoenixLoadingView(
                title: 'Открываем приложение',
                subtitle: 'Подготавливаем ваш рабочий стол',
              ),
            ),
          );
        }

        if (authService.currentUser == null) {
          return const AuthScreen();
        }

        final showAdmin = _hasAdminTab();
        final showWorker = _hasWorkerTab();
        final showTests = _hasTestsTab();

        final destinations = _buildDestinations(
          showAdmin: showAdmin,
          showWorker: showWorker,
          showTests: showTests,
        );

        if (_index >= destinations.length) _index = destinations.length - 1;

        final compactNavigation = _useCompactNavigation(context);
        final primaryDestinations = compactNavigation
            ? (destinations.toList()
                    ..sort((a, b) => b.priority.compareTo(a.priority)))
                  .take(4)
                  .toList()
            : destinations;
        final hiddenDestinations = compactNavigation
            ? destinations
                  .where(
                    (destination) => !primaryDestinations.any(
                      (primary) => primary.id == destination.id,
                    ),
                  )
                  .toList()
            : const <_ShellDestination>[];

        final visibleDestinations =
            compactNavigation && hiddenDestinations.isNotEmpty
            ? [
                ...primaryDestinations,
                const _ShellDestination(
                  id: 'more',
                  label: 'Еще',
                  icon: Icons.grid_view_rounded,
                  page: SizedBox.shrink(),
                ),
              ]
            : compactNavigation
            ? primaryDestinations
            : destinations;

        final currentDestination = destinations[_index];
        final currentNavIndex = compactNavigation
            ? (() {
                final visibleIndex = visibleDestinations.indexWhere(
                  (destination) => destination.id == currentDestination.id,
                );
                if (visibleIndex >= 0) return visibleIndex;
                return visibleDestinations.length - 1;
              })()
            : _index;

        return Scaffold(
          body: SafeArea(
            child: IndexedStack(
              index: _index,
              children: destinations
                  .map((destination) => destination.page)
                  .toList(),
            ),
          ),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: currentNavIndex,
            onTap: (i) async {
              final tapped = visibleDestinations[i];
              if (tapped.id == 'more') {
                await _openMoreSheet(context, hiddenDestinations, destinations);
                return;
              }
              final nextIndex = destinations.indexWhere(
                (destination) => destination.id == tapped.id,
              );
              if (nextIndex < 0) return;
              setState(() => _index = nextIndex);
            },
            items: visibleDestinations
                .map(
                  (destination) => BottomNavigationBarItem(
                    icon: Icon(destination.icon),
                    label: destination.label,
                  ),
                )
                .toList(),
            type: visibleDestinations.length > 3
                ? BottomNavigationBarType.fixed
                : BottomNavigationBarType.shifting,
            iconSize: compactNavigation ? 24 : 22,
            selectedFontSize: compactNavigation ? 12 : 11,
            unselectedFontSize: compactNavigation ? 11 : 10,
            showUnselectedLabels: !compactNavigation,
          ),
        );
      },
    );
  }
}
