#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_bluetooth_classic_serial.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_bluetooth_classic_serial'
  s.version          = '1.0.4'
  s.summary          = 'A Flutter plugin for Bluetooth Classic communication'
  s.description      = <<-DESC
A Flutter plugin for Bluetooth Classic communication on Android, iOS, and Windows platforms.
Supports device discovery, connection management, and data transmission.
                       DESC
  s.homepage         = 'https://github.com/C0DE-IN/flutter_bluetooth_classic_serial'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'C0DE-IN' => 'your-email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  s.platform = :ios, '11.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end