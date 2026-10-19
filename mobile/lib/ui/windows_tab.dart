import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import 'chat_screen.dart';
import 'history_tab.dart' show relativeTime;
import 'theme/ember.dart';
import 'theme/glass.dart';
import 'theme/motion.dart';

/// The tabs of the Mewo Session window on every paired PC (PROTOCOL.md
/// v3.4), as slivers for the Sessions tab: each tab with its state, what
/// it runs and whether Claude Code has ended in it; a tap opens its chat,
/// where its questions wait too.
List<Widget> windowSlivers(BuildContext context, AppState state) {
  final t = Theme.of(context).textTheme;
  final all = state.windows;
  final errors = [
    for (final pc in state.pcs)
      if (state.windowsErrorOf(pc.id).isNotEmpty) '${pc.name}: ${state.windowsErrorOf(pc.id)}',
  ];
  if (all.isEmpty) {
    return [
      SliverToBoxAdapter(
        child: EmptyState(
          icon: Icons.tab_rounded,
          title: state.pcs.isEmpty
              ? 'Pair a PC first'
              : state.windowsKnown
                  ? 'No session tabs open'
                  : 'Asking the PCs…',
          body: errors.isNotEmpty
              ? errors.join('\n')
              : 'Build with me on a feature opens each of its sessions as a tab of the '
                  'Mewo Session window on the PC. The tabs show up here while they are open: '
                  'what each runs, whether Claude works, needs you, finished or ended.',
        ),
      ),
    ];
  }
  final out = <Widget>[];
  for (final pc in state.pcs) {
    final mine = [for (final (id, w) in all) if (id == pc.id) w];
    if (mine.isEmpty) continue;
    out.add(SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
        child: Text(
          '${pc.name.toUpperCase()} · ${_count(state, pc.id, mine)}',
          style: t.labelSmall?.copyWith(color: Ember.text3, letterSpacing: 1.4),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ));
    out.add(SliverList.builder(
      itemCount: mine.length,
      itemBuilder: (context, i) => FadeSlideIn(
        key: ValueKey<String>('${pc.id}:${mine[i].pid}'),
        delay: Motion.stagger(i),
        child: _WindowCard(pcId: pc.id, pcName: pc.name, window: mine[i]),
      ),
    ));
  }
  if (errors.isNotEmpty) {
    out.add(SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
        child: Text(errors.join('\n'), style: t.bodySmall?.copyWith(color: Ember.text3)),
      ),
    ));
  }
  return out;
}

/// The session the PC pushes for a tab, fresher than the snapshot the
/// window list carried.
CcSession? liveSessionOf(AppState state, String pcId, MewoWindow w) {
  if (w.sessionId.isEmpty) return w.session;
  for (final e in state.sessions) {
    if (e.pcId == pcId && e.session.id == w.sessionId) return e.session;
  }
  return w.session;
}

/// Unanswered questions and prompts of a tab's session.
int pendingOf(AppState state, String pcId, MewoWindow w) {
  if (w.sessionId.length < 8) return 0;
  final short = w.sessionId.substring(0, 8);
  return state.requests.where((r) => r.pcId == pcId && r.request.session == short && !r.answered).length;
}

String _count(AppState state, String pcId, List<MewoWindow> tabs) {
  var working = 0, waiting = 0, ended = 0;
  for (final w in tabs) {
    final s = w.stateWith(liveSessionOf(state, pcId, w));
    if (s == SessionState.working) working++;
    if (s == SessionState.waiting || pendingOf(state, pcId, w) > 0) waiting++;
    if (s == SessionState.ended) ended++;
  }
  return [
    '${tabs.length} ${tabs.length == 1 ? 'TAB' : 'TABS'}',
    if (working > 0) '$working WORKING',
    if (waiting > 0) '$waiting ${waiting == 1 ? 'NEEDS' : 'NEED'} YOU',
    if (ended > 0) '$ended ENDED',
  ].join(' · ');
}

/// A summary line for the page header: every PC's tabs together.
String windowsSummary(AppState state) {
  final all = state.windows;
  if (all.isEmpty) return state.windowsKnown ? 'No session tabs open' : 'Asking the PCs…';
  var working = 0, waiting = 0, ended = 0;
  for (final (pcId, w) in all) {
    final s = w.stateWith(liveSessionOf(state, pcId, w));
    if (s == SessionState.working) working++;
    if (s == SessionState.waiting || pendingOf(state, pcId, w) > 0) waiting++;
    if (s == SessionState.ended) ended++;
  }
  return [
    if (working > 0) '$working working',
    if (waiting > 0) '$waiting ${waiting == 1 ? 'needs' : 'need'} you',
    if (ended > 0) '$ended ended',
    '${all.length} ${all.length == 1 ? 'tab' : 'tabs'}',
  ].join(' · ');
}

/// One tab: its number and state at a glance, what it runs, Claude's last
/// words, and the ways to act on it.
class _WindowCard extends StatelessWidget {
  const _WindowCard({required this.pcId, required this.pcName, required this.window});
  final String pcId;
  final String pcName;
  final MewoWindow window;

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final t = Theme.of(context).textTheme;
    final w = window;
    final live = liveSessionOf(state, pcId, w);
    final st = w.stateWith(live);
    final pending = pendingOf(state, pcId, w);
    final heat = Ember.heatOf(pending > 0 ? SessionState.waiting : st);
    final working = st == SessionState.working;
    final lit = working || st == SessionState.waiting || pending > 0;
    final where = [
      if (w.feature.isNotEmpty) w.feature,
      if (w.branch.isNotEmpty) w.branch,
      if (w.modelLabel.isNotEmpty) w.modelLabel,
      if (w.terminal) 'terminal',
    ].join(' · ');
    final lastText = (live?.lastText ?? '').replaceAll(RegExp(r'\s+'), ' ');
    final badge = Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: heat.withValues(alpha: lit ? 0.22 : 0.12),
        border: Border.all(color: heat.withValues(alpha: lit ? 0.8 : 0.35)),
        boxShadow: lit ? [BoxShadow(color: heat.withValues(alpha: 0.45), blurRadius: 12)] : null,
      ),
      child: Text(
        w.n > 0 ? '${w.n}' : '•',
        style: t.labelLarge?.copyWith(color: heat, fontWeight: FontWeight.w700),
      ),
    );
    return GlassCard(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      glow: lit ? heat : null,
      borderColor: lit ? heat.withValues(alpha: 0.35) : null,
      onTap: () => _open(context, state),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: working ? Breathe(min: 0.6, child: badge) : badge,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        w.displayTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: t.titleSmall?.copyWith(fontSize: 15, height: 1.25),
                      ),
                    ),
                    const SizedBox(width: 8),
                    HeatChip(state: pending > 0 ? SessionState.waiting : st, compact: true),
                  ],
                ),
                if (where.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(where, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.labelSmall?.copyWith(color: Ember.text3)),
                ],
                if (w.ended)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      w.exitCode == null || w.exitCode == 0 ? 'Claude Code ended. The tab is still open on $pcName.' : 'Claude Code stopped (exit ${w.exitCode}). The tab is still open on $pcName.',
                      style: t.bodySmall?.copyWith(color: Ember.text2),
                    ),
                  )
                else if (lastText.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(lastText, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(color: Ember.text2)),
                ] else if (w.sessionId.isEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Claude Code is starting…', style: t.bodySmall?.copyWith(color: Ember.text2)),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(Icons.schedule_rounded, size: 12, color: Ember.text3),
                    const SizedBox(width: 4),
                    Text(
                      (live?.lastTs ?? 0) > 0 ? relativeTime(live!.time) : (w.started > 0 ? 'opened ${relativeTime(w.startedAt)}' : ''),
                      style: t.labelSmall?.copyWith(color: Ember.text3),
                    ),
                    const Spacer(),
                    if (pending > 0) _Pill(icon: Icons.help_outline_rounded, text: pending == 1 ? '1 question' : '$pending questions', color: Ember.amber),
                    if ((live?.queued ?? 0) > 0) ...[
                      const SizedBox(width: 6),
                      _Pill(icon: Icons.smartphone_rounded, text: '${live!.queued} queued', color: Ember.mewoSoft),
                    ],
                  ],
                ),
              ],
            ),
          ),
          GhostIconButton(
            icon: Icons.more_horiz_rounded,
            tooltip: 'More',
            onPressed: () => _menu(context, state),
          ),
        ],
      ),
    );
  }

  void _open(BuildContext context, AppState state) {
    if (window.sessionId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Claude Code has not started in that tab yet')));
      return;
    }
    Navigator.of(context).push(ChatScreen.route(pcId, window.sessionId));
  }

  Future<void> _menu(BuildContext context, AppState state) async {
    final t = Theme.of(context).textTheme;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Ember.surface2,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  window.n > 0 ? 'Session ${window.n} · ${window.displayTitle}' : window.displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.titleSmall,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline_rounded, color: Ember.amber),
              title: const Text('Open the chat'),
              subtitle: const Text('Read it, answer its questions, send a message'),
              enabled: window.sessionId.isNotEmpty,
              onTap: () => Navigator.of(context).pop('chat'),
            ),
            ListTile(
              leading: const Icon(Icons.desktop_windows_outlined, color: Ember.text2),
              title: Text('Show on $pcName'),
              subtitle: const Text('Brings its tab forward in the Mewo Session window'),
              onTap: () => Navigator.of(context).pop('show'),
            ),
            if (!window.ended && !window.terminal)
              ListTile(
                leading: const Icon(Icons.stop_circle_outlined, color: Ember.flame),
                title: const Text('Stop the session'),
                subtitle: const Text('Closes its tab on the PC; Claude Code ends'),
                onTap: () => Navigator.of(context).pop('stop'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case 'chat':
        _open(context, state);
      case 'show':
        final err = await state.showWindow(pcId, window.pid);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err.isEmpty ? 'Shown on $pcName' : err)));
      case 'stop':
        final sure = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(window.n > 0 ? 'Stop session ${window.n}?' : 'Stop this session?'),
            content: const Text('Claude Code ends in that tab, as closing the tab on the PC does. A build session that has no pull request yet is started again by the build.'),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Stop')),
            ],
          ),
        );
        if (sure != true || !context.mounted) return;
        final err = await state.stopWindow(pcId, window.pid);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err.isEmpty ? 'Stopped on $pcName' : err)));
    }
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 2, 8, 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(text, style: t.labelSmall?.copyWith(color: color)),
        ],
      ),
    );
  }
}
