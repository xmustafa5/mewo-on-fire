import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import '../../models.dart';

/// Mewo on Fire's visual language: warm charcoal, fire for what Claude is
/// doing, electric blue for the phone (Mewo) side. Every screen reads its
/// colors from here; nothing is spelled out as a raw hex elsewhere.
class Ember {
  Ember._();

  // ---- base ----
  static const Color bg = Color(0xFF0C0A09);
  static const Color bgRaised = Color(0xFF131110);
  static const Color surface = Color(0xFF1B1816);
  static const Color surface2 = Color(0xFF242019);
  static const Color surface3 = Color(0xFF2E2823);
  static const Color line = Color(0x1AFFFFFF);
  static const Color lineStrong = Color(0x33FFFFFF);
  static const Color highlight = Color(0x14FFFFFF);
  static const Color scrim = Color(0xB30C0A09);

  /// Behind code, inline and in blocks alike (the same colour, so the lines
  /// of a block do not show as boxes).
  static const Color codeBg = Color(0xFF15110E);

  // ---- text ----
  static const Color text = Color(0xFFF6F1EC);
  static const Color text2 = Color(0xFFBCB2A8);
  static const Color text3 = Color(0xFF8A8076);

  // ---- fire (Claude's activity) ----
  static const Color heat = Color(0xFFFF3D1F);
  static const Color flame = Color(0xFFFF6B35);
  static const Color ember = Color(0xFFD97757);
  static const Color amber = Color(0xFFFFB347);
  static const Color gold = Color(0xFFFFD66B);

  // ---- Mewo (the phone side) ----
  static const Color mewo = Color(0xFF2F6BFF);
  static const Color mewoDeep = Color(0xFF1E4FD8);
  static const Color mewoSoft = Color(0xFF8FB5FF);

  // ---- semantic ----
  static const Color ok = Color(0xFF3DD68C);
  static const Color danger = Color(0xFFFF5A5F);
  static const Color ash = Color(0xFF8C837B);

  static const LinearGradient fire = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [heat, flame, amber],
  );
  static const LinearGradient fireSoft = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [ember, flame],
  );
  static const LinearGradient blue = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [mewo, mewoDeep],
  );
  static const LinearGradient glass = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0x1CFFFFFF), Color(0x05FFFFFF)],
  );
  static const LinearGradient glassBorder = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0x40FFFFFF), Color(0x0DFFFFFF), Color(0x1AFFFFFF)],
  );

  /// Monospace family that exists on the platform.
  static String mono(BuildContext context) =>
      Theme.of(context).platform == TargetPlatform.iOS ? 'Menlo' : 'monospace';

  /// Color of a session state (how hot it is).
  static Color heatOf(String state) {
    switch (state) {
      case SessionState.working:
        return flame;
      case SessionState.waiting:
        return amber;
      case SessionState.ended:
        return ash;
      default:
        return ok;
    }
  }

  /// Color of an event kind.
  static Color eventColor(String kind) {
    switch (kind) {
      case EventKind.needsInput:
        return amber;
      case EventKind.stop:
        return ok;
      case EventKind.sessionEnd:
        return ash;
      default:
        return flame;
    }
  }

  /// Color of a request kind.
  static Color requestColor(String kind) {
    switch (kind) {
      case RequestKind.question:
        return mewo;
      case RequestKind.plan:
        return ember;
      default:
        return amber;
    }
  }

  /// Color of a PC link status.
  static Color statusColor(String status) {
    switch (status) {
      case PcStatus.connected:
        return ok;
      case PcStatus.connecting:
        return amber;
      case PcStatus.unpaired:
        return danger;
      default:
        return ash;
    }
  }
}

/// Shared motion tokens, so everything moves with the same rhythm.
class Motion {
  Motion._();

  static const Duration fast = Duration(milliseconds: 150);
  static const Duration base = Duration(milliseconds: 260);
  static const Duration slow = Duration(milliseconds: 420);
  static const Duration enter = Duration(milliseconds: 480);

  static const Curve easeOut = Curves.easeOutCubic;
  static const Curve easeIn = Curves.easeInCubic;
  static const Curve emphasized = Cubic(0.2, 0.0, 0.0, 1.0);
  static const Curve spring = Curves.easeOutBack;

  /// Entrance delay of the [index]-th item of a list (capped so long lists
  /// do not keep the user waiting).
  static Duration stagger(int index, {int step = 40, int max = 10}) =>
      Duration(milliseconds: (index < max ? index : max) * step);
}

/// The one theme of the app (dark, always: the glow needs the dark).
ThemeData emberTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Ember.flame,
    onPrimary: Ember.bg,
    primaryContainer: Ember.surface3,
    onPrimaryContainer: Ember.text,
    secondary: Ember.mewo,
    onSecondary: Colors.white,
    secondaryContainer: Color(0xFF1B2A4F),
    onSecondaryContainer: Ember.mewoSoft,
    tertiary: Ember.mewo,
    onTertiary: Colors.white,
    tertiaryContainer: Ember.mewoDeep,
    onTertiaryContainer: Colors.white,
    error: Ember.danger,
    onError: Ember.bg,
    errorContainer: Color(0xFF3A1A1C),
    onErrorContainer: Color(0xFFFFB4B6),
    surface: Ember.bg,
    onSurface: Ember.text,
    onSurfaceVariant: Ember.text2,
    outline: Ember.text3,
    outlineVariant: Ember.line,
    surfaceContainerLowest: Ember.bg,
    surfaceContainerLow: Ember.bgRaised,
    surfaceContainer: Ember.surface,
    surfaceContainerHigh: Ember.surface2,
    surfaceContainerHighest: Ember.surface3,
    inverseSurface: Ember.text,
    onInverseSurface: Ember.bg,
    inversePrimary: Ember.ember,
    shadow: Colors.black,
    scrim: Ember.scrim,
  );

  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: Brightness.dark);
  final text = base.textTheme.apply(bodyColor: Ember.text, displayColor: Ember.text).copyWith(
        displaySmall: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -1.2, height: 1.1),
        headlineMedium: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.9, height: 1.15),
        headlineSmall: const TextStyle(fontSize: 23, fontWeight: FontWeight.w700, letterSpacing: -0.6, height: 1.2),
        titleLarge: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.4),
        titleMedium: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: -0.2),
        titleSmall: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: -0.1),
        bodyLarge: const TextStyle(fontSize: 16, height: 1.45),
        bodyMedium: const TextStyle(fontSize: 15, height: 1.45),
        bodySmall: const TextStyle(fontSize: 13, height: 1.4, color: Ember.text2),
        labelLarge: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.1),
        labelMedium: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3),
        labelSmall: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.4, color: Ember.text3),
      );

  return base.copyWith(
    textTheme: text,
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: Ember.bg,
    splashColor: Colors.white.withValues(alpha: 0.06),
    highlightColor: Colors.white.withValues(alpha: 0.04),
    hoverColor: Colors.transparent,
    dividerColor: Ember.line,
    dividerTheme: const DividerThemeData(color: Ember.line, thickness: 1, space: 1),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      foregroundColor: Ember.text,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    }),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Ember.surface3,
      contentTextStyle: text.bodyMedium?.copyWith(color: Ember.text),
      actionTextColor: Ember.amber,
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 108),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Ember.lineStrong),
      ),
      elevation: 0,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Ember.surface,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: Ember.surface,
      dragHandleColor: Ember.lineStrong,
      showDragHandle: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Ember.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: Ember.line),
      ),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium?.copyWith(color: Ember.text2),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Ember.flame,
        foregroundColor: Ember.bg,
        textStyle: text.labelLarge,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Ember.amber,
        textStyle: text.labelLarge,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Ember.text,
        side: const BorderSide(color: Ember.lineStrong),
        textStyle: text.labelLarge,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: Ember.text2),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Ember.surface2,
      hintStyle: text.bodyMedium?.copyWith(color: Ember.text3),
      labelStyle: text.bodyMedium?.copyWith(color: Ember.text2),
      helperStyle: text.bodySmall?.copyWith(color: Ember.text3),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Ember.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Ember.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Ember.flame, width: 1.5),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Ember.line),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Ember.flame,
      linearTrackColor: Colors.transparent,
      circularTrackColor: Colors.transparent,
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16),
      iconColor: Ember.text2,
      textColor: Ember.text,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Ember.surface2,
      side: const BorderSide(color: Ember.line),
      labelStyle: text.labelLarge?.copyWith(color: Ember.text),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: Ember.surface3, borderRadius: BorderRadius.circular(10)),
      textStyle: text.bodySmall?.copyWith(color: Ember.text),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Ember.flame : Ember.text3),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Ember.flame : Colors.transparent),
      checkColor: const WidgetStatePropertyAll(Ember.bg),
      side: const BorderSide(color: Ember.text3, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: Ember.flame,
      selectionColor: Ember.flame.withValues(alpha: 0.3),
      selectionHandleColor: Ember.flame,
    ),
  );
}
