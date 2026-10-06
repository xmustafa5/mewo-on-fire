import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../app_state.dart';

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> with WidgetsBindingObserver {
  bool? _batteryExempt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkBattery();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkBattery();
  }

  Future<void> _checkBattery() async {
    if (!Platform.isAndroid) return;
    try {
      final v = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      if (mounted) setState(() => _batteryExempt = v);
    } catch (_) {}
  }

  Future<void> _clearChats(BuildContext context, AppState state) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear cached chats?'),
        content: const Text(
            'The session list, the chats and pictures fetched so far, and the status of '
            'messages sent from this phone are removed from the phone. Nothing on the PCs '
            'is touched; the sessions are fetched again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    await state.clearChats();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cached chats cleared')));
  }

  Future<void> _batteryTap() async {
    try {
      if (_batteryExempt == true) {
        await FlutterForegroundTask.openIgnoreBatteryOptimizationSettings();
      } else {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    } catch (_) {}
    await _checkBattery();
  }

  Widget _header(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final s = state.settings;
        final cs = Theme.of(context).colorScheme;
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              _header(context, 'Answer from phone'),
              SwitchListTile(
                secondary: const Icon(Icons.touch_app_outlined),
                title: const Text('Answer prompts from phone'),
                subtitle: const Text(
                    'Permission prompts, questions and plan approvals show a notification with '
                    'Allow / Deny / option buttons. When off, they only appear under '
                    '"Waiting for you" in the app.'),
                isThreeLine: true,
                value: s.answerFromPhone,
                onChanged: (v) => state.updateSettings(s.copyWith(answerFromPhone: v)),
              ),
              _header(context, 'Notify me when'),
              SwitchListTile(
                secondary: const Icon(Icons.hourglass_top),
                title: const Text('Claude needs input'),
                subtitle: const Text('Permission prompts, questions, idle'),
                value: s.notifyNeedsInput,
                onChanged: (v) => state.updateSettings(s.copyWith(notifyNeedsInput: v)),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.check_circle_outline),
                title: const Text('Claude finished'),
                subtitle: const Text('A reply is done'),
                value: s.notifyStop,
                onChanged: (v) => state.updateSettings(s.copyWith(notifyStop: v)),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.stop_circle_outlined),
                title: const Text('Session closed'),
                subtitle: const Text('A Claude Code session ended'),
                value: s.notifySessionEnd,
                onChanged: (v) => state.updateSettings(s.copyWith(notifySessionEnd: v)),
              ),
              _header(context, 'Muted projects'),
              if (s.mutedProjects.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text(
                    'None. Long-press an event in History to mute its project.',
                    style: TextStyle(color: cs.outline),
                  ),
                )
              else
                for (final p in s.mutedProjects)
                  ListTile(
                    leading: const Icon(Icons.notifications_off_outlined),
                    title: Text(p),
                    trailing: TextButton(
                      onPressed: () => state.unmuteProject(p),
                      child: const Text('Unmute'),
                    ),
                  ),
              if (Platform.isAndroid) ...[
                _header(context, 'Reliability'),
                ListTile(
                  leading: Icon(
                    _batteryExempt == true ? Icons.battery_full : Icons.battery_alert,
                    color: _batteryExempt == false ? cs.error : null,
                  ),
                  title: const Text('Battery optimization'),
                  subtitle: Text(_batteryExempt == null
                      ? 'Checking…'
                      : _batteryExempt!
                          ? 'Unrestricted — ccnotify can stay connected'
                          : 'Optimized — Android may cut the connection. Tap to exempt.'),
                  onTap: _batteryTap,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text(
                    'Some phones (Xiaomi, Samsung, Huawei, OnePlus, Oppo…) kill background apps '
                    'even with this setting. If notifications stop arriving, follow the steps for '
                    'your phone on dontkillmyapp.com (allow autostart, set battery to '
                    '"No restrictions", lock ccnotify in recent apps).',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
              if (Platform.isIOS) ...[
                _header(context, 'Background'),
                SwitchListTile(
                  secondary: const Icon(Icons.all_inclusive),
                  title: const Text('Stay connected in the background'),
                  subtitle: const Text(
                      'iOS pauses ccnotify shortly after you leave the app, and notifications '
                      'stop until you open it again. Turn this on to keep it running: it plays '
                      'silent audio in the background, which uses more battery.'),
                  isThreeLine: true,
                  value: s.keepAlive,
                  onChanged: (v) => state.updateSettings(s.copyWith(keepAlive: v)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text(
                    'Swiping ccnotify away in the app switcher stops it either way. '
                    'Events you missed are listed in History when you open the app again.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
              _header(context, 'Data'),
              ListTile(
                leading: const Icon(Icons.cleaning_services_outlined),
                title: const Text('Clear cached chats'),
                subtitle: const Text(
                    'Forgets the sessions and chats stored on this phone. They are fetched '
                    'again from your PCs.'),
                onTap: () => _clearChats(context, state),
              ),
              _header(context, 'About'),
              const ListTile(
                leading: Icon(Icons.lock_outline),
                title: Text('Private'),
                subtitle: Text(
                    'The phone talks to your PCs over TLS with a pinned certificate — directly on '
                    'your network, or through a relay that only passes the encrypted connection.'),
              ),
            ],
          ),
        );
      },
    );
  }
}
