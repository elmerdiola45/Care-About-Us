// price_list_page.dart
//
// Medicine Price List management page.
// - OPTION A: tap any row to edit that medicine's price directly.
// - OPTION B: "Upload" button lets the pharmacist/admin pick an
//   Excel/CSV file; shows a preview (X updated, Y new, any errors) before
//   committing anything to the database.

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../../common/theme/app_colors.dart';
import '../../common/services/laravel_api_service.dart';
import '../../common/session.dart';

class PriceListPage extends StatefulWidget {
  const PriceListPage({super.key});

  @override
  State<PriceListPage> createState() => _PriceListPageState();
}

class _PriceListPageState extends State<PriceListPage> {
  final LaravelApiService _api = LaravelApiService(
    token: AppSession.instance.token,
  );
  final TextEditingController _searchController = TextEditingController();

  List<MedicinePrice> _medicines = [];
  bool _isLoading = true;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _fetchMedicines();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Shows a message and, on session expiry, flags that the caller should
  /// route back to login. Wire `_handleSessionExpired` to whatever your app
  /// actually uses to log a user out (clear AppSession, push the login
  /// route, etc.) — left as a stub here since that's app-specific.
  void _handleError(
    Object e, {
    String fallbackPrefix = 'Something went wrong',
  }) {
    if (!mounted) return;
    final message = e is LaravelApiException
        ? e.message
        : '$fallbackPrefix: $e';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.danger),
    );
    if (e is LaravelAuthException) {
      _handleSessionExpired();
    }
  }

  void _handleSessionExpired() {
    // TODO: hook this up to your actual logout flow, e.g.:
    // AppSession.instance.clear();
    // Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
  }

  Future<void> _fetchMedicines() async {
    setState(() => _isLoading = true);
    try {
      final items = await _api.fetchProducts();
      if (!mounted) return;
      setState(() {
        _medicines = items;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _handleError(e, fallbackPrefix: 'Failed to load price list');
    }
  }

  List<MedicinePrice> get _visibleMedicines {
    if (_searchQuery.isEmpty) return _medicines;
    final q = _searchQuery.toLowerCase();
    return _medicines
        .where(
          (m) =>
              m.medicineName.toLowerCase().contains(q) ||
              (m.genericName?.toLowerCase().contains(q) ?? false) ||
              (m.brandName?.toLowerCase().contains(q) ?? false),
        )
        .toList();
  }

  // ---------------- OPTION A: single price edit ----------------

  Future<void> _openEditDialog({MedicinePrice? existing}) async {
    final nameController = TextEditingController(
      text: existing?.medicineName ?? '',
    );
    final genericController = TextEditingController(
      text: existing?.genericName ?? '',
    );
    final brandController = TextEditingController(
      text: existing?.brandName ?? '',
    );
    final dosageController = TextEditingController(
      text: existing?.dosageForm ?? '',
    );
    final priceController = TextEditingController(
      text: existing?.sellingPrice != null
          ? existing!.sellingPrice!.toStringAsFixed(2)
          : '',
    );

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(existing == null ? 'Add Medicine' : 'Edit Medicine'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              enabled:
                  existing == null, // don't let name change on an existing row
              decoration: const InputDecoration(labelText: 'Medicine Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: genericController,
              decoration: const InputDecoration(
                labelText: 'Generic Name — optional',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: brandController,
              decoration: const InputDecoration(
                labelText: 'Brand Name — optional',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: dosageController,
              decoration: const InputDecoration(
                labelText: 'Dosage/Form — optional',
                helperText: 'Strength only, e.g. 500 MG. (not "tablet").',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: priceController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Unit Price (₱) — optional',
                prefixText: '₱ ',
                helperText: 'Leave blank if the price isn\'t known yet.',
              ),
            ),
          ],
        ),
        actions: [
          if (existing != null)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'delete'),
              style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              child: const Text('Delete'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.teal,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result == 'delete' && existing != null) {
      await _confirmAndDelete(existing);
      return;
    }

    if (result != 'save') return;

    final name = nameController.text.trim();
    final generic = genericController.text.trim();
    final brand = brandController.text.trim();
    final dosage = dosageController.text.trim();
    final priceText = priceController.text.trim();

    if (name.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a medicine name.'),
          backgroundColor: AppColors.danger,
        ),
      );
      return;
    }

    // Price is optional — the backend stores it as NULL ("not yet set")
    // rather than rejecting the save, so a blank field here is valid.
    // Only reject it if something was typed and it doesn't parse.
    double? price;
    if (priceText.isNotEmpty) {
      price = double.tryParse(priceText);
      if (price == null || price < 0) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Please enter a valid, non-negative price, or leave it blank.',
            ),
            backgroundColor: AppColors.danger,
          ),
        );
        return;
      }
      // Sanity cap — catches an obvious fat-finger entry (e.g. an extra
      // digit) before it ever reaches the server.
      if (price > 999999) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'That price looks too high — please double-check it.',
            ),
            backgroundColor: AppColors.danger,
          ),
        );
        return;
      }
    }

    try {
      // updateProductPrice throws on any non-2xx response, so reaching the
      // line after it means the server actually confirmed the save.
      await _api.updateProductPrice(
        medicineName: name,
        genericName: generic.isEmpty ? null : generic,
        brandName: brand.isEmpty ? null : brand,
        dosageForm: dosage.isEmpty ? null : dosage,
        sellingPrice: price,
      );
      if (!mounted) return;
      final priceLabel = price != null
          ? '₱${price.toStringAsFixed(2)}'
          : 'not set';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$name updated (price: $priceLabel)'),
          backgroundColor: AppColors.success,
        ),
      );
      _fetchMedicines();
    } catch (e) {
      _handleError(e, fallbackPrefix: 'Failed to save');
    }
  }

  Future<void> _confirmAndDelete(MedicinePrice medicine) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Remove this medicine?'),
        content: Text(
          'This will remove "${medicine.medicineName}" from the price list. '
          'This can be undone by an admin later if needed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed != true || medicine.id == null) return;

    try {
      await _api.deleteProduct(medicine.id!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${medicine.medicineName} removed.'),
          backgroundColor: AppColors.success,
        ),
      );
      _fetchMedicines();
    } catch (e) {
      _handleError(e, fallbackPrefix: 'Failed to remove medicine');
    }
  }

  Future<void> _showRecentlyRemoved() async {
    List<MedicinePrice> trashed = [];
    bool loading = true;
    String? error;

    Future<void> load(StateSetter setSheetState) async {
      try {
        trashed = await _api.fetchTrashedProducts();
        loading = false;
        error = null;
      } catch (e) {
        loading = false;
        error = e is LaravelApiException ? e.message : 'Failed to load: $e';
      }
      setSheetState(() {});
    }

    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            if (loading && error == null && trashed.isEmpty) {
              load(setSheetState);
            }
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Recently Removed',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Restore a medicine that was removed by mistake.',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Colors.grey.shade500,
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (loading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 30),
                        child: Center(
                          child: CircularProgressIndicator(
                            color: AppColors.teal,
                          ),
                        ),
                      )
                    else if (error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Text(
                          error!,
                          style: const TextStyle(color: AppColors.danger),
                        ),
                      )
                    else if (trashed.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 30),
                        child: Center(
                          child: Text(
                            'No removed medicines.',
                            style: TextStyle(color: Colors.grey.shade500),
                          ),
                        ),
                      )
                    else
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 360),
                        child: SingleChildScrollView(
                          child: Column(
                            children: trashed.map((m) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF4F6F6),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              m.medicineName,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 13.5,
                                                color: AppColors.textPrimary,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              m.sellingPrice != null
                                                  ? '₱${m.sellingPrice!.toStringAsFixed(2)}'
                                                  : 'Price not set',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.grey.shade600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      TextButton.icon(
                                        onPressed: () async {
                                          if (m.id == null) return;
                                          try {
                                            await _api.restoreProduct(m.id!);
                                            if (!mounted) return;
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  '${m.medicineName} restored.',
                                                ),
                                                backgroundColor:
                                                    AppColors.success,
                                              ),
                                            );
                                            trashed.removeWhere(
                                              (t) => t.id == m.id,
                                            );
                                            setSheetState(() {});
                                            _fetchMedicines();
                                          } catch (e) {
                                            _handleError(
                                              e,
                                              fallbackPrefix:
                                                  'Failed to restore',
                                            );
                                          }
                                        },
                                        icon: const Icon(
                                          Icons.restore,
                                          size: 16,
                                          color: AppColors.teal,
                                        ),
                                        label: const Text(
                                          'Restore',
                                          style: TextStyle(
                                            color: AppColors.teal,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ---------------- OPTION B: bulk upload ----------------

  Future<void> _pickAndPreviewUpload() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx', 'xls', 'csv', 'txt'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    if (file.bytes == null || file.bytes!.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not read the selected file.'),
          backgroundColor: AppColors.danger,
        ),
      );
      return;
    }

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      // uploadPriceListPreview validates extension/size itself and applies
      // its own timeout — nothing is written to the database by this call,
      // it only returns a preview of what *would* change.
      final preview = await _api.uploadPriceListPreview(
        filename: file.name,
        bytes: file.bytes!,
      );

      if (!mounted) return;
      Navigator.pop(context); // close loading spinner

      await _showUploadPreviewDialog(preview);
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // close loading spinner
      _handleError(e, fallbackPrefix: 'Upload failed');
    }
  }

  Future<void> _showUploadPreviewDialog(PriceListUploadPreview preview) async {
    final toUpdate = preview.rows.where((r) => r.action == 'update').length;
    final toAdd = preview.rows.where((r) => r.action == 'new').length;
    final toRestore = preview.rows.where((r) => r.action == 'restoring').length;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Review Price List Upload'),
        scrollable: true,
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _summaryChip('$toUpdate to update', AppColors.teal),
                  _summaryChip('$toAdd new', AppColors.success),
                  if (toRestore > 0)
                    _summaryChip('$toRestore restoring', AppColors.warning),
                ],
              ),
              if (preview.errors.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.warningBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Some rows were skipped:',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppColors.warning,
                        ),
                      ),
                      const SizedBox(height: 4),
                      ...preview.errors.map(
                        (e) =>
                            Text('• $e', style: const TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              const Text(
                'Preview:',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: SingleChildScrollView(
                  child: Column(
                    children: preview.rows.map((r) {
                      final isNew = r.action == 'new';
                      final isRestoring = r.action == 'restoring';
                      final subtitle = [
                        r.genericName,
                        r.brandName,
                        r.dosageForm,
                      ].where((p) => p != null && p.isNotEmpty).join(' • ');
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    r.medicineName,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (subtitle.isNotEmpty)
                                    Text(
                                      subtitle,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade500,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            if (!isNew && r.oldPrice != null)
                              Text(
                                '₱${r.oldPrice!.toStringAsFixed(2)} → ',
                                style: TextStyle(color: Colors.grey.shade500),
                              ),
                            if (isRestoring)
                              const Padding(
                                padding: EdgeInsets.only(right: 6),
                                child: Icon(
                                  Icons.restore,
                                  size: 16,
                                  color: AppColors.warning,
                                ),
                              ),
                            Text(
                              r.newPrice != null
                                  ? '₱${r.newPrice!.toStringAsFixed(2)}'
                                  : 'Not set',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: isRestoring
                                    ? AppColors.warning
                                    : isNew
                                    ? AppColors.success
                                    : AppColors.teal,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.teal,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm & Save'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await _confirmUpload(preview.batchId);
  }

  Widget _summaryChip(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: color,
        fontWeight: FontWeight.w700,
        fontSize: 12.5,
      ),
    ),
  );

  Future<void> _confirmUpload(String batchId) async {
    try {
      // confirmPriceListUpload throws on any non-2xx response, so reaching
      // the success snackbar means the server actually committed the batch.
      await _api.confirmPriceListUpload(batchId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Upload complete.'),
          backgroundColor: AppColors.success,
        ),
      );
      _fetchMedicines();
    } catch (e) {
      _handleError(e, fallbackPrefix: 'Failed to confirm upload');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.teal),
        title: const Text(
          'Medicine Price List',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditDialog(),
        backgroundColor: AppColors.teal,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text(
          'Add Medicine',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        ),
      ),
      body: Column(
        children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF4F6F6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: TextField(
                      controller: _searchController,
                      onChanged: (v) => setState(() => _searchQuery = v),
                      decoration: InputDecoration(
                        hintText: 'Search medicine...',
                        hintStyle: TextStyle(
                          color: Colors.grey.shade400,
                          fontSize: 13.5,
                        ),
                        prefixIcon: Icon(
                          Icons.search,
                          color: Colors.grey.shade400,
                          size: 20,
                        ),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 14,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: _pickAndPreviewUpload,
                  icon: const Icon(
                    Icons.upload_file,
                    size: 18,
                    color: AppColors.teal,
                  ),
                  label: const Text(
                    'Upload',
                    style: TextStyle(
                      color: AppColors.teal,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.teal),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _showRecentlyRemoved,
                  tooltip: 'Recently Removed',
                  icon: const Icon(
                    Icons.history,
                    color: AppColors.teal,
                    size: 18,
                  ),
                  constraints: const BoxConstraints(),
                  style: IconButton.styleFrom(
                    side: const BorderSide(color: AppColors.teal),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.all(14),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.teal),
                  )
                : _visibleMedicines.isEmpty
                ? Center(
                    child: Text(
                      'No medicines in the price list yet.',
                      style: TextStyle(color: Colors.grey.shade500),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 90),
                    itemCount: _visibleMedicines.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) => _PriceCard(
                      medicine: _visibleMedicines[index],
                      onTap: () =>
                          _openEditDialog(existing: _visibleMedicines[index]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _PriceCard extends StatelessWidget {
  final MedicinePrice medicine;
  final VoidCallback onTap;

  const _PriceCard({required this.medicine, required this.onTap});

  /// Builds the "Generic • Brand • Dosage" subtitle line, skipping
  /// whichever of the three fields aren't set.
  String? get _subtitle {
    final parts = [
      medicine.genericName,
      medicine.brandName,
      medicine.dosageForm,
    ].where((p) => p != null && p.isNotEmpty).toList();
    return parts.isEmpty ? null : parts.join(' • ');
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _subtitle;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.tealPale,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.medication_outlined,
                color: AppColors.teal,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    medicine.medicineName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Text(
              medicine.sellingPrice != null
                  ? '₱${medicine.sellingPrice!.toStringAsFixed(2)}'
                  : 'Price not set',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: medicine.sellingPrice != null
                    ? AppColors.teal
                    : Colors.grey.shade400,
                fontSize: 15,
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, color: Colors.grey.shade400, size: 18),
          ],
        ),
      ),
    );
  }
}
