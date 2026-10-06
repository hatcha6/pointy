# Flutter Bluetooth Classic

A Flutter plugin for Bluetooth Classic communication supporting Android, iOS, macOS, Linux, and Windows platforms.

## Features

- 🔍 **Device Discovery**: Scan for and discover nearby Bluetooth Classic devices
- 🔗 **Connection Management**: Connect and disconnect from Bluetooth devices
- 📡 **Data Transmission**: Send and receive data over Bluetooth connections
- 📱 **Multi-Platform**: Supports Android, iOS, macOS, Linux, and Windows
- 🔄 **Real-time Communication**: Stream data for real-time applications

## Platform Support

| Platform | Support |
|----------|---------|
| Android  | ✅      |
| iOS      | ✅      |
| Windows  | ✅      |
| macOS    | ✅      |
| Linux    | ✅      |
| Web      | ❌      |

## Quick Start

1. **Add the dependency**:
   ```yaml
   dependencies:
     flutter_bluetooth_classic_serial: ^1.3.2
   ```

2. **Import the package**:
   ```dart
   import 'package:flutter_bluetooth_classic_serial/flutter_bluetooth_classic.dart';
   ```

3. **Initialize and use**:
   ```dart
   FlutterBluetoothClassic bluetooth = FlutterBluetoothClassic();
   
   // Check if Bluetooth is available
   bool isSupported = await bluetooth.isBluetoothSupported();
   bool isEnabled = await bluetooth.isBluetoothEnabled();
   
   // Get paired devices
   List<BluetoothDevice> devices = await bluetooth.getPairedDevices();
   
   // Connect to a device
   bool connected = await bluetooth.connect(device.address);
   
   // Listen for data
   bluetooth.onDataReceived.listen((data) {
     print('Received: ${data.asString()}');
   });
   
   // Send message
   await bluetooth.sendString('Hello World!');
   ```

## Example Project

A complete example app is included in the `example/` directory. To run it:

```bash
cd example
flutter run
```

The example demonstrates:
- ✅ Bluetooth state management
- ✅ Device discovery and connection
- ✅ Real-time data communication
- ✅ Auto-reconnection
- ✅ Error handling
- ✅ Modern Material 3 UI

## Permissions

### Android

Add these permissions to your `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />

<!-- For Android 12+ (API 31+) -->
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
```

### iOS

Add to `ios/Runner/Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app needs Bluetooth access to communicate with devices</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>This app needs Bluetooth access to communicate with devices</string>
```

### Windows

Bluetooth capability is automatically included in the Windows implementation.

### macOS

Add to `macos/Runner/Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app needs Bluetooth access to communicate with devices</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>This app needs Bluetooth access to communicate with devices</string>
```

### Linux

No additional permissions required. The plugin uses BlueZ stack which is typically available on Linux systems.

## Usage

### Basic Example

```dart
import 'package:flutter_bluetooth_classic_serial/flutter_bluetooth_classic.dart';

class BluetoothService {
  final FlutterBluetoothClassic _bluetooth = FlutterBluetoothClassic();
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<BluetoothData>? _dataSubscription;
  StreamSubscription<BluetoothState>? _stateSubscription;

  // Check if Bluetooth is supported
  Future<bool> isBluetoothSupported() async {
    try {
      return await _bluetooth.isBluetoothSupported();
    } catch (e) {
      print('Error checking Bluetooth support: $e');
      return false;
    }
  }

  // Check if Bluetooth is enabled
  Future<bool> isBluetoothEnabled() async {
    try {
      return await _bluetooth.isBluetoothEnabled();
    } catch (e) {
      print('Error checking Bluetooth status: $e');
      return false;
    }
  }

  // Get paired devices
  Future<List<BluetoothDevice>> getPairedDevices() async {
    try {
      return await _bluetooth.getPairedDevices();
    } catch (e) {
      print('Error getting paired devices: $e');
      return [];
    }
  }

  // Setup event listeners
  void setupListeners() {
    // Listen for Bluetooth state changes
    _stateSubscription = _bluetooth.onStateChanged.listen(
      (state) {
        print('Bluetooth state: ${state.isEnabled ? "enabled" : "disabled"}');
      },
    );

    // Listen for connection state changes
    _connectionSubscription = _bluetooth.onConnectionChanged.listen(
      (connectionState) {
        if (connectionState.isConnected) {
          print('Connected to ${connectionState.deviceAddress}');
        } else {
          print('Disconnected: ${connectionState.status}');
        }
      },
    );

    // Listen for incoming data
    _dataSubscription = _bluetooth.onDataReceived.listen(
      (data) {
        String received = data.asString();
        print('Received from ${data.deviceAddress}: $received');
      },
    );
  }

  // Connect to a device
  Future<bool> connectToDevice(String deviceAddress) async {
    try {
      return await _bluetooth.connect(deviceAddress);
    } catch (e) {
      print('Connection failed: $e');
      return false;
    }
  }

  // Send string data
  Future<bool> sendMessage(String message) async {
    try {
      return await _bluetooth.sendString(message);
    } catch (e) {
      print('Send failed: $e');
      return false;
    }
  }

  // Send raw data
  Future<bool> sendData(List<int> data) async {
    try {
      return await _bluetooth.sendData(data);
    } catch (e) {
      print('Send failed: $e');
      return false;
    }
  }

  // Disconnect
  Future<bool> disconnect() async {
    try {
      return await _bluetooth.disconnect();
    } catch (e) {
      print('Disconnect failed: $e');
      return false;
    }
  }

  // Start device discovery
  Future<bool> startDiscovery() async {
    try {
      return await _bluetooth.startDiscovery();
    } catch (e) {
      print('Discovery failed: $e');
      return false;
    }
  }

  // Stop device discovery
  Future<bool> stopDiscovery() async {
    try {
      return await _bluetooth.stopDiscovery();
    } catch (e) {
      print('Stop discovery failed: $e');
      return false;
    }
  }

  // Clean up resources
  void dispose() {
    _connectionSubscription?.cancel();
    _dataSubscription?.cancel();
    _stateSubscription?.cancel();
  }
}
```

### Complete Example

```dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_classic_serial/flutter_bluetooth_classic.dart';

class BluetoothScreen extends StatefulWidget {
  const BluetoothScreen({super.key});

  @override
  State<BluetoothScreen> createState() => _BluetoothScreenState();
}

class _BluetoothScreenState extends State<BluetoothScreen> {
  late FlutterBluetoothClassic _bluetooth;
  List<BluetoothDevice> _devices = [];
  BluetoothDevice? _connectedDevice;
  bool _isBluetoothEnabled = false;
  bool _isConnected = false;
  String _receivedData = '';
  final TextEditingController _messageController = TextEditingController();
  
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<BluetoothData>? _dataSubscription;
  StreamSubscription<BluetoothState>? _stateSubscription;

  @override
  void initState() {
    super.initState();
    _bluetooth = FlutterBluetoothClassic();
    _initBluetooth();
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    _dataSubscription?.cancel();
    _stateSubscription?.cancel();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _initBluetooth() async {
    // Check Bluetooth status
    bool isSupported = await _bluetooth.isBluetoothSupported();
    bool isEnabled = await _bluetooth.isBluetoothEnabled();
    
    setState(() {
      _isBluetoothEnabled = isEnabled;
    });

    if (isSupported && isEnabled) {
      await _loadDevices();
      _setupListeners();
    }
  }

  void _setupListeners() {
    // Listen for Bluetooth state changes
    _stateSubscription = _bluetooth.onStateChanged.listen((state) {
      setState(() {
        _isBluetoothEnabled = state.isEnabled;
      });
    });

    // Listen for connection changes
    _connectionSubscription = _bluetooth.onConnectionChanged.listen((connectionState) {
      setState(() {
        _isConnected = connectionState.isConnected;
        if (connectionState.isConnected) {
          _connectedDevice = _devices.firstWhere(
            (device) => device.address == connectionState.deviceAddress,
            orElse: () => BluetoothDevice(
              name: 'Unknown Device',
              address: connectionState.deviceAddress,
              paired: false,
            ),
          );
        } else {
          _connectedDevice = null;
        }
      });

      // Show connection status
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(connectionState.isConnected 
              ? 'Connected to ${_connectedDevice?.name}' 
              : 'Disconnected: ${connectionState.status}'),
          backgroundColor: connectionState.isConnected ? Colors.green : Colors.red,
        ),
      );
    });

    // Listen for incoming data
    _dataSubscription = _bluetooth.onDataReceived.listen((data) {
      setState(() {
        _receivedData += data.asString();
      });
    });
  }

  Future<void> _loadDevices() async {
    try {
      List<BluetoothDevice> devices = await _bluetooth.getPairedDevices();
      setState(() {
        _devices = devices;
      });
    } catch (e) {
      _showError('Failed to load devices: $e');
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      bool success = await _bluetooth.connect(device.address);
      if (!success) {
        _showError('Failed to connect to ${device.name}');
      }
    } catch (e) {
      _showError('Connection error: $e');
    }
  }

  Future<void> _disconnect() async {
    try {
      await _bluetooth.disconnect();
    } catch (e) {
      _showError('Disconnect error: $e');
    }
  }

  Future<void> _sendMessage() async {
    if (_messageController.text.isEmpty || !_isConnected) return;

    try {
      bool success = await _bluetooth.sendString(_messageController.text);
      if (success) {
        setState(() {
          _receivedData += 'Sent: ${_messageController.text}\n';
        });
        _messageController.clear();
      } else {
        _showError('Failed to send message');
      }
    } catch (e) {
      _showError('Send error: $e');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bluetooth Classic Demo'),
        actions: [
          IconButton(
            onPressed: _loadDevices,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: !_isBluetoothEnabled
          ? const Center(
              child: Text('Please enable Bluetooth'),
            )
          : Column(
              children: [
                // Connection Status
                Card(
                  margin: const EdgeInsets.all(8),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(
                          _isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                          color: _isConnected ? Colors.green : Colors.grey,
                        ),
                        const SizedBox(width: 8),
                        Text(_isConnected 
                            ? 'Connected to ${_connectedDevice?.name}' 
                            : 'Not connected'),
                        const Spacer(),
                        if (_isConnected)
                          ElevatedButton(
                            onPressed: _disconnect,
                            child: const Text('Disconnect'),
                          ),
                      ],
                    ),
                  ),
                ),
                
                // Device List
                Expanded(
                  flex: 2,
                  child: Card(
                    margin: const EdgeInsets.all(8),
                    child: Column(
                      children: [
                        const Padding(
                          padding: EdgeInsets.all(8),
                          child: Text('Paired Devices', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        Expanded(
                          child: ListView.builder(
                            itemCount: _devices.length,
                            itemBuilder: (context, index) {
                              BluetoothDevice device = _devices[index];
                              bool isConnectedDevice = _connectedDevice?.address == device.address;
                              
                              return ListTile(
                                leading: Icon(
                                  Icons.bluetooth,
                                  color: isConnectedDevice ? Colors.green : null,
                                ),
                                title: Text(device.name),
                                subtitle: Text(device.address),
                                trailing: isConnectedDevice 
                                    ? const Icon(Icons.check, color: Colors.green)
                                    : ElevatedButton(
                                        onPressed: _isConnected ? null : () => _connectToDevice(device),
                                        child: const Text('Connect'),
                                      ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Message Input
                if (_isConnected)
                  Card(
                    margin: const EdgeInsets.all(8),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _messageController,
                              decoration: const InputDecoration(
                                hintText: 'Enter message',
                                border: OutlineInputBorder(),
                              ),
                              onSubmitted: (_) => _sendMessage(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: _sendMessage,
                            child: const Text('Send'),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Received Data
                Expanded(
                  flex: 1,
                  child: Card(
                    margin: const EdgeInsets.all(8),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Row(
                            children: [
                              const Text('Received Data', style: TextStyle(fontWeight: FontWeight.bold)),
                              const Spacer(),
                              IconButton(
                                onPressed: () => setState(() => _receivedData = ''),
                                icon: const Icon(Icons.clear),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Container(
                            width: double.infinity,
                            margin: const EdgeInsets.all(8),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: SingleChildScrollView(
                              child: Text(
                                _receivedData.isEmpty ? 'No data received' : _receivedData,
                                style: const TextStyle(fontFamily: 'monospace'),
                              ),
                            ),
                          ),
                        ),
                      ],                ),
                  ),
                ),
              ],
            ),
    );
  }
}
```

## Testing with Hardware

### Arduino with HC-05/HC-06

```cpp
void setup() {
  Serial.begin(9600);
}

void loop() {
  if (Serial.available()) {
    String data = Serial.readString();
    data.trim();
    Serial.print("Echo: ");
    Serial.println(data);
  }
  delay(100);
}
```

### ESP32 Bluetooth Classic

```cpp
#include "BluetoothSerial.h"

BluetoothSerial SerialBT;

void setup() {
  Serial.begin(115200);
  SerialBT.begin("ESP32test"); // Bluetooth device name
  Serial.println("The device started, now you can pair it with bluetooth!");
}

void loop() {
  if (SerialBT.available()) {
    String message = SerialBT.readString();
    message.trim();
    SerialBT.print("Received: ");
    SerialBT.println(message);
    Serial.println("Sent response: " + message);
  }
  delay(20);
}
```

## Common Issues & Solutions

### Permission Issues
- **Android**: Ensure all required permissions are added to `AndroidManifest.xml`
- **Location**: Enable location services for device discovery (Android requirement)
- **Runtime**: Request permissions at runtime for Android 6+

### Connection Problems
- **Pairing**: Ensure device is paired before connecting
- **Range**: Keep devices within Bluetooth range (typically 10 meters)
- **Interference**: Avoid interference from other 2.4GHz devices
- **Multiple Connections**: Most devices support only one active connection

### Data Issues
- **Encoding**: Ensure both devices use the same text encoding (UTF-8 recommended)
- **Termination**: Use consistent line endings (`\n` or `\r\n`)
- **Buffer**: Implement proper buffering for large data transfers
- **Timing**: Add appropriate delays between rapid data transmissions

### Platform-Specific Notes

**Android:**
- Requires API level 21+ (Android 5.0)
- Location permission needed for device discovery
- Some devices may require specific UUIDs

**iOS:**
- Limited to MFi-certified devices or accessories using standard profiles
- May require additional entitlements for certain device types

**Windows:**
- Requires Windows 10 build 1803 or later
- Bluetooth adapter must support classic profiles

**macOS:**
- Requires macOS 10.13 or later
- Uses IOBluetooth framework for Classic Bluetooth support
- May require user interaction for device pairing

**Linux:**
- Requires BlueZ stack (typically pre-installed on most Linux distributions)
- May require additional permissions for Bluetooth device access
- Supports RFCOMM protocol for serial communication
```

## API Reference

### FlutterBluetoothClassic

Main class for Bluetooth operations.

#### Constructor

```dart
FlutterBluetoothClassic bluetooth = FlutterBluetoothClassic();
```

#### Methods

| Method | Return Type | Description |
|--------|-------------|-------------|
| `isBluetoothSupported()` | `Future<bool>` | Check if Bluetooth is supported on the device |
| `isBluetoothEnabled()` | `Future<bool>` | Check if Bluetooth is currently enabled |
| `enableBluetooth()` | `Future<bool>` | Request to enable Bluetooth |
| `getPairedDevices()` | `Future<List<BluetoothDevice>>` | Get list of paired devices |
| `startDiscovery()` | `Future<bool>` | Start discovering nearby devices |
| `stopDiscovery()` | `Future<bool>` | Stop device discovery |
| `connect(String address)` | `Future<bool>` | Connect to device by address |
| `disconnect()` | `Future<bool>` | Disconnect from current device |
| `sendData(List<int> data)` | `Future<bool>` | Send raw byte data |
| `sendString(String message)` | `Future<bool>` | Send string message |

#### Event Streams

| Stream | Type | Description |
|--------|------|-------------|
| `onStateChanged` | `Stream<BluetoothState>` | Bluetooth enable/disable events |
| `onConnectionChanged` | `Stream<BluetoothConnectionState>` | Connection status changes |
| `onDataReceived` | `Stream<BluetoothData>` | Incoming data from connected device |

### Data Models

#### BluetoothDevice

Represents a Bluetooth device.

```dart
class BluetoothDevice {
  final String name;        // Device name
  final String address;     // Device MAC address
  final bool paired;        // Whether device is paired
}
```

#### BluetoothConnectionState

Represents connection status.

```dart
class BluetoothConnectionState {
  final bool isConnected;      // Connection status
  final String deviceAddress;  // Connected device address
  final String status;         // Status description
}
```

#### BluetoothData

Represents received data.

```dart
class BluetoothData {
  final String deviceAddress;  // Source device address
  final List<int> data;        // Raw byte data
  
  String asString();           // Convert data to string
}
```

#### BluetoothState

Represents Bluetooth adapter state.

```dart
class BluetoothState {
  final bool isEnabled;    // Whether Bluetooth is enabled
  final String status;     // Status description
}
```

#### BluetoothException

Exception thrown by Bluetooth operations.

```dart
class BluetoothException implements Exception {
  final String message;
}
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Support

If you encounter any issues or have questions, please file an issue on our [GitHub repository](https://github.com/C0DE-IN/flutter_bluetooth_classic_serial/issues).