import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../app_state.dart';
import 'home_screen.dart' show EmberTabBar;
import 'theme/ember.dart';
import 'theme/glass.dart';
import 'theme/motion.dart';

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

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final s = state.settings;
        var n = 0;
        Widget group(List<Widget> rows) => FadeSlideIn(
              delay: Motion.stagger(n++, step: 60),
              child: _Group(children: rows),
            );
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: ListView(
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.only(bottom: EmberTabBar.bottomInset(context)),
            children: [
              const ScreenHeader(title: 'Settings', subtitle: Text('Notifications, background, data')),
              const SectionLabel('Answer from phone', top: 16),
              group([
                _Row(
                  icon: Icons.touch_app_outlined,
                  color: Ember.mewo,
                  title: 'Answer prompts from phone',
                  subtitle: 'Permission prompts, questions and plan approvals arrive as a notification '
                      'with Allow / Deny / option buttons. Off: they only show under "Waiting for you".',
                  trailing: EmberSwitch(
                    value: s.answerFromPhone,
                    onChanged: (v) => state.updateSettings(s.copyWith(answerFromPhone: v)),
                  ),
                ),
              ]),
              const SectionLabel('Notify me when'),
              group([
                _Row(
                  icon: Icons.hourglass_top_rounded,
                  color: Ember.amber,
                  title: 'Claude needs input',
                  subtitle: 'Permission prompts, questions, idle',
                  trailing: EmberSwitch(
                    value: s.notifyNeedsInput,
                    onChanged: (v) => state.updateSettings(s.copyWith(notifyNeedsInput: v)),
                  ),
                ),
                _Row(
                  icon: Icons.check_circle_outline_rounded,
                  color: Ember.ok,
                  title: 'Claude finished',
                  subtitle: 'A reply is done',
                  trailing: EmberSwitch(
                    value: s.notifyStop,
                    onChanged: (v) => state.updateSettings(s.copyWith(notifyStop: v)),
                  ),
                ),
                _Row(
                  icon: Icons.stop_circle_outlined,
                  color: Ember.ash,
                  title: 'Session closed',
                  subtitle: 'A Claude Code session ended',
                  trailing: EmberSwitch(
                    value: s.notifySessionEnd,
                    onChanged: (v) => state.updateSettings(s.copyWith(notifySessionEnd: v)),
                  ),
                ),
              ]),
              const SectionLabel('Signatures'),
              group([
                _Row(
                  icon: Icons.draw_rounded,
                  color: Ember.amber,
                  title: 'Your name',
                  subtitle: s.signerName.isEmpty ? 'Written into a record when you sign a checkpoint from this phone' : s.signerName,
                  onTap: () => _editName(context, state),
                ),
              ]),
              const SectionLabel('Muted projects'),
              if (s.mutedProjects.isEmpty)
                group([
                  const _Row(
                    icon: Icons.notifications_off_outlined,
                    color: Ember.ash,
                    title: 'None muted',
                    subtitle: 'Long-press an event in History to mute its project.',
                  ),
                ])
              else
                group([
                  for (final p in s.mutedProjects)
                    _Row(
                      icon: Icons.notifications_off_outlined,
                      color: Ember.amber,
                      title: p,
                      trailing: EmberButton(
                        label: 'Unmute',
                        small: true,
                        style: EmberButtonStyle.ghost,
                        onPressed: () => state.unmuteProject(p),
                      ),
                    ),
                ]),
              if (Platform.isAndroid) ...[
                const SectionLabel('Reliability'),
                group([
                  _Row(
                    icon: _batteryExempt == true ? Icons.battery_full_rounded : Icons.battery_alert_rounded,
                    color: _batteryExempt == false ? Ember.danger : Ember.ok,
                    title: 'Battery optimization',
                    subtitle: _batteryExempt == null
                        ? 'Checking…'
                        : _batteryExempt!
                            ? 'Unrestricted — Mewo on Fire can stay connected'
                            : 'Optimized — Android may cut the connection. Tap to exempt.',
                    onTap: _batteryTap,
                  ),
                ]),
                const _Note(
                  'Some phones (Xiaomi, Samsung, Huawei, OnePlus, Oppo…) kill background apps '
                  'even with this setting. If notifications stop arriving, follow the steps for '
                  'your phone on dontkillmyapp.com (allow autostart, set battery to '
                  '"No restrictions", lock Mewo on Fire in recent apps).',
                ),
              ],
              if (Platform.isIOS) ...[
                const SectionLabel('Background'),
                group([
                  _Row(
                    icon: Icons.all_inclusive_rounded,
                    color: Ember.flame,
                    title: 'Stay connected in the background',
                    subtitle: 'iOS pauses the app shortly after you leave it and notifications stop '
                        'until you come back. On, it keeps running by playing silent audio, which '
                        'uses more battery.',
                    trailing: EmberSwitch(
                      value: s.keepAlive,
                      onChanged: (v) => state.updateSettings(s.copyWith(keepAlive: v)),
                    ),
                  ),
                ]),
                const _Note(
                  'Swiping Mewo on Fire away in the app switcher stops it either way. '
                  'Events you missed are listed in History when you open the app again.',
                ),
              ],
              const SectionLabel('Data'),
              group([
                _Row(
                  icon: Icons.cleaning_services_outlined,
                  color: Ember.ember,
                  title: 'Clear cached chats',
                  subtitle: 'Forgets the sessions and chats stored on this phone. '
                      'They are fetched again from your PCs.',
                  onTap: () => _clearChats(context, state),
                ),
              ]),
              const SectionLabel('About'),
              group([
                const _Row(
                  leading: MewoAvatar(size: 36),
                  title: 'Mewo on Fire',
                  subtitle: 'Claude Code in your pocket: see what it is doing, answer it, '
                      'and keep the conversation going from anywhere.',
                ),
                const _Row(
                  icon: Icons.lock_outline_rounded,
                  color: Ember.ok,
                  title: 'Private by design',
                  subtitle: 'The phone talks to your PCs over TLS with a pinned certificate — directly on '
                      'your network, or through a relay that only passes the encrypted connection along.',
                ),
              ]),
            ],
          ),
        );
      },
    );
  }
}

/// Rows in one glass card, separated by hairlines.
class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(indent: 66, endIndent: 0),
            children[i],
          ],
        ],
      ),
    );
  }
}

Future<void> _editName(BuildContext context, AppState state) async {
  final c = TextEditingController(text: state.settings.signerName);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Your name'),
      content: TextField(
        controller: c,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(hintText: 'As it goes into the records'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
      ],
    ),
  );
  if (name == null) return;
  await state.updateSettings(state.settings.copyWith(signerName: name.trim()));
}

class _Row extends StatelessWidget {
  const _Row({
    this.icon,
    this.color = Ember.text2,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData? icon;
  final Color color;
  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(16, 13, 14, 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          leading ?? IconTile(icon: icon!, color: color, size: 36, iconSize: 18),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: t.titleSmall),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(subtitle!, style: t.bodySmall?.copyWith(color: Ember.text2)),
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
          if (onTap != null) ...[
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right_rounded, size: 20, color: Ember.text3),
          ],
        ],
      ),
    );
    if (onTap == null) return row;
    return PressScale(scale: 0.985, onTap: onTap, child: row);
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 0),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Ember.text3)),
    );
  }
}
