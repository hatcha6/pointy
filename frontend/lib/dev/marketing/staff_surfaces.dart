// Dev-only, safe to delete, never imported by lib/main.dart.
//
// Attendance from a BioTime (ZKTeco) fingerprint device, and the payroll run
// it feeds, against a fake HTTP backend — the JSON goes through the real
// parsing. Surfaces:
//   attendance         — «الحضور» tab of the employees workspace, September,
//                        سالم علي المسماري: a late morning here and there and
//                        one absence
//   attendance-device  — the BioTime connection page: device linked, synced
//                        minutes ago, four staff mapped to their device codes
//   payroll            — September's draft payroll run: absences and overtime
//                        from the device, loan instalments taken
//   payroll-home       — the payroll tab with the run history
//
// Every figure reconciles: the payroll run's absences and overtime hours are
// the attendance days below, and its totals are the sums of its lines.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/employee.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/attendance_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/employee_repository.dart';
import 'package:pointy_frontend/src/data/repositories/user_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/attendance/view_models/attendance_view_model.dart';
import 'package:pointy_frontend/src/features/attendance/views/attendance_settings_page.dart';
import 'package:pointy_frontend/src/features/employees/view_models/employee_payroll_view_model.dart';
import 'package:pointy_frontend/src/features/employees/views/employee_payroll_screen.dart';
import 'package:pointy_frontend/src/features/employees/views/payroll_run_details_screen.dart';

import 'drive.dart';
import 'preview_navigation.dart';

class StaffSurface extends StatefulWidget {
  const StaffSurface({super.key, required this.screen});

  final String screen;

  @override
  State<StaffSurface> createState() => _StaffSurfaceState();
}

class _StaffSurfaceState extends State<StaffSurface> {
  late final PosApiService _service = PosApiService(
    baseUrl: 'http://preview.local/api',
    client: MockClient(_handle),
  );
  late final _payroll = EmployeePayrollViewModel(EmployeeRepository(_service));
  late final _attendance = AttendanceViewModel(AttendanceRepository(_service));

  @override
  void initState() {
    super.initState();
    if (widget.screen == 'attendance') {
      unawaited(_openAttendanceReview());
    }
  }

  /// «الحضور» tab → سالم → back one month to September.
  Future<void> _openAttendanceReview() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await selectTab(3);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await pickFirstDropdown<int>(5);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    // RTL: the arrow pointing back in time is the trailing one.
    await pressIconButton(Icons.arrow_back);
  }

  @override
  void dispose() {
    _payroll.dispose();
    _attendance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final capabilities = AuthorizationCapabilities.forUser(previewManager);
    return switch (widget.screen) {
      'attendance-device' => AttendanceSettingsPage(viewModel: _attendance),
      'payroll' => PayrollRunDetailsScreen(
        viewModel: _payroll,
        attendanceViewModel: _attendance,
        capabilities: capabilities,
        initialRun: PayrollRun.fromJson(_septemberRun()),
      ),
      _ => EmployeePayrollScreen(
        viewModel: _payroll,
        attendanceViewModel: _attendance,
        userRepository: UserRepository(_service),
        capabilities: capabilities,
        navigation: PreviewNavigation(previewManager, capabilities),
        contactRepository: ContactRepository(_service),
      ),
    };
  }

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    final query = request.url.queryParameters;
    Object? body = const {'count': 0, 'next': null, 'results': <Object?>[]};

    if (path.endsWith('/attendance/connection/')) {
      body = _connection();
    } else if (path.endsWith('/attendance/profiles/ensure/')) {
      body = const <String, Object?>{};
    } else if (path.endsWith('/attendance/profiles/')) {
      body = _page(_profiles);
    } else if (path.endsWith('/attendance/days/summary/')) {
      final days = _daysFor(query);
      body = _summaryOf(days, query);
    } else if (path.endsWith('/attendance/days/')) {
      body = _page(_daysFor(query).reversed.toList());
    } else if (path.endsWith('/payroll-runs/31/')) {
      body = _septemberRun();
    } else if (path.endsWith('/payroll-runs/')) {
      body = _page(_runs());
    } else if (path.endsWith('/employee-loans/')) {
      body = _page(_loans);
    } else if (path.endsWith('/employees/')) {
      body = _page(_employees);
    }
    return http.Response(
      jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  }
}

Map<String, Object?> _page(List<Object?> rows) => {
  'count': rows.length,
  'next': null,
  'results': rows,
};

// ---------------------------------------------------------------------------
// Staff
// ---------------------------------------------------------------------------

Map<String, Object?> _employee(
  int id,
  String name,
  String title,
  String salary,
  String hired,
) => {
  'id': id,
  'employee_number': 'E-${id.toString().padLeft(4, '0')}',
  'full_name': name,
  'job_title': title,
  'status': 'active',
  'employment_type': 'full_time',
  'hire_date': hired,
  'active_compensation_plan': {
    'id': id + 10,
    'employee': id,
    'pay_type': 'monthly_salary',
    'salary_type': 'monthly_fixed',
    'amount': salary,
    'effective_from': '2026-01-01',
    'is_active': true,
  },
};

final _employees = <Map<String, Object?>>[
  _employee(5, 'سالم علي المسماري', 'كاشير', '1500.00', '2025-02-01'),
  _employee(6, 'فاطمة الورفلي', 'محاسبة', '1800.00', '2024-09-15'),
  _employee(7, 'خالد بن عمران', 'أمين مخزن', '1200.00', '2026-03-01'),
  _employee(8, 'مريم التاجوري', 'مندوبة مبيعات', '1400.00', '2023-05-01'),
];

String _nameOf(int id) =>
    _employees.firstWhere((row) => row['id'] == id)['full_name']! as String;

final _profiles = <Map<String, Object?>>[
  for (final employee in _employees)
    {
      'id': employee['id'],
      'employee': employee['id'],
      'employee_name': employee['full_name'],
      'employee_number': employee['employee_number'],
      'biotime_emp_code': '10${employee['id']}',
      'biotime_full_name': employee['full_name'],
      'is_tracked': true,
    },
];

const _loans = <Map<String, Object?>>[
  {
    'id': 40,
    'employee': 5,
    'employee_name': 'سالم علي المسماري',
    'employee_number': 'E-0005',
    'status': 'approved',
    'amount': '1200.00',
    'monthly_deduction': '200.00',
    'outstanding_balance': '800.00',
    'deducted_amount': '400.00',
    'purpose': 'علاج',
    'created_at': '2026-07-02T09:00:00Z',
    'disbursed_at': '2026-07-02T09:00:00Z',
    'disbursement_method': 'cash',
  },
  {
    'id': 38,
    'employee': 6,
    'employee_name': 'فاطمة الورفلي',
    'employee_number': 'E-0006',
    'status': 'approved',
    'amount': '2000.00',
    'monthly_deduction': '250.00',
    'outstanding_balance': '1500.00',
    'deducted_amount': '500.00',
    'purpose': 'مصاريف دراسة',
    'created_at': '2026-07-10T09:00:00Z',
    'disbursed_at': '2026-07-10T09:00:00Z',
    'disbursement_method': 'cash',
  },
];

// ---------------------------------------------------------------------------
// The fingerprint device
// ---------------------------------------------------------------------------

/// Saturday to Thursday; Friday off. Python weekday numbering (Mon = 0).
const _workdays = {5, 6, 0, 1, 2, 3};
const _graceMinutes = 10;

Map<String, Object?> _connection() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return {
    'base_url': 'http://192.168.1.20:8090',
    'username': 'admin',
    'has_password': true,
    'is_enabled': true,
    'workdays': '5,6,0,1,2,3',
    'shift_start': '09:00',
    'shift_end': '17:00',
    'grace_minutes': _graceMinutes,
    // The device is pulled every few minutes; a mid-morning pull reads best.
    'last_synced_at': today
        .add(const Duration(hours: 9, minutes: 47))
        .toUtc()
        .toIso8601String(),
    'last_sync_status': 'success',
    'synced_from': '2025-02-01',
    'synced_through': _iso(today),
  };
}

/// What happened on one day of September 2026, by employee: minutes late,
/// minutes of overtime, or absent. Every other workday is an ordinary one.
/// Kept small and explicit so the payroll run can be checked against it.
const _septemberEvents = <int, Map<int, ({int late, int overtime})?>>{
  // سالم: three late mornings (22 + 35 + 18 = 75 min), absent on the 17th.
  5: {
    3: (late: 22, overtime: 0),
    14: (late: 35, overtime: 0),
    17: null,
    22: (late: 18, overtime: 0),
  },
  // فاطمة: month-end closing — 90 + 120 + 150 = 360 min = 6 h overtime.
  6: {
    7: (late: 0, overtime: 90),
    10: (late: 14, overtime: 0),
    15: (late: 0, overtime: 120),
    29: (late: 0, overtime: 150),
  },
  // خالد: absent on the 8th and the 21st.
  7: {
    2: (late: 40, overtime: 0),
    8: null,
    16: (late: 25, overtime: 0),
    21: null,
  },
  // مريم: two long days with a delivery round — 60 + 120 = 180 min = 3 h.
  8: {12: (late: 0, overtime: 60), 26: (late: 0, overtime: 120)},
};

/// Workdays an absence is costed against in September (30 days, 4 Fridays).
const _septemberWorkdays = 26;

String _iso(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

String _clock(DateTime day, int minutes) {
  final at = day.add(Duration(minutes: minutes));
  return '${_iso(at)}T${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}:00Z';
}

List<Map<String, Object?>> _daysFor(Map<String, String> query) {
  final employeeId = int.tryParse(query['employee'] ?? '') ?? 5;
  final from = DateTime.tryParse(query['date_from'] ?? '');
  final to = DateTime.tryParse(query['date_to'] ?? '');
  if (from == null || to == null) {
    return const [];
  }
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final rows = <Map<String, Object?>>[];
  var id = employeeId * 1000;
  for (
    var day = from;
    !day.isAfter(to) && day.isBefore(today);
    day = DateTime(day.year, day.month, day.day + 1)
  ) {
    if (!_workdays.contains(day.weekday - 1)) {
      continue;
    }
    final events = day.year == 2026 && day.month == 9
        ? _septemberEvents[employeeId] ?? const {}
        : const <int, ({int late, int overtime})?>{};
    if (events.containsKey(day.day) && events[day.day] == null) {
      continue; // absent: the device has no punch for the day
    }
    final event = events[day.day];
    final seed = employeeId * 7 + day.day * 13;
    // An ordinary morning: between 8:47 and 9:04, inside the grace window.
    final late = event?.late ?? 0;
    final inAt = late > 0 ? 9 * 60 + late : 8 * 60 + 47 + seed % 18;
    final overtime = event?.overtime ?? 0;
    final outAt = overtime > 0
        ? 17 * 60 + overtime
        : 16 * 60 + 56 + (seed ~/ 3) % 5;
    rows.add({
      'id': id++,
      'employee': employeeId,
      'employee_name': _nameOf(employeeId),
      'date': _iso(day),
      'status': late > 0 ? 'late' : 'present',
      'first_in': _clock(day, inAt),
      'last_out': _clock(day, outAt),
      'punch_count': 2,
      'worked_minutes': outAt - inAt,
      'late_minutes': late,
      'early_leave_minutes': 0,
      'overtime_minutes': overtime,
    });
  }
  return rows;
}

Map<String, Object?> _summaryOf(
  List<Map<String, Object?>> days,
  Map<String, String> query,
) {
  final from = DateTime.parse(query['date_from']!);
  final to = DateTime.parse(query['date_to']!);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  var expected = 0;
  for (
    var day = from;
    !day.isAfter(to) && day.isBefore(today);
    day = DateTime(day.year, day.month, day.day + 1)
  ) {
    if (_workdays.contains(day.weekday - 1)) {
      expected += 1;
    }
  }
  int sum(String key) =>
      days.fold(0, (total, row) => total + (row[key]! as int));
  return {
    'expected_days': expected,
    'present_days': days.length,
    'absent_days': expected - days.length,
    'worked_minutes': sum('worked_minutes'),
    'late_minutes': sum('late_minutes'),
    'early_leave_minutes': 0,
    'overtime_minutes': sum('overtime_minutes'),
  };
}

// ---------------------------------------------------------------------------
// Payroll
// ---------------------------------------------------------------------------

double _round(double value) => (value * 100).roundToDouble() / 100;
String _money(double value) => value.toStringAsFixed(2);

/// One employee's September line, built from their salary, the absences and
/// overtime in [_septemberEvents], and the extra adjustments given.
Map<String, Object?> _line(
  int id,
  int employeeId, {
  List<Map<String, Object?>> adjustments = const [],
}) {
  final employee = _employees.firstWhere((row) => row['id'] == employeeId);
  final plan = employee['active_compensation_plan']! as Map<String, Object?>;
  final salary = double.parse(plan['amount']! as String);
  final events = _septemberEvents[employeeId] ?? const {};
  final absences = events.values.where((event) => event == null).length;
  final overtimeMinutes = events.values.fold<int>(
    0,
    (total, event) => total + (event?.overtime ?? 0),
  );
  final dayRate = _round(salary / _septemberWorkdays);
  final absenceAmount = _round(salary / _septemberWorkdays * absences);
  final hourly = _round(salary / _septemberWorkdays / 8);
  final overtimeHours = overtimeMinutes / 60;
  final overtimeAmount = _round(
    salary / _septemberWorkdays / 8 * 1.5 * overtimeHours,
  );
  double total(String direction) => adjustments
      .where((row) => row['direction'] == direction)
      .fold(0, (sum, row) => sum + double.parse(row['amount']! as String));
  final additions = _round(overtimeAmount + total('addition'));
  final deductions = _round(absenceAmount + total('deduction'));
  return {
    'id': id,
    'employee': employeeId,
    'employee_name': employee['full_name'],
    'employee_number': employee['employee_number'],
    'compensation_plan': plan['id'],
    'pay_type': 'monthly_salary',
    'salary_type': 'monthly_fixed',
    'units': '1',
    'rate': _money(salary),
    'gross_amount': _money(salary),
    'absence_days': '$absences',
    'absence_day_rate': _money(dayRate),
    'absence_deduction_amount': _money(absenceAmount),
    'overtime_hours': overtimeHours.toStringAsFixed(2),
    'overtime_hourly_rate': _money(hourly),
    'overtime_multiplier': '1.50',
    'overtime_amount': _money(overtimeAmount),
    'additions_amount': _money(additions),
    'deductions_amount': _money(deductions),
    'net_amount': _money(_round(salary + additions - deductions)),
    'adjustments': adjustments,
  };
}

Map<String, Object?> _septemberRun() {
  final lines = [
    _line(
      311,
      5,
      adjustments: const [
        {
          'id': 1,
          'direction': 'deduction',
          'adjustment_type': 'loan',
          'amount': '200.00',
          'notes': 'قسط سلفة العلاج',
        },
      ],
    ),
    _line(
      312,
      6,
      adjustments: const [
        {
          'id': 2,
          'direction': 'deduction',
          'adjustment_type': 'loan',
          'amount': '250.00',
          'notes': 'قسط سلفة الدراسة',
        },
      ],
    ),
    _line(313, 7),
    _line(
      314,
      8,
      adjustments: const [
        {
          'id': 3,
          'direction': 'addition',
          'adjustment_type': 'commission',
          'amount': '150.00',
          'notes': 'عمولة مبيعات سبتمبر',
        },
      ],
    ),
  ];
  double sum(String key) => _round(
    lines.fold(0, (total, line) => total + double.parse('${line[key]}')),
  );
  return {
    'id': 31,
    'run_number': 'PAY-2026-09',
    'status': 'draft',
    'period_start': '2026-09-01',
    'period_end': '2026-09-30',
    'gross_total': _money(sum('gross_amount')),
    'additions_total': _money(sum('additions_amount')),
    'deductions_total': _money(sum('deductions_amount')),
    'net_total': _money(sum('net_amount')),
    'line_count': lines.length,
    'lines': lines,
    'created_at': '2026-10-01T08:30:00',
  };
}

List<Map<String, Object?>> _runs() {
  final september = _septemberRun()..remove('lines');
  return [
    september,
    {
      'id': 30,
      'run_number': 'PAY-2026-08',
      'status': 'paid',
      'period_start': '2026-08-01',
      'period_end': '2026-08-31',
      'gross_total': '5900.00',
      'additions_total': '186.40',
      'deductions_total': '503.85',
      'net_total': '5582.55',
      'line_count': 4,
      'payment_date': '2026-09-02',
    },
    {
      'id': 29,
      'run_number': 'PAY-2026-07',
      'status': 'paid',
      'period_start': '2026-07-01',
      'period_end': '2026-07-31',
      'gross_total': '5900.00',
      'additions_total': '120.00',
      'deductions_total': '446.15',
      'net_total': '5573.85',
      'line_count': 4,
      'payment_date': '2026-08-02',
    },
  ];
}

/// The shop owner, who sees and approves everything here.
final previewManager = PosUser.fromJson(const {
  'id': 1,
  'username': 'owner',
  'display_name': 'المالك',
  'email': '',
  'role': 'manager',
  'permissions': <String>[],
  'is_active': true,
});
