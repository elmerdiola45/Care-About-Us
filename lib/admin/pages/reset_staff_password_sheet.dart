import 'dart:math';

import 'package:flutter/material.dart';
import '../../../admin/data/admin_api_service.dart';
import '../../../admin/models/admin_models.dart';
import '../../../common/theme/app_colors.dart';
import 'add_staff_sheet.dart' show LabeledField, ErrorBanner, StrengthIndicator;

/// Admin-only bottom sheet for setting a new password on another staff
/// member's account. The existing password is never fetched or shown —
/// this only ever writes a new one. Pre-fills a securely-generated random
/// password (covers "trigger a secure reset") that the admin can edit or
/// regenerate before confirming (covers "set a temporary/new password"),
/// rather than building two separate flows for the same underlying write.
class ResetStaffPasswordSheet extends StatefulWidget {
  final StaffAccount staff;
  final AdminApiService api;

  const ResetStaffPasswordSheet({
    super.key,
    required this.staff,
    required this.api,
  });

  static Future<bool?> show(
    BuildContext context, {
    required StaffAccount staff,
    required AdminApiService api,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ResetStaffPasswordSheet(staff: staff, api: api),
    );
  }

  @override
  State<ResetStaffPasswordSheet> createState() =>
      _ResetStaffPasswordSheetState();
}

class _ResetStaffPasswordSheetState extends State<ResetStaffPasswordSheet> {
  final _formKey = GlobalKey<FormState>();
  late final _passwordController = TextEditingController(
    text: _generateSecurePassword(),
  );

  bool _obscurePassword = true;
  bool _submitting = false;
  Map<String, String> _fieldErrors = {};
  String? _generalError;

  static String _generateSecurePassword({int length = 14}) {
    const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
    const lower = 'abcdefghijkmnpqrstuvwxyz';
    const digits = '23456789';
    const symbols = '!@#%^&*-_=+';
    const all = upper + lower + digits + symbols;
    final rand = Random.secure();

    // Guarantee at least one of each character class, then fill the rest
    // randomly and shuffle — avoids a password that happens to pass length
    // but fails the strength indicator's class checks.
    final chars = <String>[
      upper[rand.nextInt(upper.length)],
      lower[rand.nextInt(lower.length)],
      digits[rand.nextInt(digits.length)],
      symbols[rand.nextInt(symbols.length)],
    ];
    for (var i = chars.length; i < length; i++) {
      chars.add(all[rand.nextInt(all.length)]);
    }
    chars.shuffle(rand);
    return chars.join();
  }

  @override
  void initState() {
    super.initState();
    _passwordController.addListener(_onPasswordChanged);
  }

  void _onPasswordChanged() => setState(() {});

  @override
  void dispose() {
    _passwordController.removeListener(_onPasswordChanged);
    _passwordController.dispose();
    super.dispose();
  }

  void _regenerate() {
    setState(() {
      _passwordController.text = _generateSecurePassword();
    });
  }

  String? _requiredValidator(String? v) {
    if (v == null || v.trim().isEmpty) return 'Required';
    if (v.length < 8) return 'Must be at least 8 characters';
    return null;
  }

  Future<void> _submit() async {
    setState(() {
      _fieldErrors = {};
      _generalError = null;
    });

    if (!_formKey.currentState!.validate()) return;

    setState(() => _submitting = true);

    try {
      await widget.api.resetStaffPassword(
        widget.staff.id,
        _passwordController.text,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Password reset for ${widget.staff.name}'),
          backgroundColor: AppColors.teal700,
          behavior: SnackBarBehavior.floating,
        ),
      );
      Navigator.of(context).pop(true);
    } on StaffValidationException catch (e) {
      if (!mounted) return;
      setState(() {
        _fieldErrors = Map<String, String>.from(
          e.fieldErrors.map((k, v) => MapEntry(k, v.join(', '))),
        );
        _generalError = e.fieldErrors.isEmpty ? e.message : null;
        _submitting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _generalError = "Couldn't reach the backend — $e";
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = (MediaQuery.of(
      context,
    ).viewInsets.bottom).clamp(0.0, double.infinity);

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: AppColors.border,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const Text(
                    'Reset Password',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${widget.staff.name} · ${widget.staff.email}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textFaint,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_generalError != null) ...[
                    ErrorBanner(message: _generalError!),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: LabeledField(
                          label: 'New Password',
                          controller: _passwordController,
                          validator: _requiredValidator,
                          serverError: _fieldErrors['password'],
                          obscureText: _obscurePassword,
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 18,
                              color: AppColors.textFaint,
                            ),
                            tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                            onPressed: () => setState(
                              () => _obscurePassword = !_obscurePassword,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  StrengthIndicator(password: _passwordController.text),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _submitting ? null : _regenerate,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Generate New'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.teal700,
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 0),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'The staff member will need this password to log in. '
                    'Share it with them directly — it will not be shown '
                    'again after this screen closes.',
                    style: TextStyle(fontSize: 11.5, color: AppColors.textFaint),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _submitting
                              ? null
                              : () => Navigator.of(context).pop(false),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.textFaint,
                            side: const BorderSide(color: AppColors.border),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text(
                            'Cancel',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _submitting ? null : _submit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.teal700,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: _submitting
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text(
                                  'Reset Password',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
