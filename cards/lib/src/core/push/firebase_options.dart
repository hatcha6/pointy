import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// The Firebase project «دفتر كروت» sends its notifications through
/// (`daftar-cards`), as `firebase apps:sdkconfig` prints it for the two
/// phone apps. These are client keys: every copy of the app carries them,
/// and they only identify the app to Firebase. None for the web build, which
/// has no notifications.
FirebaseOptions? cardsFirebaseOptions() {
  if (kIsWeb) {
    return null;
  }
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS => const FirebaseOptions(
      apiKey: 'AIzaSyDEBJNye2h6yNs0r9UQ_wWmu841Oc4zo4U',
      appId: '1:738711514356:ios:1061f050bb7a97dd5c42a1',
      messagingSenderId: '738711514356',
      projectId: 'daftar-cards',
      storageBucket: 'daftar-cards.firebasestorage.app',
      iosBundleId: 'ly.dftr.cards',
    ),
    TargetPlatform.android => const FirebaseOptions(
      apiKey: 'AIzaSyDAel8XOEk4BHkoy9r4xYSFCFiHMvBbqog',
      appId: '1:738711514356:android:0b1a2e6bdcb54c0a5c42a1',
      messagingSenderId: '738711514356',
      projectId: 'daftar-cards',
      storageBucket: 'daftar-cards.firebasestorage.app',
    ),
    _ => null,
  };
}
