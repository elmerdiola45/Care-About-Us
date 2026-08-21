import 'package:flutter/material.dart';

class BranchInfoCard extends StatefulWidget {
  const BranchInfoCard({super.key});

  @override
  State<BranchInfoCard> createState() => _BranchInfoCardState();
}

class _BranchInfoCardState extends State<BranchInfoCard> {
  final _formKey = GlobalKey<FormState>();
  final _pharmacyNameController = TextEditingController();
  final _branchController = TextEditingController();
  final _addressController = TextEditingController();
  final _staffController = TextEditingController();
  final _pharmacistController = TextEditingController();
  final _licenseController = TextEditingController();

  @override
  void dispose() {
    _pharmacyNameController.dispose();
    _branchController.dispose();
    _addressController.dispose();
    _staffController.dispose();
    _pharmacistController.dispose();
    _licenseController.dispose();
    super.dispose();
  }

  void _submit(BuildContext context) {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(values);
  }

  Map<String, String> get values => {
        'pharmacyName': _pharmacyNameController.text.trim(),
        'branch': _branchController.text.trim(),
        'address': _addressController.text.trim(),
        'staff': _staffController.text.trim(),
        'pharmacist': _pharmacistController.text.trim(),
        'license': _licenseController.text.trim(),
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Icon(Icons.store_outlined, color: Color(0xFF0B7B77), size: 18),
                SizedBox(width: 8),
                Text(
                  'YOUR PHARMACY DETAILS',
                  style: TextStyle(
                    color: Color(0xFF6B7280),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _field('Pharmacy Name', _pharmacyNameController, required: true),
            const SizedBox(height: 10),
            _field('Branch', _branchController, required: true),
            const SizedBox(height: 10),
            _field('Address', _addressController, required: true),
            const SizedBox(height: 10),
            _field('Staff Dispensing', _staffController, required: true),
            const SizedBox(height: 10),
            _field('Pharmacist on Duty', _pharmacistController, required: true),
            const SizedBox(height: 10),
            _field('FDA License No.', _licenseController, required: true),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF6B7280),
                      side: const BorderSide(color: Color(0xFFE5E7EB)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => _submit(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0B7B77),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                    child: const Text('Continue', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController controller, {bool required = false}) {
    return TextFormField(
      controller: controller,
      validator: required
          ? (v) => v == null || v.trim().isEmpty ? '$label is required' : null
          : null,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Color(0xFF6B7280), fontSize: 12.5, fontWeight: FontWeight.w600),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        isDense: true,
      ),
      style: const TextStyle(fontSize: 13.5, color: Color(0xFF1F2937), fontWeight: FontWeight.w600),
    );
  }
}
