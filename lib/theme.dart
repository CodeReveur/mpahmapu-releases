import 'package:flutter/material.dart';

/// The look the web apps set: true black, orange, small sharp type.
class Brand {
  static const orange = Color(0xFFF97316);
  static const black = Color(0xFF000000);
  static const surface = Color(0xFF0A0A0A);
  static const line = Color(0xFF1F1F1F);
  static const text = Color(0xFFFFFFFF);
  static const muted = Color(0xFF888888);
  static const dim = Color(0xFF555555);
  static const green = Color(0xFF4ADE80);
  static const amber = Color(0xFFFBBF24);
  static const red = Color(0xFFF87171);

  /// The uppercase micro-label used throughout both web apps.
  static const micro = TextStyle(
    fontSize: 9,
    fontWeight: FontWeight.w800,
    letterSpacing: 1.1,
    color: muted,
  );

  static ThemeData get theme => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: black,
        colorScheme: const ColorScheme.dark(
          primary: orange,
          secondary: orange,
          surface: black,
          error: red,
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: text, fontSize: 13),
          bodySmall: TextStyle(color: muted, fontSize: 11.5),
          titleMedium: TextStyle(color: text, fontSize: 15, fontWeight: FontWeight.w800),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surface,
          hintStyle: const TextStyle(color: Color(0xFF4A4A4A), fontSize: 13),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: orange),
          ),
        ),
      );
}

/// A card the way the web sheets draw one.
class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final Color? borderColor;
  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: Brand.surface,
          border: Border.all(color: borderColor ?? Brand.line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      );
}

/// The orange call to action, black text, uppercase — as on the web.
class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final Color background;
  final IconData? icon;
  const PrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.background = Brand.orange,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: enabled ? background : const Color(0xFF1A1A1A),
          foregroundColor: enabled ? Colors.black : Brand.dim,
          disabledBackgroundColor: const Color(0xFF1A1A1A),
          disabledForegroundColor: Brand.dim,
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 13),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[Icon(icon, size: 15), const SizedBox(width: 7)],
            Text(
              label.toUpperCase(),
              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w900, letterSpacing: 0.6),
            ),
          ],
        ),
      ),
    );
  }
}

/// RWF 1,500 — the money format both web apps use.
String rwf(num? amount) {
  final v = (amount ?? 0).round();
  final s = v.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return 'RWF $buf';
}

/// 1.2 km — distances stay in kilometres, one decimal, like the web.
String km(num? metres) => '${((metres ?? 0) / 1000).toStringAsFixed(1)} km';
