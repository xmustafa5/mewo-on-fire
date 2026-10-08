import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
import 'theme/ember.dart';
import 'theme/glass.dart';
import 'theme/motion.dart';

/// Signs a gate of a feature (v1.7): the role, the name that goes into
/// the record, and the checklist lines the signer confirms. The PC writes
/// the record and commits it on the feature branch.
Future<void> showSignSheet(BuildContext context, {required String pcId, required TorchFeature feature, required TorchGate gate}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _SignSheet(pcId: pcId, feature: feature, gate: gate),
  );
}

class _SignSheet extends StatefulWidget {
  const _SignSheet({required this.pcId, required this.feature, required this.gate});

  final String pcId;
  final TorchFeature feature;
  final TorchGate gate;

  @override
  State<_SignSheet> createState() => _SignSheetState();
}

class _SignSheetState extends State<_SignSheet> {
  final AppState _state = AppState.instance;
  late final TextEditingController _name = TextEditingController(text: _state.settings.signerName);
  late String _role = widget.gate.openRoles.isNotEmpty ? widget.gate.openRoles.first : (widget.gate.roles.isNotEmpty ? widget.gate.roles.first : '');
  late final List<bool> _checks = [for (final i in widget.gate.items) i.checked];
  bool _busy = false;
  String _error = '';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _sign() async {
    if (_busy) return;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Your name goes into the record');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    HapticFeedback.mediumImpact();
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final note = await _state.sign(widget.pcId, widget.feature, widget.gate, _role, name, _checks);
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(note.isEmpty ? 'Signed and committed on ${widget.feature.branch}' : note)));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is StateError ? e.message : 'Could not sign';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final g = widget.gate;
    final roles = g.openRoles.isNotEmpty ? g.openRoles : g.roles;
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
                  const IconTile(icon: Icons.draw_rounded, color: Ember.amber, size: 36, iconSize: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(g.title, style: t.titleMedium),
                        Text(
                          '${g.checklist.isEmpty ? 'Policy review' : 'Checklist ${g.checklist}'} · ${widget.feature.app} / ${widget.feature.slug}',
                          style: t.bodySmall?.copyWith(color: Ember.text2),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (roles.length > 1) ...[
                const SizedBox(height: 18),
                Text('SIGN AS', style: t.labelSmall?.copyWith(color: Ember.text3, letterSpacing: 1.2)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final r in roles)
                      PressScale(
                        onTap: () => setState(() => _role = r),
                        child: AnimatedContainer(
                          duration: Motion.base,
                          curve: Motion.easeOut,
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                          decoration: BoxDecoration(
                            color: r == _role ? Ember.amber.withValues(alpha: 0.14) : Ember.surface2.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: r == _role ? Ember.amber.withValues(alpha: 0.7) : Ember.line),
                          ),
                          child: Text(r, style: t.labelLarge?.copyWith(fontSize: 13)),
                        ),
                      ),
                  ],
                ),
              ] else if (roles.length == 1) ...[
                const SizedBox(height: 14),
                Text('Signing as ${roles.first}', style: t.bodySmall?.copyWith(color: Ember.text2)),
              ],
              const SizedBox(height: 18),
              Text('YOUR NAME', style: t.labelSmall?.copyWith(color: Ember.text3, letterSpacing: 1.2)),
              const SizedBox(height: 8),
              TextField(
                controller: _name,
                enabled: !_busy,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(hintText: 'As it goes into the record'),
              ),
              if (g.items.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text('I CONFIRM', style: t.labelSmall?.copyWith(color: Ember.text3, letterSpacing: 1.2)),
                const SizedBox(height: 4),
                for (var i = 0; i < g.items.length; i++)
                  CheckboxListTile(
                    value: _checks[i],
                    onChanged: g.items[i].checked || _busy ? null : (v) => setState(() => _checks[i] = v ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    activeColor: Ember.amber,
                    title: Text(
                      g.items[i].text,
                      style: t.bodySmall?.copyWith(color: g.items[i].checked ? Ember.text3 : Ember.text, decoration: g.items[i].checked ? TextDecoration.lineThrough : null),
                    ),
                  ),
              ],
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
                label: _role.isEmpty ? 'Sign' : 'Sign as $_role',
                icon: Icons.draw_rounded,
                expand: true,
                shimmer: true,
                busy: _busy,
                onPressed: _busy ? null : _sign,
              ),
              const SizedBox(height: 6),
              Text(
                'Writes your name and today\'s date into ${g.file.split('/').last} and commits it when the workspace is on ${widget.feature.branch}.',
                style: t.labelSmall?.copyWith(color: Ember.text3, fontWeight: FontWeight.w400, letterSpacing: 0),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
