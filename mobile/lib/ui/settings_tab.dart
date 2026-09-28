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
              _header(context, 'About'),
              const ListTile(
                leading: Icon(Icons.lock_outline),
                title: Text('LAN only'),
                subtitle: Text(
                    'The phone connects directly to your PCs over TLS with a pinned certificate. '
                    'Nothing goes through the internet.'),
              ),
            ],
          ),
        );
      },
    );
  }
}
