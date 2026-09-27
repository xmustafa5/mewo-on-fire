import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import 'pair_screen.dart';

class PcsTab extends StatelessWidget {
  const PcsTab({super.key});

  static Color statusColor(String s, ColorScheme cs) {
    switch (s) {
      case PcStatus.connected:
        return Colors.green;
      case PcStatus.connecting:
        return Colors.amber;
      case PcStatus.unpaired:
        return cs.error;
      default:
        return cs.outline;
    }
  }

  static String statusLabel(String s, bool serviceRunning) {
    if (!serviceRunning) return 'Service stopped';
    switch (s) {
      case PcStatus.connected:
        return 'Connected';
      case PcStatus.connecting:
        return 'Connecting…';
      case PcStatus.unpaired:
        return 'Unpaired — removed on the PC. Remove it and pair again.';
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
            'You can also revoke it on the PC with `ccnotify devices` / `ccnotify revoke`.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) await AppState.instance.removePc(pc.id);
  }

  void _openPair(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PairScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        return Scaffold(
          appBar: AppBar(title: const Text('ccnotify')),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _openPair(context),
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Pair PC'),
          ),
          body: !state.loaded
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.only(bottom: 96),
                  children: [
                    _ServiceCard(state: state),
                    if (state.pcs.isEmpty) const _EmptyPcs(),
                    for (final pc in state.pcs)
                      ListTile(
                        leading: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Icon(Icons.circle,
                              size: 14, color: statusColor(state.statusOf(pc.id), cs)),
                        ),
                        minLeadingWidth: 20,
                        title: Text(pc.name),
                        subtitle: Text(
                          '${statusLabel(state.statusOf(pc.id), state.serviceRunning)}\n'
                          '${pc.hosts.join(', ')} · port ${pc.port}',
                        ),
                        isThreeLine: true,
                        trailing: IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _confirmRemove(context, pc),
                        ),
                      ),
                  ],
                ),
        );
      },
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final running = state.serviceRunning;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Icon(running ? Icons.sensors : Icons.sensors_off,
                color: running ? cs.primary : cs.outline),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(running ? 'Background service running' : 'Background service stopped',
                      style: Theme.of(context).textTheme.titleSmall),
                  Text(
                    running
                        ? 'Listening for Claude Code sessions'
                        : (state.pcs.isEmpty ? 'Pair a PC to start' : 'No notifications will arrive'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (running)
              OutlinedButton(
                onPressed: () => state.stopService(byUser: true),
                child: const Text('Stop'),
              )
            else
              FilledButton(
                onPressed: state.pcs.isEmpty ? null : state.startService,
                child: const Text('Start'),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyPcs extends StatelessWidget {
  const _EmptyPcs();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      child: Column(
        children: [
          Icon(Icons.laptop_chromebook_outlined, size: 56, color: cs.outline),
          const SizedBox(height: 16),
          Text('No PCs paired yet', style: t.titleMedium),
          const SizedBox(height: 12),
          Text('On your PC run:', style: t.bodyMedium),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const SelectableText(
              'ccnotify install\nccnotify pair',
              style: TextStyle(fontFamily: 'monospace'),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Then tap "Pair PC" and scan the QR code. The phone and the PC must be on the same network.',
            style: t.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
