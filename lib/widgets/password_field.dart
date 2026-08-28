import 'package:flutter/material.dart';

import '../i18n.dart';
import '../theme.dart';

/// A password box with an eye on it.
///
/// A password typed on a phone, outdoors, one-handed, at a junction, is a
/// password typed wrong. Hiding it protects nobody standing alone in the
/// street, and it is the reason people give up on a sign-in and reset instead.
///
/// It starts hidden, because that is what somebody looking over a shoulder
/// expects, and reveals only while asked.
class PasswordField extends StatefulWidget {
  final TextEditingController controller;
  final String? hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;

  const PasswordField({
    super.key,
    required this.controller,
    this.hint,
    this.onChanged,
    this.onSubmitted,
    this.textInputAction,
  });

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      obscureText: !_shown,
      // A password manager should still recognise this as a password, and the
      // keyboard should not offer to autocorrect it into a different one.
      autocorrect: false,
      enableSuggestions: false,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      textInputAction: widget.textInputAction,
      style: const TextStyle(color: Brand.text, fontSize: 13),
      decoration: InputDecoration(
        hintText: widget.hint,
        suffixIcon: Semantics(
          button: true,
          label: _shown ? t('password.hide') : t('password.show'),
          child: IconButton(
            icon: Icon(
              _shown ? Icons.visibility_off_outlined : Icons.visibility_outlined,
              size: 18,
              color: _shown ? Brand.orange : Brand.muted,
            ),
            splashRadius: 18,
            tooltip: _shown ? t('password.hide') : t('password.show'),
            onPressed: () => setState(() => _shown = !_shown),
          ),
        ),
        // Room for the eye without the text running under it.
        suffixIconConstraints: const BoxConstraints(minWidth: 42, minHeight: 36),
      ),
    );
  }
}
