import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import 'theme/ember.dart';
import 'theme/glass.dart';
import 'theme/motion.dart';

/// "New session" (v1.6): pick a PC and a project the daemon has seen, write
/// the first message, and Claude Desktop on that PC starts the session with
/// it. It shows up in the list a few seconds later like any other.
Future<void> showNewSessionSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => const _NewSessionSheet(),
  );
}

class _Project {
  const _Project({required this.pcId, required this.pcName, required this.cwd, required this.name});
  final String pcId;
  final String pcName;
  final String cwd;
  final String name;
}

class _NewSessionSheet extends StatefulWidget {
  const _NewSessionSheet();

  @override
  State<_NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends State<_NewSessionSheet> {
  final AppState _state = AppState.instance;
  final TextEditingController _text = TextEditingController();
  String _pcId = '';
  String _cwd = ''; // empty: the project Desktop has in front
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _pcId = _state.pcs.isEmpty ? '' : _state.pcs.first.id;
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// Projects the chosen PC has sessions in, newest first.
  List<_Project> get _projects {
    final out = <_Project>[];
    final seen = <String>{};
    for (final e in _state.sessions) {
      if (e.pcId != _pcId || e.session.cwd.isEmpty || !seen.add(e.session.cwd)) continue;
      out.add(_Project(
        pcId: e.pcId,
        pcName: e.pcName,
        cwd: e.session.cwd,
        name: e.session.project.isEmpty ? e.session.cwd.split('/').last : e.session.project,
      ));
      if (out.length >= 8) break;
    }
    return out;
  }

  Future<void> _start() async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    HapticFeedback.mediumImpact();
    setState(() {
      _busy = true;
      _error = '';
    });
    final error = await _state.newSession(_pcId, cwd: _cwd, prompt: _text.text);
    if (!mounted) return;
    if (error.isNotEmpty) {
      setState(() {
        _busy = false;
        _error = error;
      });
      return;
    }
    HapticFeedback.heavyImpact();
    final name = _state.pcNameFor(_pcId);
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Claude Desktop on $name is starting it. It shows up here in a moment.')),
    );
  }

  Widget _chip({required bool selected, required Color color, required Widget child, required VoidCallback onTap}) {
    return PressScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.base,
        curve: Motion.easeOut,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.14) : Ember.surface2.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? color.withValues(alpha: 0.7) : Ember.line),
        ),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final pcs = _state.pcs;
    final projects = _projects;
    final canStart = !_busy && _pcId.isNotEmpty && _text.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const IconTile(icon: Icons.add_rounded, color: Ember.amber, size: 36, iconSize: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('New session', style: t.titleMedium),
                        Text('Claude Desktop on the PC starts it with your first message.',
                            style: t.bodySmall?.copyWith(color: Ember.text2)),
                      ],
                    ),
                  ),
                ],
              ),
              if (pcs.length > 1) ...[
                const SizedBox(height: 18),
                Text('PC', style: t.labelSmall?.copyWith(color: Ember.text3, letterSpacing: 1.2)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final pc in pcs)
                      _chip(
                        selected: pc.id == _pcId,
                        color: Ember.ok,
                        onTap: () => setState(() {
                          _pcId = pc.id;
                          _cwd = '';
                        }),
                        child: Text(pc.name, style: t.labelLarge?.copyWith(fontSize: 13)),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 18),
              Text('PROJECT', style: t.labelSmall?.copyWith(color: Ember.text3, letterSpacing: 1.2)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _chip(
                    selected: _cwd.isEmpty,
                    color: Ember.amber,
                    onTap: () => setState(() => _cwd = ''),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.desktop_mac_rounded, size: 14, color: Ember.amber),
                        const SizedBox(width: 6),
                        Text("Desktop's current project", style: t.labelLarge?.copyWith(fontSize: 13)),
                      ],
                    ),
                  ),
                  for (final p in projects)
                    _chip(
                      selected: _cwd == p.cwd,
                      color: Ember.amber,
                      onTap: () => setState(() => _cwd = p.cwd),
                      child: Text(p.name, style: t.labelLarge?.copyWith(fontSize: 13)),
                    ),
                ],
              ),
              if (_cwd.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_cwd,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.labelSmall?.copyWith(color: Ember.text3, fontFamily: Ember.mono(context), fontWeight: FontWeight.w400, letterSpacing: 0)),
                ),
              const SizedBox(height: 18),
              Text('FIRST MESSAGE', style: t.labelSmall?.copyWith(color: Ember.text3, letterSpacing: 1.2)),
              const SizedBox(height: 8),
              TextField(
                controller: _text,
                autofocus: true,
                minLines: 3,
                maxLines: 8,
                enabled: !_busy,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(hintText: 'What should Claude do?'),
              ),
              if (_error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline_rounded, size: 16, color: Ember.danger),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_error, style: t.bodySmall?.copyWith(color: Ember.danger))),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
              EmberButton(
                label: 'Start session',
                icon: Icons.play_arrow_rounded,
                expand: true,
                shimmer: true,
                busy: _busy,
                onPressed: canStart ? _start : null,
              ),
              const SizedBox(height: 6),
              Text(
                'Needs Claude Desktop on the PC. If Desktop does not take the project you picked, it opens the session in the project it has in front.',
                style: t.labelSmall?.copyWith(color: Ember.text3, fontWeight: FontWeight.w400, letterSpacing: 0),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
