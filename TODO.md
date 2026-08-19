# TODO - Fix DispenseScreen Not Fetching Prescription Data

## Steps

### 1. ✅ Add `fetchFromBackend()` to `SavedPrescriptionsStore`
- [x] Added `fetchFromBackend()` method that fetches from API, maps to `PrescriptionEntry`, merges/updates existing entries and adds new ones, sorts by date
- [x] Includes `_parseDispensingStatus()` helper

### 2. ✅ Update `DispenseScreen` to Fetch on Init
- [x] Added `_isLoading` state variable
- [x] Calls `SavedPrescriptionsStore.instance.fetchFromBackend()` in `initState()`
- [x] Shows loading spinner while fetching
- [x] Shows error snackbars on timeout/API errors
- [x] Added refresh button in AppBar

### 3. ✅ Refactor `SavedPrescriptionsListScreen` to Use Store Method
- [x] Simplified `_fetchFromBackend()` to call `SavedPrescriptionsStore.instance.fetchFromBackend()`

### 4. ✅ Fix Backend: Add Missing Columns
- [x] Added `dispensing_status`, `is_senior`, `osca_id`, `pharmacist_id`, `dispenser_id`, `pharmacy_id` columns to migration
- [x] Updated `Prescription.php` model `$fillable` and `$casts`

### 5. Test
- [ ] Run `flutter run` and navigate to Dispense tab — prescriptions should now load from backend

### 6. Fix: Add `pharmacy_id` to `dispense_alerts` table (SQL 1054 error)
- [x] Ran migration `2026_07_30_000005_add_pharmacy_id_to_dispense_alerts_table.php` on the Laravel backend
- [x] The `DashboardController::summary()` queries `dispense_alerts` with `where('pharmacy_id', ...)` but the column was missing
- [x] Error was: `SQLSTATE[42S22] Column not found, 1054 Unknown column 'pharmacy_id' in 'where clause'`

### 7. Fix: Start Laravel backend and update Flutter API URL
- [x] Started Laravel server on `192.168.100.223:8000`
- [x] Updated `AppConfig.baseUrl` from `http://localhost:8000/api` to `http://192.168.100.223:8000/api`
- [x] "Could not connect to server" error resolved

### 8. Fix: Create missing `adherence_status` table and fix DashboardSummaryResource
- [x] Created migration `2026_07_30_000006_create_adherence_status_table.php`
- [x] Fixed `DashboardSummaryResource` to use array access (`$this['key']`) instead of property access (`$this->key`)
- [x] 500 error on `/dashboard/summary` resolved

### 9. Fix: Admin routes returning "Route [login] not defined" error
- [x] Created custom `Authenticate` middleware (`app/Http/Middleware/Authenticate.php`) that returns 401 JSON for unauthenticated API requests
- [x] Registered `auth.sanctum` alias in `bootstrap/app.php` pointing to custom `Authenticate` middleware
- [x] `/api/admin/dashboard/summary` and `/api/admin/reports/summary` now return proper 401 JSON instead of crashing

### 10. Fix: Flutter admin dashboard not using `DashboardSummary.fromJson()`
- [x] Updated `admin_dashboard_page.dart` to use `DashboardSummary.fromJson(summary)` instead of creating `DashboardSummary` directly
- [x] This fixes the issue where dashboard summary values were always 0 because the backend wraps data in a `data` key

### 11. Fix: Backend `ReportsController` SQL typo
- [x] Fixed `cpharmacy_id` typo to `cpr.requesting_pharmacy_id` in `ReportsController::summary()`
- [x] This was causing SQL errors that resulted in "Failed to fetch reports summary" in Flutter

### 12. Fix: `fetchReportsSummary` error handling in `AdminApiService`
- [x] Added JSON error response parsing for non-200 responses (consistent with `fetchDashboardSummary`)
- [x] Added `TimeoutException` handling with a clear "Timed out while fetching reports summary" message
- [x] Added fallback for network errors (non-Exception errors) with a clean "Could not reach the server" message
- [x] This fixes the "could not reach the server exception failed to fetch reports summary" error that showed raw technical exceptions to the user

### 13. Fix: Backend `dispensing_logs` table missing `created_at`/`updated_at` columns (SQL 1054 error)
- [x] Diagnosed: `dispensing_logs` table has `dispensed_at` but no `created_at`/`updated_at` columns — the `2026_07_17_124607_create_dispensing_logs_table.php` migration was missing `$table->timestamps()`
- [x] Diagnosed: `DispensingLog` Eloquent model did not declare `$timestamps = false`, causing Laravel to assume `created_at`/`updated_at` exist
- [x] Diagnosed: `DispensingLogController::store()` correctly uses `dispensed_at` for the event date and `orderByDesc('dispensed_at')` for sorting — no queries in the current committed codebase incorrectly reference `created_at` on dispensing_logs
- [x] Created migration `2026_07_31_000000_add_timestamps_to_dispensing_logs.php` that adds `created_at` and `updated_at` columns and backfills from `dispensed_at`
- [x] Flagged `SeniorCitizenDiscount` model as another table missing `$timestamps = false` (migration creates manual `created_at`/`updated_at` columns but model lacks the declaration)
- [x] Flagged `MedicationHistory`, `QrToken`, `ScanLog`, `SystemLog`, `Alert`, `Customer`, `Physician`, `Pharmacist` as models with `$timestamps = false;` but whose migrations should be audited for consistency
- [x] Created feature test `DashboardSummaryTest` in `tests/Feature/` covering the `/api/dashboard/overview` endpoint
- [x] Note: Any new queries filtering dispensing events by date should use `dispensed_at`, not `created_at` (dispensed_at = when the dispensing event occurred; created_at = when the DB record was written)
