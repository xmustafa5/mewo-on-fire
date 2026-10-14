import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
import 'flow_sheets.dart';
import 'theme/ember.dart';
import 'theme/flame.dart';
import 'theme/glass.dart';

/// Which wave each session of a plan is in: 1 for no dependency, else one
/// past its deepest dependency. Sessions of one wave can run together.
Map<int, int> planWaves(List<PlanSession> ss) {
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

/// The colour of a plan session on the map, by where it stands.
Color mapColorOf(String effective) {
  switch (effective) {
    case 'merged':
      return Ember.ok;
    case 'review':
      return Ember.mewoSoft;
    case 'progress':
      return Ember.ember;
    case 'ready':
      return Ember.amber;
    case 'blocked':
      return Ember.danger;
    default:
      return Ember.text3;
  }
}

/// The build map of a feature's plan, drawn as the console draws it: a
/// column per wave (what can run together), a card per session, a line
/// from each dependency. It is a canvas: drag it, pinch to zoom, double tap
/// to zoom in there (and back out). Tap a session for its chain: what it
/// needs and what waits for it; its details are one more tap away.
class BuildMapScreen extends StatefulWidget {
  const BuildMapScreen({super.key, required this.pcId, required this.featureKey});

  final String pcId;
  final String featureKey;

  static Route<void> route(String pcId, String featureKey) => MaterialPageRoute<void>(builder: (_) => BuildMapScreen(pcId: pcId, featureKey: featureKey));

  @override
  State<BuildMapScreen> createState() => _BuildMapScreenState();
}

class _BuildMapScreenState extends State<BuildMapScreen> with SingleTickerProviderStateMixin {
  final AppState _state = AppState.instance;
  final TransformationController _view = TransformationController();
  late final AnimationController _anim = AnimationController(vsync: this, duration: Motion.base);
  Animation<Matrix4>? _tween;
  int? _sel;
  Size _viewport = Size.zero;
  Size _map = Size.zero;
  bool _placed = false;
  Offset _doubleTapAt = Offset.zero;

  @override
  void initState() {
    super.initState();
    _anim.addListener(() {
      final t = _tween;
      if (t != null) _view.value = t.value;
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    _view.dispose();
    super.dispose();
  }

  TorchFeature? get _feature => _state.featuresOf(widget.pcId)?.features.where((f) => f.key == widget.featureKey).firstOrNull;

  /// The scale at which the whole map fits the screen (never above 1).
  double get _fitScale {
    if (_viewport.isEmpty || _map.isEmpty) return 1;
    return math.min(1.0, math.min(_viewport.width / _map.width, _viewport.height / _map.height));
  }

  Matrix4 _fit() {
    final k = _fitScale;
    return Matrix4.diagonal3Values(k, k, 1)..setTranslationRaw((_viewport.width - _map.width * k) / 2, (_viewport.height - _map.height * k) / 2, 0);
  }

  void _animateTo(Matrix4 target) {
    _tween = Matrix4Tween(begin: _view.value.clone(), end: target).animate(CurvedAnimation(parent: _anim, curve: Motion.easeOut));
    _anim.forward(from: 0);
  }

  void _onDoubleTap() {
    if (_viewport.isEmpty || _map.isEmpty) return;
    final scale = _view.value.getMaxScaleOnAxis();
    if (scale > _fitScale * 1.5) {
      _animateTo(_fit());
      return;
    }
    // Zoom in where the finger is: that point of the map stays under it.
    final p = _view.toScene(_doubleTapAt);
    const k = 1.15;
    _animateTo(Matrix4.diagonal3Values(k, k, 1)..setTranslationRaw(_doubleTapAt.dx - p.dx * k, _doubleTapAt.dy - p.dy * k, 0));
  }

  void _pick(int n) {
    HapticFeedback.selectionClick();
    setState(() => _sel = _sel == n ? null : n);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _state,
      builder: (context, _) {
        final f = _feature;
        final t = Theme.of(context).textTheme;
        final plan = f?.plan;
        final ss = plan?.sessions ?? const <PlanSession>[];
        final layout = ss.isEmpty ? null : _MapLayout(ss);
        final sub = f == null ? widget.featureKey : '${f.app} / ${f.slug}${layout == null ? '' : ' · ${layout.waves} wave${layout.waves == 1 ? '' : 's'} · ${f.sessionsMerged}/${f.sessionsTotal} merged'}';
        return Scaffold(
          backgroundColor: Colors.transparent,
          extendBodyBehindAppBar: true,
          appBar: GlassTopBar(
            title: const Text('Build map'),
            subtitle: Text(sub),
            actions: [
              GhostIconButton(icon: Icons.fit_screen_rounded, tooltip: 'Fit the map', onPressed: layout == null ? null : () => _animateTo(_fit())),
              GhostIconButton(icon: Icons.refresh_rounded, tooltip: 'Refresh', onPressed: _state.refreshFeatures),
            ],
          ),
          body: EmberBackground(
            animate: false,
            child: Builder(
              builder: (context) {
                final pad = MediaQuery.paddingOf(context);
                if (f == null || layout == null) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(f == null ? 'This feature is gone from the PC' : 'This feature has no session plan yet', textAlign: TextAlign.center, style: t.bodyMedium?.copyWith(color: Ember.text2)),
                    ),
                  );
                }
                final by = {for (final s in ss) s.n: s};
                final sel = _sel != null && by.containsKey(_sel) ? _sel : null;
                return Column(
                  children: [
                    SizedBox(height: pad.top),
                    _StatusStrip(sessions: ss, waves: layout.waves),
                    Expanded(child: _canvas(context, layout, ss, sel)),
                    _BottomPanel(
                      pcId: widget.pcId,
                      feature: f,
                      session: sel == null ? null : by[sel],
                      sessions: ss,
                      bottom: pad.bottom,
                      onClose: () => setState(() => _sel = null),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _canvas(BuildContext context, _MapLayout layout, List<PlanSession> ss, int? sel) {
    final up = sel == null ? const <int>{} : _chainUp(sel, ss);
    final down = sel == null ? const <int>{} : _chainDown(sel, ss);
    final chain = {...up, ...down, ?sel};
    return LayoutBuilder(
      builder: (context, box) {
        _viewport = box.biggest;
        _map = layout.size;
        if (!_placed && !_viewport.isEmpty) {
          // The first time the map is shown: all of it, centred.
          _placed = true;
          _view.value = _fit();
        }
        final mono = Ember.mono(context);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: sel == null ? null : () => setState(() => _sel = null),
          onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
          onDoubleTap: _onDoubleTap,
          child: ClipRect(
            child: InteractiveViewer(
              transformationController: _view,
              constrained: false,
              minScale: math.max(0.05, _fitScale * 0.6),
              maxScale: 3,
              boundaryMargin: EdgeInsets.symmetric(horizontal: _viewport.width * 0.6, vertical: _viewport.height * 0.6),
              onInteractionStart: (_) => _anim.stop(),
              child: MediaQuery.withNoTextScaling(
                child: SizedBox(
                  width: layout.size.width,
                  height: layout.size.height,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(painter: _EdgePainter(layout: layout, sessions: ss, chain: chain, selected: sel)),
                      ),
                      for (var ci = 0; ci < layout.cols.length; ci++)
                        Positioned(
                          left: _MapLayout.pad + ci * (_MapLayout.nw + _MapLayout.gx),
                          top: _MapLayout.pad,
                          width: _MapLayout.nw,
                          child: Text(
                            'WAVE ${ci + 1}${layout.cols[ci].length > 1 ? ' · ${layout.cols[ci].length} TOGETHER' : ''}',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontFamily: mono, fontSize: 9.5, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: Ember.text3),
                          ),
                        ),
                      for (final s in ss)
                        Positioned(
                          left: layout.pos[s.n]!.dx,
                          top: layout.pos[s.n]!.dy,
                          width: _MapLayout.nw,
                          height: _MapLayout.nh,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _pick(s.n),
                            child: _MapNode(
                              session: s,
                              selected: sel == s.n,
                              inChain: chain.contains(s.n) && sel != s.n,
                              dim: sel != null && !chain.contains(s.n),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Every session `n` needs, all the way back.
Set<int> _chainUp(int n, List<PlanSession> ss) {
  final by = {for (final s in ss) s.n: s};
  final acc = <int>{};
  void walk(int m) {
    for (final d in by[m]?.dependsOn ?? const <int>[]) {
      if (d != m && by.containsKey(d) && acc.add(d)) walk(d);
    }
  }

  walk(n);
  return acc;
}

/// Every session that waits for `n`, all the way down.
Set<int> _chainDown(int n, List<PlanSession> ss) {
  final acc = <int>{};
  void walk(int m) {
    for (final s in ss) {
      if (s.n != m && s.dependsOn.contains(m) && acc.add(s.n)) walk(s.n);
    }
  }

  walk(n);
  return acc;
}

/// Where everything goes: the console's sizes (pc/dashboard, buildMapHtml).
class _MapLayout {
  _MapLayout(List<PlanSession> ss) {
    final w = planWaves(ss);
    waves = w.values.fold<int>(1, (a, b) => a > b ? a : b);
    cols = List<List<PlanSession>>.generate(waves, (i) {
      final c = ss.where((s) => w[s.n] == i + 1).toList();
      c.sort((a, b) => a.repo != b.repo ? a.repo.compareTo(b.repo) : a.n - b.n);
      return c;
    });
    final rows = cols.map((c) => c.length).fold<int>(1, (a, b) => a > b ? a : b);
    for (var ci = 0; ci < cols.length; ci++) {
      for (var ri = 0; ri < cols[ci].length; ri++) {
        pos[cols[ci][ri].n] = Offset(pad + ci * (nw + gx), pad + head + ri * (nh + gy));
      }
    }
    size = Size(pad * 2 + waves * nw + (waves - 1) * gx, pad * 2 + head + rows * nh + (rows - 1) * gy);
  }

  static const double nw = 170, nh = 46, gx = 64, gy = 12, pad = 14, head = 22;
  late final int waves;
  late final List<List<PlanSession>> cols;
  final Map<int, Offset> pos = <int, Offset>{};
  late final Size size;
}

/// The dependency lines: from the right of what is needed to the left of
/// what needs it. The selected chain is lit; the rest fades.
class _EdgePainter extends CustomPainter {
  _EdgePainter({required this.layout, required this.sessions, required this.chain, required this.selected});

  final _MapLayout layout;
  final List<PlanSession> sessions;
  final Set<int> chain;
  final int? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = Ember.mewoSoft.withValues(alpha: selected == null ? 0.32 : 0.1);
    final lit = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Ember.flame;
    final litPaths = <Path>[];
    for (final s in sessions) {
      final p = layout.pos[s.n];
      if (p == null) continue;
      for (final d in s.dependsOn) {
        final q = layout.pos[d];
        if (d == s.n || q == null) continue;
        final x1 = q.dx + _MapLayout.nw, y1 = q.dy + _MapLayout.nh / 2, x2 = p.dx, y2 = p.dy + _MapLayout.nh / 2, mx = (x1 + x2) / 2;
        final path = Path()
          ..moveTo(x1, y1)
          ..cubicTo(mx, y1, mx, y2, x2, y2);
        if (selected != null && chain.contains(d) && chain.contains(s.n)) {
          litPaths.add(path);
        } else {
          canvas.drawPath(path, base);
        }
      }
    }
    // The chain on top of the rest.
    for (final path in litPaths) {
      canvas.drawPath(path, lit);
    }
  }

  @override
  bool shouldRepaint(_EdgePainter old) => true;
}

/// One session's card: its number, goal, repository, tier and where it stands.
class _MapNode extends StatelessWidget {
  const _MapNode({required this.session, required this.selected, required this.inChain, required this.dim});

  final PlanSession session;
  final bool selected;
  final bool inChain;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final color = mapColorOf(s.effective);
    final mono = Ember.mono(context);
    final repo = s.repo.replaceFirst('code/', '');
    final width = selected ? 2.4 : inChain ? 2.0 : s.effective == 'ready' || s.effective == 'progress' ? 1.8 : 1.2;
    return AnimatedOpacity(
      duration: Motion.fast,
      opacity: dim ? 0.3 : 1,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
        decoration: BoxDecoration(
          color: selected ? Color.alphaBlend(color.withValues(alpha: 0.16), Ember.surface) : Ember.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color, width: width),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('S${s.n}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(s.goal, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Ember.text)),
                ),
                if (s.running) ...[
                  const SizedBox(width: 4),
                  Container(width: 6, height: 6, decoration: BoxDecoration(color: Ember.flame, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Ember.flame.withValues(alpha: 0.6), blurRadius: 4)])),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${repo.toUpperCase()} · T${s.tier > 0 ? s.tier : '?'} · ${s.effective.toUpperCase()}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: mono, fontSize: 8.5, fontWeight: FontWeight.w600, letterSpacing: 0.4, color: Ember.text2),
            ),
          ],
        ),
      ),
    );
  }
}

/// Above the map: how long the longest chain is and what can start now.
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.sessions, required this.waves});

  final List<PlanSession> sessions;
  final int waves;

  @override
  Widget build(BuildContext context) {
    final mono = Ember.mono(context);
    final ready = sessions.where((s) => s.effective == 'ready').map((s) => 'S${s.n}').toList();
    final running = sessions.where((s) => s.running).map((s) => 'S${s.n}').toList();
    final String note;
    final Color tone;
    if (ready.isNotEmpty) {
      note = 'CAN START NOW: ${ready.join(', ')}';
      tone = Ember.amber;
    } else if (sessions.every((s) => s.effective == 'merged')) {
      note = 'ALL MERGED';
      tone = Ember.ok;
    } else if (sessions.any((s) => s.effective == 'progress' || s.effective == 'review')) {
      note = 'WAITING ON THE SESSIONS IN FLIGHT';
      tone = Ember.text2;
    } else {
      note = 'NOTHING READY';
      tone = Ember.text3;
    }
    final style = TextStyle(fontFamily: mono, fontSize: 10, letterSpacing: 1.2, color: Ember.text3);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$waves WAVE${waves == 1 ? '' : 'S'} · LONGEST CHAIN $waves${running.isEmpty ? '' : ' · RUNNING ${running.join(', ')}'}', style: style),
          const SizedBox(height: 3),
          Text(note, style: style.copyWith(color: tone)),
        ],
      ),
    );
  }
}

/// Below the map: the legend, or the session you tapped with its chain.
class _BottomPanel extends StatelessWidget {
  const _BottomPanel({required this.pcId, required this.feature, required this.session, required this.sessions, required this.bottom, required this.onClose});

  final String pcId;
  final TorchFeature feature;
  final PlanSession? session;
  final List<PlanSession> sessions;
  final double bottom;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final mono = Ember.mono(context);
    final s = session;
    if (s == null) {
      const items = <(String, String)>[('ready', 'Ready'), ('progress', 'In progress'), ('review', 'In review'), ('merged', 'Merged'), ('blocked', 'Blocked'), ('waiting', 'Waiting')];
      return Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 12 + bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                for (final (key, label) in items)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(width: 8, height: 8, decoration: BoxDecoration(color: mapColorOf(key), shape: BoxShape.circle)),
                      const SizedBox(width: 5),
                      Text(label, style: t.labelSmall?.copyWith(color: Ember.text2)),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text('A wave is what can run together. Drag and pinch the map; double tap to zoom; tap a session for its chain.', style: t.bodySmall?.copyWith(color: Ember.text3, fontSize: 11.5)),
          ],
        ),
      );
    }
    final color = mapColorOf(s.effective);
    final needs = s.dependsOn.where((d) => d != s.n).map((d) => 'S$d').toList();
    final next = sessions.where((x) => x.n != s.n && x.dependsOn.contains(s.n)).map((x) => 'S${x.n}').toList();
    final repo = s.repo.replaceFirst('code/', '');
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 6, 12, 10 + bottom),
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        radius: 16,
        borderColor: color.withValues(alpha: 0.5),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('S${s.n} · ${s.goal}', maxLines: 2, overflow: TextOverflow.ellipsis, style: t.titleSmall?.copyWith(color: Ember.text)),
                  const SizedBox(height: 4),
                  Text(
                    [s.statusLabel, if (repo.isNotEmpty) repo, if (s.tier > 0) 'Tier ${s.tier}'].join(' · '),
                    style: t.bodySmall?.copyWith(color: color),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${needs.isEmpty ? 'needs nothing' : 'needs ${needs.join(', ')}'} · ${next.isEmpty ? 'nothing waits for it' : 'then ${next.join(', ')}'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: mono, fontSize: 10.5, color: Ember.text3),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            TextButton(
              onPressed: () => showSessionDetailSheet(context, pcId: pcId, feature: feature, session: s),
              child: const Text('Details'),
            ),
            GhostIconButton(icon: Icons.close_rounded, tooltip: 'Close', size: 34, iconSize: 17, filled: false, onPressed: onClose),
          ],
        ),
      ),
    );
  }
}
