// lib/screens/main_shell.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../services/auth_service.dart';
import '../services/web_notification_service.dart';
import '../services/web_push_client_service.dart';
import '../widgets/web_notification_prompt.dart';
import 'admin_panel.dart';
import 'auth_screen.dart';
import 'cart_screen.dart';
import 'chats_screen.dart';
import 'profile_screen.dart';
import 'pwa_guide_screen.dart';
import 'settings_screen.dart';
import 'stats_dashboard_screen.dart';
import 'system_tests_screen.dart';
import 'worker_panel.dart';

class _ShellDestination {
  const _ShellDestination({
    required this.id,
    required this.label,
    required this.icon,
    required this.builder,
    this.priority = 0,
  });

  final String id;
  final String label;
  final IconData icon;
  final WidgetBuilder builder;
  final int priority;
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  static const String _iosHomeHintShownKey = 'web_ios_add_to_home_hint_seen_v2';
  static const String _webNotificationsBannerDismissedKey =
      'web_notifications_banner_dismissed_v1';
  int _index = 0;
  StreamSubscription<User?>? _authSub;
  String _lastEffectiveRole = '';
  final Set<String> _activatedDestinations = <String>{};
  String? _phoneAccessDecisionInFlightId;
  WebNotificationPermissionState _webNotificationPermissionState =
      WebNotificationPermissionState.unsupported;
  bool _webNotificationStatusLoaded = false;
  bool _webNotificationBannerDismissed = false;
  bool _webNotificationRequestInProgress = false;
  Timer? _supportQueueRefreshTimer;

  @override
  void initState() {
    super.initState();
    if (_isAndroidWeb()) return;
    _lastEffectiveRole = authService.effectiveRole;
    _authSub = authService.authStream.listen((_) {
      final nextRole = authService.effectiveRole;
      final currentUser = authService.currentUser;
      unawaited(refreshSupportQueueNotices());
      if (kIsWeb &&
          currentUser != null &&
          _webNotificationPermissionState ==
              WebNotificationPermissionState.granted) {
        unawaited(WebPushClientService.ensureSubscribed(dio));
        unawaited(WebPushClientService.syncUnreadBadge(dio));
      }
      setState(() {
        if (_lastEffectiveRole != nextRole) {
          final nextIndex = _resolveNextIndexForRole(nextRole);
          _lastEffectiveRole = nextRole;
          _index = nextIndex;
          _activatedDestinations.clear();
        }
      });
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _maybeShowIosAddToHomeHint();
    });
    unawaited(_loadWebNotificationPromptState());
    unawaited(refreshSupportQueueNotices());
    _supportQueueRefreshTimer = Timer.periodic(
      const Duration(seconds: 12),
      (_) => unawaited(refreshSupportQueueNotices()),
    );
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _supportQueueRefreshTimer?.cancel();
    super.dispose();
  }

  String _effectiveRole() => authService.effectiveRole;

  bool _isCreatorNativeView() {
    final baseRole = (authService.currentUser?.role ?? '').toLowerCase().trim();
    final effectiveRole = authService.effectiveRole.toLowerCase().trim();
    return baseRole == 'creator' && effectiveRole == 'creator';
  }

  List<String> _destinationIdsForRole(String role) {
    final normalized = role.toLowerCase().trim();
    final showAdmin =
        normalized == 'admin' ||
        normalized == 'tenant' ||
        normalized == 'creator';
    final showStats = showAdmin;
    final showWorker =
        normalized == 'worker' ||
        normalized == 'tenant' ||
        normalized == 'creator';
    final showTests = _isCreatorNativeView();
    return <String>[
      'chats',
      'cart',
      if (showAdmin) 'admin',
      if (showStats) 'stats',
      if (showWorker) 'worker',
      'profile',
      'settings',
      if (showTests) 'tests',
    ];
  }

  int _resolveNextIndexForRole(String nextRole) {
    final previousIds = _destinationIdsForRole(_lastEffectiveRole);
    final currentId = previousIds.isEmpty
        ? 'profile'
        : previousIds[_index.clamp(0, previousIds.length - 1)];
    final nextIds = _destinationIdsForRole(nextRole);
    if (currentId == 'profile') {
      final profileSameIndex = nextIds.indexOf('profile');
      if (profileSameIndex >= 0) return profileSameIndex;
    }
    final sameTabIndex = nextIds.indexOf(currentId);
    if (sameTabIndex >= 0) return sameTabIndex;
    final profileIndex = nextIds.indexOf('profile');
    if (profileIndex >= 0) return profileIndex;
    return 0;
  }

  bool _hasAdminTab() {
    const roles = {'admin', 'tenant', 'creator'};
    final role = _effectiveRole();
    if (!roles.contains(role)) return false;
    if (_isCreatorNativeView()) return true;
    return _hasAnyPermission(const [
      'chat.write.public',
      'chat.write.support',
      'chat.pin',
      'chat.delete.all',
      'product.publish',
      'reservation.fulfill',
      'delivery.manage',
      'tenant.users.manage',
      'support.manage',
    ]);
  }

  bool _hasStatsTab() {
    const roles = {'admin', 'tenant', 'creator'};
    final role = _effectiveRole();
    if (!roles.contains(role)) return false;
    if (_isCreatorNativeView()) return true;
    return _hasAnyPermission(const [
      'delivery.manage',
      'reservation.fulfill',
      'support.manage',
      'tenant.users.manage',
      'chat.write.support',
    ]);
  }

  bool _hasWorkerTab() {
    const roles = {'worker', 'tenant', 'creator'};
    final role = _effectiveRole();
    if (!roles.contains(role)) return false;
    if (role == 'tenant') return true;
    if (_isCreatorNativeView()) return true;
    return _hasAnyPermission(const [
      'product.create',
      'product.requeue',
      'product.edit.own_pending',
    ]);
  }

  bool _hasTestsTab() {
    return _isCreatorNativeView();
  }

  bool _hasAnyPermission(List<String> keys) {
    for (final key in keys) {
      if (authService.hasPermission(key)) return true;
    }
    return false;
  }

  bool _useCompactNavigation(BuildContext context) {
    if (kIsWeb) return true;
    final width = MediaQuery.sizeOf(context).width;
    final platform = Theme.of(context).platform;
    final isIosLike =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
    return isIosLike && width < 700;
  }

  bool _isIosWeb() {
    return kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  }

  bool _isAndroidWeb() {
    return kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  }

  Future<void> _loadWebNotificationPromptState() async {
    if (!kIsWeb) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final dismissed =
          prefs.getBool(_webNotificationsBannerDismissedKey) == true;
      final permission = await WebNotificationService.getPermissionState();
      if (!mounted) return;
      setState(() {
        _webNotificationBannerDismissed =
            dismissed && permission != WebNotificationPermissionState.granted;
        _webNotificationPermissionState = permission;
        _webNotificationStatusLoaded = true;
      });
      if (permission == WebNotificationPermissionState.granted &&
          authService.currentUser != null) {
        unawaited(WebPushClientService.ensureSubscribed(dio));
        unawaited(WebPushClientService.syncUnreadBadge(dio));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _webNotificationStatusLoaded = true;
      });
    }
  }

  Future<void> _dismissWebNotificationPrompt() async {
    if (!kIsWeb) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_webNotificationsBannerDismissedKey, true);
    if (!mounted) return;
    setState(() {
      _webNotificationBannerDismissed = true;
    });
  }

  Future<void> _requestWebNotificationAccess() async {
    if (!kIsWeb) return;
    if (_webNotificationRequestInProgress) return;
    setState(() {
      _webNotificationRequestInProgress = true;
    });
    try {
      final current = await WebNotificationService.getPermissionState();
      var next = current;
      final showGuideInstead =
          current == WebNotificationPermissionState.unsupported ||
          (_isIosWeb() && !WebNotificationService.isStandaloneDisplayMode);

      if (showGuideInstead) {
        if (!mounted) return;
        await showWebNotificationHelpSheet(
          context,
          permissionState: current,
          isIosWeb: _isIosWeb(),
          isAndroidWeb: _isAndroidWeb(),
          isStandalone: WebNotificationService.isStandaloneDisplayMode,
        );
      } else if (current == WebNotificationPermissionState.granted) {
        await WebPushClientService.ensureSubscribed(dio);
        await WebPushClientService.syncUnreadBadge(dio);
        final sent = await WebPushClientService.sendServerTestPush(dio);
        if (sent <= 0) {
          await WebNotificationService.showSystemNotification(
            title: 'Проект Феникс',
            body: 'Системные уведомления уже включены.',
            tag: 'settings-test-notification',
          );
        }
        if (!mounted) return;
        showAppNotice(
          context,
          sent > 0
              ? 'Тестовый push отправлен с сервера'
              : 'Тестовое уведомление отправлено',
          tone: AppNoticeTone.success,
        );
      } else {
        next = await WebNotificationService.requestPermission();
        if (!mounted) return;
        if (next == WebNotificationPermissionState.granted) {
          await WebPushClientService.ensureSubscribed(dio);
          await WebPushClientService.syncUnreadBadge(dio);
          final sent = await WebPushClientService.sendServerTestPush(dio);
          if (sent <= 0) {
            await WebNotificationService.showSystemNotification(
              title: 'Проект Феникс',
              body:
                  'Уведомления включены. Новые сообщения будут приходить со звуком и в центре уведомлений браузера.',
              tag: 'notifications-enabled',
            );
          }
          if (!mounted) return;
          showAppNotice(
            context,
            sent > 0
                ? 'Системные уведомления включены, тестовый push отправлен'
                : 'Системные уведомления включены',
            tone: AppNoticeTone.success,
          );
        } else {
          await showWebNotificationHelpSheet(
            context,
            permissionState: next,
            isIosWeb: _isIosWeb(),
            isAndroidWeb: _isAndroidWeb(),
            isStandalone: WebNotificationService.isStandaloneDisplayMode,
          );
        }
      }

      if (!mounted) return;
      final refreshed = await WebNotificationService.getPermissionState();
      setState(() {
        _webNotificationPermissionState = refreshed;
        if (refreshed == WebNotificationPermissionState.granted) {
          _webNotificationBannerDismissed = true;
        }
      });
      if (refreshed == WebNotificationPermissionState.granted) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_webNotificationsBannerDismissedKey, true);
        await WebPushClientService.syncUnreadBadge(dio);
      }
    } finally {
      if (mounted) {
        setState(() {
          _webNotificationRequestInProgress = false;
        });
      } else {
        _webNotificationRequestInProgress = false;
      }
    }
  }

  Future<void> _openWebNotificationGuide() async {
    if (!kIsWeb || !mounted) return;
    await showWebNotificationHelpSheet(
      context,
      permissionState: _webNotificationPermissionState,
      isIosWeb: _isIosWeb(),
      isAndroidWeb: _isAndroidWeb(),
      isStandalone: WebNotificationService.isStandaloneDisplayMode,
    );
  }

  bool _shouldShowWebNotificationPrompt() {
    if (!kIsWeb) return false;
    if (!_webNotificationStatusLoaded) return false;
    if (_webNotificationBannerDismissed) return false;
    if (authService.currentUser == null) return false;
    if (_webNotificationPermissionState ==
        WebNotificationPermissionState.granted) {
      return false;
    }
    if (WebNotificationService.isSupported) return true;
    return _isIosWeb();
  }

  Future<void> _maybeShowIosAddToHomeHint() async {
    if (!_isIosWeb()) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final alreadyShown = prefs.getBool(_iosHomeHintShownKey) == true;
      if (alreadyShown || !mounted) return;
      await prefs.setBool(_iosHomeHintShownKey, true);
      if (!mounted) return;

      final action = await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('Как добавить сайт в быстрый доступ'),
            content: const Text(
              'Чтобы сайт открывался как приложение, добавьте его на экран «Домой»:\n\n'
              'Safari → Поделиться → На экран «Домой».',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop('later'),
                child: const Text('Позже'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop('guide'),
                child: const Text('Инструкция'),
              ),
            ],
          );
        },
      );
      if (!mounted || action != 'guide') return;
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const PwaGuideScreen()));
    } catch (_) {
      // ignore
    }
  }

  List<_ShellDestination> _buildDestinations({
    required bool showAdmin,
    required bool showStats,
    required bool showWorker,
    required bool showTests,
  }) {
    return <_ShellDestination>[
      const _ShellDestination(
        id: 'chats',
        label: 'Чаты',
        icon: Icons.chat_bubble_outline_rounded,
        builder: _buildChatsScreen,
        priority: 100,
      ),
      const _ShellDestination(
        id: 'cart',
        label: 'Корзина',
        icon: Icons.shopping_bag_outlined,
        builder: _buildCartScreen,
        priority: 95,
      ),
      if (showAdmin)
        const _ShellDestination(
          id: 'admin',
          label: 'Админ',
          icon: Icons.admin_panel_settings_outlined,
          builder: _buildAdminScreen,
          priority: 85,
        ),
      if (showStats)
        const _ShellDestination(
          id: 'stats',
          label: 'Статистика',
          icon: Icons.bar_chart_rounded,
          builder: _buildStatsScreen,
          priority: 80,
        ),
      if (showWorker)
        const _ShellDestination(
          id: 'worker',
          label: 'Рабочий',
          icon: Icons.inventory_2_outlined,
          builder: _buildWorkerScreen,
          priority: 70,
        ),
      const _ShellDestination(
        id: 'profile',
        label: 'Профиль',
        icon: Icons.person_outline_rounded,
        builder: _buildProfileScreen,
        priority: 90,
      ),
      const _ShellDestination(
        id: 'settings',
        label: 'Настройки',
        icon: Icons.tune_rounded,
        builder: _buildSettingsScreen,
        priority: 40,
      ),
      if (showTests)
        const _ShellDestination(
          id: 'tests',
          label: 'Тесты',
          icon: Icons.science_outlined,
          builder: _buildTestsScreen,
          priority: 20,
        ),
    ];
  }

  static Widget _buildChatsScreen(BuildContext context) => const ChatsScreen();
  static Widget _buildCartScreen(BuildContext context) => const CartScreen();
  static Widget _buildAdminScreen(BuildContext context) => const AdminPanel();
  static Widget _buildWorkerScreen(BuildContext context) => const WorkerPanel();
  static Widget _buildStatsScreen(BuildContext context) =>
      const StatsDashboardScreen();
  static Widget _buildProfileScreen(BuildContext context) =>
      const ProfileScreen();
  static Widget _buildSettingsScreen(BuildContext context) =>
      const SettingsScreen();
  static Widget _buildTestsScreen(BuildContext context) =>
      const SystemTestsScreen();
  static Widget _buildEmptyScreen(BuildContext context) =>
      const SizedBox.shrink();

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
    setState(() {
      _index = nextIndex;
      _activatedDestinations.add(allDestinations[nextIndex].id);
    });
    if (allDestinations[nextIndex].id == 'chats') {
      unawaited(refreshSupportQueueNotices());
    }
  }

  Future<void> _submitPhoneAccessOwnerDecision({
    required PhoneAccessOwnerRequest request,
    required bool approve,
  }) async {
    if (_phoneAccessDecisionInFlightId != null) return;
    setState(() {
      _phoneAccessDecisionInFlightId = request.id;
    });
    try {
      await submitPhoneAccessOwnerDecision(request.id, approve: approve);
    } finally {
      if (mounted) {
        setState(() {
          _phoneAccessDecisionInFlightId = null;
        });
      } else {
        _phoneAccessDecisionInFlightId = null;
      }
    }
  }

  Widget _buildPhoneAccessOwnerBanner(BuildContext context) {
    return ValueListenableBuilder<PhoneAccessOwnerRequest?>(
      valueListenable: phoneAccessOwnerRequestNotifier,
      builder: (context, request, _) {
        if (request == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final busy = _phoneAccessDecisionInFlightId == request.id;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Material(
            color: theme.colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Подтверждение номера',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Пользователь "${request.requesterLabel}" запросил доступ к вашей корзине'
                    '${request.phone.isNotEmpty ? ' (${request.phone})' : ''}.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: busy
                              ? null
                              : () => _submitPhoneAccessOwnerDecision(
                                  request: request,
                                  approve: false,
                                ),
                          child: const Text('Отклонить'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          onPressed: busy
                              ? null
                              : () => _submitPhoneAccessOwnerDecision(
                                  request: request,
                                  approve: true,
                                ),
                          child: const Text('Разрешить'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildWebNotificationBanner(BuildContext context) {
    if (!_shouldShowWebNotificationPrompt()) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: WebNotificationPromptCard(
        permissionState: _webNotificationPermissionState,
        isStandalone: WebNotificationService.isStandaloneDisplayMode,
        loading: _webNotificationRequestInProgress,
        onPrimaryPressed: _requestWebNotificationAccess,
        onGuidePressed: _openWebNotificationGuide,
        onDismissed: _dismissWebNotificationPrompt,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isAndroidWeb()) {
      return const AuthScreen();
    }
    return StreamBuilder<User?>(
      stream: authService.authStream,
      initialData: authService.currentUser,
      builder: (context, _) {
        if (authService.currentUser == null) {
          return const AuthScreen();
        }

        final showAdmin = _hasAdminTab();
        final showStats = _hasStatsTab();
        final showWorker = _hasWorkerTab();
        final showTests = _hasTestsTab();
        final effectiveRole = _effectiveRole();

        final destinations = _buildDestinations(
          showAdmin: showAdmin,
          showStats: showStats,
          showWorker: showWorker,
          showTests: showTests,
        );
        if (_index >= destinations.length) _index = destinations.length - 1;
        if (destinations.isNotEmpty) {
          final safeIndex = _index.clamp(0, destinations.length - 1);
          _activatedDestinations.add(destinations[safeIndex].id);
        }

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
                  builder: _buildEmptyScreen,
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
            child: Column(
              children: [
                _buildPhoneAccessOwnerBanner(context),
                _buildWebNotificationBanner(context),
                Expanded(
                  child: IndexedStack(
                    key: ValueKey('shell-$effectiveRole'),
                    index: _index,
                    children: destinations.map((destination) {
                      if (!_activatedDestinations.contains(destination.id)) {
                        return const SizedBox.shrink();
                      }
                      return KeyedSubtree(
                        key: ValueKey('page-${destination.id}-$effectiveRole'),
                        child: destination.builder(context),
                      );
                    }).toList(),
                  ),
                ),
              ],
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
              setState(() {
                _index = nextIndex;
                _activatedDestinations.add(destinations[nextIndex].id);
              });
              if (destinations[nextIndex].id == 'chats') {
                unawaited(refreshSupportQueueNotices());
              }
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
