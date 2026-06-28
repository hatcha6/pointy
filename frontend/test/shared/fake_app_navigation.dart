import 'package:flutter/widgets.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';

/// Test double for the app-level navigation handle: records requested
/// destinations instead of routing.
class FakeAppNavigation implements AppNavigation {
  FakeAppNavigation({
    required this.currentUser,
    AuthorizationCapabilities? capabilities,
    this.onNavigate,
    this.onLogoutRequested,
    this.onOpenAiChat,
  }) : capabilities =
           capabilities ?? AuthorizationCapabilities.forUser(currentUser);

  @override
  final PosUser currentUser;

  @override
  final AuthorizationCapabilities capabilities;

  final void Function(AppNavigationDestination destination)? onNavigate;
  final VoidCallback? onLogoutRequested;
  final void Function(String? seedPrompt, bool autoSend)? onOpenAiChat;

  @override
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  }) {
    onNavigate?.call(destination);
  }

  @override
  void openAiChat(
    BuildContext context, {
    String? seedPrompt,
    bool autoSend = false,
    AppNavigationDestination? from,
  }) {
    onOpenAiChat?.call(seedPrompt, autoSend);
  }

  @override
  void logout(BuildContext context) {
    onLogoutRequested?.call();
  }
}
