import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../models.dart';
import 'artifact_screen.dart';
import 'chat_screen.dart';
import 'flow_sheets.dart';
import 'sign_sheet.dart';
import 'theme/ember.dart';
import 'theme/flame.dart';
import 'theme/glass.dart';
import 'theme/motion.dart';

/// One feature of a TORCH workspace (v1.7): where it stands in the twelve
/// steps, its planned sessions (start them from here), its sign-offs
/// (sign them from here) and its handoff files.
class FeatureScreen extends StatefulWidget {
  const FeatureScreen({super.key, required this.pcId, required this.featureKey});

  final String pcId;
  final String featureKey;

  @override
  State<FeatureScreen> createState() => _FeatureScreenState();
}

class _FeatureScreenState extends State<FeatureScreen> {
  final AppState _state = AppState.instance;
  final Set<int> _starting = <int>{};
  bool _flowBusy = false;

  Future<void> _doNext(TorchFeature f) async {
    if (_flowBusy) return;
    final a = f.flow.action;
    if (a.kind == 'close') {
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Merge and close the branches?'),
          content: Text('Merges ${f.branch} into main in torch-main and every code repository on it, pushes, and deletes the branch.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Merge and close')),
          ],
        ),
      );
      if (yes != true || !mounted) return;
    }
    if (a.kind == 'estimates') {
      await showEstimateSheet(context, pcId: widget.pcId, feature: f);
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() => _flowBusy = true);
    final error = await _state.flowNext(widget.pcId, f);
    if (!mounted) return;
    setState(() => _flowBusy = false);
    _toast(error.isEmpty ? 'Done: ${a.title}' : error);
  }

  /// Which wave each session is in: 1 for no dependency, else one past its
  /// deepest dependency. Sessions of one wave can run together.
  Map<int, int> _waves(List<PlanSession> ss) {
    final by = {for (final s in ss) s.n: s};
    final w = <int, int>{};
    int depth(int n, Set<int> seen) {
      final cached = w[n];
      if (cached != null) return cached;
      if (!seen.add(n)) return 1;
      final deps = (by[n]?.dependsOn ?? const <int>[]).where((d) => d != n && by.containsKey(d)).toList();
      final v = deps.isEmpty ? 1 : 1 + deps.map((d) => depth(d, seen)).reduce((a, b) => a > b ? a : b);
      w[n] = v;
      return v;
    }
    for (final s in ss) {
      depth(s.n, <int>{});
    }
    return w;
  }

  /// The sign sheet of the gate the flow asks for, when you are the one to sign it.
  VoidCallback? _signFromFlow(TorchFeature f) {
    final a = f.flow.action;
    if (a.kind != 'ask' || a.gate.isEmpty) return null;
    final g = f.gates.where((x) => x.id == a.gate).firstOrNull;
    if (g == null || g.signed || !g.present) return null;
    return () => showSignSheet(context, pcId: widget.pcId, feature: f, gate: g);
  }

  /// v2.4: the step's session again; for the design the earlier boards stop counting.
  Future<void> _doRedo(TorchFeature f) async {
    if (_flowBusy) return;
    final a = f.flow.action;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_FlowCard.redoLabels[a.step] ?? 'Run the step again?'),
        content: Text(a.step == 4 ? 'A new design session starts on the PC. The boards made so far stop counting; the export takes the new ones.' : 'A new session starts on the PC with the step\'s prompt as it stands now.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Start')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    HapticFeedback.mediumImpact();
    setState(() => _flowBusy = true);
    final error = await _state.flowRedo(widget.pcId, f, a.step);
    if (!mounted) return;
    setState(() => _flowBusy = false);
    _toast(error.isEmpty ? 'Started: ${_FlowCard.redoLabels[a.step] ?? 'the step'}' : error);
  }

  TorchFeature? get _feature => _state.featuresOf(widget.pcId)?.features.where((f) => f.key == widget.featureKey).firstOrNull;

  void _toast(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _start(TorchFeature f, PlanSession s) async {
    if (_starting.contains(s.n)) return;
    HapticFeedback.mediumImpact();
    setState(() => _starting.add(s.n));
    final error = await _state.startPlanSession(widget.pcId, f, s.n);
    if (!mounted) return;
    setState(() => _starting.remove(s.n));
    _toast(error.isEmpty ? 'Claude Desktop on ${_state.pcNameFor(widget.pcId)} starts session ${s.n}. It appears under Sessions in a moment.' : error);
  }

  Future<void> _rollback(TorchFeature f, FlowJournal j) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Roll back?'),
        content: Text('${j.title}\n\n${j.commit.isNotEmpty ? 'Its commit is reverted on ${f.branch}.' : j.files.isNotEmpty ? 'The file goes back to its last commit.' : 'The flow forgets it and offers the step again.'}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Roll back')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    HapticFeedback.mediumImpact();
    final r = await _state.rollback(widget.pcId, f, j.id);
    if (!mounted) return;
    if (r['ok'] == true) {
      final notes = r['notes'] is List ? (r['notes'] as List).map((e) => '$e').join('. ') : '';
      _toast(notes.isEmpty ? 'Rolled back' : notes);
    } else {
      _toast('${r['error'] ?? 'Could not roll it back'}');
    }
  }

  Future<void> _unsign(TorchFeature f, TorchGate g, String role) async {
    final all = role.isEmpty && g.signatures.isNotEmpty;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(g.id == 'prd' ? 'Withdraw the PRD V1.0?' : all ? 'Remove every signature?' : role.isEmpty ? 'Untick the items?' : 'Remove the signature?'),
        content: Text(g.id == 'prd'
            ? 'The V1.0 file and its Register row are removed in one commit, so the feature goes back to the latest draft. History can revert it.'
            : all
                ? 'The signatures of ${g.signatures.keys.join(', ')} come out of ${g.title}; the items they ticked go back to open.'
                : role.isEmpty
                    ? 'Every item of ${g.title} goes back to open.'
                    : 'The signature of $role comes out of ${g.title}; the items it ticked go back to open.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(role.isEmpty ? 'Untick' : 'Remove')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    HapticFeedback.mediumImpact();
    final roles = all ? g.signatures.keys.toList() : <String>[role];
    var error = '';
    for (final r in roles) {
      error = await _state.unsign(widget.pcId, f, g, g.id == 'prd' ? '' : r);
      if (error.isNotEmpty) break;
    }
    if (!mounted) return;
    _toast(error.isEmpty ? (g.id == 'prd' ? 'PRD V1.0 withdrawn' : role.isEmpty && !all ? 'Items unticked' : 'Signature${roles.length > 1 ? 's' : ''} removed') : error);
  }

  Future<void> _ask(TorchFeature f, TorchGate g) async {
    final role = g.openRoles.isNotEmpty ? g.openRoles.first : '';
    final error = await _state.requestSign(widget.pcId, f, g, role);
    if (!mounted) return;
    _toast(error.isEmpty ? 'Asked. Every paired phone gets a notification.' : error);
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _openPlane(String url) async {
    final u = Uri.tryParse(url);
    if (u == null) return;
    try {
      await launchUrl(u, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  void _handoff(TorchFeature f, String file) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ArtifactScreen(
        pcId: widget.pcId,
        sessionId: '',
        artifact: SessionArtifact(url: '', title: file, kind: file.endsWith('.md') ? 'document' : 'page', id: f.handoffId, local: true, entry: file),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _state,
      builder: (context, _) {
        final f = _feature;
        final t = Theme.of(context).textTheme;
        final title = f == null ? widget.featureKey : '${f.app} / ${f.slug}';
        final sub = f == null
            ? _state.pcNameFor(widget.pcId)
            : f.light
                ? 'Light path · ${f.released ? 'released' : f.stepLabel}'
                : f.released
                    ? 'Released'
                    : 'Step ${f.step} of 12 · ${f.stepLabel}';
        return Scaffold(
          backgroundColor: Colors.transparent,
          extendBodyBehindAppBar: true,
          appBar: GlassTopBar(
            title: Text(title),
            subtitle: Text(sub),
            actions: [
              GhostIconButton(icon: Icons.refresh_rounded, tooltip: 'Refresh', onPressed: _state.refreshFeatures),
            ],
          ),
          body: EmberBackground(
            animate: false,
            child: f == null
                ? Center(child: Text('This feature is gone from the PC', style: t.bodyMedium?.copyWith(color: Ember.text2)))
                : Builder(
                    builder: (context) => ListView(
                      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
                      children: _body(context, f),
                    ),
                  ),
          ),
        );
      },
    );
  }

  List<Widget> _body(BuildContext context, TorchFeature f) {
    final t = Theme.of(context).textTheme;
    final mono = Ember.mono(context);
    final out = <Widget>[];
    var n = 0;
    Widget enter(Widget child) => FadeSlideIn(delay: Motion.stagger(n++, step: 40), offset: const Offset(0, 10), child: child);

    out.add(enter(Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(f.branch, style: t.labelSmall?.copyWith(fontFamily: mono, color: Ember.text2, fontWeight: FontWeight.w400, letterSpacing: 0)),
          PressScale(
            onTap: () => showPrdSheet(context, pcId: widget.pcId, feature: f),
            child: _tag(
              context,
              f.prd.isEmpty ? 'No PRD found · pick one' : '${f.prdSigned ? 'PRD signed' : 'PRD draft'}${f.prdSource == 'picked' ? ' · picked' : ''} ▾',
              f.prd.isEmpty ? Ember.text3 : f.prdSigned ? Ember.ok : Ember.amber,
            ),
          ),
          PressScale(
            onTap: () => showDesignSheet(context, pcId: widget.pcId, feature: f),
            child: _tag(context, 'Design · ${f.design.name}${f.design.checkedOut ? '' : ' · checkout missing'} ▾', f.design.checkedOut ? (f.design.glare ? Ember.text3 : Ember.mewoSoft) : Ember.amber),
          ),
          if (f.planeParentUrl.isNotEmpty)
            PressScale(onTap: () => _openPlane(f.planeParentUrl), child: _tag(context, 'On Plane ↗', Ember.mewoSoft)),
          if (f.openQuestions > 0) _tag(context, '${f.openQuestions} open question${f.openQuestions == 1 ? '' : 's'}', Ember.amber),
          if (f.running) _tag(context, 'Running now', Ember.ember),
        ],
      ),
    )));

    for (final w in f.warnings) {
      out.add(enter(_warning(context, w)));
    }

    out.add(enter(_FlowCard(
      feature: f,
      busy: _flowBusy,
      onNext: () => _doNext(f),
      onRedo: () => _doRedo(f),
      onSign: _signFromFlow(f),
      onAutopilot: (v) async {
        final e = await _state.flowSet(widget.pcId, f, v);
        if (e.isNotEmpty && mounted) _toast(e);
      },
      onEstimate: () => showEstimateSheet(context, pcId: widget.pcId, feature: f),
      onEstimatesDone: () => _state.estimatesDone(widget.pcId, f),
      onUat: () => showUatSheet(context, pcId: widget.pcId, feature: f),
    )));

    if (!f.light) {
      out.add(enter(_StepStrip(feature: f)));
    }

    // Sessions.
    final plan = f.plan;
    out.add(enter(SectionLabel(
      plan == null ? 'Session plan' : 'Sessions · ${f.sessionsMerged}/${f.sessionsTotal} merged',
      trailing: plan != null && plan.reviewedBy.isNotEmpty ? Text('Reviewed by ${plan.reviewedBy.split(',').first}', style: t.labelSmall?.copyWith(color: Ember.text3)) : null,
    )));
    if (plan == null) {
      out.add(enter(GlassCard(
        padding: const EdgeInsets.all(14),
        child: Text(
          f.light ? 'A light-path fix needs no plan unless it takes more than one session.' : 'No SESSION_PLAN.md yet. Write it in Claude Cowork with the session-plan skill, once the handoff is signed.',
          style: t.bodySmall?.copyWith(color: Ember.text2),
        ),
      )));
    } else {
      for (final r in plan.revised) {
        out.add(enter(_warning(context, 'Revised $r', color: Ember.amber)));
      }
      final waveOf = _waves(plan.sessions);
      final ordered = [...plan.sessions]..sort((a, b) => (waveOf[a.n] ?? 1) != (waveOf[b.n] ?? 1) ? (waveOf[a.n] ?? 1) - (waveOf[b.n] ?? 1) : a.n - b.n);
      var shownWave = 0;
      for (final s in ordered) {
        final wave = waveOf[s.n] ?? 1;
        if (wave != shownWave) {
          shownWave = wave;
          final together = ordered.where((x) => (waveOf[x.n] ?? 1) == wave).toList();
          final ready = together.where((x) => x.effective == 'ready').length;
          out.add(enter(Padding(
            padding: const EdgeInsets.fromLTRB(6, 10, 6, 6),
            child: Text(
              'WAVE $wave · ${together.length == 1 ? 'ONE SESSION' : '${together.length} CAN RUN TOGETHER'}${ready > 0 ? ' · $ready READY NOW' : ''}',
              style: t.labelSmall?.copyWith(fontFamily: mono, color: ready > 0 ? Ember.amber : Ember.text3, letterSpacing: 1.4, fontSize: 10),
            ),
          )));
        }
        final pi = f.planeItems['session:${s.n}'];
        out.add(enter(_SessionRow(
          session: s,
          feature: f,
          pcId: widget.pcId,
          starting: _starting.contains(s.n),
          onStart: () => _start(f, s),
          onOpenPr: s.prUrl.isNotEmpty || s.pr.isNotEmpty ? () => _open(s.prUrl.isNotEmpty ? s.prUrl : s.pr) : null,
          onOpenLive: (id) => Navigator.of(context).push(ChatScreen.route(widget.pcId, id)),
          planeUrl: pi?.url ?? '',
          planeSeq: pi?.sequenceId ?? 0,
          onTasks: pi == null ? null : () => showTasksSheet(context, pcId: widget.pcId, feature: f, session: s),
          onOpenPlane: pi == null ? null : () => _openPlane(pi.url),
        )));
      }
    }

    // Sign-offs.
    out.add(enter(const SectionLabel('Sign-offs')));
    for (final g in f.gates) {
      final gi = f.planeItems[g.id == 'prd' ? 'prd' : 'gate:${g.id}'];
      out.add(enter(_GateCard(
        gate: g,
        onSign: g.signed || !g.present ? null : () => showSignSheet(context, pcId: widget.pcId, feature: f, gate: g),
        onAsk: g.signed || !g.present ? null : () => _ask(f, g),
        onUnsign: (role) => _unsign(f, g, role),
        planeSeq: gi?.sequenceId ?? 0,
        onOpenPlane: gi == null ? null : () => _openPlane(gi.url),
      )));
    }

    // History: what Mewo wrote, with roll back.
    if (f.flow.history.isNotEmpty) {
      out.add(enter(const SectionLabel('History')));
      for (final j in f.flow.history.take(12)) {
        out.add(enter(_JournalRow(entry: j, onRollback: j.undoable && !j.undone ? () => _rollback(f, j) : null)));
      }
    }

    // Handoff.
    if (f.handoffFiles.isNotEmpty) {
      out.add(enter(SectionLabel('Handoff · ${f.handoffFiles.length} file${f.handoffFiles.length == 1 ? '' : 's'}')));
      out.add(enter(Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final file in f.handoffFiles)
            PressScale(
              onTap: () => _handoff(f, file),
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                decoration: BoxDecoration(
                  color: Ember.surface2.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Ember.line),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(file.endsWith('.html') ? Icons.web_rounded : Icons.article_outlined, size: 15, color: Ember.ok),
                    const SizedBox(width: 6),
                    Text(file, style: t.labelLarge?.copyWith(fontSize: 12.5)),
                  ],
                ),
              ),
            ),
        ],
      )));
    }
    return out;
  }

  Widget _tag(BuildContext context, String text, Color color) {
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 3, 8, 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(text, style: t.labelSmall?.copyWith(color: color, fontSize: 11)),
    );
  }

  Widget _warning(BuildContext context, String text, {Color color = Ember.danger}) {
    final t = Theme.of(context).textTheme;
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      radius: 14,
      borderColor: color.withValues(alpha: 0.5),
      fill: color.withValues(alpha: 0.08),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: t.bodySmall?.copyWith(color: Ember.text))),
        ],
      ),
    );
  }
}

/// The twelve steps as a strip: done, current, to come.
class _StepStrip extends StatelessWidget {
  const _StepStrip({required this.feature});

  final TorchFeature feature;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final f = feature;
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      radius: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (var i = 1; i <= 12; i++) ...[
                Expanded(
                  child: AnimatedContainer(
                    duration: Motion.base,
                    height: 6,
                    decoration: BoxDecoration(
                      color: f.released || i < f.step
                          ? Ember.ok
                          : i == f.step
                              ? Ember.amber
                              : Ember.line,
                      borderRadius: BorderRadius.circular(3),
                      boxShadow: i == f.step && !f.released ? [BoxShadow(color: Ember.amber.withValues(alpha: 0.6), blurRadius: 8)] : null,
                    ),
                  ),
                ),
                if (i < 12) const SizedBox(width: 3),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  f.released ? 'Released. Every gate is signed.' : 'Step ${f.step}: ${f.stepLabel}',
                  style: t.bodySmall?.copyWith(color: Ember.text),
                ),
              ),
              if (!f.released && f.step < 12)
                Text('Next: ${TorchFeature.steps[f.step]}', style: t.labelSmall?.copyWith(color: Ember.text3)),
            ],
          ),
        ],
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.feature,
    required this.pcId,
    required this.starting,
    required this.onStart,
    required this.onOpenPr,
    required this.onOpenLive,
    this.planeUrl = '',
    this.planeSeq = 0,
    this.onTasks,
    this.onOpenPlane,
  });

  final String planeUrl;
  final int planeSeq;
  final VoidCallback? onTasks;
  final VoidCallback? onOpenPlane;

  final PlanSession session;
  final TorchFeature feature;
  final String pcId;
  final bool starting;
  final VoidCallback onStart;
  final VoidCallback? onOpenPr;
  final void Function(String sessionId) onOpenLive;

  static Color colorOf(String effective) {
    switch (effective) {
      case 'merged':
        return Ember.ok;
      case 'review':
        return Ember.mewoSoft;
      case 'progress':
        return Ember.ember;
      case 'ready':
        return Ember.amber;
      default:
        return Ember.text3;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = session;
    final color = colorOf(s.effective);
    final canStart = (s.effective == 'ready' || s.effective == 'progress') && s.prompt.isNotEmpty;
    final meta = <String>[
      if (s.level.isNotEmpty) s.level,
      if (s.tier > 0) 'Tier ${s.tier}',
      if (s.repo.isNotEmpty) s.repo.replaceFirst('code/', ''),
      if (s.owner.isNotEmpty) s.owner,
      if (s.dependsOn.isNotEmpty) 'after ${s.dependsOn.join(', ')}',
      if (s.attempts > 0) '${s.attempts} attempt${s.attempts == 1 ? '' : 's'}',
    ];
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      radius: 16,
      borderColor: s.running ? Ember.ember.withValues(alpha: 0.5) : null,
      glow: s.running ? Ember.ember : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: color.withValues(alpha: 0.4)),
                ),
                child: Text('${s.n}', style: t.labelLarge?.copyWith(color: color, fontFamily: Ember.mono(context))),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.goal.isEmpty ? 'Session ${s.n}' : s.goal, style: t.titleSmall?.copyWith(fontSize: 14)),
                    const SizedBox(height: 3),
                    Text(meta.join(' · '), style: t.labelSmall?.copyWith(color: Ember.text3)),
                    if (s.note.isNotEmpty) Text(s.note, style: t.labelSmall?.copyWith(color: Ember.text3)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: color.withValues(alpha: 0.4)),
                ),
                child: Text(s.statusLabel, style: t.labelSmall?.copyWith(color: color, fontSize: 11)),
              ),
            ],
          ),
          for (final w in s.warnings)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded, size: 15, color: Ember.danger),
                  const SizedBox(width: 6),
                  Expanded(child: Text(w, style: t.bodySmall?.copyWith(color: Ember.danger, fontSize: 12))),
                ],
              ),
            ),
          if (s.live.isNotEmpty || canStart || onOpenPr != null || onTasks != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final l in s.live)
                    _MiniButton(
                      icon: Icons.chat_bubble_outline_rounded,
                      label: '${l.short}${l.tier > 0 ? ' · T${l.tier}' : ''} · ${l.state}',
                      color: l.state == 'working' ? Ember.ember : Ember.text2,
                      onTap: () => onOpenLive(l.id),
                    ),
                  if (onOpenPr != null)
                    _MiniButton(icon: Icons.call_merge_rounded, label: s.prNumber > 0 ? 'PR #${s.prNumber}' : 'Pull request', color: Ember.mewoSoft, onTap: onOpenPr!),
                  if (onTasks != null) _MiniButton(icon: Icons.checklist_rounded, label: 'Tasks', color: Ember.text2, onTap: onTasks!),
                  if (onOpenPlane != null) _MiniButton(icon: Icons.open_in_new_rounded, label: planeSeq > 0 ? 'Plane #$planeSeq' : 'Plane', color: Ember.text3, onTap: onOpenPlane!),
                  if (canStart)
                    EmberButton(label: starting ? 'Starting…' : 'Start', icon: Icons.play_arrow_rounded, small: true, busy: starting, onPressed: starting ? null : onStart),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _GateCard extends StatelessWidget {
  const _GateCard({required this.gate, required this.onSign, required this.onAsk, required this.onUnsign, this.planeSeq = 0, this.onOpenPlane});

  final int planeSeq;
  final VoidCallback? onOpenPlane;
  final TorchGate gate;
  final VoidCallback? onSign;
  final VoidCallback? onAsk;
  final void Function(String role) onUnsign;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final g = gate;
    final color = g.signed ? Ember.ok : g.present ? Ember.amber : Ember.text3;
    final ticked = g.items.where((i) => i.checked).length;
    final signed = [for (final e in g.signatures.entries) '${e.value} (${e.key})'];
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      radius: 16,
      borderColor: g.signed ? Ember.ok.withValues(alpha: 0.35) : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconTile(icon: g.signed ? Icons.verified_rounded : Icons.draw_rounded, color: color, size: 34, iconSize: 17),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(g.title, style: t.titleSmall?.copyWith(fontSize: 14)),
                const SizedBox(height: 3),
                Text(
                  [
                    if (g.checklist.isNotEmpty) 'Checklist ${g.checklist}',
                    if (g.items.isNotEmpty) '$ticked/${g.items.length} items',
                    if (g.roles.isNotEmpty) g.roles.join(' · '),
                    if (!g.present) 'no record file yet',
                  ].join(' · '),
                  style: t.labelSmall?.copyWith(color: Ember.text3),
                ),
                if (onOpenPlane != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: _MiniButton(icon: Icons.open_in_new_rounded, label: planeSeq > 0 ? 'Plane #$planeSeq' : 'Plane', color: Ember.text3, onTap: onOpenPlane!),
                  ),
                if (signed.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final e in g.signatures.entries)
                          PressScale(
                            onTap: () => onUnsign(e.key),
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(9, 4, 6, 4),
                              decoration: BoxDecoration(
                                color: Ember.ok.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: Ember.ok.withValues(alpha: 0.4)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text('${e.value} · ${e.key}', style: t.labelSmall?.copyWith(color: Ember.ok, fontSize: 11)),
                                  const SizedBox(width: 4),
                                  const Icon(Icons.close_rounded, size: 13, color: Ember.ok),
                                ],
                              ),
                            ),
                          ),
                        if (g.date.isNotEmpty) Text(g.date, style: t.labelSmall?.copyWith(color: Ember.text3)),
                      ],
                    ),
                  )
                else if (g.signed && g.items.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: _MiniButton(icon: Icons.undo_rounded, label: 'Untick all', color: Ember.text2, onTap: () => onUnsign('')),
                  ),
                if (onSign != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        EmberButton(label: 'Sign', icon: Icons.draw_rounded, small: true, onPressed: onSign),
                        _MiniButton(icon: Icons.notifications_active_outlined, label: 'Ask for it', color: Ember.text2, onTap: onAsk!),
                        if (g.signatures.isNotEmpty)
                          _MiniButton(icon: Icons.undo_rounded, label: 'Roll back', color: Ember.danger, onTap: () => onUnsign(g.signatures.length == 1 ? g.signatures.keys.first : '')),
                      ],
                    ),
                  )
                else if (g.signed)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: EmberButton(
                      label: g.id == 'prd' ? 'Roll back: withdraw V1.0' : 'Roll back the signature${g.signatures.length > 1 ? 's' : ''}',
                      icon: Icons.undo_rounded,
                      small: true,
                      style: EmberButtonStyle.danger,
                      onPressed: () => onUnsign(g.signatures.length == 1 ? g.signatures.keys.first : ''),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  const _MiniButton({required this.icon, required this.label, required this.color, required this.onTap});

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return PressScale(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 7, 12, 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(label, style: t.labelMedium?.copyWith(color: color, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// Where the flow stands and what Mewo does next, with autopilot.
class _FlowCard extends StatelessWidget {
  const _FlowCard({
    required this.feature,
    required this.busy,
    required this.onNext,
    required this.onRedo,
    required this.onSign,
    required this.onAutopilot,
    required this.onEstimate,
    required this.onEstimatesDone,
    required this.onUat,
  });

  final TorchFeature feature;
  final bool busy;
  final VoidCallback onNext;
  final VoidCallback onRedo;

  /// Sign the gate the step asks for yourself (null when there is none to sign).
  final VoidCallback? onSign;
  final ValueChanged<bool> onAutopilot;
  final VoidCallback onEstimate;
  final VoidCallback onEstimatesDone;
  final VoidCallback onUat;

  static const Map<int, String> redoLabels = <int, String>{1: 'Draft the PRD again', 2: 'Estimates into the PRD again', 4: 'Redo the design', 7: 'Redo the intake', 8: 'Redo the session plan'};

  static String buttonFor(FlowAction a) {
    switch (a.kind) {
      case 'run':
        return 'Start the session';
      case 'ask':
        return a.roles.length > 1 ? 'Ask for the signatures' : 'Ask for the signature';
      case 'estimates':
        return 'Add my estimate';
      case 'export':
        return 'Export to handoff';
      case 'start':
        return 'Start session ${a.session}';
      case 'release':
        return 'Record the release';
      case 'close':
        return 'Merge and close the branches';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final fl = feature.flow;
    final a = fl.action;
    final button = buttonFor(a);
    final estimatesPhase = a.step == 2 && !fl.estimatesDone && !feature.light;
    final color = a.kind == 'wait' ? Ember.text2 : Ember.amber;
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      radius: 18,
      borderColor: Ember.amber.withValues(alpha: fl.autopilot ? 0.6 : 0.3),
      glow: fl.autopilot ? Ember.amber : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(fl.autopilot ? Icons.auto_mode_rounded : Icons.route_rounded, size: 18, color: Ember.amber),
              const SizedBox(width: 8),
              Expanded(child: Text('THE FLOW${a.step > 0 ? ' · STEP ${a.step}' : ''}', style: t.labelSmall?.copyWith(color: Ember.amber, letterSpacing: 1.4))),
              Text('Autopilot', style: t.labelSmall?.copyWith(color: Ember.text3)),
              const SizedBox(width: 8),
              EmberSwitch(value: fl.autopilot, onChanged: onAutopilot),
            ],
          ),
          const SizedBox(height: 10),
          Text(a.title.isEmpty ? 'Nothing to do' : a.title, style: t.titleSmall?.copyWith(fontSize: 15, color: color == Ember.text2 ? Ember.text : Ember.text)),
          if (a.detail.isNotEmpty || a.roles.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                [if (a.detail.isNotEmpty) a.detail, if (a.roles.isNotEmpty && a.kind != 'estimates') a.roles.join(', ')].join(' · '),
                style: t.bodySmall?.copyWith(color: Ember.text2),
              ),
            ),
          if (fl.estimates.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Estimates: ${fl.estimates.map((e) => '${e.role} ${e.days} d').join(' · ')}${fl.estimatesDone ? ' · in the PRD' : ''}',
                style: t.labelSmall?.copyWith(color: Ember.text3),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (button.isNotEmpty)
                  EmberButton(
                    label: button,
                    icon: a.kind == 'run' || a.kind == 'start' ? Icons.play_arrow_rounded : a.kind == 'ask' ? Icons.notifications_active_outlined : Icons.bolt_rounded,
                    small: true,
                    busy: busy,
                    onPressed: busy ? null : onNext,
                  ),
                if (estimatesPhase && a.kind != 'estimates') EmberButton(label: 'Add my estimate', icon: Icons.timelapse_rounded, small: true, style: EmberButtonStyle.secondary, onPressed: onEstimate),
                if (a.kind == 'ask' && onSign != null) EmberButton(label: 'Sign it myself', icon: Icons.draw_rounded, small: true, style: EmberButtonStyle.secondary, onPressed: busy ? null : onSign),
                if (redoLabels.containsKey(a.step) && a.kind != 'run') EmberButton(label: redoLabels[a.step]!, icon: Icons.replay_rounded, small: true, style: EmberButtonStyle.ghost, onPressed: busy ? null : onRedo),
                if (estimatesPhase && fl.estimates.length >= 3) EmberButton(label: 'Estimates are in the PRD', small: true, style: EmberButtonStyle.ghost, onPressed: onEstimatesDone),
                if (a.gate == 'uat' || a.step >= 11 && a.step <= 12 && !feature.released) EmberButton(label: 'Add a UAT user', icon: Icons.groups_rounded, small: true, style: EmberButtonStyle.secondary, onPressed: onUat),
              ],
            ),
          ),
          if (fl.log.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final e in fl.log.reversed.take(3))
              Text(
                '${_clock(e.$1)} · ${e.$2}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: t.labelSmall?.copyWith(color: Ember.text3, fontWeight: FontWeight.w400, letterSpacing: 0),
              ),
          ],
        ],
      ),
    );
  }

  static String _clock(int ts) {
    if (ts <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}

/// One of Mewo's writes, with Roll back when it can be undone.
class _JournalRow extends StatelessWidget {
  const _JournalRow({required this.entry, required this.onRollback});

  final FlowJournal entry;
  final VoidCallback? onRollback;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final j = entry;
    final meta = <String>[
      j.kind.replaceAll('_', ' '),
      if (j.commit.isNotEmpty) j.commit.substring(0, j.commit.length < 7 ? j.commit.length : 7) else if (j.files.isNotEmpty) 'not committed',
      if (j.undone) 'rolled back',
    ];
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      radius: 14,
      fill: Ember.surface2.withValues(alpha: j.undone ? 0.5 : 0.9),
      child: Row(
        children: [
          Text(_FlowCard._clock(j.ts), style: t.labelSmall?.copyWith(color: Ember.text3, fontFamily: Ember.mono(context), fontWeight: FontWeight.w400, letterSpacing: 0)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(j.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(color: j.undone ? Ember.text3 : Ember.text, decoration: j.undone ? TextDecoration.lineThrough : null)),
                Text(meta.join(' · '), style: t.labelSmall?.copyWith(color: Ember.text3)),
              ],
            ),
          ),
          if (onRollback != null) ...[
            const SizedBox(width: 8),
            EmberButton(label: 'Roll back', icon: Icons.undo_rounded, small: true, style: EmberButtonStyle.secondary, onPressed: onRollback),
          ],
        ],
      ),
    );
  }
}
