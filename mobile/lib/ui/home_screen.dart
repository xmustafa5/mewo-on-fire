import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import 'history_tab.dart';
import 'pcs_tab.dart';
import 'sessions_tab.dart';
import 'settings_tab.dart';
import 'theme/ember.dart';
import 'theme/flame.dart';
import 'theme/glass.dart';
import 'theme/motion.dart';

/// The shell: the four tabs over the ember background, with the floating
/// glass tab bar. Tabs keep their state; the one in front fades in.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  static const List<Widget> _tabs = <Widget>[PcsTab(), SessionsTab(), HistoryTab(), SettingsTab()];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppState.instance.requestPermissions();
    });
  }

  void _select(int i) {
    if (i == _index) return;
    HapticFeedback.selectionClick();
    setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: EmberBackground(
        child: IndexedStack(
          index: _index,
          children: [
            for (var i = 0; i < _tabs.length; i++) _TabPage(active: i == _index, child: _tabs[i]),
          ],
        ),
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: AppState.instance,
        builder: (context, _) => EmberTabBar(
          index: _index,
          waiting: AppState.instance.waitingCount,
          onChanged: _select,
        ),
      ),
    );
  }
}

/// One tab inside the [IndexedStack]: its animations pause while it is not
/// in front, and it fades and lifts in when it comes to the front.
class _TabPage extends StatefulWidget {
  const _TabPage({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<_TabPage> createState() => _TabPageState();
}

class _TabPageState extends State<_TabPage> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: Motion.slow, value: 1);
  late final Animation<double> _t = CurvedAnimation(parent: _c, curve: Motion.easeOut);

  @override
  void didUpdateWidget(_TabPage old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      if (reducedMotion(context)) {
        _c.value = 1;
      } else {
        _c.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TickerMode(
      enabled: widget.active,
      child: FadeTransition(
        opacity: _t,
        child: AnimatedBuilder(
          animation: _t,
          builder: (_, child) => Transform.translate(
            offset: Offset(0, 10 * (1 - _t.value)),
            child: Transform.scale(scale: 0.985 + 0.015 * _t.value, child: child),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Floating glass pill with four destinations; the lit segment slides to the
/// chosen one, and Home carries the count of requests waiting for you.
class EmberTabBar extends StatelessWidget {
  const EmberTabBar({super.key, required this.index, required this.waiting, required this.onChanged});

  final int index;
  final int waiting;
  final ValueChanged<int> onChanged;

  static const List<(IconData, IconData, String)> _items = <(IconData, IconData, String)>[
    (Icons.space_dashboard_outlined, Icons.space_dashboard_rounded, 'Home'),
    (Icons.forum_outlined, Icons.forum_rounded, 'Sessions'),
    (Icons.history_rounded, Icons.history_rounded, 'History'),
    (Icons.tune_rounded, Icons.tune_rounded, 'Settings'),
  ];

  /// Room the tabs need under their content so nothing hides behind the bar.
  static double bottomInset(BuildContext context) =>
      math.max(MediaQuery.paddingOf(context).bottom, 12) + 64 + 20;

  @override
  Widget build(BuildContext context) {
    final bottom = math.max(MediaQuery.paddingOf(context).bottom, 12.0);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottom),
      child: GlassBar(
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: Ember.lineStrong),
        child: SizedBox(
          height: 64,
          child: LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth / _items.length;
              return Stack(
                children: [
                  AnimatedPositioned(
                    duration: Motion.slow,
                    curve: Motion.emphasized,
                    left: w * index + 6,
                    top: 6,
                    bottom: 6,
                    width: w - 12,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Ember.flame.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(26),
                        border: Border.all(color: Ember.flame.withValues(alpha: 0.35)),
                        boxShadow: [BoxShadow(color: Ember.flame.withValues(alpha: 0.25), blurRadius: 18)],
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < _items.length; i++)
                        Expanded(
                          child: _TabItem(
                            icon: _items[i].$1,
                            activeIcon: _items[i].$2,
                            label: _items[i].$3,
                            selected: i == index,
                            badge: i == 0 ? waiting : 0,
                            onTap: () => onChanged(i),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.badge,
    required this.onTap,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final int badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Ember.amber : Ember.text3;
    return Semantics(
      button: true,
      selected: selected,
      label: badge > 0 ? '$label, $badge waiting' : label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedScale(
                  scale: selected ? 1.08 : 1,
                  duration: Motion.slow,
                  curve: Motion.spring,
                  child: AnimatedSwitcher(
                    duration: Motion.base,
                    transitionBuilder: fadeScaleTransition,
                    child: Icon(
                      selected ? activeIcon : icon,
                      key: ValueKey<bool>(selected),
                      size: 23,
                      color: color,
                    ),
                  ),
                ),
                if (badge > 0)
                  Positioned(
                    top: -7,
                    right: -12,
                    child: Breathe(
                      min: 0.75,
                      scale: 0.08,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        constraints: const BoxConstraints(minWidth: 18),
                        decoration: BoxDecoration(
                          color: Ember.amber,
                          borderRadius: BorderRadius.circular(999),
                          boxShadow: [BoxShadow(color: Ember.amber.withValues(alpha: 0.6), blurRadius: 10)],
                        ),
                        child: Text(
                          '$badge',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Ember.bg,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            AnimatedDefaultTextStyle(
              duration: Motion.base,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                letterSpacing: 0.2,
                color: color,
              ),
              child: Text(label),
            ),
          ],
        ),
      ),
    );
  }
}
