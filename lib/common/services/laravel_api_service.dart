//laravel_api_service.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../../admin/models/admin_models.dart';
import '../../pharmacist/models/dispense_alert.dart';
import 'app_config.dart';

/// Base exception for all Laravel API errors.
class LaravelApiException implements Exception {
  final int? statusCode;
  final String message;
  const LaravelApiException(this.message, {this.statusCode});

  @override
  String toString() => 'LaravelApiException($statusCode): $message';
}

/// Thrown specifically on 401 responses so callers can distinguish
/// "session expired, please log in again" from other API failures.
class LaravelAuthException extends LaravelApiException {
  const LaravelAuthException([
    super.message = 'Session expired. Please log in again.',
  ]) : super(statusCode: 401);
}

// ---------------------------------------------------------------------------
// Safe JSON coercion helpers (consolidated so every callsite behaves the same)
// ---------------------------------------------------------------------------

Map<String, dynamic> _safeMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return <String, dynamic>{};
}

List<dynamic> _safeList(dynamic value) {
  if (value is List) return value;
  return const [];
}

int _safeInt(dynamic value, [int fallback = 0]) {
  if (value == null) return fallback;
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is num) return value.toInt();
  final parsed = int.tryParse(value.toString());
  return parsed ?? fallback;
}

double _safeDouble(dynamic value, [double fallback = 0.0]) {
  if (value == null) return fallback;
  if (value is double) return value;
  if (value is num) return value.toDouble();
  final parsed = double.tryParse(value.toString());
  return parsed ?? fallback;
}

/// Accepts real booleans as well as the truthy/falsy shapes PHP/Laravel
/// commonly serializes (1/0, "1"/"0", "true"/"false"), instead of silently
/// defaulting to false whenever the backend sends anything but a literal bool.
bool _safeBool(dynamic value, [bool fallback = false]) {
  if (value == null) return fallback;
  if (value is bool) return value;
  if (value is num) return value != 0;
  final str = value.toString().toLowerCase().trim();
  if (str == 'true' || str == '1') return true;
  if (str == 'false' || str == '0') return false;
  return fallback;
}

T _safeEnumValue<T>(Iterable<T> values, dynamic raw, T fallback) {
  if (raw == null) return fallback;
  final str = raw.toString().toLowerCase();
  for (final v in values) {
    if (v.toString().toLowerCase() == str) return v;
  }
  return fallback;
}

DateTime? _safeDateTime(dynamic value) {
  if (value == null) return null;
  return DateTime.tryParse(value.toString());
}

// ---------------------------------------------------------------------------
// Models (unchanged field shapes — only parsing internals hardened)
// ---------------------------------------------------------------------------

class LaravelPrescription {
  final String id;
  final String ocrCode;
  final String patientName;
  final int patientAge;
  final String patientGender;
  final bool isSenior;
  final String? oscaId;
  final String doctorName;
  final String licenseNo;
  final String ptNo;
  final String s2;
  final String? patientAddress;
  final DateTime dateTime;
  final List<LaravelPrescriptionItem> items;
  final double totalPrice;
  final String status;
  final String dispensingStatus;
  final String? rawExtractedText;
  final String? qrToken;
  final String? patientId;
  final String? pharmacyId;
  final DateTime? qrExpiresAt;
  final String? imageUrl;

  const LaravelPrescription({
    required this.id,
    required this.ocrCode,
    required this.patientName,
    required this.patientAge,
    required this.patientGender,
    this.isSenior = false,
    this.oscaId,
    required this.doctorName,
    this.licenseNo = '',
    this.ptNo = '',
    this.s2 = '',
    this.patientAddress,
    required this.dateTime,
    required this.items,
    required this.totalPrice,
    required this.status,
    this.dispensingStatus = 'pending',
    this.rawExtractedText,
    this.qrToken,
    this.patientId,
    this.pharmacyId,
    this.qrExpiresAt,
    this.imageUrl,
  });

  factory LaravelPrescription.fromJson(Map<String, dynamic> json) {
    final items = _safeList(
      json['items'],
    ).map((e) => LaravelPrescriptionItem.fromJson(_safeMap(e))).toList();

    return LaravelPrescription(
      id: json['id']?.toString() ?? '',
      ocrCode:
          json['ocr_code']?.toString() ?? json['ocrCode']?.toString() ?? '',
      patientName:
          json['patient_name']?.toString() ??
          json['patientName']?.toString() ??
          'Unknown Patient',
      patientAge: _safeInt(json['patient_age'] ?? json['patientAge']),
      patientGender:
          json['patient_gender']?.toString() ??
          json['patientGender']?.toString() ??
          'M',
      isSenior: _safeBool(json['is_senior']),
      oscaId: json['osca_id']?.toString() ?? json['oscaId']?.toString(),
      doctorName:
          json['doctor_name']?.toString() ??
          json['doctorName']?.toString() ??
          'Unknown Doctor',
      licenseNo:
          json['license_no']?.toString() ?? json['licenseNo']?.toString() ?? '',
      ptNo: json['pt_no']?.toString() ?? json['ptNo']?.toString() ?? '',
      s2: json['s2']?.toString() ?? '',
      patientAddress:
          json['patient_address']?.toString() ??
          json['patientAddress']?.toString(),
      dateTime: _safeDateTime(json['date_time']) ?? DateTime.now(),
      items: items,
      totalPrice: _safeDouble(json['total_price']),
      status: json['status']?.toString() ?? 'pending',
      dispensingStatus: json['dispensing_status']?.toString() ?? 'pending',
      rawExtractedText: json['raw_extracted_text']?.toString(),
      qrToken: json['qr_token']?.toString(),
      patientId:
          json['patient_id']?.toString() ?? json['patientId']?.toString(),
      pharmacyId:
          json['pharmacy_id']?.toString() ?? json['pharmacyId']?.toString(),
      qrExpiresAt: _safeDateTime(json['qr_expires_at']),
      imageUrl: json['image_url']?.toString() ?? json['imageUrl']?.toString(),
    );
  }
}

class LaravelPrescriptionItem {
  final String id;
  final String name;
  final String? originalOcrName;
  final String? genericName;
  final String? brandName;
  final String? dosage;
  final int quantity;
  final int disposedQuantity;
  final double unitPrice;
  final bool isEssential;
  final String? duration;
  final int daysSupply;

  /// Live stock remaining for this medicine at the dispensing pharmacy,
  /// as of when this prescription was fetched — see
  /// PrescriptionController::format()'s `available_stock`. Null means
  /// this medicine isn't tracked in inventory at all (no matching
  /// product, or no stock batch ever recorded for it here), which the
  /// dispense screen treats as "don't cap/block on stock" rather than
  /// as zero.
  final int? availableStock;

  const LaravelPrescriptionItem({
    required this.id,
    required this.name,
    this.originalOcrName,
    this.genericName,
    this.brandName,
    this.dosage,
    required this.quantity,
    this.disposedQuantity = 0,
    this.unitPrice = 0.0,
    this.isEssential = true,
    this.duration,
    this.daysSupply = 0,
    this.availableStock,
  });

  factory LaravelPrescriptionItem.fromJson(Map<String, dynamic> json) {
    return LaravelPrescriptionItem(
      id: json['id']?.toString() ?? '',
      name:
          json['name']?.toString() ??
          json['medicine_name']?.toString() ??
          'Unknown',
      originalOcrName: json['original_ocr_name']?.toString(),
      // The backend already returns these separately (see
      // PrescriptionController@show) — they were never being read here,
      // which is why generic/brand name were always blank downstream in
      // the dispensing report even though the data existed server-side.
      genericName: json['generic_name']?.toString(),
      brandName: json['brand_name']?.toString(),
      dosage: json['dosage']?.toString(),
      quantity: _safeInt(
        json['quantity'] ??
            json['quantity_prescribed'] ??
            json['prescribed_quantity'] ??
            json['prescribedQuantity'] ??
            json['initial_quantity'] ??
            json['initialQuantity'] ??
            json['total_quantity'],
        1,
      ),
      disposedQuantity: _safeInt(
        json['disposed_quantity'] ??
            json['disposedQuantity'] ??
            json['dispensed_quantity'] ??
            json['dispensedQuantity'] ??
            json['quantity_dispensed'] ??
            json['quantityDispensed'] ??
            json['quantity_served'] ??
            json['quantityServed'] ??
            json['served'] ??
            json['given'] ??
            json['dispensed'] ??
            json['qty_dispensed'] ??
            json['qtyDispensed'],
      ),
      unitPrice: _safeDouble(json['unit_price']),
      isEssential: _safeBool(json['is_essential'], true),
      duration: json['duration']?.toString(),
      daysSupply: _safeInt(json['days_supply']),
      availableStock: json['available_stock'] == null
          ? null
          : _safeInt(json['available_stock']),
    );
  }
}

class LaravelQrTokenResponse {
  final String token;
  final String ocrCode;
  final String patientName;
  final int patientAge;
  final String patientGender;
  final String doctorName;
  final String licenseNo;
  final String ptNo;
  final String s2;
  final String? patientAddress;
  final DateTime dateTime;
  final List<LaravelVerifiedMedicine> medicines;
  final double totalPrice;
  final bool valid;
  final String? message;
  final String verifyUrl;

  const LaravelQrTokenResponse({
    required this.token,
    required this.ocrCode,
    required this.patientName,
    required this.patientAge,
    required this.patientGender,
    required this.doctorName,
    required this.licenseNo,
    required this.ptNo,
    required this.s2,
    this.patientAddress,
    required this.dateTime,
    required this.medicines,
    required this.totalPrice,
    required this.valid,
    this.message,
    required this.verifyUrl,
  });

  factory LaravelQrTokenResponse.fromJson(Map<String, dynamic> json) {
    final medicines = _safeList(
      json['medicines'],
    ).map((e) => LaravelVerifiedMedicine.fromJson(_safeMap(e))).toList();

    return LaravelQrTokenResponse(
      token: json['token']?.toString() ?? '',
      ocrCode: json['ocr_code']?.toString() ?? '',
      patientName: json['patient_name']?.toString() ?? 'Unknown Patient',
      patientAge: _safeInt(json['patient_age']),
      patientGender: json['patient_gender']?.toString() ?? 'M',
      doctorName: json['doctor_name']?.toString() ?? 'Unknown Doctor',
      licenseNo: json['license_no']?.toString() ?? '',
      ptNo: json['pt_no']?.toString() ?? '',
      s2: json['s2']?.toString() ?? '',
      patientAddress: json['patient_address']?.toString(),
      dateTime: _safeDateTime(json['date_time']) ?? DateTime.now(),
      medicines: medicines,
      totalPrice: _safeDouble(json['total_price']),
      valid: _safeBool(json['valid'], true),
      message: json['message']?.toString(),
      verifyUrl:
          json['verify_url']?.toString() ?? json['verifyUrl']?.toString() ?? '',
    );
  }
}

class LaravelVerifiedPrescription {
  final String token;
  final String ocrCode;
  final String patientName;
  final int patientAge;
  final String patientGender;
  final String doctorName;
  final String licenseNo;
  final String ptNo;
  final String s2;
  final String? patientAddress;
  final DateTime dateTime;
  final List<LaravelVerifiedMedicine> medicines;
  final double totalPrice;
  final bool valid;
  final String? message;
  final String? verifyUrl;

  const LaravelVerifiedPrescription({
    required this.token,
    required this.ocrCode,
    required this.patientName,
    required this.patientAge,
    required this.patientGender,
    required this.doctorName,
    required this.licenseNo,
    required this.ptNo,
    required this.s2,
    this.patientAddress,
    required this.dateTime,
    required this.medicines,
    required this.totalPrice,
    required this.valid,
    this.message,
    this.verifyUrl,
  });

  factory LaravelVerifiedPrescription.fromJson(Map<String, dynamic> json) {
    final rawPayload = json['data'];
    final payload = rawPayload is Map
        ? Map<String, dynamic>.from(rawPayload)
        : json;
    final medicines = _safeList(
      payload['medicines'],
    ).map((e) => LaravelVerifiedMedicine.fromJson(_safeMap(e))).toList();

    return LaravelVerifiedPrescription(
      token: json['token']?.toString() ?? '',
      ocrCode:
          payload['ocr_code']?.toString() ??
          payload['ocrCode']?.toString() ??
          '',
      patientName:
          payload['patient_name']?.toString() ??
          payload['patientName']?.toString() ??
          'Unknown Patient',
      patientAge: _safeInt(payload['patient_age'] ?? payload['patientAge']),
      patientGender:
          payload['patient_gender']?.toString() ??
          payload['patientGender']?.toString() ??
          'M',
      doctorName:
          payload['doctor_name']?.toString() ??
          payload['doctorName']?.toString() ??
          'Unknown Doctor',
      licenseNo:
          payload['license_no']?.toString() ??
          payload['licenseNo']?.toString() ??
          '',
      ptNo: payload['pt_no']?.toString() ?? payload['ptNo']?.toString() ?? '',
      s2: payload['s2']?.toString() ?? '',
      patientAddress:
          payload['patient_address']?.toString() ??
          payload['patientAddress']?.toString(),
      dateTime: _safeDateTime(payload['date_time']) ?? DateTime.now(),
      medicines: medicines,
      totalPrice: _safeDouble(payload['total_price'] ?? payload['totalPrice']),
      valid: _safeBool(json['valid'], true),
      message: json['message']?.toString(),
      verifyUrl:
          json['verify_url']?.toString() ?? json['verifyUrl']?.toString() ?? '',
    );
  }
}

class LaravelVerifiedMedicine {
  final String name;
  final String? strength;
  final String? dosage;
  final int quantity;
  final double unitPrice;
  final int stock;

  const LaravelVerifiedMedicine({
    required this.name,
    this.strength,
    this.dosage,
    required this.quantity,
    required this.unitPrice,
    required this.stock,
  });

  factory LaravelVerifiedMedicine.fromJson(Map<String, dynamic> json) {
    return LaravelVerifiedMedicine(
      name: json['name']?.toString() ?? 'Unknown',
      strength: json['strength']?.toString(),
      dosage: json['dosage']?.toString(),
      quantity: _safeInt(json['quantity'], 1),
      unitPrice: _safeDouble(json['unit_price']),
      stock: _safeInt(json['stock']),
    );
  }
}

class MedicinePrice {
  final int? id;
  final String medicineName;
  // Split out to match the source price list format (Medicine Name,
  // Generic Name, Brand Name, Dosage/Form, Unit Price). All three are
  // optional — a row may have no brand name, for instance.
  final String? genericName;
  final String? brandName;
  final String? dosageForm;
  // `unit_price` is nullable on the backend — a medicine can exist with its
  // price "not yet set" (see ProductPriceController). Null here means
  // exactly that, not zero/free.
  final double? sellingPrice;
  final DateTime? deletedAt;

  const MedicinePrice({
    this.id,
    required this.medicineName,
    this.genericName,
    this.brandName,
    this.dosageForm,
    required this.sellingPrice,
    this.deletedAt,
  });

  factory MedicinePrice.fromJson(Map<String, dynamic> json) {
    final rawId = json['id'];
    final rawPrice = json['selling_price'];
    return MedicinePrice(
      id: rawId == null ? null : _safeInt(rawId),
      medicineName: json['medicine_name']?.toString() ?? '',
      genericName: _blankToNull(json['generic_name']?.toString()),
      brandName: _blankToNull(json['brand_name']?.toString()),
      dosageForm: _blankToNull(json['dosage_form']?.toString()),
      sellingPrice: rawPrice == null ? null : _safeDouble(rawPrice),
      deletedAt: _safeDateTime(json['deleted_at']),
    );
  }

  static String? _blankToNull(String? s) {
    if (s == null) return null;
    final trimmed = s.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// Result of an upload-preview call: what would change if the pharmacist
/// confirms, without anything having been written to the database yet.
class PriceListUploadPreview {
  final String batchId;
  final List<PriceListPreviewRow> rows;
  final List<String> errors;

  const PriceListUploadPreview({
    required this.batchId,
    required this.rows,
    required this.errors,
  });

  factory PriceListUploadPreview.fromJson(Map<String, dynamic> json) {
    return PriceListUploadPreview(
      batchId: json['batch_id']?.toString() ?? '',
      rows: _safeList(
        json['preview_rows'],
      ).map((e) => PriceListPreviewRow.fromJson(_safeMap(e))).toList(),
      errors: _safeList(json['errors']).map((e) => e.toString()).toList(),
    );
  }
}

class PriceListPreviewRow {
  final String medicineName;
  final String? genericName;
  final String? brandName;
  final String? dosageForm;
  final String action; // 'update' | 'new' | 'restoring'
  final double? oldPrice;
  // A blank price cell in the uploaded sheet is allowed through by the
  // backend (unit_price stored as NULL) — so this can legitimately be null,
  // not just oldPrice.
  final double? newPrice;

  const PriceListPreviewRow({
    required this.medicineName,
    this.genericName,
    this.brandName,
    this.dosageForm,
    required this.action,
    this.oldPrice,
    required this.newPrice,
  });

  factory PriceListPreviewRow.fromJson(Map<String, dynamic> json) {
    return PriceListPreviewRow(
      medicineName: json['medicine_name']?.toString() ?? 'Unknown',
      genericName: MedicinePrice._blankToNull(json['generic_name']?.toString()),
      brandName: MedicinePrice._blankToNull(json['brand_name']?.toString()),
      dosageForm: MedicinePrice._blankToNull(json['dosage_form']?.toString()),
      action: json['action']?.toString() ?? 'update',
      oldPrice: json['old_price'] == null
          ? null
          : _safeDouble(json['old_price']),
      newPrice: json['new_price'] == null
          ? null
          : _safeDouble(json['new_price']),
    );
  }
}

class DispensingLog {
  final String logId;
  final String? batchId;
  final String prescriptionId;
  final String pharmacyId;
  final String dispenserId;
  final String? tokenId;
  final String? rxNo;
  final String? physicianName;
  final String? patientName;
  final String productName;
  final String? genericName;
  final String? brandName;
  final String? lotNo;
  final String? expiryDate;
  final int quantityServed;
  final String? remarks;
  final bool isSeniorCitizen;
  final String? oscaId;
  final String status;
  final DateTime? dispensedAt;

  const DispensingLog({
    required this.logId,
    this.batchId,
    required this.prescriptionId,
    required this.pharmacyId,
    required this.dispenserId,
    this.tokenId,
    this.rxNo,
    this.physicianName,
    this.patientName,
    required this.productName,
    this.genericName,
    this.brandName,
    this.lotNo,
    this.expiryDate,
    required this.quantityServed,
    this.remarks,
    this.isSeniorCitizen = false,
    this.oscaId,
    this.status = 'pending',
    this.dispensedAt,
  });

  factory DispensingLog.fromJson(Map<String, dynamic> json) {
    return DispensingLog(
      logId: json['log_id']?.toString() ?? '',
      batchId: json['batch_id']?.toString(),
      prescriptionId: json['prescription_id']?.toString() ?? '',
      pharmacyId: json['pharmacy_id']?.toString() ?? '',
      dispenserId: json['dispenser_id']?.toString() ?? '',
      tokenId: json['token_id']?.toString(),
      rxNo: json['rx_no']?.toString(),
      physicianName: json['physician_name']?.toString(),
      patientName: json['patient_name']?.toString(),
      productName: json['product_name']?.toString() ?? '',
      genericName: json['generic_name']?.toString(),
      brandName: json['brand_name']?.toString(),
      lotNo: json['lot_no']?.toString(),
      expiryDate: json['expiry_date']?.toString(),
      quantityServed: _safeInt(json['quantity_served']),
      remarks: json['remarks']?.toString(),
      isSeniorCitizen: _safeBool(json['is_senior_citizen']),
      oscaId: json['osca_id']?.toString(),
      status: json['status']?.toString() ?? 'pending',
      dispensedAt: _safeDateTime(json['dispensed_at']),
    );
  }
}

// ---------------------------------------------------------------------------
// API service
// ---------------------------------------------------------------------------

class LaravelApiService {
  static const Duration _timeout = Duration(seconds: 30);
  static const Duration _connectivityTimeout = Duration(seconds: 5);

  final String baseUrl;
  final String? _token;

  LaravelApiService({String? baseUrl, this._token})
    : baseUrl = baseUrl ?? AppConfig.baseUrl {
    _assertSecureBaseUrl(this.baseUrl);
  }

  /// Refuses to talk to a plaintext endpoint outside of debug builds, so a
  /// misconfigured AppConfig can never silently send bearer tokens and
  /// patient data over an unencrypted connection in production.
  static void _assertSecureBaseUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      throw ArgumentError('Invalid API base URL: $url');
    }
    final isLocalDev =
        uri.host == 'localhost' ||
        uri.host == '127.0.0.1' ||
        uri.host == '10.0.2.2'; // Android emulator loopback
    if (uri.scheme != 'https' && !(kDebugMode && isLocalDev)) {
      throw ArgumentError(
        'Refusing to use insecure API base URL "$url" outside local debug '
        'builds. Use https:// in production.',
      );
    }
  }

  Map<String, String> get _headers => {
    'Accept': 'application/json',
    if (_token != null && _token.isNotEmpty) 'Authorization': 'Bearer $_token',
  };

  Map<String, String> get headers => _headers;

  /// Builds a safe URI by properly encoding each path segment, so IDs/tokens
  /// containing "/", "?", "#", etc. can never redirect the request to an
  /// unintended endpoint or corrupt the query string.
  Uri _buildUri(List<String> segments, [Map<String, String>? query]) {
    final base = Uri.parse(baseUrl);
    return base.replace(
      pathSegments: [
        ...base.pathSegments.where((s) => s.isNotEmpty),
        ...segments,
      ],
      queryParameters: query,
    );
  }

  /// Central response handler: validates status, safely decodes JSON (never
  /// throws an unhandled FormatException to the caller), and turns non-2xx
  /// responses into a typed exception with a sanitized message — never the
  /// raw response body, which may contain HTML error pages or internals.
  Map<String, dynamic> _decodeJsonMap(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      return _safeMap(decoded);
    } on FormatException {
      throw LaravelApiException(
        'Received an invalid response from the server.',
        statusCode: response.statusCode,
      );
    }
  }

  Never _throwForError(http.Response response, String fallbackMessage) {
    if (response.statusCode == 401) {
      throw const LaravelAuthException();
    }

    String errorMessage = fallbackMessage;
    try {
      final errorData = _safeMap(jsonDecode(response.body));
      final errors = errorData['errors'];
      if (errors is Map && errors.isNotEmpty) {
        final validationErrors = <String>[];
        errors.forEach((key, value) {
          if (value is List) {
            validationErrors.add('$key: ${value.join(', ')}');
          } else {
            validationErrors.add('$key: $value');
          }
        });
        errorMessage = 'Validation failed: ${validationErrors.join('; ')}';
      } else {
        // Most endpoints use {"message": "..."}, but the product-upload
        // endpoints (previewUpload's "Unsupported file type.",
        // confirmUpload's "This upload preview has expired.") use a plain
        // {"error": "..."} shape instead — check both so those specific
        // messages actually reach the user instead of falling back to a
        // generic one.
        final message =
            errorData['message']?.toString() ?? errorData['error']?.toString();
        if (message != null && message.isNotEmpty) {
          errorMessage = message;
        }
      }
    } catch (_) {
      // Body wasn't JSON (proxy/HTML error page, etc.) — keep the fallback
      // message rather than surfacing raw server internals to the caller.
    }
    throw LaravelApiException(errorMessage, statusCode: response.statusCode);
  }

  Future<bool> checkConnection() async {
    try {
      final response = await http
          .get(Uri.parse(baseUrl), headers: _headers)
          .timeout(_connectivityTimeout);
      return response.statusCode < 500;
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> submitCrossPharmacyRequest({
    required String rxNumber,
    required String patientName,
    required String requestingPharmacyName,
    required String requestingPharmacyLocation,
    required String requestingStaffName,
    required List<Map<String, dynamic>> medicines,
  }) async {
    final response = await http
        .post(
          _buildUri(['cross-pharmacy-requests']),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'rx_number': rxNumber,
            'patient_name': patientName,
            'requesting_pharmacy_name': requestingPharmacyName,
            'requesting_pharmacy_location': requestingPharmacyLocation,
            'requesting_staff_name': requestingStaffName,
            'medicines': medicines,
          }),
        )
        .timeout(_timeout);

    if (response.statusCode == 201 || response.statusCode == 200) {
      return _decodeJsonMap(response);
    }
    _throwForError(response, 'Failed to submit cross-pharmacy request');
  }

  Future<Map<String, dynamic>> reportCrossPharmacyDispensing({
    required String requestId,
    required List<Map<String, dynamic>> medicines,
    String? notes,
  }) async {
    final response = await http
        .post(
          _buildUri(['cross-pharmacy-requests', requestId, 'dispense']),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'medicines': medicines,
            if (notes != null && notes.isNotEmpty) 'notes': notes,
          }),
        )
        .timeout(_timeout);

    if (response.statusCode == 201 || response.statusCode == 200) {
      return _decodeJsonMap(response);
    }
    _throwForError(response, 'Failed to report cross-pharmacy dispensing');
  }

  Future<List<CrossPharmacyRequestResponse>>
  fetchApprovedCrossPharmacyRequests() async {
    final response = await http
        .get(
          _buildUri(['cross-pharmacy-requests'], {'status': 'approved'}),
          headers: _headers,
        )
        .timeout(_timeout);

    if (response.statusCode == 200) {
      final data = _decodeJsonMap(response);
      final requests = _safeList(data['requests']);
      return requests.map((e) {
        final m = _safeMap(e);
        final requestId =
            m['request_id']?.toString() ?? m['id']?.toString() ?? '';
        return CrossPharmacyRequestResponse(
          requestId: requestId,
          requestingPharmacyName:
              m['requesting_pharmacy_name']?.toString() ?? '',
          requestingPharmacyLocation:
              m['requesting_pharmacy_location']?.toString() ?? '',
          rxNumber: m['rx_number']?.toString() ?? m['rx_no']?.toString() ?? '',
          patientName: m['patient_name']?.toString() ?? '',
          medicines: _safeList(m['medicines']).map((e) {
            final me = _safeMap(e);
            return MedicineItem(
              name: me['name']?.toString() ?? '',
              quantity: _safeInt(me['quantity']),
            );
          }).toList(),
          requestingStaffName: m['requesting_staff_name']?.toString() ?? '',
          rejectionReason: m['rejection_reason']?.toString(),
          status: _safeEnumValue(
            RequestStatus.values,
            m['status'],
            RequestStatus.pending,
          ),
          dispensingStatus: m['dispensing_status']?.toString(),
          dispensedBy: m['dispensed_by']?.toString(),
          dispensedAt: m['dispensed_at']?.toString(),
        );
      }).toList();
    }

    _throwForError(
      response,
      'Failed to fetch approved cross-pharmacy requests',
    );
  }

  Future<LaravelPrescription> createPrescription({
    required String ocrCode,
    required String patientName,
    required int patientAge,
    required String patientGender,
    bool isSenior = false,
    String? oscaId,
    required String doctorName,
    required String licenseNo,
    required String ptNo,
    required String s2,
    String? patientAddress,
    required DateTime dateTime,
    required List<Map<String, dynamic>> medicines,
    required double totalPrice,
    String? rawExtractedText,
    String? pharmacistId,
    String? dispenserId,
    String? pharmacyId,
  }) async {
    final response = await http
        .post(
          _buildUri(['prescriptions']),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'ocr_code': ocrCode,
            'patient_name': patientName,
            'patient_age': patientAge,
            'patient_gender': patientGender,
            'doctor_name': doctorName,
            'is_senior': isSenior,
            'osca_id': oscaId,
            'license_no': licenseNo,
            'pt_no': ptNo,
            's2': s2,
            'patient_address': patientAddress,
            'date_time': dateTime.toIso8601String(),
            'medicines': medicines,
            'total_price': totalPrice,
            'raw_extracted_text': rawExtractedText,
            'pharmacist_id': pharmacistId,
            'dispenser_id': dispenserId,
            'pharmacy_id': pharmacyId,
          }),
        )
        .timeout(_timeout);

    if (response.statusCode == 201 || response.statusCode == 200) {
      return LaravelPrescription.fromJson(_decodeJsonMap(response));
    }
    _throwForError(response, 'Failed to create prescription');
  }

  Future<LaravelPrescription> updatePrescription(
    String id,
    Map<String, dynamic> data,
  ) async {
    final response = await http
        .put(
          _buildUri(['prescriptions', id]),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode(data),
        )
        .timeout(_timeout);

    if (response.statusCode == 200) {
      return LaravelPrescription.fromJson(_decodeJsonMap(response));
    }
    _throwForError(response, 'Failed to update prescription');
  }

  Future<void> updateDisposedQuantities(
    String id,
    List<Map<String, dynamic>> medicines,
  ) async {
    final response = await http
        .put(
          _buildUri(['prescriptions', id]),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'medicines': medicines}),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      _throwForError(response, 'Failed to update disposed quantities');
    }
  }

  Future<void> deletePrescription(String id) async {
    final response = await http
        .delete(_buildUri(['prescriptions', id]), headers: _headers)
        .timeout(_timeout);

    if (response.statusCode != 200 && response.statusCode != 204) {
      _throwForError(response, 'Failed to delete prescription');
    }
  }

  Future<List<LaravelPrescription>> fetchPrescriptions({
    String? search,
    String? status,
  }) async {
    final uri = _buildUri(
      ['prescriptions'],
      {
        if (search != null && search.isNotEmpty) 'search': search,
        if (status != null && status.isNotEmpty) 'status': status,
      },
    );

    final response = await http.get(uri, headers: _headers).timeout(_timeout);

    if (response.statusCode == 200) {
      final data = _decodeJsonMap(response);
      final items = _safeList(data['data']);
      return items
          .map((e) => LaravelPrescription.fromJson(_safeMap(e)))
          .toList();
    }
    _throwForError(response, 'Failed to fetch prescriptions');
  }

  Future<LaravelQrTokenResponse> generateQrToken({
    required String ocrCode,
    required String patientName,
    required int patientAge,
    required String patientGender,
    required String doctorName,
    required String licenseNo,
    required String ptNo,
    required String s2,
    String? patientAddress,
    required DateTime dateTime,
    required List<Map<String, dynamic>> medicines,
    required double totalPrice,
    String? rawExtractedText,
    String? prescriptionId,
  }) async {
    final response = await http
        .post(
          _buildUri(['qr', 'token']),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'ocr_code': ocrCode,
            'patient_name': patientName,
            'patient_age': patientAge,
            'patient_gender': patientGender,
            'doctor_name': doctorName,
            'license_no': licenseNo,
            'pt_no': ptNo,
            's2': s2,
            'patient_address': patientAddress,
            'date_time': dateTime.toIso8601String(),
            'medicines': medicines,
            'total_price': totalPrice,
            'raw_extracted_text': rawExtractedText,
            'prescription_id': prescriptionId,
          }),
        )
        .timeout(_timeout);

    if (response.statusCode == 201 || response.statusCode == 200) {
      return LaravelQrTokenResponse.fromJson(_decodeJsonMap(response));
    }
    _throwForError(response, 'Failed to generate QR token');
  }

  Future<LaravelVerifiedPrescription> verifyQrToken(String token) async {
    if (token.trim().isEmpty) {
      throw const LaravelApiException('A QR token is required.');
    }

    final response = await http
        .get(_buildUri(['qr', 'verify', token]), headers: _headers)
        .timeout(_timeout);

    if (response.statusCode == 200) {
      return LaravelVerifiedPrescription.fromJson(_decodeJsonMap(response));
    }

    if (response.statusCode == 404) {
      return LaravelVerifiedPrescription(
        token: token,
        ocrCode: '',
        patientName: '',
        patientAge: 0,
        patientGender: '',
        doctorName: '',
        licenseNo: '',
        ptNo: '',
        s2: '',
        dateTime: DateTime.now(),
        medicines: const [],
        totalPrice: 0.0,
        valid: false,
        message: 'QR code not found or expired',
      );
    }

    _throwForError(response, 'Failed to verify QR token');
  }

  Future<bool> revokeQrToken(String token) async {
    if (token.trim().isEmpty) return false;
    final response = await http
        .delete(_buildUri(['qr', 'token', token]), headers: _headers)
        .timeout(_timeout);
    return response.statusCode == 200 || response.statusCode == 204;
  }

  Future<List<DispensingLog>> fetchDispensingLogs(String prescriptionId) async {
    final uri = _buildUri(
      ['dispensing-logs'],
      {'prescription_id': prescriptionId},
    );
    final response = await http.get(uri, headers: _headers).timeout(_timeout);

    if (response.statusCode == 200) {
      final data = _decodeJsonMap(response);
      final logs = _safeList(data['data']);
      return logs.map((e) => DispensingLog.fromJson(_safeMap(e))).toList();
    }
    _throwForError(response, 'Failed to fetch dispensing logs');
  }

  Future<DispensingLog> createDispensingLog({
    required String prescriptionId,
    required String pharmacyId,
    required String dispenserId,
    required String productName,
    required int quantityServed,
    String? tokenId,
    String? batchId,
    String? rxNo,
    String? physicianName,
    String? patientName,
    String? genericName,
    String? brandName,
    String? lotNo,
    String? expiryDate,
    String? remarks,
    bool isSeniorCitizen = false,
    String? oscaId,
    String? orNumber,
  }) async {
    final response = await http
        .post(
          _buildUri(['dispensing-logs']),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'prescription_id': prescriptionId,
            'pharmacy_id': pharmacyId,
            'dispenser_id': dispenserId,
            'token_id': tokenId,
            'batch_id': batchId,
            'rx_no': rxNo,
            'physician_name': physicianName,
            'patient_name': patientName,
            'product_name': productName,
            'generic_name': genericName,
            'brand_name': brandName,
            'lot_no': lotNo,
            'expiry_date': expiryDate,
            'quantity_served': quantityServed,
            'remarks': remarks,
            'is_senior_citizen': isSeniorCitizen,
            'osca_id': oscaId,
            'or_number': orNumber,
          }),
        )
        .timeout(_timeout);

    if (response.statusCode == 201) {
      final data = _decodeJsonMap(response);
      return DispensingLog.fromJson(_safeMap(data['data']));
    }
    _throwForError(response, 'Failed to create dispensing log');
  }

  Future<void> createSeniorCitizenDiscount({
    required String patientId,
    required String patientName,
    required String oscaId,
    required String drugName,
    required double grossCost,
    required double discountAmount,
    required double netCost,
    double discountPercentage = 20.00,
    String? prescriptionId,
    String? dispensingLogId,
  }) async {
    final response = await http
        .post(
          _buildUri(['senior-citizen-discounts']),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'prescription_id': prescriptionId,
            'dispensing_log_id': dispensingLogId,
            'patient_id': patientId,
            'patient_name': patientName,
            'osca_id': oscaId,
            'drug_name': drugName,
            'gross_cost': grossCost,
            'discount_percentage': discountPercentage,
            'discount_amount': discountAmount,
            'net_cost': netCost,
          }),
        )
        .timeout(_timeout);

    if (response.statusCode == 201) {
      return;
    }
    _throwForError(response, 'Failed to record senior citizen discount');
  }

  Future<List<Map<String, dynamic>>> fetchPatients() async {
    final response = await http
        .get(_buildUri(['patients']), headers: _headers)
        .timeout(_timeout);

    if (response.statusCode == 200) {
      final data = _decodeJsonMap(response);
      final patients = _safeList(data['data']);
      return patients.map((e) => _safeMap(e)).toList();
    }
    _throwForError(response, 'Failed to fetch patients');
  }

  Future<Map<String, dynamic>> fetchPatient(String patientId) async {
    final response = await http
        .get(_buildUri(['patients', patientId]), headers: _headers)
        .timeout(_timeout);

    if (response.statusCode == 200) {
      final data = _decodeJsonMap(response);
      return _safeMap(data['data']);
    }
    _throwForError(response, 'Failed to fetch patient');
  }

  Future<Map<String, dynamic>> fetchPatientAdherence(String patientId) async {
    final response = await http
        .get(_buildUri(['patients', patientId, 'adherence']), headers: _headers)
        .timeout(_timeout);

    if (response.statusCode == 200) {
      final data = _decodeJsonMap(response);
      return _safeMap(data['data']);
    }
    _throwForError(response, 'Failed to fetch adherence status');
  }

  /// Fetches a patient's dispensing history. The various historical key
  /// names ('history', 'records', 'refill_history', etc.) are checked
  /// without ever logging the response body — that body contains PHI
  /// (patient name, address, medicines) and must never hit device logs,
  /// even in debug builds, since debug logs can still be captured by
  /// crash-reporting/log-shipping tooling.
  Future<List<Map<String, dynamic>>> fetchPatientDispensingHistory(
    String patientId,
  ) async {
    final response = await http
        .get(
          _buildUri(['patients', patientId, 'dispensing-history']),
          headers: _headers,
        )
        .timeout(_timeout);

    if (response.statusCode == 200) {
      final data = _decodeJsonMap(response);

      final historyRaw = data['data'];
      if (historyRaw is List) {
        return historyRaw.map((e) => _safeMap(e)).toList();
      }

      const candidateKeys = [
        'dispensing_logs',
        'dispensingHistory',
        'history',
        'records',
        'data',
        'items',
        'refill_history',
        'refillHistory',
        'dispensing_history',
      ];

      if (historyRaw is Map) {
        final nestedMap = _safeMap(historyRaw);
        for (final key in candidateKeys) {
          final nested = _safeList(nestedMap[key]);
          if (nested.isNotEmpty) {
            return nested.map((e) => _safeMap(e)).toList();
          }
        }
      }

      for (final key in candidateKeys) {
        final nested = _safeList(data[key]);
        if (nested.isNotEmpty) {
          return nested.map((e) => _safeMap(e)).toList();
        }
      }

      return [];
    }
    _throwForError(response, 'Failed to fetch dispensing history');
  }

  Future<Map<String, dynamic>> validateDispense(
    String prescriptionId,
    String pharmacyId,
    int attemptedQuantity,
  ) async {
    final response = await http
        .post(
          _buildUri(['dispensing-logs', 'validate']),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'prescription_id': prescriptionId,
            'pharmacy_id': pharmacyId,
            'attempted_quantity': attemptedQuantity,
          }),
        )
        .timeout(_timeout);

    if (response.statusCode == 200) {
      final data = _decodeJsonMap(response);
      return _safeMap(data['data']);
    }

    if (response.statusCode == 401) {
      throw const LaravelAuthException();
    }

    String backendMessage = 'Failed to validate dispense';
    try {
      final errorData = _safeMap(jsonDecode(response.body));
      final errors = errorData['errors'];
      if (errors is Map && errors.isNotEmpty) {
        final firstError = errors.values.first?.toString();
        if (firstError != null && firstError.isNotEmpty) {
          backendMessage = firstError
              .replaceAll(RegExp(r'[\[\]"]'), '')
              .split(',')
              .first
              .trim();
        }
      } else {
        final message = errorData['message']?.toString();
        if (message != null && message.isNotEmpty) {
          backendMessage = message;
        }
      }
    } catch (_) {
      // Non-JSON body — keep the generic fallback message.
    }

    throw LaravelApiException(backendMessage, statusCode: response.statusCode);
  }

  Future<List<DispenseAlert>> fetchAlerts({
    String? priority,
    String? type,
    bool? unresolvedOnly,
  }) async {
    final uri = _buildUri(
      ['alerts'],
      {
        if (priority != null && priority.isNotEmpty) 'priority': priority,
        if (type != null && type.isNotEmpty) 'type': type,
        if (unresolvedOnly == true) 'resolved': 'false',
      },
    );

    final response = await http.get(uri, headers: _headers).timeout(_timeout);

    if (response.statusCode == 200) {
      final data = _decodeJsonMap(response);
      final alerts = _safeList(data['data']);
      return alerts.map((e) => DispenseAlert.fromJson(_safeMap(e))).toList();
    }
    _throwForError(response, 'Failed to fetch alerts');
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
    required String newPasswordConfirmation,
  }) async {
    final response = await http
        .post(
          _buildUri(['change-password']),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'current_password': currentPassword,
            'new_password': newPassword,
            'new_password_confirmation': newPasswordConfirmation,
          }),
        )
        .timeout(_timeout);

    if (response.statusCode == 200) {
      return;
    }
    _throwForError(response, 'Failed to change password');
  }

  Future<DispenseAlert> fetchAlert(String alertId) async {
    final response = await http
        .get(_buildUri(['alerts', alertId]), headers: _headers)
        .timeout(_timeout);

    if (response.statusCode == 200) {
      final data = _decodeJsonMap(response);
      return DispenseAlert.fromJson(_safeMap(data['data']));
    }
    _throwForError(response, 'Failed to fetch alert');
  }

  Future<DispenseAlert> resolveAlert(String alertId) async {
    final response = await http
        .put(_buildUri(['alerts', alertId, 'resolve']), headers: _headers)
        .timeout(_timeout);

    if (response.statusCode == 200) {
      final data = _decodeJsonMap(response);
      return DispenseAlert.fromJson(_safeMap(data['data']));
    }
    _throwForError(response, 'Failed to resolve alert');
  }

  // -------------------------------------------------------------------------
  // Product / price-list management
  // -------------------------------------------------------------------------

  /// Client-side cap matching the backend's actual limit — ProductPriceController
  /// validates `'file' => '...|max:5120'` (5120 KB). Kept in sync here so a
  /// huge file is rejected before it's ever read fully into memory and sent,
  /// rather than after a slow upload just to be told it was too big.
  static const int maxUploadBytes = 5120 * 1024; // 5,242,880 bytes (5120 KB)
  static const _allowedUploadExtensions = {'xlsx', 'xls', 'csv', 'txt'};

  Future<List<MedicinePrice>> fetchProducts() async {
    final response = await http
        .get(_buildUri(['admin', 'products']), headers: _headers)
        .timeout(_timeout);

    if (response.statusCode == 200) {
      final data = _decodeJsonMap(response);
      final items = _safeList(data['data']);
      return items.map((e) => MedicinePrice.fromJson(_safeMap(e))).toList();
    }
    _throwForError(response, 'Failed to load price list');
  }

  Future<List<MedicinePrice>> fetchTrashedProducts() async {
    final response = await http
        .get(_buildUri(['admin', 'products', 'trashed']), headers: _headers)
        .timeout(_timeout);

    if (response.statusCode == 200) {
      final data = _decodeJsonMap(response);
      final items = _safeList(data['data']);
      return items.map((e) => MedicinePrice.fromJson(_safeMap(e))).toList();
    }
    _throwForError(response, 'Failed to load recently removed medicines');
  }

  /// Creates a new medicine or updates the price of an existing one
  /// (matched by name on the backend). Returns nothing on success — throws
  /// on any non-2xx response, including validation failures, so callers
  /// never have to remember to check the status code themselves.
  ///
  /// [sellingPrice] is intentionally nullable: the backend allows adding or
  /// importing a medicine before its price is known (stored as NULL, not
  /// rejected) — see ProductPriceController::updatePrice.
  ///
  /// [genericName], [brandName], and [dosageForm] are also optional, mirroring
  /// the source price list format (Medicine Name, Generic Name, Brand Name,
  /// Dosage/Form, Unit Price) — a row need not have all of them filled in.
  Future<void> updateProductPrice({
    required String medicineName,
    required double? sellingPrice,
    String? genericName,
    String? brandName,
    String? dosageForm,
  }) async {
    final response = await http
        .put(
          _buildUri(['admin', 'products', 'price']),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'medicine_name': medicineName,
            'generic_name': genericName,
            'brand_name': brandName,
            'dosage_form': dosageForm,
            'selling_price': sellingPrice,
          }),
        )
        .timeout(_timeout);

    if (response.statusCode != 200 && response.statusCode != 201) {
      _throwForError(response, 'Failed to save price');
    }
  }

  Future<void> deleteProduct(int productId) async {
    final response = await http
        .delete(
          _buildUri(['admin', 'products', productId.toString()]),
          headers: _headers,
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      _throwForError(response, 'Failed to remove medicine');
    }
  }

  Future<void> restoreProduct(int productId) async {
    final response = await http
        .post(
          _buildUri(['admin', 'products', productId.toString(), 'restore']),
          headers: _headers,
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      _throwForError(response, 'Failed to restore medicine');
    }
  }

  /// Uploads a picked price-list file (xlsx/xls/csv) as multipart form data
  /// and returns a preview of what would change — nothing is committed to
  /// the database until [confirmPriceListUpload] is called with the
  /// returned batch id.
  ///
  /// Validates extension and size client-side before ever reading the file
  /// bytes into memory, and applies its own timeout since multipart uploads
  /// aren't covered by the plain-request timeout used elsewhere.
  Future<PriceListUploadPreview> uploadPriceListPreview({
    required String filename,
    required List<int> bytes,
  }) async {
    final ext = filename.contains('.')
        ? filename.split('.').last.toLowerCase()
        : '';
    if (!_allowedUploadExtensions.contains(ext)) {
      throw LaravelApiException(
        'Unsupported file type "$ext". Please upload an xlsx, xls, csv, or txt file.',
      );
    }
    if (bytes.isEmpty) {
      throw const LaravelApiException('The selected file is empty.');
    }
    if (bytes.length > maxUploadBytes) {
      final maxMb = (maxUploadBytes / (1024 * 1024)).toStringAsFixed(0);
      throw LaravelApiException(
        'File is too large. Please keep uploads under ${maxMb}MB.',
      );
    }

    final request =
        http.MultipartRequest(
            'POST',
            _buildUri(['admin', 'products', 'upload-preview']),
          )
          ..headers.addAll(_headers)
          ..files.add(
            http.MultipartFile.fromBytes(
              'file',
              bytes,
              filename: filename,
              contentType: MediaType('application', 'octet-stream'),
            ),
          );

    final http.Response response;
    try {
      final streamed = await request.send().timeout(_timeout);
      response = await http.Response.fromStream(streamed);
    } on TimeoutException {
      throw const LaravelApiException('Upload timed out. Please try again.');
    }

    if (response.statusCode == 200) {
      return PriceListUploadPreview.fromJson(_decodeJsonMap(response));
    }
    _throwForError(response, 'Upload failed');
  }

  Future<void> confirmPriceListUpload(String batchId) async {
    final response = await http
        .post(
          _buildUri(['admin', 'products', 'upload-confirm']),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'batch_id': batchId}),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      _throwForError(response, 'Failed to confirm upload');
    }
  }
}
