# Laravel Backend API Setup for Home Dashboard

## Goal
Create Laravel API endpoints that the Flutter `HomeDashboardScreen` connects to via `DashboardRepository`.

Base URL: `http://192.168.100.223:8000/api`
All endpoints require `Authorization: Bearer <token>` header.
All endpoints accept optional `?period=today|week|month` query parameter.

---

## Endpoints Required

### 1. GET `/api/dashboard/summary`
**Query params:** `period`, `date_from`, `date_to`, `branch_id`

**Response:**
```json
{
  "data": {
    "period": "today",
    "date_from": "2025-01-15 00:00:00",
    "date_to": "2025-01-15 23:59:59",
    "rx_count": 42,
    "active_alerts": 3,
    "od_flags_logged": 5,
    "avg_adherence": 87.5,
    "refills_due": 12
  }
}
```

**Controller logic:**
- Count prescriptions dispensed in period
- Count unresolved alerts in period
- Count overdispensing flags logged in period
- Calculate avg adherence % from patient_adherence records
- Count refills due in period (patients with refill_date <= today)

---

### 2. GET `/api/me`
**No query params.**

**Response:**
```json
{
  "data": {
    "user": {
      "name": "Maria Santos",
      "branch_name": "Main Branch",
      "shift_start": "08:00:00",
      "shift_end": "17:00:00"
    }
  }
}
```

**Controller logic:**
- Return authenticated user info
- Include shift and branch info from `users` table

---

## Database Tables Needed

```sql
-- Already likely exists
prescriptions (id, ocr_code, total_price, created_at, status, ...)
patients (id, name, ...)
users (id, name, branch_id, shift_start, shift_end, ...)
```

---

## Routes (routes/api.php)

```php
Route::middleware('auth:sanctum')->group(function () {
    Route::get('/me', [DashboardController::class, 'me']);
    Route::get('/dashboard/summary', [DashboardController::class, 'summary']);
});
```

---

## Period Date Mapping

| Period | Date Range |
|--------|------------|
| `today` | `whereDate('created_at', today())` |
| `week` | `whereBetween('created_at', [startOfWeek(), endOfWeek()])` |
| `month` | `whereMonth('created_at', now()->month)` |
