import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
import 'chat_screen.dart';
import 'theme/ember.dart';
import 'theme/glass.dart';
import 'theme/motion.dart';

/// The small forms of the flow (v1.8): an estimate, a UAT user, a new
/// feature, the roles.

Widget _header(BuildContext context, IconData icon, String title, String sub) {
  final t = Theme.of(context).textTheme;
  return Row(
    children: [
      IconTile(icon: icon, color: Ember.amber, size: 36, iconSize: 20),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: t.titleMedium),
            Text(sub, style: t.bodySmall?.copyWith(color: Ember.text2)),
          ],
        ),
      ),
    ],
  );
}

Widget _label(BuildContext context, String text) {
  final t = Theme.of(context).textTheme;
  return Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 8),
    child: Text(text, style: t.labelSmall?.copyWith(color: Ember.text3, letterSpacing: 1.2)),
  );
}

Widget _chips(BuildContext context, List<String> options, String value, void Function(String) onPick) {
  final t = Theme.of(context).textTheme;
  return Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final o in options)
        PressScale(
          onTap: () => onPick(o),
          child: AnimatedContainer(
            duration: Motion.base,
            curve: Motion.easeOut,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              color: o == value ? Ember.amber.withValues(alpha: 0.14) : Ember.surface2.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: o == value ? Ember.amber.withValues(alpha: 0.7) : Ember.line),
            ),
            child: Text(o, style: t.labelLarge?.copyWith(fontSize: 13)),
          ),
        ),
    ],
  );
}

Widget _errorLine(BuildContext context, String text) {
  if (text.isEmpty) return const SizedBox.shrink();
  final t = Theme.of(context).textTheme;
  return Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Row(
      children: [
        const Icon(Icons.error_outline_rounded, size: 16, color: Ember.danger),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: t.bodySmall?.copyWith(color: Ember.danger))),
      ],
    ),
  );
}

Widget _sheet(BuildContext context, Widget child) {
  return Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: child,
      ),
    ),
  );
}

// ---- estimate ----

Future<void> showEstimateSheet(BuildContext context, {required String pcId, required TorchFeature feature}) {
  return showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => _EstimateSheet(pcId: pcId, feature: feature));
}

class _EstimateSheet extends StatefulWidget {
  const _EstimateSheet({required this.pcId, required this.feature});
  final String pcId;
  final TorchFeature feature;
  @override
  State<_EstimateSheet> createState() => _EstimateSheetState();
}

class _EstimateSheetState extends State<_EstimateSheet> {
  static const roles = <String>['Design lead', 'FE lead', 'BE lead'];
  final AppState _state = AppState.instance;
  final TextEditingController _days = TextEditingController();
  final TextEditingController _assumptions = TextEditingController();
  late String _role = roles.first;
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    final mine = _state.featuresOf(widget.pcId)?.roles[widget.feature.workspace] ?? const <RoleEntry>[];
    final me = _state.settings.signerName;
    final held = mine.where((r) => r.name == me && roles.contains(r.role)).map((r) => r.role).toList();
    if (held.isNotEmpty) _role = held.first;
  }

  Future<void> _save() async {
    final days = double.tryParse(_days.text.trim());
    if (days == null || days < 0) {
      setState(() => _error = 'Person-days, please');
      return;
    }
    if (_state.settings.signerName.isEmpty) {
      setState(() => _error = 'Set your name under Settings first');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    final e = await _state.estimate(widget.pcId, widget.feature, _role, days, _assumptions.text.trim());
    if (!mounted) return;
    if (e.isNotEmpty) {
      setState(() {
        _busy = false;
        _error = e;
      });
      return;
    }
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return _sheet(
      context,
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, Icons.timelapse_rounded, 'Your estimate', 'Policy step 2 · ${widget.feature.app} / ${widget.feature.slug}'),
          _label(context, 'FOR'),
          _chips(context, roles, _role, (r) => setState(() => _role = r)),
          _label(context, 'PERSON-DAYS'),
          TextField(controller: _days, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(hintText: 'For example 8')),
          _label(context, 'ASSUMPTIONS'),
          TextField(controller: _assumptions, minLines: 2, maxLines: 5, decoration: const InputDecoration(hintText: 'What the estimate assumes, the riskiest items')),
          _errorLine(context, _error),
          const SizedBox(height: 16),
          EmberButton(label: 'Record my estimate', icon: Icons.check_rounded, expand: true, busy: _busy, onPressed: _busy ? null : _save),
        ],
      ),
    );
  }
}

// ---- UAT user ----

Future<void> showUatSheet(BuildContext context, {required String pcId, required TorchFeature feature}) {
  return showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => _UatSheet(pcId: pcId, feature: feature));
}

class _UatSheet extends StatefulWidget {
  const _UatSheet({required this.pcId, required this.feature});
  final String pcId;
  final TorchFeature feature;
  @override
  State<_UatSheet> createState() => _UatSheetState();
}

class _UatSheetState extends State<_UatSheet> {
  final AppState _state = AppState.instance;
  final TextEditingController _user = TextEditingController();
  final TextEditingController _role = TextEditingController();
  final TextEditingController _notes = TextEditingController();
  bool _unaided = true;
  bool _busy = false;
  String _error = '';
  String _result = '';

  Future<void> _save() async {
    if (_user.text.trim().isEmpty) {
      setState(() => _error = "The user's name, please");
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    final r = await _state.uatUser(widget.pcId, widget.feature, _user.text.trim(), _role.text.trim(), _unaided, _notes.text.trim());
    if (!mounted) return;
    if (r['ok'] != true) {
      setState(() {
        _busy = false;
        _error = '${r['error'] ?? 'Could not record it'}';
      });
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() {
      _busy = false;
      _result = '${r['unaided']} of ${r['total']} unaided, ${r['percent']}%${r['pass'] == true ? '. Passes the bar.' : '. Pass bar: 80% of 5 to 8 users.'}';
      _user.clear();
      _role.clear();
      _notes.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return _sheet(
      context,
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, Icons.groups_rounded, 'UAT user', 'Policy Checklist J · ${widget.feature.app} / ${widget.feature.slug}'),
          _label(context, 'USER'),
          TextField(controller: _user, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(hintText: 'Name')),
          _label(context, 'THEIR ROLE'),
          TextField(controller: _role, decoration: const InputDecoration(hintText: 'The job the feature supports')),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: Text('Completed the core flows unaided', style: t.bodyMedium)),
              EmberSwitch(value: _unaided, onChanged: (v) => setState(() => _unaided = v)),
            ],
          ),
          _label(context, 'NOTES'),
          TextField(controller: _notes, minLines: 1, maxLines: 4, decoration: const InputDecoration(hintText: 'Feedback')),
          _errorLine(context, _error),
          if (_result.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_result, style: t.bodySmall?.copyWith(color: Ember.ok)),
            ),
          const SizedBox(height: 16),
          EmberButton(label: 'Record', icon: Icons.check_rounded, expand: true, busy: _busy, onPressed: _busy ? null : _save),
        ],
      ),
    );
  }
}

// ---- new feature ----

Future<void> showNewFeatureSheet(BuildContext context) {
  return showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => const _NewFeatureSheet());
}

class _NewFeatureSheet extends StatefulWidget {
  const _NewFeatureSheet();
  @override
  State<_NewFeatureSheet> createState() => _NewFeatureSheetState();
}

class _NewFeatureSheetState extends State<_NewFeatureSheet> {
  final AppState _state = AppState.instance;
  final TextEditingController _slug = TextEditingController();
  String _pcId = '';
  String _workspace = '';
  String _app = '';
  bool _light = false;
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    for (final pc in _state.pcs) {
      final d = _state.featuresOf(pc.id);
      if (d != null && d.workspaces.isNotEmpty) {
        _pcId = pc.id;
        _workspace = d.workspaces.first;
        _app = (d.apps[_workspace] ?? const <String>[]).firstOrNull ?? '';
        break;
      }
    }
  }

  Future<void> _create() async {
    final slug = _slug.text.trim().toLowerCase();
    if (_pcId.isEmpty || _workspace.isEmpty) {
      setState(() => _error = 'No TORCH workspace known yet on a paired PC');
      return;
    }
    if (_app.isEmpty || slug.isEmpty) {
      setState(() => _error = 'An app and a slug, please');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    final r = await _state.newFeature(_pcId, _workspace, _app, slug, _light);
    if (!mounted) return;
    if (r['ok'] != true) {
      setState(() {
        _busy = false;
        _error = '${r['error'] ?? 'Could not create it'}';
      });
      return;
    }
    HapticFeedback.heavyImpact();
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${r['output'] ?? 'Created'}')));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final data = _pcId.isEmpty ? null : _state.featuresOf(_pcId);
    final workspaces = data?.workspaces ?? const <String>[];
    final apps = data?.apps[_workspace] ?? const <String>[];
    return _sheet(
      context,
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, Icons.add_rounded, 'New feature', 'The branch and the record files, as new-feature.sh makes them'),
          if (_state.pcs.length > 1) ...[
            _label(context, 'PC'),
            _chips(context, [for (final pc in _state.pcs) pc.name], _state.pcNameFor(_pcId), (name) {
              final pc = _state.pcs.firstWhere((p) => p.name == name);
              setState(() {
                _pcId = pc.id;
                _workspace = _state.featuresOf(pc.id)?.workspaces.firstOrNull ?? '';
                _app = (_state.featuresOf(pc.id)?.apps[_workspace] ?? const <String>[]).firstOrNull ?? '';
              });
            }),
          ],
          if (workspaces.length > 1) ...[
            _label(context, 'WORKSPACE'),
            _chips(context, [for (final w in workspaces) w.split('/').last], _workspace.split('/').last, (short) {
              setState(() {
                _workspace = workspaces.firstWhere((w) => w.split('/').last == short);
                _app = (data?.apps[_workspace] ?? const <String>[]).firstOrNull ?? '';
              });
            }),
          ],
          _label(context, 'APP'),
          if (apps.isEmpty) Text('No notebooks found in the workspace', style: t.bodySmall?.copyWith(color: Ember.text2)) else _chips(context, apps, _app, (a) => setState(() => _app = a)),
          _label(context, 'SLUG'),
          TextField(controller: _slug, autocorrect: false, decoration: const InputDecoration(hintText: 'bank-reconciliation')),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: Text('Light path (a fix: no PRD, no UAT)', style: t.bodyMedium)),
              EmberSwitch(value: _light, onChanged: (v) => setState(() => _light = v)),
            ],
          ),
          _errorLine(context, _error),
          const SizedBox(height: 16),
          EmberButton(label: 'Create', icon: Icons.add_rounded, expand: true, shimmer: true, busy: _busy, onPressed: _busy ? null : _create),
        ],
      ),
    );
  }
}

// ---- roles ----

Future<void> showRolesSheet(BuildContext context) {
  return showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => const _RolesSheet());
}

class _RolesSheet extends StatefulWidget {
  const _RolesSheet();
  @override
  State<_RolesSheet> createState() => _RolesSheetState();
}

class _RolesSheetState extends State<_RolesSheet> {
  final AppState _state = AppState.instance;
  String _busyRole = '';
  String _error = '';

  Future<void> _claim(String pcId, String workspace, String role) async {
    if (_state.settings.signerName.isEmpty) {
      setState(() => _error = 'Set your name under Settings first');
      return;
    }
    setState(() {
      _busyRole = role;
      _error = '';
    });
    final e = await _state.setRole(pcId, workspace, role, _state.settings.signerName);
    if (!mounted) return;
    setState(() {
      _busyRole = '';
      _error = e;
    });
    if (e.isEmpty) HapticFeedback.mediumImpact();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: _state,
      builder: (context, _) {
        final blocks = <Widget>[];
        for (final pc in _state.pcs) {
          final d = _state.featuresOf(pc.id);
          if (d == null) continue;
          for (final ws in d.workspaces) {
            final names = d.roleNames.isNotEmpty ? d.roleNames : const <String>['CEO', 'Product lead', 'Design lead', 'Tech lead', 'FE lead', 'BE lead'];
            final held = d.roles[ws] ?? const <RoleEntry>[];
            blocks.add(_label(context, '${ws.split('/').last.toUpperCase()} · ${pc.name.toUpperCase()}'));
            for (final role in names) {
              final r = held.where((x) => x.role.toLowerCase() == role.toLowerCase()).firstOrNull;
              final mine = r != null && r.name == _state.settings.signerName && _state.settings.signerName.isNotEmpty;
              blocks.add(GlassCard(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                radius: 14,
                borderColor: mine ? Ember.amber.withValues(alpha: 0.5) : null,
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(role, style: t.titleSmall?.copyWith(fontSize: 14)),
                          Text(r == null ? 'Nobody yet' : '${r.name}${r.phone.isNotEmpty ? ' · ${r.phone}' : ''}', style: t.labelSmall?.copyWith(color: mine ? Ember.amber : Ember.text3)),
                        ],
                      ),
                    ),
                    EmberButton(label: mine ? 'Yours' : 'I am', small: true, style: mine ? EmberButtonStyle.ghost : EmberButtonStyle.secondary, busy: _busyRole == role, onPressed: mine || _busyRole.isNotEmpty ? null : () => _claim(pc.id, ws, role)),
                  ],
                ),
              ));
            }
          }
        }
        return _sheet(
          context,
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(context, Icons.badge_rounded, 'Roles', "Who signs what. A signature request reaches the role's phone."),
              if (blocks.isEmpty) Padding(padding: const EdgeInsets.only(top: 16), child: Text('No TORCH workspace known yet.', style: t.bodySmall?.copyWith(color: Ember.text2))),
              ...blocks,
              _errorLine(context, _error),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

// ---- one plan session in full (v2.6) ----

Future<void> showSessionDetailSheet(BuildContext context, {required String pcId, required TorchFeature feature, required PlanSession session}) {
  return showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => _SessionDetailSheet(pcId: pcId, feature: feature, session: session));
}

class _SessionDetailSheet extends StatefulWidget {
  const _SessionDetailSheet({required this.pcId, required this.feature, required this.session});
  final String pcId;
  final TorchFeature feature;
  final PlanSession session;
  @override
  State<_SessionDetailSheet> createState() => _SessionDetailSheetState();
}

class _SessionDetailSheetState extends State<_SessionDetailSheet> {
  final AppState _state = AppState.instance;
  Map<String, dynamic>? _d;
  String _error = '';
  bool _busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final r = await _state.sessionDetail(widget.pcId, widget.feature, widget.session.n);
    if (!mounted) return;
    setState(() {
      if (r['ok'] == true) {
        _d = r;
        _error = '';
      } else {
        _error = '${r['error'] ?? 'Could not load it'}';
      }
    });
  }

  static String _dur(num? s) {
    final v = (s ?? 0).round();
    final h = v ~/ 3600, m = (v % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    if (m > 0) return '${m}m';
    return '${v}s';
  }

  static String _at(num? ms) {
    if (ms == null || ms == 0) return '—';
    final t = DateTime.fromMillisecondsSinceEpoch(ms.toInt());
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    final e = await _state.sessionStop(widget.pcId, widget.feature, widget.session.n);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = e;
    });
    _load();
  }

  Widget _row(BuildContext context, String k, String v) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 92, child: Text(k, style: t.labelSmall?.copyWith(color: Ember.text3, fontFamily: Ember.mono(context), fontSize: 10, letterSpacing: 1.2))),
          Expanded(child: Text(v, style: t.bodySmall?.copyWith(color: Ember.text))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s0 = widget.session;
    final d = _d;
    final s = d?['session'] is Map ? Map<String, dynamic>.from(d!['session'] as Map) : null;
    final tm = d?['timing'] is Map ? Map<String, dynamic>.from(d!['timing'] as Map) : const <String, dynamic>{};
    final run = d?['run'] is Map ? Map<String, dynamic>.from(d!['run'] as Map) : null;
    final rv = d?['review'] is Map ? Map<String, dynamic>.from(d!['review'] as Map) : null;
    final live = <Map<String, dynamic>>[if (d?['live'] is List) for (final l in d!['live'] as List) if (l is Map) Map<String, dynamic>.from(l)];
    final now = live.where((l) => l['state'] == 'working' || l['state'] == 'waiting').firstOrNull ?? live.lastOrNull;
    final eff = '${s?['effective'] ?? s0.effective}';
    final running = run != null && run['alive'] == true;
    final reviewing = rv != null && rv['alive'] == true;
    final what = eff == 'merged'
        ? 'Merged. Done.'
        : eff == 'review'
            ? (reviewing ? 'A reviewer session is on the pull request, ${_dur(rv!['elapsed_s'] as num?)} so far.' : 'Pull request open, waiting for its review.')
            : running
                ? 'Working headless on the PC.'
                : eff == 'progress'
                    ? (now != null && now['state'] == 'waiting' ? 'Waiting for your answer.' : 'Started; no live run at the moment.')
                    : eff == 'ready'
                        ? 'Ready: its dependencies are merged. The autopilot starts it next.'
                        : eff == 'blocked'
                            ? 'Blocked: a person decides.'
                            : 'Waiting for ${s0.dependsOn.map((x) => 'S$x').join(', ')}.';
    final steps = now != null && now['chat'] is List ? [for (final c in (now['chat'] as List).reversed.take(8)) if (c is Map) Map<String, dynamic>.from(c)] : const <Map<String, dynamic>>[];
    final color = _SessionTone.of(eff);
    return _sheet(
      context,
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, Icons.insights_rounded, 'S${s0.n} · ${s0.goal}', '${s0.repo.replaceFirst('code/', '')} · tier ${s0.tier}${s0.dependsOn.isNotEmpty ? ' · after ${s0.dependsOn.map((x) => 'S$x').join(', ')}' : ''}'),
          if (d == null && _error.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))),
          if (d != null) ...[
            GlassCard(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              radius: 14,
              borderColor: color.withValues(alpha: 0.5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(what, style: t.bodyMedium?.copyWith(color: Ember.text)),
                  const SizedBox(height: 8),
                  _row(context, 'ELAPSED', tm['started_at'] != null ? _dur(tm['elapsed_s'] as num?) : '—'),
                  _row(context, 'ESTIMATE', eff == 'progress' && tm['eta_s'] != null ? 'about ${_dur(tm['eta_s'] as num?)} left' : 'typically ${_dur(tm['typical_s'] as num?)} for tier ${s0.tier}${(tm['typical_from'] ?? 0) == 0 ? ' (a default)' : ''}'),
                  _row(context, 'WHOLE BUILD', '${tm['build_merged']}/${tm['build_total']} merged · roughly ${_dur(tm['build_remaining_s'] as num?)} left'),
                  _row(context, 'STARTED', _at(tm['started_at'] as num?)),
                  _row(context, 'IN REVIEW', _at(tm['in_review_at'] as num?)),
                  _row(context, 'MERGED', _at(tm['merged_at'] as num?)),
                  if (run != null) _row(context, 'RUN', run['headless'] == true ? 'headless · ${run['alive'] == true ? 'alive' : 'ended'}${run['exit'] != null ? ' · exit ${run['exit']}' : ''} · attempt ${run['attempt']}' : 'in Claude Desktop'),
                ],
              ),
            ),
            if (steps.isNotEmpty || (now?['last_text'] ?? '').toString().isNotEmpty) ...[
              _label(context, 'LAST STEPS${now != null ? ' · ${now['short']}' : ''}'),
              GlassCard(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                radius: 14,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final c in steps)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: RichText(
                          text: TextSpan(style: t.bodySmall?.copyWith(color: Ember.text), children: [
                            TextSpan(text: '${(c['tool'] ?? (c['role'] == 'assistant' ? 'CLAUDE' : c['role'] == 'user' ? 'PROMPT' : c['role'])).toString().toUpperCase()}  ', style: t.labelSmall?.copyWith(color: c['tool'] != null ? Ember.amber : Ember.mewoSoft, fontFamily: Ember.mono(context), fontSize: 9, letterSpacing: 1.2)),
                            TextSpan(text: '${c['text'] ?? ''}'),
                          ]),
                        ),
                      ),
                    if (steps.isEmpty) Text('${now?['last_text'] ?? ''}', style: t.bodySmall?.copyWith(color: Ember.text)),
                  ],
                ),
              ),
            ],
            if (s0.doneWhen.isNotEmpty) ...[
              _label(context, 'DONE WHEN'),
              for (final x in s0.doneWhen) Padding(padding: const EdgeInsets.fromLTRB(6, 2, 0, 2), child: Text('• $x', style: t.bodySmall?.copyWith(color: Ember.text2))),
            ],
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if ((s?['pr_url'] ?? '').toString().isNotEmpty) EmberButton(label: 'Open the pull request', icon: Icons.open_in_new_rounded, small: true, style: EmberButtonStyle.secondary, onPressed: () => launchUrl(Uri.parse('${s!['pr_url']}'), mode: LaunchMode.externalApplication)),
                  if (now != null) EmberButton(label: 'Open its chat', icon: Icons.chat_bubble_outline_rounded, small: true, style: EmberButtonStyle.secondary, onPressed: () => Navigator.of(context).push(ChatScreen.route(widget.pcId, '${now['id']}'))),
                  if (running || reviewing) EmberButton(label: 'Stop this run', icon: Icons.stop_circle_outlined, small: true, style: EmberButtonStyle.ghost, busy: _busy, onPressed: _busy ? null : _stop),
                ],
              ),
            ),
          ],
          _errorLine(context, _error),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _SessionTone {
  static Color of(String effective) {
    switch (effective) {
      case 'merged':
        return Ember.ok;
      case 'review':
        return Ember.mewoSoft;
      case 'progress':
        return Ember.ember;
      case 'blocked':
        return Ember.heat;
      case 'ready':
        return Ember.amber;
      default:
        return Ember.text3;
    }
  }
}

// ---- the design system a feature follows (v2.3) ----

Future<void> showDesignSheet(BuildContext context, {required String pcId, required TorchFeature feature}) {
  return showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => _DesignSheet(pcId: pcId, feature: feature));
}

class _DesignSheet extends StatefulWidget {
  const _DesignSheet({required this.pcId, required this.feature});
  final String pcId;
  final TorchFeature feature;
  @override
  State<_DesignSheet> createState() => _DesignSheetState();
}

class _DesignSheetState extends State<_DesignSheet> {
  final AppState _state = AppState.instance;
  late final TextEditingController _name;
  late final TextEditingController _repo;
  late final TextEditingController _dir;
  late final TextEditingController _ref;
  bool _busy = false;
  String _error = '';
  String _note = '';

  @override
  void initState() {
    super.initState();
    final d = widget.feature.design;
    _name = TextEditingController(text: d.glare ? '' : d.name);
    _repo = TextEditingController(text: d.glare ? '' : d.repo);
    _dir = TextEditingController(text: d.glare ? '' : d.dir);
    _ref = TextEditingController(text: d.glare ? '' : d.reference);
  }

  @override
  void dispose() {
    _name.dispose();
    _repo.dispose();
    _dir.dispose();
    _ref.dispose();
    super.dispose();
  }

  Future<void> _save({bool glare = false}) async {
    final name = glare ? '' : _name.text.trim();
    if (!glare && name.isEmpty) {
      setState(() => _error = 'Name the system');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
      _note = '';
    });
    final r = await _state.setDesign(widget.pcId, widget.feature, name: name, repo: glare ? '' : _repo.text.trim(), dir: glare ? '' : _dir.text.trim(), reference: glare ? '' : _ref.text.trim());
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = r.$1;
      _note = r.$2.join(' · ');
    });
    if (r.$1.isEmpty) {
      HapticFeedback.mediumImpact();
      if (_note.isEmpty) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final f = widget.feature;
    final d = f.design;
    return _sheet(
      context,
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, Icons.palette_rounded, 'Design system', 'What the designs and build sessions of ${f.app} / ${f.slug} follow. The policy\'s default is Glare.'),
          _label(context, d.glare ? 'NOW GLARE' : 'NOW ${d.name.toUpperCase()}${d.checkedOut ? '' : ' · CHECKOUT MISSING'}'),
          _label(context, 'SYSTEM'),
          TextField(controller: _name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(hintText: 'Tauri Template')),
          _label(context, 'REPOSITORY'),
          TextField(controller: _repo, keyboardType: TextInputType.url, autocorrect: false, decoration: const InputDecoration(hintText: 'https://github.com/TORCH-Corp/tauri-templete')),
          _label(context, 'CHECKOUT, IN THE WORKSPACE'),
          TextField(controller: _dir, autocorrect: false, decoration: const InputDecoration(hintText: 'code/tauri-templete (empty: code/ + the repository name)')),
          _label(context, 'READ FIRST'),
          TextField(controller: _ref, minLines: 1, maxLines: 3, autocorrect: false, decoration: const InputDecoration(hintText: 'src/app/modules/example, src/app/components/ui/components, src/styles/theme.css')),
          const SizedBox(height: 14),
          EmberButton(label: 'Save for this feature', icon: Icons.check_rounded, expand: true, busy: _busy, onPressed: _busy ? null : () => _save()),
          if (!d.glare)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: EmberButton(label: 'Back to Glare', small: true, style: EmberButtonStyle.ghost, onPressed: _busy ? null : () => _save(glare: true)),
            ),
          if (_note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_note, style: t.bodySmall?.copyWith(color: Ember.amber))),
          _errorLine(context, _error),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ---- which PRD a feature follows (v2.2) ----

Future<void> showPrdSheet(BuildContext context, {required String pcId, required TorchFeature feature}) {
  return showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => _PrdSheet(pcId: pcId, feature: feature));
}

class _PrdSheet extends StatefulWidget {
  const _PrdSheet({required this.pcId, required this.feature});
  final String pcId;
  final TorchFeature feature;
  @override
  State<_PrdSheet> createState() => _PrdSheetState();
}

class _PrdSheetState extends State<_PrdSheet> {
  final AppState _state = AppState.instance;
  List<PrdChoice>? _list;
  String _inUse = '';
  String _busy = '';
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _state.prds(widget.pcId, widget.feature);
    if (!mounted) return;
    setState(() {
      _list = r.$1;
      _inUse = r.$2;
      _error = r.$3;
    });
  }

  Future<void> _use(String stem) async {
    setState(() {
      _busy = stem.isEmpty ? '-' : stem;
      _error = '';
    });
    final e = await _state.setPrd(widget.pcId, widget.feature, stem);
    if (!mounted) return;
    setState(() {
      _busy = '';
      _error = e;
    });
    if (e.isEmpty) {
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final f = widget.feature;
    final list = _list;
    final rows = <Widget>[];
    if (list == null) {
      rows.add(const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))));
    } else if (list.isEmpty) {
      rows.add(Padding(padding: const EdgeInsets.only(top: 12), child: Text('No …_PRD_V….md file under torch-product.', style: t.bodySmall?.copyWith(color: Ember.text2))));
    } else {
      for (final p in list) {
        final inUse = p.file == _inUse;
        rows.add(GlassCard(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          radius: 14,
          borderColor: inUse ? Ember.amber.withValues(alpha: 0.5) : null,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.display, style: t.titleSmall?.copyWith(fontSize: 14)),
                    Text('${p.version} · ${p.signed ? 'signed' : 'draft'}${inUse ? ' · in use' : ''}${p.current ? ' · picked' : ''}', style: t.labelSmall?.copyWith(color: p.signed ? Ember.ok : Ember.text3)),
                    Text(p.folder, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.labelSmall?.copyWith(color: Ember.text3, fontSize: 10)),
                  ],
                ),
              ),
              EmberButton(label: inUse ? 'In use' : 'Use', small: true, style: inUse ? EmberButtonStyle.ghost : EmberButtonStyle.secondary, busy: _busy == p.stem, onPressed: inUse || _busy.isNotEmpty ? null : () => _use(p.stem)),
            ],
          ),
        ));
      }
    }
    final picked = f.prdSource == 'picked';
    return _sheet(
      context,
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, Icons.description_rounded, 'PRD', 'The PRD ${f.app} / ${f.slug} follows. Its newest version counts, and V1.0 means signed.'),
          _label(context, picked ? 'PICKED BY HAND' : 'MATCHED BY NAME'),
          ...rows,
          if (picked)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: EmberButton(label: 'Back to the automatic match', small: true, style: EmberButtonStyle.ghost, busy: _busy == '-', onPressed: _busy.isNotEmpty ? null : () => _use('')),
            ),
          _errorLine(context, _error),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ---- tasks under a session, in Plane (v2.1) ----

Future<void> showTasksSheet(BuildContext context, {required String pcId, required TorchFeature feature, required PlanSession session}) {
  return showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => _TasksSheet(pcId: pcId, feature: feature, session: session));
}

class _TasksSheet extends StatefulWidget {
  const _TasksSheet({required this.pcId, required this.feature, required this.session});
  final String pcId;
  final TorchFeature feature;
  final PlanSession session;
  @override
  State<_TasksSheet> createState() => _TasksSheetState();
}

class _TasksSheetState extends State<_TasksSheet> {
  final AppState _state = AppState.instance;
  final TextEditingController _name = TextEditingController();
  List<PlaneTask> _tasks = const <PlaneTask>[];
  bool _loading = true;
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await _state.planeTasks(widget.pcId, widget.feature, widget.session.n);
      if (!mounted) return;
      setState(() {
        _tasks = t;
        _loading = false;
        _error = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is StateError ? e.message : 'Could not read the tasks';
      });
    }
  }

  Future<void> _add() async {
    final name = _name.text.trim();
    if (name.isEmpty || _busy) return;
    setState(() => _busy = true);
    final e = await _state.planeTaskAdd(widget.pcId, widget.feature, widget.session.n, name);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = e;
    });
    if (e.isEmpty) {
      _name.clear();
      HapticFeedback.selectionClick();
      await _load();
    }
  }

  Future<void> _toggle(PlaneTask t) async {
    HapticFeedback.selectionClick();
    setState(() => _tasks = [for (final x in _tasks) x.id == t.id ? PlaneTask(id: x.id, name: x.name, done: !x.done, url: x.url, sequenceId: x.sequenceId) : x]);
    final e = await _state.planeTaskDone(widget.pcId, t.id, !t.done);
    if (!mounted) return;
    if (e.isNotEmpty) {
      setState(() => _error = e);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final done = _tasks.where((x) => x.done).length;
    return _sheet(
      context,
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, Icons.checklist_rounded, 'Tasks · S${widget.session.n}', _tasks.isEmpty ? widget.session.goal : '$done of ${_tasks.length} done · ${widget.session.goal}'),
          const SizedBox(height: 14),
          if (_loading)
            const Center(child: Padding(padding: EdgeInsets.all(20), child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Ember.amber))))
          else if (_tasks.isEmpty)
            Text('No tasks yet. Break the session down below; each one is a work item under S${widget.session.n} in Plane, assigned to you.', style: t.bodySmall?.copyWith(color: Ember.text2))
          else
            for (final task in _tasks)
              CheckboxListTile(
                value: task.done,
                onChanged: (_) => _toggle(task),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
                activeColor: Ember.ok,
                title: Text(task.name, style: t.bodyMedium?.copyWith(color: task.done ? Ember.text3 : Ember.text, decoration: task.done ? TextDecoration.lineThrough : null)),
                secondary: task.sequenceId > 0 ? Text('#${task.sequenceId}', style: t.labelSmall?.copyWith(color: Ember.text3)) : null,
              ),
          _label(context, 'ADD A TASK'),
          Row(
            children: [
              Expanded(child: TextField(controller: _name, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(hintText: 'What you will do next'), onSubmitted: (_) => _add())),
              const SizedBox(width: 10),
              EmberButton(label: 'Add', icon: Icons.add_rounded, small: true, busy: _busy, onPressed: _busy ? null : _add),
            ],
          ),
          _errorLine(context, _error),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
