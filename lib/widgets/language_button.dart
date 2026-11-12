import 'package:flutter/material.dart';

import '../i18n.dart';
import '../theme.dart';

/// The globe the website carries in its top right corner, in the app's own
/// shape: two letters, and a sheet of four languages behind them.
class LanguageButton extends StatelessWidget {
  /// Draw it as a flat row instead of a pill, for lists and settings.
  final bool inline;

  const LanguageButton({super.key, this.inline = false});

  Future<void> _pick(BuildContext context) async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Brand.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 34,
              height: 3,
              decoration: BoxDecoration(
                color: const Color(0xFF333333),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(t('common.language').toUpperCase(), style: Brand.micro),
              ),
            ),
            const SizedBox(height: 6),
            for (final code in Lang.codes)
              ListTile(
                dense: true,
                onTap: () => Navigator.of(context).pop(code),
                leading: Text(
                  Lang.short(code),
                  style: TextStyle(
                    color: code == appLanguage.value ? Brand.orange : Brand.dim,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
                title: Text(
                  Lang.names[code]!,
                  style: TextStyle(
                    color: code == appLanguage.value ? Brand.text : Brand.muted,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                trailing: code == appLanguage.value
                    ? const Icon(Icons.check, size: 15, color: Brand.orange)
                    : null,
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen != null) await setLanguage(chosen);
  }

  @override
  Widget build(BuildContext context) {
    if (inline) {
      return GestureDetector(
        onTap: () => _pick(context),
        behavior: HitTestBehavior.opaque,
        child: Row(
          children: [
            const Icon(Icons.language, size: 15, color: Brand.orange),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                t('common.language'),
                style: const TextStyle(
                  color: Brand.text,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Text(
              Lang.names[appLanguage.value]!,
              style: const TextStyle(color: Brand.muted, fontSize: 11.5),
            ),
            const Icon(Icons.chevron_right, size: 16, color: Brand.dim),
          ],
        ),
      );
    }

    return GestureDetector(
      onTap: () => _pick(context),
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: Brand.black.withValues(alpha: 0.92),
          border: Border.all(color: Brand.line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.language, size: 13, color: Brand.orange),
            const SizedBox(width: 5),
            Text(
              Lang.short(appLanguage.value),
              style: const TextStyle(
                color: Brand.text,
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
