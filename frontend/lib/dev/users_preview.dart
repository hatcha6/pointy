// Dev-only preview harness for the redesigned Users area.
//
// Renders the user-management list, the create/edit sheets + role picker, and
// the per-user permission editor full-viewport, backed by an in-memory fake
// repository (no backend/auth). Every action works — search, role filter,
// create, edit, toggle active, and grant/revoke extra permissions. Pick the
// surface with a `?screen=` query param and resize the browser to test
// responsiveness. Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/users_preview.dart
//
// Screens: list | permissions | empty
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/permission_catalog.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/user_activity.dart';
import 'package:pointy_frontend/src/data/repositories/user_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/users/view_models/user_details_view_model.dart';
import 'package:pointy_frontend/src/features/users/view_models/user_management_view_model.dart';
import 'package:pointy_frontend/src/features/users/view_models/user_permissions_view_model.dart';
import 'package:pointy_frontend/src/features/users/views/user_details_screen.dart';
import 'package:pointy_frontend/src/features/users/views/user_management_screen.dart';
import 'package:pointy_frontend/src/features/users/views/user_permissions_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: const _Router(),
    );
  }
}

String _screen() {
  final uri = Uri.base;
  final direct = uri.queryParameters['screen'];
  if (direct != null) {
    return direct;
  }
  final fragment = uri.fragment;
  final parsed = Uri.tryParse(
    fragment.startsWith('/') ? fragment.substring(1) : fragment,
  );
  return parsed?.queryParameters['screen'] ?? 'list';
}

final _capabilities = AuthorizationCapabilities.forUser(_managerUser);

class _Router extends StatelessWidget {
  const _Router();

  @override
  Widget build(BuildContext context) {
    final repo = _FakeUserRepository(_screen() == 'empty' ? [] : _seedUsers());
    if (_screen() == 'details') {
      return UserDetailsScreen(
        viewModel: UserDetailsViewModel(
          repo,
          initialUser: PosUser.fromJson(_seedUsers()[2]),
        ),
        capabilities: _capabilities,
        onManagePermissions: (_) async => false,
      );
    }
    if (_screen() == 'permissions') {
      return UserPermissionsScreen(
        viewModel: UserPermissionsViewModel(
          repo,
          user: PosUser.fromJson(_seedUsers()[2]),
        ),
      );
    }
    return _UsersHost(repo: repo);
  }
}

class _UsersHost extends StatelessWidget {
  const _UsersHost({required this.repo});

  final _FakeUserRepository repo;

  @override
  Widget build(BuildContext context) {
    final viewModel = UserManagementViewModel(repo);
    return UserManagementScreen(
      viewModel: viewModel,
      currentUser: _managerUser,
      capabilities: _capabilities,
      navigation: _FakeNavigation(),
      onOpenUserDetails: (user) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => UserDetailsScreen(
            viewModel: UserDetailsViewModel(repo, initialUser: user),
            capabilities: _capabilities,
            onManagePermissions: (target) => _openPermissions(context, target),
          ),
        ),
      ),
      onOpenUserPermissions: (user) => _openPermissions(context, user),
    );
  }

  Future<bool> _openPermissions(BuildContext context, PosUser user) async {
    final updated = await Navigator.of(context).push<PosUser>(
      MaterialPageRoute<PosUser>(
        builder: (_) => UserPermissionsScreen(
          viewModel: UserPermissionsViewModel(repo, user: user),
        ),
      ),
    );
    return updated != null;
  }
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeNavigation implements AppNavigation {
  _FakeNavigation();

  @override
  final AuthorizationCapabilities capabilities = _capabilities;
  @override
  final PosUser currentUser = _managerUser;

  @override
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  }) {}

  @override
  void openAiChat(
    BuildContext context, {
    String? seedPrompt,
    bool autoSend = false,
    AppNavigationDestination? from,
  }) {}

  @override
  void logout(BuildContext context) {}
}

final PosUser _managerUser = PosUser.fromJson(const {
  'id': 1,
  'username': 'manager',
  'role': 'manager',
  'permissions': <String>[],
});

/// In-memory user store backing the preview. Mutating methods update the store
/// so the harness behaves like the real thing.
class _FakeUserRepository extends UserRepository {
  _FakeUserRepository(List<Map<String, Object?>> seed)
    : super(PosApiService()) {
    _users.addAll(seed.map(Map<String, Object?>.from));
    _nextId = _users.fold<int>(0, (max, u) {
      final id = (u['id'] as num?)?.toInt() ?? 0;
      return id > max ? id : max;
    });
  }

  final List<Map<String, Object?>> _users = [];
  int _nextId = 0;

  @override
  Future<Result<PosUserPage>> loadUsers({
    int page = 1,
    String search = '',
    String role = '',
  }) async {
    Iterable<Map<String, Object?>> rows = _users;
    if (search.trim().isNotEmpty) {
      final term = search.trim().toLowerCase();
      rows = rows.where((u) {
        final hay = '${u['username']} ${u['first_name']} ${u['email']}'
            .toLowerCase();
        return hay.contains(term);
      });
    }
    if (role.trim().isNotEmpty) {
      rows = rows.where((u) => u['assigned_role'] == role.trim());
    }
    final list = rows.toList(growable: false);
    return Ok(
      PosUserPage(
        users: list.map(PosUser.fromJson).toList(growable: false),
        hasMore: false,
        totalCount: list.length,
      ),
    );
  }

  @override
  Future<Result<PosUser>> loadUser(int id) async {
    final map = _users.firstWhere((u) => (u['id'] as num).toInt() == id);
    return Ok(PosUser.fromJson(map));
  }

  @override
  Future<Result<PosUser>> createUser(UserCreateDraft draft) async {
    final role = draft.role.toJson();
    final map = <String, Object?>{
      'id': ++_nextId,
      'username': draft.username,
      'first_name': draft.displayName,
      'email': draft.email,
      'assigned_role': role,
      'is_active': draft.isActive,
      'role_permissions': _roleCodes[role] ?? const <String>[],
      'extra_permissions': draft.extraPermissions ?? const <String>[],
      'extra_permission_count': draft.extraPermissions?.length ?? 0,
      'effective_permissions': {
        ...?(_roleCodes[role]),
        ...?draft.extraPermissions,
      }.toList(),
    };
    _users.add(map);
    return Ok(PosUser.fromJson(map));
  }

  @override
  Future<Result<PosUser>> updateUser({
    required int id,
    required UserUpdateDraft draft,
  }) async {
    final map = _users.firstWhere((u) => (u['id'] as num).toInt() == id);
    final body = draft.toJson();
    if (body.containsKey('first_name')) {
      map['first_name'] = body['first_name'];
    }
    if (body.containsKey('email')) map['email'] = body['email'];
    if (body.containsKey('is_active')) map['is_active'] = body['is_active'];
    if (body.containsKey('role')) {
      map['assigned_role'] = body['role'];
      map['role_permissions'] = _roleCodes[body['role']] ?? const <String>[];
    }
    final role = map['assigned_role'] as String;
    final roleCodes = (_roleCodes[role] ?? const <String>[]).toSet();
    if (body.containsKey('extra_permissions')) {
      final extras = ((body['extra_permissions'] as List?) ?? const [])
          .map((e) => e.toString())
          .where((code) => !roleCodes.contains(code))
          .toList();
      map['extra_permissions'] = extras;
      map['extra_permission_count'] = extras.length;
    }
    final extras = ((map['extra_permissions'] as List?) ?? const []).map(
      (e) => e.toString(),
    );
    map['effective_permissions'] = {...roleCodes, ...extras}.toList();
    return Ok(PosUser.fromJson(map));
  }

  @override
  Future<Result<UserActivityOverview>> loadUserActivity(int id) async {
    final map = _users.firstWhere((u) => (u['id'] as num).toInt() == id);
    return Ok(
      UserActivityOverview.fromJson({
        'user': map,
        'summary': {
          'sales': {
            'invoice_count': 128,
            'paid_invoice_count': 119,
            'credit_invoice_count': 9,
            'credit_outstanding_total': '820.00',
            'net_sales': '14350.00',
          },
        },
        'recent_sales': [
          _previewSale(id: 901, number: '1042', total: '47.00'),
          _previewSale(id: 902, number: '1041', total: '128.50'),
        ],
        // The point of the split: debt reads apart from settled cash sales.
        'recent_credit_sales': [
          _previewSale(
            id: 801,
            number: '1039',
            total: '400.00',
            saleType: 'credit',
            amountPaid: '150.00',
            balanceDue: '250.00',
            paymentStatus: 'partial',
            isOverdue: true,
          ),
          _previewSale(
            id: 802,
            number: '1035',
            total: '320.00',
            saleType: 'credit',
            balanceDue: '320.00',
            paymentStatus: 'unpaid',
            dueDate: '2026-10-01',
          ),
          _previewSale(
            id: 803,
            number: '1028',
            total: '250.00',
            saleType: 'credit',
            balanceDue: '250.00',
            paymentStatus: 'unpaid',
          ),
        ],
      }),
    );
  }

  @override
  Future<Result<PermissionCatalog>> loadPermissionCatalog() async {
    return Ok(PermissionCatalog.fromJson(_catalogJson));
  }
}

Map<String, Object?> _previewSale({
  required int id,
  required String number,
  required String total,
  String saleType = 'standard',
  String amountPaid = '0.00',
  String balanceDue = '0.00',
  String paymentStatus = 'paid',
  String? dueDate,
  bool isOverdue = false,
}) {
  return {
    'id': id,
    'receipt_number': number,
    'status': saleType == 'credit' ? 'open' : 'paid',
    'sale_type': saleType,
    'customer_name': 'سارة أحمد',
    'register_session_number': 'RS-7',
    'subtotal': total,
    'discount_total': '0.00',
    'total': total,
    'amount_paid': amountPaid,
    'balance_due': balanceDue,
    'payment_status': paymentStatus,
    'due_date': dueDate,
    'is_overdue': isOverdue,
    'created_at': '2026-09-15T09:00:00Z',
  };
}

// ---------------------------------------------------------------------------
// Seed data
// ---------------------------------------------------------------------------

const Map<String, List<String>> _roleCodes = {
  'manager': ['*'],
  'supervisor': [
    'reports.view_reportrun',
    'sales.view_order',
    'sales.add_order',
    'inventory.apply_stockcount',
    'operations.assign_job',
  ],
  'accountant': [
    'reports.view_reportrun',
    'payments.view_payment',
    'expenses.view_expense',
  ],
  'auditor': [
    'reports.view_reportrun',
    'sales.view_order',
    'inventory.view_stockitem',
  ],
  'purchasing_agent': [
    'purchasing.add_purchaseorder',
    'purchasing.receive_purchaseorder',
    'purchasing.view_supplier',
  ],
  'inventory_clerk': [
    'inventory.view_stockitem',
    'inventory.add_stockcount',
    'inventory.apply_stockcount',
  ],
  'technician': ['operations.view_job', 'operations.add_job'],
  'cashier': ['sales.add_order', 'sales.view_order'],
};

Map<String, Object?> _user(
  int id,
  String username,
  String name,
  String role, {
  bool active = true,
  List<String> extras = const [],
  String email = '',
}) {
  final roleCodes = _roleCodes[role] ?? const <String>[];
  return {
    'id': id,
    'username': username,
    'first_name': name,
    'email': email,
    'assigned_role': role,
    'is_active': active,
    'role_permissions': roleCodes,
    'extra_permissions': extras,
    'extra_permission_count': extras.length,
    'effective_permissions': {...roleCodes, ...extras}.toList(),
  };
}

List<Map<String, Object?>> _seedUsers() => [
  _user(1, 'manager', 'هند العامري', 'manager', email: 'hind@shop.ly'),
  _user(2, 'supervisor', 'سالم الورفلي', 'supervisor', email: 'salem@shop.ly'),
  _user(
    3,
    'cashier1',
    'ليلى أحمد',
    'cashier',
    extras: ['inventory.apply_stockcount', 'payments.view_payment'],
    email: 'layla@shop.ly',
  ),
  _user(4, 'cashier2', 'كريم منصور', 'cashier', active: false),
  _user(5, 'accountant', 'نور الدين', 'accountant', email: 'nour@shop.ly'),
  _user(6, 'buyer', 'عبدالله الزروق', 'purchasing_agent'),
  _user(7, 'store', 'منى البركي', 'inventory_clerk'),
  _user(8, 'tech', 'يوسف الفيتوري', 'technician'),
  _user(9, 'auditor', 'سعاد الشريف', 'auditor'),
];

const Map<String, Object?> _catalogJson = {
  'groups': [
    {
      'key': 'inventory',
      'label': 'المخزون',
      'description': 'متابعة المخزون وحركاته والجرد.',
      'permissions': [
        {
          'code': 'inventory.view_stockitem',
          'label': 'عرض المخزون',
          'description': 'الاطلاع على الكميات ولوحة المخزون.',
          'grantable': true,
        },
        {
          'code': 'inventory.apply_stockcount',
          'label': 'اعتماد الجرد',
          'description': 'تطبيق فروقات الجرد على المخزون.',
          'grantable': true,
        },
      ],
    },
    {
      'key': 'sales',
      'label': 'المبيعات ونقطة البيع',
      'description': 'البيع وإدارة الورديات والفواتير.',
      'permissions': [
        {
          'code': 'sales.add_order',
          'label': 'إجراء المبيعات',
          'description': 'الوصول لنقطة البيع وإتمام عمليات البيع.',
          'grantable': true,
        },
        {
          'code': 'sales.view_order',
          'label': 'عرض الفواتير',
          'description': 'الاطلاع على الفواتير وأوامر البيع.',
          'grantable': true,
        },
      ],
    },
    {
      'key': 'payments',
      'label': 'المدفوعات والخزينة',
      'description': 'متابعة المقبوضات والمدفوعات.',
      'permissions': [
        {
          'code': 'payments.view_payment',
          'label': 'عرض الخزينة والمدفوعات',
          'description': 'الاطلاع على المقبوضات والمدفوعات.',
          'grantable': true,
        },
      ],
    },
    {
      'key': 'reports',
      'label': 'التقارير والتحليلات',
      'description': 'لوحات المعلومات والتقارير.',
      'permissions': [
        {
          'code': 'reports.view_reportrun',
          'label': 'عرض التقارير ولوحات المعلومات',
          'description': 'يفتح اللوحات ويمنح رؤية على مستوى المتجر كاملاً.',
          'grantable': true,
        },
      ],
    },
    {
      'key': 'expenses',
      'label': 'المصروفات',
      'description': 'تسجيل المصروفات ومتابعتها.',
      'permissions': [
        {
          'code': 'expenses.view_expense',
          'label': 'عرض المصروفات',
          'description': 'الاطلاع على سجل المصروفات.',
          'grantable': true,
        },
        {
          'code': 'expenses.add_expense',
          'label': 'تسجيل المصروفات',
          'description': 'إضافة مصروفات جديدة.',
          'grantable': true,
        },
      ],
    },
  ],
};
