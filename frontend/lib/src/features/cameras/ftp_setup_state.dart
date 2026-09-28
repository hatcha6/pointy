import '../../data/models/camera.dart';

/// Where an FTP upload setup stands, most urgent first.
///
/// The order is the order an installer has to fix things in: nothing else
/// matters while the server is down, a wrong password explains why nothing
/// arrives, and "waiting" is only worth saying once nothing is wrong.
enum FtpSetupHealth {
  /// The FTP service is not running on the server at all.
  serverDown,

  /// The server is refusing uploads: the disk is at its floor.
  refusingDisk,

  /// The server is refusing uploads: files are piling up undecided.
  refusingInbox,

  /// A device keeps trying this username with the wrong password.
  wrongPassword,

  /// Nothing has logged in with these credentials yet.
  waiting,

  /// The DVR logged in but has uploaded nothing.
  loggedIn,

  /// Uploads are arriving.
  receiving,

  /// Uploads arrived once and then stopped.
  stale,
}

class FtpSetupStatus {
  const FtpSetupStatus({
    required this.health,
    this.at,
    this.peer = '',
    this.unknownLogins = const [],
    this.ingestError = '',
  });

  final FtpSetupHealth health;

  /// The moment [health] is about: the last upload, or the last login.
  final DateTime? at;

  /// The address a wrong password came from.
  final String peer;

  /// Recent logins with usernames no setup has — worth showing on every FTP
  /// setup, because the typo could have been meant for any of them.
  final List<FtpUnknownLogin> unknownLogins;

  /// The last reason an upload could not be read, if the problem is current.
  final String ingestError;

  bool get isHealthy =>
      health == FtpSetupHealth.receiving || health == FtpSetupHealth.waiting;
}

/// How long without an upload before a working setup is called stale. A DVR
/// uploading around the clock sends something every few minutes; a day of
/// silence is a DVR that has stopped, not a quiet shop.
const ftpStaleAfter = Duration(hours: 24);

/// How far back an unknown-username login is still worth mentioning.
const ftpUnknownLoginWindow = Duration(minutes: 30);

FtpSetupStatus ftpSetupStatusOf(
  FtpAccountInfo account, {
  required DateTime now,
  Duration staleAfter = ftpStaleAfter,
}) {
  final server = account.server;
  final unknown = [
    for (final login in server.recentUnknownLogins)
      if (login.at == null ||
          now.difference(login.at!) <= ftpUnknownLoginWindow)
        login,
  ];
  final ingestError =
      account.lastIngestError.isNotEmpty &&
          (account.lastUploadAt == null ||
              account.lastIngestErrorAt == null ||
              !account.lastIngestErrorAt!.isBefore(
                account.lastUploadAt!.subtract(const Duration(hours: 1)),
              ))
      ? account.lastIngestError
      : '';

  FtpSetupStatus status(
    FtpSetupHealth health, {
    DateTime? at,
    String peer = '',
  }) {
    return FtpSetupStatus(
      health: health,
      at: at,
      peer: peer,
      unknownLogins: unknown,
      ingestError: ingestError,
    );
  }

  if (!server.running) {
    return status(FtpSetupHealth.serverDown);
  }
  if (!server.accepting) {
    return status(
      server.refusingReason == 'inbox_full'
          ? FtpSetupHealth.refusingInbox
          : FtpSetupHealth.refusingDisk,
    );
  }
  final failedAt = account.failedLoginAt;
  final lastLogin = account.lastLoginAt;
  if (account.failedLoginCount > 0 &&
      failedAt != null &&
      (lastLogin == null || failedAt.isAfter(lastLogin))) {
    return status(
      FtpSetupHealth.wrongPassword,
      at: failedAt,
      peer: account.failedLoginPeer,
    );
  }
  final lastUpload = account.lastUploadAt;
  if (lastUpload == null) {
    return lastLogin == null
        ? status(FtpSetupHealth.waiting)
        : status(FtpSetupHealth.loggedIn, at: lastLogin);
  }
  if (now.difference(lastUpload) > staleAfter) {
    return status(FtpSetupHealth.stale, at: lastUpload);
  }
  return status(FtpSetupHealth.receiving, at: lastUpload);
}
