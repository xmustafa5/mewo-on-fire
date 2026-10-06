import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import 'chat_screen.dart';
import 'history_tab.dart' show relativeTime;

/// All Claude Code sessions of all PCs, newest first (PROTOCOL.md v1.2).
class SessionsTab extends StatefulWidget {
  const SessionsTab({super.key});

  @override
  State<SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<SessionsTab> {
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

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final sessions = state.sessions;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Sessions'),
            actions: [
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: state.refreshSessions,
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: state.refreshSessions,
            child: sessions.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          state.pcs.isEmpty
                              ? 'Pair a PC to see its Claude Code sessions.'
                              : 'No sessions yet.\nThey appear here once Claude Code runs on a paired PC '
                                  '(needs Mewo on Fire on the PC with session support — run `mewo install` again after updating).',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: cs.outline),
                        ),
                      ),
                    ],
                  )
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: sessions.length,
                    separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                    itemBuilder: (context, i) => _SessionTile(entry: sessions[i]),
                  ),
          ),
        );
      },
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.entry});
  final SessionEntry entry;

  @override
  Widget build(BuildContext context) {
    final s = entry.session;
    final cs = Theme.of(context).colorScheme;
    final (icon, color) = SessionStateChip.iconFor(s.state, cs);
    return ListTile(
      leading: Icon(icon, color: color),
      title: Row(
        children: [
          Flexible(
            child: Text(
              s.displayTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (s.queued > 0) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: '${s.queued} message${s.queued == 1 ? '' : 's'} from the phone waiting',
              child: Badge.count(count: s.queued),
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${s.project.isEmpty ? '(unknown project)' : s.project} · ${entry.pcName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: cs.outline, fontSize: 13),
          ),
          if (s.lastText.isNotEmpty)
            Text(s.lastText, maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SessionStateChip(session: s),
          if (s.lastTs > 0) ...[
            const SizedBox(height: 4),
            Text(relativeTime(s.time), style: TextStyle(color: cs.outline, fontSize: 12)),
          ],
        ],
      ),
      onTap: () => Navigator.of(context).push(ChatScreen.route(entry.pcId, s.id)),
    );
  }
}

/// Small colored label: Working / Finished / Needs you / Closed.
class SessionStateChip extends StatelessWidget {
  const SessionStateChip({super.key, required this.session});
  final CcSession session;

  static String label(String state) {
    switch (state) {
      case SessionState.working:
        return 'Working';
      case SessionState.waiting:
        return 'Needs you';
      case SessionState.ended:
        return 'Closed';
      default:
        return 'Finished';
    }
  }

  static (IconData, Color) iconFor(String state, ColorScheme cs) {
    switch (state) {
      case SessionState.working:
        return (Icons.autorenew, cs.primary);
      case SessionState.waiting:
        return (Icons.hourglass_top, Colors.amber.shade700);
      case SessionState.ended:
        return (Icons.stop_circle_outlined, cs.outline);
      default:
        return (Icons.check_circle, Colors.green);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (_, color) = iconFor(session.state, cs);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label(session.state),
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}
