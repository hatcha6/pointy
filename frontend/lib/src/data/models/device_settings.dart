enum DeviceUsageMode { singleUser, multiUser }

class DeviceSettings {
  const DeviceSettings({
    required this.usageMode,
    this.cameraWedgeEnabled = false,
    this.cameraWedgeDeviceId,
  });

  final DeviceUsageMode usageMode;

  /// Whether a camera on this machine acts as a barcode scanner. Off until a
  /// shop asks for it: a camera that starts reading barcodes on its own is a
  /// surprise, and on a machine with no camera over the counter it would be a
  /// permission prompt for nothing.
  final bool cameraWedgeEnabled;

  /// Which camera on this machine is the one over the counter. Null means
  /// "whichever is first", which is right when there is only one.
  final String? cameraWedgeDeviceId;

  factory DeviceSettings.defaults() {
    return const DeviceSettings(usageMode: DeviceUsageMode.singleUser);
  }

  DeviceSettings copyWith({
    DeviceUsageMode? usageMode,
    bool? cameraWedgeEnabled,
    String? cameraWedgeDeviceId,
  }) {
    return DeviceSettings(
      usageMode: usageMode ?? this.usageMode,
      cameraWedgeEnabled: cameraWedgeEnabled ?? this.cameraWedgeEnabled,
      cameraWedgeDeviceId: cameraWedgeDeviceId ?? this.cameraWedgeDeviceId,
    );
  }
}

DeviceUsageMode deviceUsageModeFromJson(Object? value) {
  return switch (value?.toString()) {
    'multi_user' || 'multiUser' => DeviceUsageMode.multiUser,
    _ => DeviceUsageMode.singleUser,
  };
}

String deviceUsageModeToJson(DeviceUsageMode mode) {
  return switch (mode) {
    DeviceUsageMode.singleUser => 'single_user',
    DeviceUsageMode.multiUser => 'multi_user',
  };
}
