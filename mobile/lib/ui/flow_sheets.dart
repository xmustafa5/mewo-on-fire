import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
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
