import 'package:flutter/material.dart';
import '../../../admin/data/admin_api_service.dart';
import '../../../common/theme/app_colors.dart';

enum StaffRole { dispenser, pharmacist }

/// Bottom sheet form for creating a new dispenser or pharmacist account.
class AddStaffSheet extends StatefulWidget {
  final String defaultPharmacyId;
  const AddStaffSheet({super.key, required this.defaultPharmacyId});

  static Future<bool?> show(
    BuildContext context, {
    required String defaultPharmacyId,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddStaffSheet(defaultPharmacyId: defaultPharmacyId),
    );
  }

  @override
  State<AddStaffSheet> createState() => _AddStaffSheetState();
}

class _AddStaffSheetState extends State<AddStaffSheet> {
  final AdminApiService _api = AdminApiService();
  final _formKey = GlobalKey<FormState>();

  StaffRole _role = StaffRole.dispenser;
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  late final _pharmacyIdController = TextEditingController(
    text: widget.defaultPharmacyId,
  );
  final _licenseController = TextEditingController();
  final _staffIdController = TextEditingController();

  bool _obscurePassword = true;
  bool _submitting = false;
  bool _isLoadingId = false;

  Map<String, String> _fieldErrors = {};
  String? _generalError;

  @override
  void initState() {
    super.initState();
    _loadNextStaffId();
    // Rebuilds StrengthIndicator on every keystroke — without this, its
    // `password: _passwordController.text` argument is only read at
    // whatever moment the widget tree happens to rebuild for some OTHER
    // reason. Toggling the "show password" eye icon does call setState
    // (to flip _obscurePassword), which is why the strength bar looked
    // like it only ever updated at that exact moment — it wasn't
    // reacting to the toggle, it was just piggybacking on being the
    // first rebuild since the user last typed. Typing alone triggered
    // no rebuild at all, so the bar sat stale (or fully empty, since it
    // was last built when the field actually was empty) the entire time
    // the password was hidden.
    _passwordController.addListener(_onPasswordChanged);
  }

  void _onPasswordChanged() => setState(() {});

  @override
  void dispose() {
    _passwordController.removeListener(_onPasswordChanged);
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _pharmacyIdController.dispose();
    _licenseController.dispose();
    _staffIdController.dispose();
    super.dispose();
  }

  String? _requiredValidator(String? value) {
    if (value == null || value.trim().isEmpty) return 'Required';
    return null;
  }

  String? _emailValidator(String? value) {
    if (value == null || value.trim().isEmpty) return 'Required';
    final emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    if (!emailRegex.hasMatch(value.trim())) return 'Enter a valid email';
    return null;
  }

  Future<void> _loadNextStaffId() async {
    setState(() => _isLoadingId = true);
    try {
      final role = _role == StaffRole.dispenser ? 'dispenser' : 'pharmacist';
      final nextId = await _api.fetchNextStaffId(role);
      if (mounted) {
        setState(() {
          _staffIdController.text = nextId;
          _isLoadingId = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingId = false);
      }
    }
  }

  Future<void> _submit() async {
    setState(() {
      _fieldErrors = {};
      _generalError = null;
    });

    if (!_formKey.currentState!.validate()) return;

    setState(() => _submitting = true);

    try {
      await _api.createStaff(
        role: _role == StaffRole.dispenser ? 'dispenser' : 'pharmacist',
        firstName: _firstNameController.text.trim(),
        lastName: _lastNameController.text.trim(),
        email: _emailController.text.trim(),
        password: _passwordController.text,
        pharmacyId: _pharmacyIdController.text.trim(),
        licenseNumber: _licenseController.text.trim().isEmpty
            ? null
            : _licenseController.text.trim(),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Staff member created successfully'),
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
    // Clamp to zero — on Flutter Web the engine can report a negative
    // viewInsets value during keyboard-dismiss viewport resizing, which
    // triggers an assertion crash.  A zero inset is a safe fallback.
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
                        color: AppColors.divider,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const Text(
                    'Add Staff Member',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AppColors.ink,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _role == StaffRole.dispenser
                        ? 'Dispenser — Pharmacy Assistant'
                        : 'Pharmacist — Licensed Staff',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.muted,
                    ),
                  ),
                  const SizedBox(height: 16),
                  RoleToggle(
                    role: _role,
                    onChanged: (r) {
                      setState(() => _role = r);
                      _loadNextStaffId();
                    },
                  ),
                  const SizedBox(height: 16),
                  if (_isLoadingId)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.teal600,
                          ),
                        ),
                      ),
                    ),
                  if (!_isLoadingId)
                    LabeledField(
                      label: _role == StaffRole.pharmacist
                          ? 'Pharmacist ID'
                          : 'Dispenser ID',
                      controller: _staffIdController,
                      readOnly: true,
                    ),
                  const SizedBox(height: 12),
                  if (_generalError != null) ...[
                    ErrorBanner(message: _generalError!),
                    const SizedBox(height: 12),
                  ],
                  LabeledField(
                    label: 'First Name',
                    controller: _firstNameController,
                    validator: _requiredValidator,
                    serverError: _fieldErrors['first_name'],
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                  LabeledField(
                    label: 'Last Name',
                    controller: _lastNameController,
                    validator: _requiredValidator,
                    serverError: _fieldErrors['last_name'],
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                  LabeledField(
                    label: 'Email',
                    controller: _emailController,
                    validator: _emailValidator,
                    serverError: _fieldErrors['email'],
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                  LabeledField(
                    label: 'Password',
                    controller: _passwordController,
                    validator: _requiredValidator,
                    serverError: _fieldErrors['password'],
                    obscureText: _obscurePassword,
                    textInputAction: TextInputAction.next,
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        size: 18,
                        color: AppColors.muted,
                      ),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  StrengthIndicator(password: _passwordController.text),
                  const SizedBox(height: 12),
                  LabeledField(
                    label: _role == StaffRole.pharmacist
                        ? 'License Number'
                        : 'License Number (optional)',
                    controller: _licenseController,
                    validator: _role == StaffRole.pharmacist
                        ? _requiredValidator
                        : null,
                    serverError: _fieldErrors['license_number'],
                    textInputAction: TextInputAction.done,
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _submitting
                              ? null
                              : () => Navigator.of(context).pop(false),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.muted,
                            side: const BorderSide(color: AppColors.line),
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
                                  'Create',
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

class RoleToggle extends StatelessWidget {
  final StaffRole role;
  final ValueChanged<StaffRole> onChanged;
  const RoleToggle({super.key, required this.role, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _RoleCard(
            label: 'Dispenser',
            subtitle: 'Pharmacy Assistant',
            selected: role == StaffRole.dispenser,
            onTap: () => onChanged(StaffRole.dispenser),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _RoleCard(
            label: 'Pharmacist',
            subtitle: 'Licensed Staff',
            selected: role == StaffRole.pharmacist,
            onTap: () => onChanged(StaffRole.pharmacist),
          ),
        ),
      ],
    );
  }
}

class _RoleCard extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  const _RoleCard({
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? AppColors.teal700 : AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppColors.teal700 : AppColors.line,
            width: 1.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : AppColors.ink,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: selected ? AppColors.mint100 : AppColors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class StrengthIndicator extends StatelessWidget {
  final String password;
  const StrengthIndicator({super.key, required this.password});

  static int _getStrength(String password) {
    if (password.isEmpty) return 0;
    int strength = 0;
    if (password.length >= 6) strength++;
    if (password.length >= 8) strength++;
    if (password.contains(RegExp(r'[A-Z]'))) strength++;
    if (password.contains(RegExp(r'[a-z]'))) strength++;
    if (password.contains(RegExp(r'[0-9]'))) strength++;
    if (password.contains(RegExp(r'[!@#\$%^&*(),.?":{}|<>]'))) strength++;
    return strength.clamp(0, 4);
  }

  static Color _getStrengthColor(int strength) {
    switch (strength) {
      case 0:
        return AppColors.divider;
      case 1:
        return AppColors.danger;
      case 2:
        return AppColors.red;
      case 3:
        return AppColors.teal600;
      case 4:
        return AppColors.green;
      default:
        return AppColors.divider;
    }
  }

  static String _getStrengthLabel(int strength) {
    switch (strength) {
      case 0:
        return '';
      case 1:
        return 'Weak';
      case 2:
        return 'Fair';
      case 3:
        return 'Good';
      case 4:
        return 'Strong';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final strength = _getStrength(password);
    final color = _getStrengthColor(strength);
    final label = _getStrengthLabel(strength);
    final segments = 4;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Row(
                children: List.generate(segments, (index) {
                  final filled = index < strength;
                  return Expanded(
                    child: Container(
                      height: 4,
                      margin: EdgeInsets.only(
                        right: index < segments - 1 ? 3 : 0,
                      ),
                      decoration: BoxDecoration(
                        color: filled ? color : AppColors.divider,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  );
                }),
              ),
            ),
            if (label.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class LabeledField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? Function(String?)? validator;
  final String? serverError;
  final bool obscureText;
  final bool readOnly;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Widget? suffixIcon;

  const LabeledField({
    super.key,
    required this.label,
    required this.controller,
    this.validator,
    this.serverError,
    this.obscureText = false,
    this.readOnly = false,
    this.keyboardType,
    this.textInputAction,
    this.suffixIcon,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: AppColors.muted,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          validator: readOnly ? null : validator,
          obscureText: obscureText,
          readOnly: readOnly,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          style: TextStyle(
            fontSize: 14,
            color: readOnly ? AppColors.muted : AppColors.ink,
          ),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: readOnly ? AppColors.divider : AppColors.surface,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 14,
            ),
            suffixIcon: suffixIcon,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: readOnly ? AppColors.divider : AppColors.line,
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: readOnly ? AppColors.divider : AppColors.line,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(
                color: AppColors.teal600,
                width: 1.5,
              ),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.danger),
            ),
          ),
        ),
        if (serverError != null) ...[
          const SizedBox(height: 4),
          Text(
            serverError!,
            style: const TextStyle(fontSize: 11.5, color: AppColors.danger),
          ),
        ],
      ],
    );
  }
}

class ErrorBanner extends StatelessWidget {
  final String message;
  const ErrorBanner({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.dangerBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 18, color: AppColors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 12.5, color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}
