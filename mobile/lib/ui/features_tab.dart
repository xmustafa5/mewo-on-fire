import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import 'feature_screen.dart';
import 'theme/ember.dart';
import 'theme/glass.dart';
import 'theme/motion.dart';

/// The features of every paired PC's TORCH workspaces (v1.7), as slivers
/// for the Sessions tab.
List<Widget> featureSlivers(BuildContext context, AppState state) {
  final all = state.allFeatures;
  final t = Theme.of(context).textTheme;
  final errors = [
    for (final pc in state.pcs)
      if ((state.featuresOf(pc.id)?.error ?? '').isNotEmpty) '${pc.name}: ${state.featuresOf(pc.id)!.error}',
  ];
  if (all.isEmpty) {
    return [
      SliverToBoxAdapter(
        child: EmptyState(
          icon: Icons.account_tree_outlined,
          title: state.pcs.isEmpty ? 'Pair a PC first' : 'No features yet',
          body: errors.isNotEmpty
              ? errors.join('\n')
              : 'Features show up once a Claude Code session runs inside a TORCH workspace on a paired PC: a folder with app-notebooks/ and context/templates/.',
        ),
      ),
    ];
  }
  return [
    if (errors.isNotEmpty)
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Text(errors.join('\n'), style: t.labelSmall?.copyWith(color: Ember.text3)),
        ),
      ),
    SliverPadding(
      padding: const EdgeInsets.only(top: 8),
      sliver: SliverList.builder(
        itemCount: all.length,
        itemBuilder: (context, i) => FadeSlideIn(
          key: ValueKey<String>('${all[i].$1}/${all[i].$2.key}'),
          delay: Motion.stagger(i),
          child: _FeatureCard(pcId: all[i].$1, feature: all[i].$2),
        ),
      ),
    ),
  ];
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({required this.pcId, required this.feature});

  final String pcId;
  final TorchFeature feature;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final f = feature;
    final warnings = f.warningCount;
    final color = f.released
        ? Ember.ok
        : f.running
            ? Ember.ember
            : Ember.amber;
    return GlassCard(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      radius: 18,
      glow: f.running ? Ember.ember : null,
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FeatureScreen(pcId: pcId, featureKey: f.key))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconTile(icon: f.light ? Icons.healing_rounded : Icons.account_tree_rounded, color: color, size: 36, iconSize: 18, glow: f.running),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${f.app} / ${f.slug}', maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleSmall?.copyWith(fontSize: 14.5)),
                    const SizedBox(height: 2),
                    Text(
                      f.light
                          ? 'Light path · ${f.released ? 'released' : f.stepLabel}'
                          : f.released
                              ? 'Released'
                              : 'Step ${f.step} of 12 · ${f.stepLabel}',
                      style: t.labelSmall?.copyWith(color: Ember.text3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: Ember.text3.withValues(alpha: 0.7)),
            ],
          ),
          if (!f.light) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                for (var i = 1; i <= 12; i++) ...[
                  Expanded(
                    child: Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: f.released || i < f.step
                            ? Ember.ok
                            : i == f.step
                                ? Ember.amber
                                : Ember.line,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  if (i < 12) const SizedBox(width: 2),
                ],
              ],
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 4,
            children: [
              if (f.sessionsTotal > 0) _meta(context, Icons.layers_outlined, '${f.sessionsMerged}/${f.sessionsTotal} merged', Ember.text2),
              if (f.openQuestions > 0) _meta(context, Icons.help_outline_rounded, '${f.openQuestions} open', Ember.amber),
              if (warnings > 0) _meta(context, Icons.warning_amber_rounded, '$warnings warning${warnings == 1 ? '' : 's'}', Ember.danger),
              if (f.running) _meta(context, Icons.local_fire_department_rounded, 'Claude at work', Ember.ember),
              _meta(context, Icons.computer_rounded, AppState.instance.pcNameFor(pcId), Ember.text3),
            ],
          ),
        ],
      ),
    );
  }

  Widget _meta(BuildContext context, IconData icon, String text, Color color) {
    final t = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Text(text, style: t.labelSmall?.copyWith(color: color)),
      ],
    );
  }
}
