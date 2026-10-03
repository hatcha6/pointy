import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/auth_repository.dart';
import 'package:pointy_frontend/src/data/repositories/employee_repository.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/surveillance_api_client.dart';
import 'package:pointy_frontend/src/features/user_settings/view_models/user_settings_view_model.dart';

/// A refusal the UI is built to read has to survive the API client.
///
/// Clients that checked responses with `ensureSuccess` threw a bare Exception
/// and dropped the status and body, so every flow reading them was dead in
/// production while its tests, fed ready-made exceptions, passed. These go
/// through the real client, over a mocked HTTP connection.
void main() {
  test('a taken username reaches the profile form as a field issue', () async {
    final service = PosApiService(
      client: MockClient((request) async {
        if (request.method == 'PATCH' &&
            request.url.path.endsWith('/auth/me/')) {
          return _json({
            'username': ['A user with that username already exists.'],
          }, status: 400);
        }
        return http.Response('', 404);
      }),
    );
    final viewModel = UserSettingsViewModel(
      AuthRepository(service),
      EmployeeRepository(service),
    );
    addTearDown(viewModel.dispose);

    final saved = await viewModel.updateProfile(
      const CurrentUserProfileDraft(
        username: 'ahmed',
        firstName: 'أحمد',
        lastName: '',
        email: '',
      ),
    );

    expect(saved, isNull);
    // Only the key travels: the backend's sentence is English.
    expect(viewModel.profileIssue, ProfileFieldIssue.usernameTaken);
  });

  test(
    "a polled camera frame's refusal keeps its status and retry_after",
    () async {
      final client = SurveillanceApiClient(
        PosApiSession(
          client: MockClient(
            (_) async => _json({'retry_after': 7}, status: 503),
          ),
          baseUrl: 'http://127.0.0.1:8000/api',
        ),
      );

      final error = await client
          .pollFrames(
            'surveillance/cameras/3/snapshot/',
            const Duration(milliseconds: 1),
          )
          .first
          .then<Object?>((_) => null, onError: (Object e) => e);

      // What the camera view reads to back off as asked, and to stop for good
      // on a 401 or 501 instead of asking a dead recorder twice a second.
      expect(error, isA<PosApiException>());
      final refusal = error! as PosApiException;
      expect(refusal.statusCode, 503);
      expect((refusal.decodedBody as Map)['retry_after'], 7);
    },
  );
}

http.Response _json(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
