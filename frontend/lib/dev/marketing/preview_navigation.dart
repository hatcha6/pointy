// Dev-only, safe to delete, never imported by lib/main.dart.
import 'package:flutter/material.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';

/// Feeds the real navigation drawer; every destination is a no-op here.
class PreviewNavigation implements AppNavigation {
  const PreviewNavigation(this.currentUser, this.capabilities);

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
