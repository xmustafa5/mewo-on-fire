import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models.dart';
import 'ember.dart';
import 'flame.dart';
import 'motion.dart';

/// A translucent card with a hairline border and a soft shadow; [glow]
/// tints the shadow (amber for "needs you", fire for "working"...).
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.radius = 20,
    this.glow,
    this.borderColor,
    this.fill,
    this.onTap,
    this.onLongPress,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final double radius;
  final Color? glow;
  final Color? borderColor;
  final Color? fill;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);
    Widget box = DecoratedBox(
      decoration: BoxDecoration(
        color: fill ?? Ember.surface.withValues(alpha: 0.8),
        borderRadius: shape,
        border: Border.all(color: borderColor ?? Ember.line),
        boxShadow: [
          if (glow != null)
            BoxShadow(color: glow!.withValues(alpha: 0.26), blurRadius: 30, spreadRadius: -2),
          const BoxShadow(color: Color(0x40000000), blurRadius: 24, offset: Offset(0, 10)),
        ],
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: Ember.glass, borderRadius: shape),
        child: Padding(padding: padding, child: child),
      ),
    );
    if (onTap != null || onLongPress != null) {
      box = PressScale(onTap: onTap, onLongPress: onLongPress, child: box);
    }
    return Padding(padding: margin, child: box);
  }
}

/// A blurred, translucent bar (tab bar, input bar, top bars): what scrolls
/// beneath it shows through.
class GlassBar extends StatelessWidget {
  const GlassBar({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.border,
    this.alpha = 0.74,
    this.blur = 24,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final BoxBorder? border;
  final double alpha;
  final double blur;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Ember.surface.withValues(alpha: alpha),
            borderRadius: borderRadius,
            border: border,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// A round, bordered icon button (toolbar actions).
class GhostIconButton extends StatelessWidget {
  const GhostIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.color,
    this.size = 40,
    this.iconSize = 20,
    this.filled = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final double size;
  final double iconSize;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: PressScale(
          scale: 0.9,
          onTap: onPressed,
          child: AnimatedOpacity(
            duration: Motion.fast,
            opacity: enabled ? 1 : 0.4,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: filled ? Ember.surface2.withValues(alpha: 0.9) : Colors.transparent,
                border: Border.all(color: filled ? Ember.line : Colors.transparent),
              ),
              child: Icon(icon, size: iconSize, color: color ?? Ember.text2),
            ),
          ),
        ),
      ),
    );
  }
}

enum EmberButtonStyle { primary, blue, secondary, ghost, danger }

/// The app's button. [primary] burns (fire gradient, glow); the rest are
/// quiet so every screen has one obvious action.
class EmberButton extends StatelessWidget {
  const EmberButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.style = EmberButtonStyle.primary,
    this.busy = false,
    this.expand = false,
    this.small = false,
    this.shimmer = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final EmberButtonStyle style;
  final bool busy;
  final bool expand;
  final bool small;

  /// A light sweeps across now and then (the main action of a screen).
  final bool shimmer;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final radius = BorderRadius.circular(small ? 12 : 16);
    Gradient? gradient;
    Color? fill;
    Color fg;
    Color border = Colors.transparent;
    List<BoxShadow> shadow = const [];
    switch (style) {
      case EmberButtonStyle.primary:
        gradient = Ember.fire;
        fg = Ember.bg;
        shadow = [BoxShadow(color: Ember.flame.withValues(alpha: 0.38), blurRadius: 22, offset: const Offset(0, 6))];
        break;
      case EmberButtonStyle.blue:
        gradient = Ember.blue;
        fg = Colors.white;
        shadow = [BoxShadow(color: Ember.mewo.withValues(alpha: 0.38), blurRadius: 22, offset: const Offset(0, 6))];
        break;
      case EmberButtonStyle.secondary:
        fill = Ember.surface3;
        fg = Ember.text;
        border = Ember.lineStrong;
        break;
      case EmberButtonStyle.ghost:
        fill = Colors.transparent;
        fg = Ember.text2;
        border = Ember.lineStrong;
        break;
      case EmberButtonStyle.danger:
        fill = Ember.danger.withValues(alpha: 0.12);
        fg = Ember.danger;
        border = Ember.danger.withValues(alpha: 0.45);
        break;
    }
    final textStyle = (small ? Theme.of(context).textTheme.labelMedium : Theme.of(context).textTheme.labelLarge)
        ?.copyWith(color: fg, fontSize: small ? 13 : 15);

    Widget content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (busy)
          SizedBox(
            width: small ? 14 : 18,
            height: small ? 14 : 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: fg),
          )
        else ...[
          if (icon != null) ...[
            Icon(icon, size: small ? 16 : 19, color: fg),
            SizedBox(width: small ? 6 : 8),
          ],
          Flexible(
            child: Text(label, style: textStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ],
    );

    Widget box = Container(
      height: small ? 38 : 52,
      padding: EdgeInsets.symmetric(horizontal: small ? 14 : 20),
      decoration: BoxDecoration(
        gradient: enabled ? gradient : null,
        color: enabled ? fill : (gradient != null ? Ember.surface3 : fill),
        borderRadius: radius,
        border: Border.all(color: enabled ? border : Ember.line),
        boxShadow: enabled ? shadow : const [],
      ),
      child: content,
    );
    if (shimmer && enabled && gradient != null) {
      box = ClipRRect(borderRadius: radius, child: Shimmer(child: box));
    }
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: AnimatedOpacity(
        duration: Motion.fast,
        opacity: enabled ? 1 : 0.5,
        child: PressScale(
          scale: 0.96,
          onTap: enabled ? onPressed : null,
          child: box,
        ),
      ),
    );
  }
}

/// A small coloured dot; [live] makes it breathe.
class GlowDot extends StatelessWidget {
  const GlowDot({super.key, required this.color, this.size = 10, this.live = false});

  final Color color;
  final double size;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.7), blurRadius: size, spreadRadius: size * 0.1)],
      ),
    );
    return live ? Breathe(scale: 0.12, child: dot) : dot;
  }
}

/// Session state as a pill: a flame while Claude works, a dot otherwise.
class HeatChip extends StatelessWidget {
  const HeatChip({super.key, required this.state, this.compact = false});

  final String state;
  final bool compact;

  static String label(String state) {
    switch (state) {
      case SessionState.working:
        return 'Working';
      case SessionState.waiting:
        return 'Needs you';
      case SessionState.ended:
        return 'Closed';
      default:
        return 'Finished';
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = Ember.heatOf(state);
    final working = state == SessionState.working;
    final waiting = state == SessionState.waiting;
    return Container(
      padding: EdgeInsets.fromLTRB(compact ? 7 : 9, 3, compact ? 8 : 10, 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (working)
            const Padding(
              padding: EdgeInsets.only(right: 5, bottom: 1),
              child: FlameIcon(size: 13),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: GlowDot(color: color, size: 7, live: waiting),
            ),
          Text(
            label(state),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color, fontSize: compact ? 11 : 12),
          ),
        ],
      ),
    );
  }
}

/// An icon on a tinted rounded square.
class IconTile extends StatelessWidget {
  const IconTile({super.key, required this.icon, required this.color, this.size = 40, this.iconSize = 20, this.glow = false});

  final IconData icon;
  final Color color;
  final double size;
  final double iconSize;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(size * 0.32),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        boxShadow: glow ? [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 18)] : const [],
      ),
      child: Icon(icon, size: iconSize, color: color),
    );
  }
}

/// Small caps label above a group.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing, this.top = 24});

  final String text;
  final Widget? trailing;
  final double top;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(22, top, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Ember.text3, letterSpacing: 1.4),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Large title at the top of a tab, with room for a line under it and actions.
class ScreenHeader extends StatelessWidget {
  const ScreenHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const <Widget>[],
  });

  final String title;
  final Widget? subtitle;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top + 14, 16, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 14)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: t.headlineMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: DefaultTextStyle(
                      style: t.bodySmall!.copyWith(color: Ember.text3),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      child: subtitle!,
                    ),
                  ),
              ],
            ),
          ),
          for (final a in actions) Padding(padding: const EdgeInsets.only(left: 8), child: a),
        ],
      ),
    );
  }
}

/// Blurred top bar of a pushed screen (chat, request, pairing).
class GlassTopBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassTopBar({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const <Widget>[],
    this.onBack,
  });

  final Widget title;
  final Widget? subtitle;
  final List<Widget> actions;
  final VoidCallback? onBack;

  @override
  Size get preferredSize => const Size.fromHeight(60);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final canPop = Navigator.of(context).canPop();
    return GlassBar(
      border: const Border(bottom: BorderSide(color: Ember.line)),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 60,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            child: Row(
              children: [
                if (canPop || onBack != null) ...[
                  GhostIconButton(
                    icon: Icons.arrow_back_ios_new_rounded,
                    iconSize: 17,
                    tooltip: 'Back',
                    onPressed: onBack ?? () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 12),
                ] else
                  const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DefaultTextStyle(
                        style: t.titleMedium!.copyWith(color: Ember.text),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        child: title,
                      ),
                      if (subtitle != null)
                        DefaultTextStyle(
                          style: t.bodySmall!.copyWith(color: Ember.text3, fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          child: subtitle!,
                        ),
                    ],
                  ),
                ),
                for (final a in actions) Padding(padding: const EdgeInsets.only(left: 8), child: a),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A box of monospaced text (commands, tool input).
class CodeBox extends StatelessWidget {
  const CodeBox({
    super.key,
    required this.text,
    this.selectable = true,
    this.maxLines,
    this.fontSize = 13,
    this.label,
  });

  final String text;
  final bool selectable;
  final int? maxLines;
  final double fontSize;

  /// Small caption in the corner ("Bash", "Plan").
  final String? label;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontFamily: Ember.mono(context),
      fontSize: fontSize,
      height: 1.5,
      color: Ember.text2,
    );
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Ember.bg.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Ember.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Ember.line)),
              ),
              child: Text(
                label!,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Ember.text3, letterSpacing: 1),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: selectable
                ? SelectableText(text, style: style, maxLines: maxLines)
                : Text(text, style: style, maxLines: maxLines, overflow: maxLines == null ? null : TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

/// A switch that burns when on.
class EmberSwitch extends StatelessWidget {
  const EmberSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return Semantics(
      toggled: value,
      enabled: enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled
            ? () {
                HapticFeedback.lightImpact();
                onChanged!(!value);
              }
            : null,
        child: AnimatedOpacity(
          duration: Motion.fast,
          opacity: enabled ? 1 : 0.5,
          child: AnimatedContainer(
            duration: Motion.base,
            curve: Motion.emphasized,
            width: 52,
            height: 32,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              gradient: value ? Ember.fire : null,
              color: value ? null : Ember.surface3,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: value ? Colors.transparent : Ember.lineStrong),
              boxShadow: value
                  ? [BoxShadow(color: Ember.flame.withValues(alpha: 0.4), blurRadius: 14)]
                  : const [],
            ),
            child: AnimatedAlign(
              duration: Motion.base,
              curve: Motion.emphasized,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: value ? Colors.white : Ember.text2,
                  boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 6, offset: Offset(0, 2))],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A big friendly message when there is nothing to show.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    required this.body,
    this.icon,
    this.flame = false,
    this.action,
    this.extra,
  });

  final String title;
  final String body;
  final IconData? icon;
  final bool flame;
  final Widget? action;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return FadeSlideIn(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 40, 28, 28),
        child: Column(
          children: [
            if (flame)
              const FlameMark(size: 72)
            else if (icon != null)
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Ember.surface2,
                  border: Border.all(color: Ember.line),
                  boxShadow: [BoxShadow(color: Ember.flame.withValues(alpha: 0.18), blurRadius: 40)],
                ),
                child: Icon(icon, size: 36, color: Ember.text2),
              ),
            const SizedBox(height: 22),
            Text(title, style: t.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(body, style: t.bodyMedium?.copyWith(color: Ember.text2), textAlign: TextAlign.center),
            if (extra != null) ...[const SizedBox(height: 18), extra!],
            if (action != null) ...[const SizedBox(height: 22), action!],
          ],
        ),
      ),
    );
  }
}

/// Glass pill of filter chips with one lit segment that slides.
class SegmentedGlass<T> extends StatelessWidget {
  const SegmentedGlass({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
  });

  final List<(T, String)> segments;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final index = segments.indexWhere((s) => s.$1 == value).clamp(0, segments.length - 1);
    final n = segments.length;
    return Container(
      height: 42,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Ember.surface.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Ember.line),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth / n;
          return Stack(
            children: [
              AnimatedPositioned(
                duration: Motion.base,
                curve: Motion.emphasized,
                left: w * index,
                top: 0,
                bottom: 0,
                width: w,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: Ember.fireSoft,
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: [BoxShadow(color: Ember.flame.withValues(alpha: 0.35), blurRadius: 14)],
                  ),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < n; i++)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          if (segments[i].$1 == value) return;
                          HapticFeedback.selectionClick();
                          onChanged(segments[i].$1);
                        },
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: Motion.base,
                            style: Theme.of(context).textTheme.labelMedium!.copyWith(
                                  color: i == index ? Ember.bg : Ember.text2,
                                  fontSize: 12.5,
                                ),
                            child: Text(segments[i].$2, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Picture of Mewo (the app icon) in a ring that burns while Claude works.
class MewoAvatar extends StatelessWidget {
  const MewoAvatar({super.key, this.size = 46, this.burning = false});

  final double size;
  final bool burning;

  @override
  Widget build(BuildContext context) {
    final ring = AnimatedContainer(
      duration: Motion.slow,
      width: size,
      height: size,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: burning ? Ember.fire : null,
        color: burning ? null : Ember.lineStrong,
        boxShadow: burning
            ? [BoxShadow(color: Ember.flame.withValues(alpha: 0.5), blurRadius: 18)]
            : [BoxShadow(color: Ember.mewo.withValues(alpha: 0.35), blurRadius: 18)],
      ),
      child: ClipOval(
        child: Image.asset('assets/mewo.png', fit: BoxFit.cover, filterQuality: FilterQuality.medium),
      ),
    );
    return burning ? Breathe(min: 0.85, scale: 0.03, child: ring) : ring;
  }
}
