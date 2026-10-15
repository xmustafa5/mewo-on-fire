import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import 'chat_screen.dart';
import 'home_screen.dart' show EmberTabBar;
import 'theme/ember.dart';
import 'theme/glass.dart';
import 'theme/motion.dart';

String relativeTime(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}

const List<String> _weekdays = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const List<String> _months = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "Today", "Yesterday", or "Mon, 6 Oct".
String dayLabel(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  final s = '${_weekdays[t.weekday - 1]}, ${t.day} ${_months[t.month - 1]}';
  return t.year == now.year ? s : '$s ${t.year}';
}

String clockOf(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}';
}

/// Everything that happened, as a timeline by day.
class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key});

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  String? _filter; // null = all, else an EventKind value
  Timer? _tick;

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
    super.dispose();
  }

  static IconData _iconFor(String kind) {
    switch (kind) {
      case EventKind.needsInput:
        return Icons.hourglass_top_rounded;
      case EventKind.stop:
        return Icons.check_rounded;
      case EventKind.sessionEnd:
        return Icons.stop_rounded;
      case EventKind.warning:
        return Icons.warning_amber_rounded;
      case EventKind.signoff:
        return Icons.draw_rounded;
      default:
        return Icons.notifications_rounded;
    }
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text('All events stored on this phone will be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Ember.danger, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) await AppState.instance.clearHistory();
  }

  void _showActions(HistoryEntry h) {
    final state = AppState.instance;
    final project = h.event.project;
    final muted = state.settings.mutedProjects.contains(project);
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                project.isEmpty ? 'This event' : project,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 14),
              SheetAction(
                icon: muted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined,
                color: muted ? Ember.ok : Ember.amber,
                title: muted ? 'Unmute project' : 'Mute project',
                subtitle: muted
                    ? 'Show notifications for this project again'
                    : 'Events stay in history, but no notifications',
                onTap: () {
                  Navigator.pop(ctx);
                  if (muted) {
                    state.unmuteProject(project);
                  } else {
                    state.muteProject(project);
                  }
                },
              ),
              if (h.event.sessionId.isNotEmpty) ...[
                const SizedBox(height: 8),
                SheetAction(
                  icon: Icons.forum_outlined,
                  color: Ember.mewo,
                  title: 'Open the chat',
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.of(context).push(ChatScreen.route(h.pcId, h.event.sessionId));
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Rows of the timeline: a day label, then its events (newest first).
  List<_Row> _rows(List<HistoryEntry> items) {
    final out = <_Row>[];
    String? day;
    for (var i = 0; i < items.length; i++) {
      final h = items[i];
      final label = dayLabel(h.event.time);
      if (label != day) {
        day = label;
        out.add(_Row.day(label));
      }
      final next = i + 1 < items.length ? dayLabel(items[i + 1].event.time) : null;
      out.add(_Row.event(h, first: out.last.isDay, last: next != label));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final items =
            _filter == null ? state.events : state.events.where((h) => h.event.kind == _filter).toList();
        final rows = _rows(items);
        final n = state.events.length;
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: ScreenHeader(
                  title: 'History',
                  subtitle: Text(n == 0 ? 'Nothing yet' : '$n ${n == 1 ? 'event' : 'events'} on this phone'),
                  actions: [
                    GhostIconButton(
                      icon: Icons.delete_sweep_outlined,
                      tooltip: 'Clear history',
                      color: Ember.danger,
                      onPressed: state.events.isEmpty ? null : _confirmClear,
                    ),
                  ],
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                  child: SegmentedGlass<String?>(
                    segments: const <(String?, String)>[
                      (null, 'All'),
                      (EventKind.needsInput, 'Needs input'),
                      (EventKind.stop, 'Finished'),
                      (EventKind.sessionEnd, 'Closed'),
                    ],
                    value: _filter,
                    onChanged: (v) => setState(() => _filter = v),
                  ),
                ),
              ),
              if (rows.isEmpty)
                SliverToBoxAdapter(
                  child: EmptyState(
                    icon: Icons.history_rounded,
                    title: state.events.isEmpty ? 'Nothing happened yet' : 'Nothing matches this filter',
                    body: state.events.isEmpty
                        ? 'Events land here when Claude finishes, needs your input, or a session ends.'
                        : 'Pick another filter to see the other events.',
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  sliver: SliverList.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final row = rows[i];
                      if (row.isDay) {
                        return Padding(
                          padding: EdgeInsets.fromLTRB(6, i == 0 ? 10 : 22, 0, 10),
                          child: Text(
                            row.label!.toUpperCase(),
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: Ember.text3,
                                  letterSpacing: 1.4,
                                ),
                          ),
                        );
                      }
                      final h = row.entry!;
                      return FadeSlideIn(
                        key: ValueKey<String>('${h.pcId}:${h.event.id}:${h.event.ts}'),
                        delay: Motion.stagger(i),
                        child: _EventRow(
                          entry: h,
                          icon: _iconFor(h.event.kind),
                          first: row.first,
                          last: row.last,
                          muted: state.settings.mutedProjects.contains(h.event.project),
                          onTap: h.event.sessionId.isEmpty
                              ? null
                              : () => Navigator.of(context).push(ChatScreen.route(h.pcId, h.event.sessionId)),
                          onLongPress: () => _showActions(h),
                        ),
                      );
                    },
                  ),
                ),
              SliverPadding(padding: EdgeInsets.only(bottom: EmberTabBar.bottomInset(context))),
            ],
          ),
        );
      },
    );
  }
}

class _Row {
  const _Row.day(this.label)
      : entry = null,
        first = false,
        last = false;
  const _Row.event(this.entry, {required this.first, required this.last}) : label = null;

  final String? label;
  final HistoryEntry? entry;
  final bool first;
  final bool last;

  bool get isDay => label != null;
}

/// One event on the timeline: a node on the rail, the project and what happened.
class _EventRow extends StatelessWidget {
  const _EventRow({
    required this.entry,
    required this.icon,
    required this.first,
    required this.last,
    required this.muted,
    required this.onTap,
    required this.onLongPress,
  });

  final HistoryEntry entry;
  final IconData icon;
  final bool first;
  final bool last;
  final bool muted;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final e = entry.event;
    final t = Theme.of(context).textTheme;
    final color = Ember.eventColor(e.kind);
    final text = e.text.replaceAll(RegExp(r'\s+'), ' ');
    return PressScale(
      onTap: onTap,
      onLongPress: onLongPress,
      scale: 0.985,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 36,
              child: CustomPaint(
                painter: _RailPainter(color: color, first: first, last: last),
                child: Padding(
                  padding: const EdgeInsets.only(top: 9),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Icon(icon, size: 11, color: Ember.bg),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 4, 4, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            e.project.isEmpty ? 'unknown project' : e.project,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.titleSmall,
                          ),
                        ),
                        if (muted) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.notifications_off_rounded, size: 13, color: Ember.text3),
                        ],
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            entry.pcName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.labelSmall?.copyWith(color: Ember.text3),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          clockOf(e.time),
                          style: t.labelSmall?.copyWith(
                            color: Ember.text3,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    if (text.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: t.bodySmall?.copyWith(color: Ember.text2),
                        ),
                      ),
                    if (onTap != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          children: [
                            Icon(Icons.forum_outlined, size: 12, color: color.withValues(alpha: 0.9)),
                            const SizedBox(width: 4),
                            Text(
                              'Open chat',
                              style: t.labelSmall?.copyWith(color: color.withValues(alpha: 0.9)),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The timeline rail of one row: the line through the day and the glowing node.
class _RailPainter extends CustomPainter {
  const _RailPainter({required this.color, required this.first, required this.last});

  final Color color;
  final bool first;
  final bool last;

  static const double _nodeY = 18;
  static const double _r = 9;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    final line = Paint()
      ..color = Ember.lineStrong
      ..strokeWidth = 1.5;
    canvas.drawLine(
      Offset(x, first ? _nodeY : 0),
      Offset(x, last ? _nodeY : size.height),
      line,
    );
    canvas.drawCircle(
      Offset(x, _nodeY),
      _r,
      Paint()
        ..color = color.withValues(alpha: 0.55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawCircle(Offset(x, _nodeY), _r, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_RailPainter old) => old.color != color || old.first != first || old.last != last;
}

/// A row in a bottom sheet of actions.
class SheetAction extends StatelessWidget {
  const SheetAction({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.color = Ember.text2,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      radius: 16,
      fill: Ember.surface2.withValues(alpha: 0.8),
      onTap: onTap,
      child: Row(
        children: [
          IconTile(icon: icon, color: color, size: 36, iconSize: 18),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: t.titleSmall),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle!, style: t.bodySmall?.copyWith(color: Ember.text2)),
                  ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, size: 20, color: Ember.text3),
        ],
      ),
    );
  }
}
