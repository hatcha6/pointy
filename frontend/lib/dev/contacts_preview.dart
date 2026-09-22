// Dev-only preview harness for the contacts screen (customers + suppliers).
//
// Renders the real `ContactManagementScreen` against a fake HTTP backend that
// paginates 500 customers and 500 suppliers 50 at a time, exactly as the real
// API does. Used to watch infinite scroll in a real engine, where the widget
// tests cannot see mouse-wheel scrolling or real frame scheduling.
//
//   flutter run -d web-server --web-port 8095 -t lib/dev/contacts_preview.dart
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/contacts/view_models/contact_management_view_model.dart';
import 'package:pointy_frontend/src/features/contacts/views/contact_management_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';

const _pageSize = 50;
const _totalRows = 500;

void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatefulWidget {
  const _PreviewApp();

  @override
  State<_PreviewApp> createState() => _PreviewAppState();
}

class _PreviewAppState extends State<_PreviewApp> {
  late final PosApiService _service;
  late final ContactManagementViewModel _viewModel;

  @override
  void initState() {
    super.initState();
    _service = PosApiService(
      baseUrl: 'http://preview.local/api',
      client: MockClient(_handle),
    );
    _viewModel = ContactManagementViewModel(ContactRepository(_service));
  }

  /// Set true to drop the first page-2 request, the way a shop LAN drops one,
  /// and watch the list offer its retry footer instead of freezing.
  bool _dropNextPage = false;

  Future<http.Response> _handle(http.Request request) async {
    final page = int.tryParse(request.url.queryParameters['page'] ?? '1') ?? 1;
    final isSuppliers = request.url.path.endsWith('/suppliers/');
    debugPrint('[preview] ${request.url.path} page=$page');
    if (page > 1 && _dropNextPage && request.url.path.endsWith('/customers/')) {
      _dropNextPage = false;
      debugPrint('[preview] DROPPED customers page=$page');
      return http.Response('', 503);
    }
    // A round trip a person would notice, so the loading state is visible.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final start = (page - 1) * _pageSize;
    final rows = [
      for (var i = start; i < start + _pageSize && i < _totalRows; i++)
        isSuppliers ? _supplierJson(i) : _customerJson(i),
    ];
    final hasNext = start + _pageSize < _totalRows;
    return http.Response(
      jsonEncode({
        'count': _totalRows,
        'next': hasNext ? 'http://preview.local/api/x?page=${page + 1}' : null,
        'previous': null,
        'results': rows,
      }),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = PosUser.fromJson(const {
      'id': 1,
      'username': 'manager',
      'display_name': 'مدير النظام',
      'email': '',
      'role': 'manager',
      'permissions': <String>[],
      'is_active': true,
    });

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
      home: ContactManagementScreen(
        viewModel: _viewModel,
        purchaseRepository: PurchaseRepository(_service),
        printingRepository: PrintingRepository(_service),
        shopSettingsRepository: ShopSettingsRepository(_service),
        capabilities: AuthorizationCapabilities.forUser(user),
        navigation: _PreviewNavigation(user),
      ),
    );
  }
}

Map<String, Object?> _customerJson(int index) {
  return {
    'id': index + 1,
    'customer_number': 'C-${(index + 1).toString().padLeft(4, '0')}',
    'full_name': 'زبون رقم ${index + 1}',
    'phone': '09${(index + 1).toString().padLeft(8, '0')}',
    'email': '',
    'gender': '',
    'marketing_consent': false,
    'notes': '',
    'is_active': true,
  };
}

Map<String, Object?> _supplierJson(int index) {
  return {
    'id': index + 1,
    'name': 'مورد رقم ${index + 1}',
    'contact_name': '',
    'phone': '09${(index + 1).toString().padLeft(8, '0')}',
    'email': '',
    'address': '',
    'notes': '',
    'is_active': true,
  };
}

class _PreviewNavigation implements AppNavigation {
  _PreviewNavigation(this.currentUser)
    : capabilities = AuthorizationCapabilities.forUser(currentUser);

  @override
  final PosUser currentUser;

  @override
  final AuthorizationCapabilities capabilities;

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
