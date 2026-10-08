import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../models.dart';
import 'artifact_screen.dart';
import 'chat_screen.dart';
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
          if (f.prd.isNotEmpty) _tag(context, f.prdSigned ? 'PRD signed' : 'PRD draft', f.prdSigned ? Ember.ok : Ember.amber),
          if (f.prd.isEmpty) _tag(context, 'No PRD found', Ember.text3),
          if (f.openQuestions > 0) _tag(context, '${f.openQuestions} open question${f.openQuestions == 1 ? '' : 's'}', Ember.amber),
          if (f.running) _tag(context, 'Running now', Ember.ember),
        ],
      ),
    )));

    for (final w in f.warnings) {
      out.add(enter(_warning(context, w)));
    }

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
      for (final s in plan.sessions) {
        out.add(enter(_SessionRow(
          session: s,
          feature: f,
          pcId: widget.pcId,
          starting: _starting.contains(s.n),
          onStart: () => _start(f, s),
          onOpenPr: s.prUrl.isNotEmpty || s.pr.isNotEmpty ? () => _open(s.prUrl.isNotEmpty ? s.prUrl : s.pr) : null,
          onOpenLive: (id) => Navigator.of(context).push(ChatScreen.route(widget.pcId, id)),
        )));
      }
    }

    // Sign-offs.
    out.add(enter(const SectionLabel('Sign-offs')));
    for (final g in f.gates) {
      out.add(enter(_GateCard(
        gate: g,
        onSign: g.signed || !g.present ? null : () => showSignSheet(context, pcId: widget.pcId, feature: f, gate: g),
        onAsk: g.signed || !g.present ? null : () => _ask(f, g),
      )));
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
  });

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
          if (s.live.isNotEmpty || canStart || onOpenPr != null)
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
  const _GateCard({required this.gate, required this.onSign, required this.onAsk});

  final TorchGate gate;
  final VoidCallback? onSign;
  final VoidCallback? onAsk;

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
                if (signed.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text('Signed by ${signed.join(', ')}${g.date.isNotEmpty ? ' · ${g.date}' : ''}', style: t.labelSmall?.copyWith(color: Ember.ok)),
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
                      ],
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
