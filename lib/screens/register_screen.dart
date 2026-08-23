import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../i18n.dart';
import '../theme.dart';
import '../widgets/language_button.dart';

/// Opening a motari account without leaving the app.
///
/// It asks for exactly what the website's own registration asks for, in the
/// same order and with the same rules, because both write to the same account:
/// a full legal name, the plate, the moto, a phone, an email and a password.
/// The moto is saved the moment the email is verified, so a motari who
/// registers here lands ready to work rather than facing the same questions
/// again on the working screen.
class RegisterScreen extends StatefulWidget {
  final Api api;
  final VoidCallback onRegistered;
  const RegisterScreen({super.key, required this.api, required this.onRegistered});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _name = TextEditingController();
  final _plate = TextEditingController();
  final _brand = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();

  /// The code step only exists once the account does.
  bool _created = false;
  bool _busy = false;
  String? _error;
  String? _notice;

  @override
  void dispose() {
    _name.dispose();
    _plate.dispose();
    _brand.dispose();
    _email.dispose();
    _phone.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  bool get _canCreate =>
      !_busy &&
      // Two words, as the website asks: a legal name is not one word.
      _name.text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length >= 2 &&
      _plate.text.trim().length >= 4 &&
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_email.text.trim()) &&
      RegExp(r'^07\d{8}$').hasMatch(_phone.text.trim()) &&
      _password.text.length >= 8;

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

  Future<void> _create() => _run(() async {
        await widget.api.register(
          name: _name.text.trim(),
          email: _email.text.trim(),
          phone: _phone.text.trim(),
          password: _password.text,
        );
        setState(() {
          _created = true;
          _notice = t('register.code_sent', {'email': _email.text.trim()});
        });
      });

  /// The code proves the address; the sign in that follows puts a session on
  /// the device; and the moto is written to the account before anyone is sent
  /// to the working screen, so it opens ready rather than asking again.
  Future<void> _verify() => _run(() async {
        await widget.api.verifyEmail(_email.text.trim(), _code.text.trim());
        await widget.api.signIn(_email.text.trim(), _password.text);
        if (!widget.api.signedIn) {
          setState(() => _error = t('register.signin_yourself'));
          return;
        }
        await widget.api.saveProfile(
          plateNumber: _plate.text.trim(),
          brandModel: _brand.text.trim().isEmpty ? null : _brand.text.trim(),
          legalName: _name.text.trim(),
        );
        widget.onRegistered();
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Brand.black,
        surfaceTintColor: Brand.black,
        iconTheme: const IconThemeData(color: Brand.text, size: 19),
        title: Text(
          t('register.title'),
          style: const TextStyle(
              fontSize: 16, fontWeight: FontWeight.w900, color: Brand.text),
        ),
        actions: const [
          Padding(padding: EdgeInsets.only(right: 12), child: LanguageButton()),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _created ? t('register.check_email') : t('register.subtitle'),
                  style: const TextStyle(color: Brand.muted, fontSize: 12.5, height: 1.4),
                ),
                const SizedBox(height: 18),

                if (_notice != null) ...[
                  Text(_notice!,
                      style: const TextStyle(color: Brand.green, fontSize: 12, height: 1.4)),
                  const SizedBox(height: 12),
                ],

                if (!_created) ...[
                  Text(t('register.name'), style: Brand.micro),
                  const SizedBox(height: 5),
                  TextField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(color: Brand.text, fontSize: 13),
                    decoration: InputDecoration(hintText: t('register.name_hint')),
                  ),
                  const SizedBox(height: 12),

                  Text(t('register.plate'), style: Brand.micro),
                  const SizedBox(height: 5),
                  TextField(
                    controller: _plate,
                    textCapitalization: TextCapitalization.characters,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(color: Brand.text, fontSize: 13),
                    decoration: InputDecoration(hintText: t('panel.plate')),
                  ),
                  const SizedBox(height: 12),

                  Text(t('register.brand'), style: Brand.micro),
                  const SizedBox(height: 5),
                  TextField(
                    controller: _brand,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(color: Brand.text, fontSize: 13),
                    decoration: InputDecoration(hintText: t('panel.brand')),
                  ),
                  const SizedBox(height: 12),

                  Text(t('signin.email'), style: Brand.micro),
                  const SizedBox(height: 5),
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(color: Brand.text, fontSize: 13),
                    decoration: InputDecoration(hintText: t('signin.email_hint')),
                  ),
                  const SizedBox(height: 12),

                  Text(t('register.phone'), style: Brand.micro),
                  const SizedBox(height: 5),
                  TextField(
                    controller: _phone,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(10),
                    ],
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(color: Brand.text, fontSize: 13),
                    decoration: const InputDecoration(hintText: '07xxxxxxxx'),
                  ),
                  const SizedBox(height: 12),

                  Text(t('signin.password'), style: Brand.micro),
                  const SizedBox(height: 5),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(color: Brand.text, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(t('register.password_rule'), style: Brand.micro),
                ] else ...[
                  Text(t('signin.email_code'), style: Brand.micro),
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
                    onChanged: (_) => setState(() {}),
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
                      ? t('register.working')
                      : _created
                          ? t('register.verify')
                          : t('register.create'),
                  onPressed: _created
                      ? (_busy || _code.text.trim().length < 4 ? null : _verify)
                      : (_canCreate ? _create : null),
                ),

                if (_created) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                              await widget.api.resendCode(_email.text.trim());
                              setState(() => _notice = t('register.code_resent'));
                            }),
                    child: Text(
                      t('signin.resend'),
                      style: const TextStyle(
                          color: Brand.muted, fontSize: 11.5, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],

                const SizedBox(height: 14),
                Text(
                  t('register.same_as_web'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Brand.dim, fontSize: 11, height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
