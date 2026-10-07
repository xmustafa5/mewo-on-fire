import 'dart:io';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import 'answer_screen.dart';
import 'history_tab.dart' show relativeTime;
import 'home_screen.dart' show EmberTabBar;
import 'pair_screen.dart';
import 'theme/ember.dart';
import 'theme/flame.dart';
import 'theme/glass.dart';
import 'theme/motion.dart';

/// Home: what needs you right now, whether the phone is listening, and the
/// PCs it is paired with.
class PcsTab extends StatelessWidget {
  const PcsTab({super.key});

  static String statusLabel(String s, bool serviceRunning) {
    if (!serviceRunning) return Platform.isIOS ? 'Not listening' : 'Service stopped';
    switch (s) {
      case PcStatus.connected:
        return 'Connected';
      case PcStatus.connecting:
        return 'Connecting…';
      case PcStatus.unpaired:
        return 'Unpaired on the PC — remove and pair again';
      default:
        return 'Offline — retrying';
    }
  }

  Future<void> _confirmRemove(BuildContext context, PairedPc pc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${pc.name}?'),
        content: const Text(
            'This phone will stop receiving notifications from this PC. '
            'You can also revoke it on the PC with `mewo devices` / `mewo revoke`.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Ember.danger, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) await AppState.instance.removePc(pc.id);
  }

  static void openPair(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PairScreen()));
  }

  /// One line under the title: what is going on right now.
  static String _summary(AppState state) {
    if (state.pcs.isEmpty) return 'Pair a PC to get started';
    if (!state.serviceRunning) return Platform.isIOS ? 'Not listening' : 'Background service stopped';
    final working = state.sessions.where((e) => e.session.state == SessionState.working).length;
    final needs = state.waitingCount;
    final parts = <String>[
      if (working > 0) '$working ${working == 1 ? 'session' : 'sessions'} working',
      if (needs > 0) '$needs ${needs == 1 ? 'request needs' : 'requests need'} you',
    ];
    if (parts.isNotEmpty) return parts.join(' · ');
    final online = state.pcs.where((p) => state.statusOf(p.id) == PcStatus.connected).length;
    return 'All quiet · $online of ${state.pcs.length} ${state.pcs.length == 1 ? 'PC' : 'PCs'} online';
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        if (!state.loaded) {
          return const Center(child: FlameMark(size: 56));
        }
        final burning = state.sessions.any((e) => e.session.state == SessionState.working);
        final summary = _summary(state);
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: ScreenHeader(
                  leading: MewoAvatar(burning: burning),
                  title: 'Mewo on Fire',
                  subtitle: AnimatedSwitcher(
                    duration: Motion.base,
                    transitionBuilder: fadeUpTransition,
                    child: Text(summary, key: ValueKey<String>(summary)),
                  ),
                  actions: [
                    GhostIconButton(
                      icon: Icons.qr_code_scanner_rounded,
                      tooltip: 'Pair a PC',
                      onPressed: () => openPair(context),
                    ),
                  ],
                ),
              ),
              if (state.requests.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: SectionLabel(
                    'Waiting for you',
                    top: 18,
                    trailing: _CountPill(count: state.waitingCount),
                  ),
                ),
                SliverList.builder(
                  itemCount: state.requests.length,
                  itemBuilder: (context, i) => FadeSlideIn(
                    key: ValueKey<String>(state.requests[i].key),
                    delay: Motion.stagger(i),
                    child: _RequestTile(entry: state.requests[i]),
                  ),
                ),
              ],
              SliverToBoxAdapter(
                child: FadeSlideIn(
                  delay: Motion.stagger(state.requests.length),
                  child: _ServiceCard(state: state),
                ),
              ),
              if (state.pcs.isEmpty)
                SliverToBoxAdapter(child: _EmptyPcs(onPair: () => openPair(context)))
              else ...[
                const SliverToBoxAdapter(child: SectionLabel('Your PCs')),
                SliverList.builder(
                  itemCount: state.pcs.length,
                  itemBuilder: (context, i) {
                    final pc = state.pcs[i];
                    return FadeSlideIn(
                      key: ValueKey<String>(pc.id),
                      delay: Motion.stagger(i + 1),
                      child: _PcCard(
                        pc: pc,
                        status: state.statusOf(pc.id),
                        serviceRunning: state.serviceRunning,
                        onRemove: () => _confirmRemove(context, pc),
                      ),
                    );
                  },
                ),
              ],
              SliverPadding(padding: EdgeInsets.only(bottom: EmberTabBar.bottomInset(context))),
            ],
          ),
        );
      },
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Ember.amber.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Ember.amber.withValues(alpha: 0.4)),
      ),
      child: Text(
        '$count',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Ember.amber),
      ),
    );
  }
}

/// A request Claude Code is blocked on: tap to answer.
class _RequestTile extends StatelessWidget {
  const _RequestTile({required this.entry});
  final PendingRequest entry;

  @override
  Widget build(BuildContext context) {
    final r = entry.request;
    final t = Theme.of(context).textTheme;
    final color = Ember.requestColor(r.kind);
    final title = r.title.isEmpty ? AnswerScreen.kindLabel(r.kind) : r.title;
    final summary = r.summary.isEmpty ? r.detail : r.summary;
    return GlassCard(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      glow: entry.answered ? null : color,
      borderColor: color.withValues(alpha: entry.answered ? 0.2 : 0.45),
      onTap: () => Navigator.of(context).push(AnswerScreen.route(entry.pcId, r.id)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Hero(
            tag: 'request:${entry.key}',
            child: IconTile(icon: AnswerScreen.iconFor(r.kind), color: color, glow: !entry.answered),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.project.isEmpty ? title : '${r.project} · $title',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.titleSmall,
                ),
                if (summary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall?.copyWith(
                        color: Ember.text2,
                        fontFamily: r.kind == RequestKind.permission ? Ember.mono(context) : null,
                        fontSize: r.kind == RequestKind.permission ? 12.5 : 13,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${entry.pcName} · ${relativeTime(r.time)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.labelSmall?.copyWith(color: Ember.text3),
                      ),
                    ),
                    if (entry.answered)
                      Row(
                        children: [
                          const Icon(Icons.schedule_send_outlined, size: 13, color: Ember.text3),
                          const SizedBox(width: 4),
                          Text('Answer sent', style: t.labelSmall?.copyWith(color: Ember.text3)),
                        ],
                      )
                    else
                      Text(
                        AnswerScreen.kindLabel(r.kind),
                        style: t.labelSmall?.copyWith(color: color),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Icon(Icons.chevron_right_rounded, size: 20, color: Ember.text3),
          ),
        ],
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final running = state.serviceRunning;
    // iOS has no background service: without keep-alive the connection only
    // lives while the app is open.
    final foregroundOnly = Platform.isIOS && !state.settings.keepAlive;
    final String title;
    final String subtitle;
    if (!running) {
      title = Platform.isIOS ? 'Not listening' : 'Background service stopped';
      subtitle = state.pcs.isEmpty ? 'Pair a PC to start' : 'No notifications will arrive';
    } else if (foregroundOnly) {
      title = 'Listening while the app is open';
      subtitle = 'iOS pauses it in the background — see Settings → Background';
    } else {
      title = Platform.isIOS ? 'Listening, also in the background' : 'Background service running';
      subtitle = 'Watching for Claude Code sessions';
    }
    return GlassCard(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
      child: Row(
        children: [
          GlowDot(color: running ? Ember.ok : Ember.ash, size: 12, live: running),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: t.titleSmall),
                const SizedBox(height: 2),
                Text(subtitle, style: t.bodySmall?.copyWith(color: Ember.text2)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (running)
            EmberButton(
              label: 'Stop',
              small: true,
              style: EmberButtonStyle.ghost,
              onPressed: () => state.stopService(byUser: true),
            )
          else
            EmberButton(
              label: 'Start',
              small: true,
              icon: Icons.play_arrow_rounded,
              onPressed: state.pcs.isEmpty ? null : state.startService,
            ),
        ],
      ),
    );
  }
}

class _PcCard extends StatelessWidget {
  const _PcCard({
    required this.pc,
    required this.status,
    required this.serviceRunning,
    required this.onRemove,
  });

  final PairedPc pc;
  final String status;
  final bool serviceRunning;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final color = serviceRunning ? Ember.statusColor(status) : Ember.ash;
    final live = serviceRunning && (status == PcStatus.connected || status == PcStatus.connecting);
    return GlassCard(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      onLongPress: onRemove,
      child: Row(
        children: [
          IconTile(icon: Icons.laptop_mac_rounded, color: color),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(pc.name, style: t.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Row(
                  children: [
                    GlowDot(color: color, size: 7, live: live),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        PcsTab.statusLabel(status, serviceRunning),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodySmall?.copyWith(color: Ember.text2),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${pc.hosts.join('  ')}  :${pc.port}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.labelSmall?.copyWith(
                    color: Ember.text3,
                    fontFamily: Ember.mono(context),
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
          ),
          GhostIconButton(
            icon: Icons.delete_outline_rounded,
            tooltip: 'Remove ${pc.name}',
            filled: false,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _EmptyPcs extends StatelessWidget {
  const _EmptyPcs({required this.onPair});
  final VoidCallback onPair;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      flame: true,
      title: 'No PCs paired yet',
      body: 'On your PC, run these two commands, then scan the QR code it shows. '
          'The phone and the PC need to be on the same network for pairing.',
      extra: const CodeBox(text: 'mewo install\nmewo pair', label: 'Terminal', fontSize: 14),
      action: EmberButton(
        label: 'Scan the QR code',
        icon: Icons.qr_code_scanner_rounded,
        shimmer: true,
        onPressed: onPair,
      ),
    );
  }
}
