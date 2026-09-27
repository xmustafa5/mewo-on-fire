import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';

String relativeTime(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}

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

  static (IconData, Color) _iconFor(String kind, ColorScheme cs) {
    switch (kind) {
      case EventKind.needsInput:
        return (Icons.hourglass_top, Colors.amber.shade700);
      case EventKind.stop:
        return (Icons.check_circle, Colors.green);
      case EventKind.sessionEnd:
        return (Icons.stop_circle_outlined, cs.outline);
      default:
        return (Icons.notifications, cs.primary);
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
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
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
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(muted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined),
              title: Text(muted ? 'Unmute project $project' : 'Mute project $project'),
              subtitle: Text(muted
                  ? 'Show notifications for this project again'
                  : 'Events stay in history, but no notifications'),
              onTap: () {
                Navigator.pop(ctx);
                if (muted) {
                  state.unmuteProject(project);
                } else {
                  state.muteProject(project);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, String? value) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilterChip(
          label: Text(label),
          selected: _filter == value,
          showCheckmark: false,
          onSelected: (_) => setState(() => _filter = value),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final items =
            _filter == null ? state.events : state.events.where((h) => h.event.kind == _filter).toList();
        return Scaffold(
          appBar: AppBar(
            title: const Text('History'),
            actions: [
              IconButton(
                tooltip: 'Clear history',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: state.events.isEmpty ? null : _confirmClear,
              ),
            ],
          ),
          body: Column(
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    _chip('All', null),
                    _chip('Needs input', EventKind.needsInput),
                    _chip('Finished', EventKind.stop),
                    _chip('Closed', EventKind.sessionEnd),
                  ],
                ),
              ),
              Expanded(
                child: items.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            state.events.isEmpty
                                ? 'No events yet.\nThey appear here when Claude Code finishes, needs input or a session ends.'
                                : 'No events match this filter.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: cs.outline),
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                        itemBuilder: (context, i) {
                          final h = items[i];
                          final (icon, color) = _iconFor(h.event.kind, cs);
                          final muted = state.settings.mutedProjects.contains(h.event.project);
                          final text = h.event.text;
                          return ListTile(
                            leading: Icon(icon, color: color),
                            title: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    h.event.project.isEmpty ? '(unknown project)' : h.event.project,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                ),
                                if (muted) ...[
                                  const SizedBox(width: 4),
                                  Icon(Icons.notifications_off, size: 14, color: cs.outline),
                                ],
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    '· ${h.pcName}',
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: cs.outline, fontSize: 13),
                                  ),
                                ),
                              ],
                            ),
                            subtitle: text.isEmpty
                                ? null
                                : Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
                            trailing: Text(
                              relativeTime(h.event.time),
                              style: TextStyle(color: cs.outline, fontSize: 12),
                            ),
                            onLongPress: () => _showActions(h),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
