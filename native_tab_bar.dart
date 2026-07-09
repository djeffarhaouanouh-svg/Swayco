// pubspec.yaml
//   dependencies:
//     cupertino_native: ^latest   # regarde la dernière version sur pub.dev
//
// Nav bar iOS 26 "liquid glass" via cupertino_native (CNTabBar).
// Tap + swipe synchronisés grâce au TabController.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:cupertino_native/cupertino_native.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const CupertinoApp(
      debugShowCheckedModeBanner: false,
      home: RootTabView(),
    );
  }
}

class RootTabView extends StatefulWidget {
  const RootTabView({super.key});

  @override
  State<RootTabView> createState() => _RootTabViewState();
}

class _RootTabViewState extends State<RootTabView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  int _index = 0;

  static const _tabs = [
    _Page(title: 'Accueil'),
    _Page(title: 'Explorer'),
    _Page(title: 'Profil'),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    // Garde _index synchro quand on swipe le TabBarView.
    _tabController.addListener(() {
      final i = _tabController.index;
      if (i != _index) setState(() => _index = i);
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      child: Stack(
        children: [
          // Contenu swipeable
          TabBarView(
            controller: _tabController,
            children: _tabs,
          ),

          // Tab bar native posée par-dessus (Stack = overlay propre)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: CNTabBar(
              currentIndex: _index,
              height: 56,
              tint: CupertinoColors.activeBlue, // couleur onglet actif
              onTap: (i) {
                setState(() => _index = i);
                _tabController.animateTo(i); // tap -> change de page
              },
              items: const [
                CNTabBarItem(
                  label: 'Accueil',
                  icon: CNIcon.symbol('house'),
                  activeIcon: CNIcon.symbol('house.fill'),
                ),
                CNTabBarItem(
                  label: 'Explorer',
                  icon: CNIcon.symbol('magnifyingglass'),
                ),
                CNTabBarItem(
                  label: 'Profil',
                  icon: CNIcon.symbol('person'),
                  activeIcon: CNIcon.symbol('person.fill'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Page extends StatelessWidget {
  final String title;
  const _Page({required this.title});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Text(
          title,
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
