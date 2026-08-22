import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../common/session.dart';
import '../../common/services/app_config.dart';
import '../models/admin_models.dart';

class StaffValidationException implements Exception {
  final String message;
  final Map<String, List<String>> fieldErrors;

  StaffValidationException({required this.message, required this.fieldErrors});
}

class AdminApiService {
  static const Duration _timeout = Duration(seconds: 30);

  String get _baseUrl => AppConfig.baseUrl;

  Future<Map<String, dynamic>> fetchMe() async {
    final response = await http
        .get(Uri.parse('$_baseUrl/me'), headers: _headers)
        .timeout(_timeout);

    if (response.statusCode == 200) {
      return safeMap(jsonDecode(response.body)) ?? {};
    }

    final data = safeMap(jsonDecode(response.body));
    final message = data?['message'] ?? 'Failed to fetch user info';
    throw Exception(message);
  }

  Map<String, String> get _headers {
    final token = AppSession.instance.token;
    return {
      'Accept': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  Future<Map<String, dynamic>> fetchDashboardSummary({
    String period = 'today',
  }) async {
    final uri = Uri.parse(
      '$_baseUrl/admin/dashboard/summary',
    ).replace(queryParameters: {'period': period});

    final response = await http.get(uri, headers: _headers).timeout(_timeout);

    if (response.statusCode == 200) {
      return safeMap(jsonDecode(response.body)) ?? {};
    }

    final data = safeMap(jsonDecode(response.body));
    final message = data?['message'] ?? 'Failed to fetch dashboard summary';
    throw Exception(message);
  }

  Future<List<Map<String, dynamic>>> fetchPatientAdherence({
    String? search,
  }) async {
    final uri = Uri.parse('$_baseUrl/admin/patients/adherence').replace(
      queryParameters: {
        if (search != null && search.isNotEmpty) 'search': search,
      },
    );

    final response = await http.get(uri, headers: _headers).timeout(_timeout);

    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body);
      debugPrint('=== RAW ADHERENCE RESPONSE ===');
      debugPrint(response.body);
      debugPrint('=== END RAW RESPONSE ===');
      final data = safeMap(decoded) ?? {};
      debugPrint('Top-level keys: ${data.keys.toList()}');
      final patients = safeList(data['patients']);
      debugPrint('Patients count from data["patients"]: ${patients.length}');
      if (patients.isEmpty) {
        debugPrint('Trying data["data"] as fallback...');
        final fallback = safeList(data['data']);
        debugPrint('Fallback count: ${fallback.length}');
        return fallback.map((e) => safeMap(e) ?? {}).toList();
      }
      return patients.map((e) => safeMap(e) ?? {}).toList();
    }

    throw Exception('Failed to fetch patient adherence');
  }

  Future<List<Map<String, dynamic>>> fetchAllPatients() async {
    final response = await http
        .get(Uri.parse('$_baseUrl/patients'), headers: _headers)
        .timeout(_timeout);

    if (response.statusCode == 200) {
      final data = safeMap(jsonDecode(response.body)) ?? {};
      final patients = safeList(data['data']);
      return patients.map((e) => safeMap(e) ?? {}).toList();
    }

    throw Exception('Failed to fetch patients');
  }

  Future<List<Map<String, dynamic>>> fetchPrescriptions({
    String? search,
    String? status,
  }) async {
    final uri = Uri.parse('$_baseUrl/prescriptions').replace(
      queryParameters: {
        if (search != null && search.isNotEmpty) 'search': search,
        if (status != null && status.isNotEmpty) 'status': status,
      },
    );

    final response = await http.get(uri, headers: _headers).timeout(_timeout);

    if (response.statusCode == 200) {
      final data = safeMap(jsonDecode(response.body)) ?? {};
      final items = safeList(data['data']);
      return items.map((e) => safeMap(e) ?? {}).toList();
    }

    throw Exception('Failed to fetch prescriptions');
  }

  Future<Map<String, dynamic>> fetchPrescription(String id) async {
    final response = await http
        .get(Uri.parse('$_baseUrl/admin/prescriptions/$id'), headers: _headers)
        .timeout(_timeout);

    if (response.statusCode == 200) {
      return safeMap(jsonDecode(response.body)) ?? {};
    }

    throw Exception('Failed to fetch prescription');
  }

  Future<List<CrossPharmacyRequestResponse>>
  fetchCrossPharmacyRequests() async {
    final response = await http
        .get(
          Uri.parse('$_baseUrl/admin/cross-pharmacy-requests'),
          headers: _headers,
        )
        .timeout(_timeout);

    if (response.statusCode == 200) {
      final data = safeMap(jsonDecode(response.body)) ?? {};
      final requests = safeList(data['requests']);
      debugPrint(
        'CrossPharmacy: fetched ${requests.length} requests from data["requests"]',
      );
      return requests.map((e) {
        final m = safeMap(e) ?? {};
        final requestId =
            m['request_id']?.toString() ?? m['id']?.toString() ?? '';
        debugPrint(
          'CrossPharmacy: requestId=$requestId keys=${m.keys.toList()}',
        );
        return CrossPharmacyRequestResponse(
          requestId: requestId,
          requestingPharmacyName:
              m['requesting_pharmacy_name']?.toString() ?? '',
          requestingPharmacyLocation:
              m['requesting_pharmacy_location']?.toString() ?? '',
          rxNumber: m['rx_number']?.toString() ?? m['rx_no']?.toString() ?? '',
          patientName: m['patient_name']?.toString() ?? '',
          medicines: safeList(m['medicines']).map((e) {
            final me = safeMap(e) ?? {};
            return MedicineItem(
              name: me['name']?.toString() ?? '',
              quantity: safeInt(me['quantity']),
            );
          }).toList(),
          requestingStaffName: m['requesting_staff_name']?.toString() ?? '',
          rejectionReason: m['rejection_reason']?.toString(),
          status: safeEnumValue(
            RequestStatus.values,
            m['status'],
            RequestStatus.pending,
          ),
          dispensingStatus: m['dispensing_status']?.toString(),
          dispensedBy: m['dispensed_by']?.toString(),
          dispensedAt: m['dispensed_at']?.toString(),
          wouldExceedRemaining: safeBool(m['would_exceed_remaining']),
          exceedDetails: safeList(m['exceed_details']).map((ed) {
            final edm = safeMap(ed) ?? {};
            return ExceedDetailItem(
              medicine: edm['medicine']?.toString() ?? '',
              requested: safeInt(edm['requested']),
              otherPending: safeInt(edm['other_pending']),
              remaining: safeInt(edm['remaining']),
            );
          }).toList(),
          fullyDispensed: safeBool(m['fully_dispensed']),
        );
      }).toList();
    }

    debugPrint(
      'CrossPharmacy: fetch failed with status ${response.statusCode}',
    );
    throw Exception('Failed to fetch cross-pharmacy requests');
  }

  Future<List<CrossPharmacyRequestResponse>>
  fetchApprovedCrossPharmacyRequests() async {
    final response = await http
        .get(
          Uri.parse('$_baseUrl/admin/cross-pharmacy-requests?status=approved'),
          headers: _headers,
        )
        .timeout(_timeout);

    if (response.statusCode == 200) {
      final data = safeMap(jsonDecode(response.body)) ?? {};
      final requests = safeList(data['requests']);
      return requests.map((e) {
        final m = safeMap(e) ?? {};
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
          medicines: safeList(m['medicines']).map((e) {
            final me = safeMap(e) ?? {};
            return MedicineItem(
              name: me['name']?.toString() ?? '',
              quantity: safeInt(me['quantity']),
            );
          }).toList(),
          requestingStaffName: m['requesting_staff_name']?.toString() ?? '',
          rejectionReason: m['rejection_reason']?.toString(),
          status: safeEnumValue(
            RequestStatus.values,
            m['status'],
            RequestStatus.pending,
          ),
          dispensingStatus: m['dispensing_status']?.toString(),
          dispensedBy: m['dispensed_by']?.toString(),
          dispensedAt: m['dispensed_at']?.toString(),
          fullyDispensed: safeBool(m['fully_dispensed']),
        );
      }).toList();
    }

    throw Exception('Failed to fetch approved cross-pharmacy requests');
  }

  /// Admin-only — applies a pending/flagged request to the prescription
  /// record (see CrossPharmacyController::approve()).
  Future<void> approveCrossPharmacyRequest(String requestId) async {
    final response = await http
        .post(
          Uri.parse('$_baseUrl/admin/cross-pharmacy-requests/$requestId/approve'),
          headers: _headers,
        )
        .timeout(_timeout);

    if (response.statusCode == 200) {
      return;
    }

    final data = safeMap(jsonDecode(response.body)) ?? {};
    throw Exception(
      data['error']?.toString() ??
          data['message']?.toString() ??
          'Failed to approve request',
    );
  }

  /// Admin-only — flags a pending request as a risk. The request stays on
  /// record and can still be approved later; there is no reject/decline
  /// action (see CrossPharmacyController::flag()).
  Future<void> flagCrossPharmacyRequest(String requestId, String reason) async {
    final response = await http
        .post(
          Uri.parse('$_baseUrl/admin/cross-pharmacy-requests/$requestId/flag'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'reason': reason}),
        )
        .timeout(_timeout);

    if (response.statusCode == 200) {
      return;
    }

    final data = safeMap(jsonDecode(response.body)) ?? {};
    throw Exception(
      data['message']?.toString() ?? 'Failed to flag request',
    );
  }

  Future<ScanRecordsResponse> fetchScanRecords({
    String type = 'all',
    String date = 'today',
    String search = '',
    bool flaggedOnly = false,
  }) async {
    final uri = Uri.parse('$_baseUrl/admin/scan-records').replace(
      queryParameters: {
        if (type != 'all') 'type': type,
        if (date != 'allTime') 'date': date,
        if (search.isNotEmpty) 'search': search,
        if (flaggedOnly) 'flagged_only': 'true',
      },
    );

    final response = await http.get(uri, headers: _headers).timeout(_timeout);

    if (response.statusCode == 200) {
      final data = safeMap(jsonDecode(response.body)) ?? {};
      return ScanRecordsResponse(
        qrCount: safeInt(data['qr_count']),
        ocrCount: safeInt(data['ocr_count']),
        records: safeList(data['records']).map((e) {
          final m = safeMap(e) ?? {};
          return ScanRecordEntry(
            status: safeEnumValue(
              ScanRecordStatus.values,
              m['status'],
              ScanRecordStatus.pending,
            ),
            type: safeEnumValue(
              ScanRecordType.values,
              m['type'],
              ScanRecordType.qr,
            ),
            refNumber: m['ref_number']?.toString() ?? '',
            patientName: m['patient_name']?.toString() ?? '',
            description: m['description']?.toString() ?? '',
            staff: m['staff']?.toString() ?? '',
            time: m['time']?.toString() ?? '',
            isFlagged: safeBool(m['is_flagged']),
            prescriptionId: m['prescription_id']?.toString(),
          );
        }).toList(),
      );
    }

    throw Exception('Failed to fetch scan records');
  }

  Future<List<StaffAccount>> fetchStaff({String? search}) async {
    final uri = Uri.parse('$_baseUrl/admin/staff').replace(
      queryParameters: {
        if (search != null && search.isNotEmpty) 'search': search,
      },
    );

    final response = await http.get(uri, headers: _headers).timeout(_timeout);

    if (response.statusCode == 200) {
      final data = safeMap(jsonDecode(response.body)) ?? {};
      final staff = safeList(data['staff']);
      return staff.map((e) => StaffAccount.fromJson(safeMap(e) ?? {})).toList();
    }

    throw Exception('Failed to fetch staff');
  }

  Future<String> fetchNextStaffId(String role) async {
    final uri = Uri.parse(
      '$_baseUrl/admin/staff/next-id',
    ).replace(queryParameters: {'role': role});

    final response = await http.get(uri, headers: _headers).timeout(_timeout);

    if (response.statusCode == 200) {
      final data = safeMap(jsonDecode(response.body)) ?? {};
      return data['id']?.toString() ?? '';
    }

    throw Exception('Failed to fetch next staff ID');
  }

  Future<Map<String, dynamic>> createStaff({
    required String role,
    required String firstName,
    required String lastName,
    required String email,
    required String password,
    required String pharmacyId,
    String? licenseNumber,
  }) async {
    final response = await http
        .post(
          Uri.parse('$_baseUrl/admin/staff'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'role': role,
            'first_name': firstName,
            'last_name': lastName,
            'email': email,
            'password': password,
            'pharmacy_id': pharmacyId,
            'license_number': licenseNumber,
          }),
        )
        .timeout(_timeout);

    if (response.statusCode == 201) {
      return safeMap(jsonDecode(response.body)) ?? {};
    }

    if (response.statusCode == 422) {
      final data = safeMap(jsonDecode(response.body)) ?? {};
      final rawErrors = data['errors'];
      final errors =
          safeMap(rawErrors)?.map(
            (k, v) => MapEntry(
              k,
              List<String>.from(safeList(v).map((e) => e.toString())),
            ),
          ) ??
          {};
      throw StaffValidationException(
        message: data['message']?.toString() ?? 'Validation failed',
        fieldErrors: errors,
      );
    }

    throw Exception('Failed to create staff');
  }

  /// Admin-only — the backend rejects this with a 403 for any non-admin
  /// caller (see AdminStaffController::resetPassword()). [newPassword] is
  /// sent once over the authenticated connection and never echoed back;
  /// nothing about it is persisted client-side beyond this call.
  Future<void> resetStaffPassword(String staffId, String newPassword) async {
    final response = await http
        .patch(
          Uri.parse('$_baseUrl/admin/staff/$staffId/password'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'password': newPassword}),
        )
        .timeout(_timeout);

    if (response.statusCode == 200) {
      return;
    }

    if (response.statusCode == 422) {
      final data = safeMap(jsonDecode(response.body)) ?? {};
      final rawErrors = data['errors'];
      final errors =
          safeMap(rawErrors)?.map(
            (k, v) => MapEntry(
              k,
              List<String>.from(safeList(v).map((e) => e.toString())),
            ),
          ) ??
          {};
      throw StaffValidationException(
        message: data['message']?.toString() ?? 'Validation failed',
        fieldErrors: errors,
      );
    }

    final data = safeMap(jsonDecode(response.body));
    final message = data?['message']?.toString() ?? 'Failed to reset password';
    throw Exception(message);
  }

  Future<void> updateStaffStatus(String staffId, StaffStatus status) async {
    final statusString = switch (status) {
      StaffStatus.active => 'active',
      StaffStatus.onLeave => 'on_leave',
      StaffStatus.inactive => 'inactive',
    };

    final response = await http
        .patch(
          Uri.parse('$_baseUrl/admin/staff/$staffId/status'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'status': statusString}),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      final data = safeMap(jsonDecode(response.body));
      final message =
          data?['message']?.toString() ?? 'Failed to update staff status';
      throw Exception(message);
    }
  }

  Future<Map<String, dynamic>> fetchReportsSummary({
    String range = 'today',
  }) async {
    final uri = Uri.parse(
      '$_baseUrl/admin/reports/summary',
    ).replace(queryParameters: {'range': range});

    try {
      final response = await http.get(uri, headers: _headers).timeout(_timeout);

      if (response.statusCode == 200) {
        return safeMap(jsonDecode(response.body)) ?? {};
      }

      final data = safeMap(jsonDecode(response.body));
      final message = data?['message'] ?? 'Failed to fetch reports summary';
      throw Exception(message);
    } on TimeoutException {
      throw Exception('Timed out while fetching reports summary');
    } catch (e) {
      if (e is Exception) {
        rethrow;
      }
      throw Exception('Could not reach the server');
    }
  }

  Future<List<DispensingReportRow>> fetchDispensingReport({
    required DateTime from,
    required DateTime to,
  }) async {
    final uri = Uri.parse('$_baseUrl/admin/reports/dispensing').replace(
      queryParameters: {
        'date_from': _formatDate(from),
        'date_to': _formatDate(to),
        'format': 'json',
      },
    );

    final response = await http.get(uri, headers: _headers).timeout(_timeout);

    if (response.statusCode == 200) {
      final data = safeMap(jsonDecode(response.body)) ?? {};
      final rows = safeList(data['data'] ?? data['rows']);
      return rows
          .map((e) => DispensingReportRow.fromJson(safeMap(e) ?? {}))
          .toList();
    }

    final data = safeMap(jsonDecode(response.body));
    final message = data?['message'] ?? 'Failed to fetch dispensing report';
    throw Exception(message);
  }

  Future<List<SeniorCitizenReportRow>> fetchSeniorCitizenReport({
    required DateTime from,
    required DateTime to,
  }) async {
    final uri = Uri.parse('$_baseUrl/admin/reports/senior-citizen').replace(
      queryParameters: {
        'date_from': _formatDate(from),
        'date_to': _formatDate(to),
        'format': 'json',
      },
    );

    final response = await http.get(uri, headers: _headers).timeout(_timeout);

    if (response.statusCode == 200) {
      final data = safeMap(jsonDecode(response.body)) ?? {};
      final rows = safeList(data['data'] ?? data['rows']);
      return rows
          .map((e) => SeniorCitizenReportRow.fromJson(safeMap(e) ?? {}))
          .toList();
    }

    final data = safeMap(jsonDecode(response.body));
    final message = data?['message'] ?? 'Failed to fetch senior citizen report';
    throw Exception(message);
  }

  Future<Uint8List> exportDispensingReportPdf({
    required DateTime from,
    required DateTime to,
  }) async {
    final uri = Uri.parse('$_baseUrl/admin/reports/dispensing').replace(
      queryParameters: {
        'date_from': _formatDate(from),
        'date_to': _formatDate(to),
        'format': 'pdf',
      },
    );

    final response = await http.get(uri, headers: _headers).timeout(_timeout);

    if (response.statusCode == 200) {
      return response.bodyBytes;
    }

    throw Exception(
      _extractErrorMessage(response, 'Failed to export dispensing report PDF'),
    );
  }

  Future<Uint8List> exportSeniorCitizenReportPdf({
    required DateTime from,
    required DateTime to,
  }) async {
    final uri = Uri.parse('$_baseUrl/admin/reports/senior-citizen').replace(
      queryParameters: {
        'date_from': _formatDate(from),
        'date_to': _formatDate(to),
        'format': 'pdf',
      },
    );

    final response = await http.get(uri, headers: _headers).timeout(_timeout);

    if (response.statusCode == 200) {
      return response.bodyBytes;
    }

    throw Exception(
      _extractErrorMessage(
        response,
        'Failed to export senior citizen report PDF',
      ),
    );
  }

  /// Pulls a usable error message out of a failed response body, falling
  /// back to [fallback] when the body isn't JSON or has no message/errors —
  /// so failures show the actual server-side reason instead of always the
  /// same generic string, which otherwise hides what actually went wrong.
  String _extractErrorMessage(http.Response response, String fallback) {
    try {
      final data = safeMap(jsonDecode(response.body));
      if (data == null) return fallback;
      if (data['message'] is String && (data['message'] as String).isNotEmpty) {
        return data['message'] as String;
      }
      if (data['errors'] != null) {
        return '$fallback: ${data['errors']}';
      }
    } catch (_) {
      // Response body wasn't JSON (e.g. an HTML error page) — fall through.
    }
    return '$fallback (HTTP ${response.statusCode})';
  }

  String _formatDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  Future<PatientDetailResponse> fetchPatientDetail(String patientId) async {
    final uris = [
      Uri.parse('$_baseUrl/admin/patients/$patientId/adherence-detail'),
      Uri.parse('$_baseUrl/admin/patients/$patientId'),
    ];

    for (final uri in uris) {
      try {
        final response = await http
            .get(uri, headers: _headers)
            .timeout(_timeout);

        developer.log(
          'AdminApiService.fetchPatientDetail: URL=$uri, statusCode=${response.statusCode}',
        );

        if (response.statusCode == 200) {
          final data = safeMap(jsonDecode(response.body)) ?? {};
          return PatientDetailResponse.fromJson(data);
        }

        if (response.statusCode == 404) {
          continue;
        }

        final data = safeMap(jsonDecode(response.body));
        final message =
            data?['message']?.toString() ?? 'Failed to fetch patient detail';
        throw Exception(message);
      } on TimeoutException {
        continue;
      }
    }

    throw Exception('Patient not found');
  }

  Future<void> lockPrescription(String prescriptionId) async {
    final response = await http
        .post(
          Uri.parse('$_baseUrl/admin/prescriptions/$prescriptionId/lock'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: '{}',
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      final data = safeMap(jsonDecode(response.body));
      final message =
          data?['message']?.toString() ?? 'Failed to lock prescription';
      throw Exception(message);
    }
  }

  Future<void> unlockPrescription(String prescriptionId) async {
    final response = await http
        .post(
          Uri.parse('$_baseUrl/admin/prescriptions/$prescriptionId/unlock'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: '{}',
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      final data = safeMap(jsonDecode(response.body));
      final message =
          data?['message']?.toString() ?? 'Failed to unlock prescription';
      throw Exception(message);
    }
  }
}
