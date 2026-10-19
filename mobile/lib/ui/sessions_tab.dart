import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import 'chat_screen.dart';
import 'features_tab.dart';
import 'flow_sheets.dart';
import 'new_session_sheet.dart';
import 'history_tab.dart' show relativeTime;
import 'home_screen.dart' show EmberTabBar;
import 'theme/ember.dart';
import 'theme/glass.dart';
import 'theme/motion.dart';
import 'windows_tab.dart';

/// What the page shows: every session, the features, or the tabs of the
/// Mewo Session windows (v3.4).
enum _Mode { sessions, features, windows }

/// All Claude Code sessions of all PCs, newest first (PROTOCOL.md v1.2).
class SessionsTab extends StatefulWidget {
  const SessionsTab({super.key});

  @override
  State<SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<SessionsTab> {
  Timer? _tick;
  Timer? _featureTick;
  _Mode _mode = _Mode.sessions;

  void _setMode(_Mode mode) {
    setState(() => _mode = mode);
    _featureTick?.cancel();
    if (mode == _Mode.features) {
      AppState.instance.refreshFeatures();
      _featureTick = Timer.periodic(const Duration(seconds: 20), (_) => AppState.instance.refreshFeatures());
    } else if (mode == _Mode.windows) {
      // The tabs come and go with the build: asked often while they are looked at.
      AppState.instance.refreshWindows();
      _featureTick = Timer.periodic(const Duration(seconds: 8), (_) => AppState.instance.refreshWindows());
    }
  }

  @override
  void initState() {
    super.initState();
    // Refresh relative times.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _featureTick?.cancel();
    super.dispose();
  }

  static String _summary(List<SessionEntry> sessions) {
    if (sessions.isEmpty) return 'Nothing running yet';
    final working = sessions.where((e) => e.session.state == SessionState.working).length;
    final waiting = sessions.where((e) => e.session.state == SessionState.waiting).length;
    final parts = <String>[
      if (working > 0) '$working working',
      if (waiting > 0) '$waiting ${waiting == 1 ? 'needs' : 'need'} you',
      '${sessions.length} ${sessions.length == 1 ? 'session' : 'sessions'}',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final sessions = state.sessions;
        final summary = _mode == _Mode.windows ? windowsSummary(state) : _summary(sessions);
        final title = switch (_mode) { _Mode.sessions => 'Sessions', _Mode.features => 'Features', _Mode.windows => 'Windows' };
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: RefreshIndicator(
            color: Ember.amber,
            backgroundColor: Ember.surface2,
            edgeOffset: MediaQuery.paddingOf(context).top + 8,
            onRefresh: () async {
              await state.refreshSessions();
              if (_mode == _Mode.features) await state.refreshFeatures();
              if (_mode == _Mode.windows) await state.refreshWindows();
            },
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
              slivers: [
                SliverToBoxAdapter(
                  child: ScreenHeader(
                    title: title,
                    subtitle: AnimatedSwitcher(
                      duration: Motion.base,
                      transitionBuilder: fadeUpTransition,
                      child: Text(summary, key: ValueKey<String>(summary)),
                    ),
                    actions: _mode == _Mode.windows
                        ? [
                            GhostIconButton(
                              icon: Icons.refresh_rounded,
                              tooltip: 'Refresh',
                              onPressed: state.refreshWindows,
                            ),
                          ]
                        : _mode == _Mode.features
                        ? [
                            GhostIconButton(
                              icon: Icons.badge_outlined,
                              tooltip: 'Roles',
                              onPressed: state.pcs.isEmpty ? null : () => showRolesSheet(context),
                            ),
                            GhostIconButton(
                              icon: Icons.refresh_rounded,
                              tooltip: 'Refresh',
                              onPressed: state.refreshFeatures,
                            ),
                            GhostIconButton(
                              icon: Icons.add_rounded,
                              tooltip: 'New feature',
                              color: Ember.amber,
                              onPressed: state.pcs.isEmpty ? null : () => showNewFeatureSheet(context),
                            ),
                          ]
                        : [
                            GhostIconButton(
                              icon: Icons.refresh_rounded,
                              tooltip: 'Refresh',
                              onPressed: state.refreshSessions,
                            ),
                            GhostIconButton(
                              icon: Icons.add_rounded,
                              tooltip: 'New session',
                              color: Ember.amber,
                              onPressed: state.pcs.isEmpty ? null : () => showNewSessionSheet(context),
                            ),
                          ],
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                    child: SegmentedGlass<_Mode>(
                      segments: const <(_Mode, String)>[(_Mode.sessions, 'Sessions'), (_Mode.features, 'Features'), (_Mode.windows, 'Windows')],
                      value: _mode,
                      onChanged: _setMode,
                    ),
                  ),
                ),
                if (_mode == _Mode.features)
                  ...featureSlivers(context, state)
                else if (_mode == _Mode.windows)
                  ...windowSlivers(context, state)
                else if (sessions.isEmpty)
                  SliverToBoxAdapter(
                    child: EmptyState(
                      flame: true,
                      title: state.pcs.isEmpty ? 'Pair a PC first' : 'No sessions yet',
                      body: state.pcs.isEmpty
                          ? 'Your Claude Code sessions show up here once a PC is paired.'
                          : 'They appear here as soon as Claude Code runs on a paired PC. '
                              'If a PC was set up before sessions existed, run `mewo install` on it again.',
                      action: state.pcs.isEmpty
                          ? null
                          : EmberButton(
                              label: 'Start a session',
                              icon: Icons.add_rounded,
                              shimmer: true,
                              onPressed: () => showNewSessionSheet(context),
                            ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.only(top: 8),
                    sliver: SliverList.builder(
                      itemCount: sessions.length,
                      itemBuilder: (context, i) => FadeSlideIn(
                        key: ValueKey<String>(sessions[i].key),
                        delay: Motion.stagger(i),
                        child: _SessionCard(entry: sessions[i]),
                      ),
                    ),
                  ),
                SliverPadding(padding: EdgeInsets.only(bottom: EmberTabBar.bottomInset(context))),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One session: a heat rail on the left tells its state at a glance, the
/// card opens its chat.
class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.entry});
  final SessionEntry entry;

  @override
  Widget build(BuildContext context) {
    final s = entry.session;
    final t = Theme.of(context).textTheme;
    final heat = Ember.heatOf(s.state);
    final working = s.state == SessionState.working;
    final waiting = s.state == SessionState.waiting;
    final lit = working || waiting;
    return GlassCard(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: EdgeInsets.zero,
      glow: lit ? heat : null,
      borderColor: lit ? heat.withValues(alpha: 0.35) : null,
      onTap: () => Navigator.of(context).push(ChatScreen.route(entry.pcId, s.id)),
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 14,
            bottom: 14,
            width: 4,
            child: _HeatRail(color: heat, live: working),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        s.displayTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: t.titleSmall?.copyWith(fontSize: 15, height: 1.25),
                      ),
                    ),
                    const SizedBox(width: 10),
                    HeatChip(state: s.state, compact: true),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${s.project.isEmpty ? 'unknown project' : s.project} · ${entry.pcName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.labelSmall?.copyWith(color: Ember.text3),
                ),
                if (s.lastText.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    s.lastText.replaceAll(RegExp(r'\s+'), ' '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodySmall?.copyWith(color: Ember.text2),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    if (s.lastTs > 0) ...[
                      const Icon(Icons.schedule_rounded, size: 12, color: Ember.text3),
                      const SizedBox(width: 4),
                      Text(relativeTime(s.time), style: t.labelSmall?.copyWith(color: Ember.text3)),
                    ],
                    const Spacer(),
                    if (s.artifacts.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(7, 2, 8, 2),
                          decoration: BoxDecoration(
                            color: Ember.amber.withValues(alpha: 0.13),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: Ember.amber.withValues(alpha: 0.4)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.brush_rounded, size: 11, color: Ember.amber),
                              const SizedBox(width: 4),
                              Text(
                                s.artifacts.length == 1 ? '1 artifact' : '${s.artifacts.length} artifacts',
                                style: t.labelSmall?.copyWith(color: Ember.amber),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (s.queued > 0)
                      Container(
                        padding: const EdgeInsets.fromLTRB(7, 2, 8, 2),
                        decoration: BoxDecoration(
                          color: Ember.mewo.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: Ember.mewo.withValues(alpha: 0.4)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.smartphone_rounded, size: 11, color: Ember.mewoSoft),
                            const SizedBox(width: 4),
                            Text(
                              '${s.queued} queued',
                              style: t.labelSmall?.copyWith(color: Ember.mewoSoft),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The coloured bar on a session card; it breathes while Claude works.
class _HeatRail extends StatelessWidget {
  const _HeatRail({required this.color, required this.live});
  final Color color;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final bar = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(4)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color, color.withValues(alpha: 0.35)],
        ),
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.55), blurRadius: 10)],
      ),
    );
    return live ? Breathe(min: 0.6, child: bar) : bar;
  }
}
