import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../i18n.dart';
import '../theme.dart';
import '../widgets/language_button.dart';
import 'register_screen.dart';

/// Signing in as a motari. Email and password, with the two gates a customer
/// account can hit handled in place: an authenticator code, or an email that
/// was never verified.
class SignInScreen extends StatefulWidget {
  final Api api;
  final VoidCallback onSignedIn;

  /// Back to the passenger side, for someone who tapped "I drive" by mistake.
  final VoidCallback? onBack;

  const SignInScreen({
    super.key,
    required this.api,
    required this.onSignedIn,
    this.onBack,
  });

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

enum _Step { credentials, totp, verifyEmail }

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();

  _Step _step = _Step.credentials;
  String? _tempToken;
  bool _busy = false;
  String? _error;
  String? _notice;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = t('common.error'));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _signIn() => _run(() async {
        final result = await widget.api.signIn(_email.text.trim(), _password.text);
        if (result['requires2fa'] == true && result['tempToken'] != null) {
          setState(() {
            _tempToken = result['tempToken'] as String;
            _step = _Step.totp;
          });
        } else if (result['requiresEmailVerification'] == true) {
          await widget.api.resendCode(_email.text.trim());
          setState(() {
            _step = _Step.verifyEmail;
            _notice = t('signin.not_verified');
          });
        } else if (widget.api.signedIn) {
          widget.onSignedIn();
        } else {
          setState(() => _error = t('signin.finish_on_web'));
        }
      });

  Future<void> _submitTotp() => _run(() async {
        await widget.api.verifyTotp(_tempToken!, _code.text.trim());
        widget.onSignedIn();
      });

  Future<void> _submitEmailCode() => _run(() async {
        await widget.api.verifyEmail(_email.text.trim(), _code.text.trim());
        // Verified: repeat the login to get real tokens.
        final result = await widget.api.signIn(_email.text.trim(), _password.text);
        if (result['requires2fa'] == true && result['tempToken'] != null) {
          setState(() {
            _tempToken = result['tempToken'] as String;
            _code.clear();
            _step = _Step.totp;
          });
        } else if (widget.api.signedIn) {
          widget.onSignedIn();
        }
      });

  Future<void> _openRegister() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RegisterScreen(
        api: widget.api,
        onRegistered: () {
          Navigator.of(context).pop();
          widget.onSignedIn();
        },
      ),
    ));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final codeStep = _step != _Step.credentials;
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
        const Positioned(top: 6, right: 10, child: LanguageButton()),
        if (widget.onBack != null)
          Positioned(
            top: 2,
            left: 4,
            child: IconButton(
              onPressed: widget.onBack,
              icon: const Icon(Icons.arrow_back, size: 19, color: Brand.muted),
            ),
          ),
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(22),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: Brand.orange,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.two_wheeler, color: Colors.black, size: 21),
                      ),
                      const SizedBox(width: 11),
                      Text(
                        t('app.name'),
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w900, color: Brand.text),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    t('signin.subtitle'),
                    style: const TextStyle(color: Brand.muted, fontSize: 12.5),
                  ),
                  const SizedBox(height: 24),

                  if (_notice != null) ...[
                    Text(_notice!, style: const TextStyle(color: Brand.green, fontSize: 12)),
                    const SizedBox(height: 10),
                  ],

                  if (!codeStep) ...[
                    Text(t('signin.email'), style: Brand.micro),
                    const SizedBox(height: 5),
                    TextField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      style: const TextStyle(color: Brand.text, fontSize: 13),
                      decoration: InputDecoration(hintText: t('signin.email_hint')),
                    ),
                    const SizedBox(height: 12),
                    Text(t('signin.password'), style: Brand.micro),
                    const SizedBox(height: 5),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      style: const TextStyle(color: Brand.text, fontSize: 13),
                      onSubmitted: (_) => _busy ? null : _signIn(),
                    ),
                  ] else ...[
                    Text(
                      _step == _Step.totp ? t('signin.totp_code') : t('signin.email_code'),
                      style: Brand.micro,
                    ),
                    const SizedBox(height: 5),
                    TextField(
                      controller: _code,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6),
                      ],
                      textAlign: TextAlign.center,
                      autofocus: true,
                      style: const TextStyle(
                        color: Brand.text,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 7,
                      ),
                      decoration: const InputDecoration(hintText: '000000'),
                    ),
                  ],

                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(_error!, style: const TextStyle(color: Brand.red, fontSize: 12)),
                  ],

                  const SizedBox(height: 18),
                  PrimaryButton(
                    label: _busy
                        ? t('signin.signing_in')
                        : codeStep
                            ? t('signin.verify')
                            : t('signin.sign_in'),
                    onPressed: _busy
                        ? null
                        : _step == _Step.credentials
                            ? _signIn
                            : _step == _Step.totp
                                ? _submitTotp
                                : _submitEmailCode,
                  ),

                  if (_step == _Step.verifyEmail) ...[
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() => widget.api.resendCode(_email.text.trim())),
                      child: Text(
                        t('signin.resend'),
                        style: const TextStyle(
                            color: Brand.muted, fontSize: 11.5, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],

                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Expanded(child: Divider(color: Brand.line, height: 1)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Text(t('signin.or'), style: Brand.micro),
                      ),
                      const Expanded(child: Divider(color: Brand.line, height: 1)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _busy ? null : _openRegister,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Brand.orange,
                      side: const BorderSide(color: Color(0xFF7C3A10)),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Text(
                      t('signin.register').toUpperCase(),
                      style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.6),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    t('signin.register_hint'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Brand.dim, fontSize: 11, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
        ),
          ],
        ),
      ),
    );
  }
}
