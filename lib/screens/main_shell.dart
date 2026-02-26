// lib/screens/main_shell.dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart';
import '../services/auth_service.dart';
import 'chats_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';
import 'admin_panel.dart';

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

    // Подписка для побочных эффектов (корректировка индекса, логирование)
    _authSub = authService.authStream.listen((user) {
      debugPrint('MainShell: authStream emitted user=${user?.email} role=${user?.role}');
      final pagesCount = _computePagesCount(user);
      if (_index >= pagesCount) {
        setState(() => _index = pagesCount - 1);
      }
      if (_loading) setState(() => _loading = false);
    });

    // Если currentUser уже есть — убираем индикатор загрузки
    final u = authService.currentUser;
    if (u != null) {
      debugPrint('MainShell.initState: currentUser present ${u.email} role=${u.role}');
      _loading = false;
    } else {
      // Снять индикатор через короткую задержку, если authStream не придёт
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted && _loading) setState(() => _loading = false);
      });
    }
  }

  int _computePagesCount(User? user) {
    final role = _normalizeRole(user);
    final isAdmin = role == 'admin' || role == 'creator' || role == 'superadmin';
    return isAdmin ? 4 : 3;
  }

  String _normalizeRole(User? user) {
    final raw = user?.role ?? authService.currentUser?.role ?? 'client';
    return raw.toString().toLowerCase().trim();
  }

  bool _isAdminRoleFrom(User? user) {
    final role = _normalizeRole(user);
    return role == 'admin' || role == 'creator' || role == 'superadmin';
  }

  @override
  void dispose() {
    try { _authSub?.cancel(); } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: authService.authStream,
      initialData: authService.currentUser,
      builder: (context, snap) {
        final user = snap.data;
        final role = _normalizeRole(user);
        final isAdmin = _isAdminRoleFrom(user);

        debugPrint('MainShell.build: role=$role isAdmin=$isAdmin loading=$_loading');

        if (_loading) {
          return const Scaffold(body: SafeArea(child: Center(child: CircularProgressIndicator())));
        }

        final pages = <Widget>[const ChatsScreen()];
        if (isAdmin) pages.add(const AdminPanel());
        pages.add(const ProfileScreen());
        pages.add(const SettingsScreen());

        final navItems = <BottomNavigationBarItem>[
          const BottomNavigationBarItem(icon: Icon(Icons.chat), label: 'Чаты'),
        ];
        if (isAdmin) {
          navItems.add(const BottomNavigationBarItem(icon: Icon(Icons.admin_panel_settings), label: 'Админ'));
        }
        navItems.add(const BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Профиль'));
        navItems.add(const BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'Настройки'));

        if (_index >= pages.length) _index = pages.length - 1;

        return Scaffold(
          body: SafeArea(child: IndexedStack(index: _index, children: pages)),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _index,
            onTap: (i) => setState(() => _index = i),
            items: navItems,
            type: BottomNavigationBarType.fixed,
          ),
        );
      },
    );
  }
}
