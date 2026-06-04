enum DeviceUsageMode { singleUser, multiUser }

class DeviceSettings {
  const DeviceSettings({required this.usageMode});

  final DeviceUsageMode usageMode;

  factory DeviceSettings.defaults() {
    return const DeviceSettings(usageMode: DeviceUsageMode.singleUser);
  }

  DeviceSettings copyWith({DeviceUsageMode? usageMode}) {
    return DeviceSettings(usageMode: usageMode ?? this.usageMode);
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
