// lib/screens/main_shell.dart
import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';
import '../services/auth_service.dart';
import 'admin_panel.dart';
import 'cart_screen.dart';
import 'chats_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';
import 'worker_panel.dart';

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

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: authService.authStream,
      initialData: authService.currentUser,
      builder: (context, _) {
        if (_loading) {
          return const Scaffold(
            body: SafeArea(child: Center(child: CircularProgressIndicator())),
          );
        }

        final showAdmin = _hasAdminTab();
        final showWorker = _hasWorkerTab();

        final pages = <Widget>[
          const ChatsScreen(),
          const CartScreen(),
          if (showAdmin) const AdminPanel(),
          if (showWorker) const WorkerPanel(),
          const ProfileScreen(),
          const SettingsScreen(),
        ];

        final navItems = <BottomNavigationBarItem>[
          const BottomNavigationBarItem(icon: Icon(Icons.chat), label: 'Чаты'),
          const BottomNavigationBarItem(icon: Icon(Icons.shopping_cart), label: 'Корзина'),
          if (showAdmin) const BottomNavigationBarItem(icon: Icon(Icons.admin_panel_settings), label: 'Админ'),
          if (showWorker) const BottomNavigationBarItem(icon: Icon(Icons.work), label: 'Worker'),
          const BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Профиль'),
          const BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'Настройки'),
        ];

        if (_index >= pages.length) _index = pages.length - 1;

        return Scaffold(
          body: SafeArea(
            child: IndexedStack(
              index: _index,
              children: pages,
            ),
          ),
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
