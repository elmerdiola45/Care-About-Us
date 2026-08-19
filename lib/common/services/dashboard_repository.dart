import 'dart:convert';

import 'package:http/http.dart' as http;

import '../session.dart';
import '../services/laravel_api_service.dart';
import '../models/dashboard_models.dart';
import 'app_config.dart';

Map<String, dynamic> _safeMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return <String, dynamic>{};
}


class DashboardRepository {
  final String _baseUrl;
  final String? _token;
  static const Duration _timeout = Duration(seconds: 30);

  DashboardRepository({String? baseUrl, String? token})
       : _baseUrl = baseUrl ?? AppConfig.baseUrl,
         _token = token ?? AppSession.instance.token;

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        if (_token != null && _token.isNotEmpty) 'Authorization': 'Bearer $_token',
      };

Future<DashboardSummary> fetchSummary({String? branchId, String? period, String? dateFrom, String? dateTo}) async {
    final params = <String, String>{};
    if (branchId != null) params['branch_id'] = branchId;
    if (period != null) params['period'] = period;
    if (dateFrom != null) params['date_from'] = dateFrom;
    if (dateTo != null) params['date_to'] = dateTo;

    final uri = Uri.parse('$_baseUrl/dashboard/summary').replace(
      queryParameters: params.isEmpty ? null : params,
    );

    final response = await http.get(uri, headers: _headers).timeout(_timeout);

    if (response.statusCode == 200) {
      return DashboardSummary.fromJson(_safeMap(jsonDecode(response.body)));
    }

    throw LaravelApiException(
      'Failed to fetch dashboard summary',
      statusCode: response.statusCode,
    );
  }

  Future<StaffProfile> fetchStaffProfile() async {
    final uri = Uri.parse('$_baseUrl/me');

    final response = await http.get(uri, headers: _headers).timeout(_timeout);

    if (response.statusCode == 200) {
      return StaffProfile.fromJson(_safeMap(jsonDecode(response.body)));
    }

    throw LaravelApiException(
      'Failed to fetch staff profile',
      statusCode: response.statusCode,
    );
   }
}