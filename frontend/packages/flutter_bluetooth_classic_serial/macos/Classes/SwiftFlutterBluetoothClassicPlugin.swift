import FlutterMacOS
import Foundation
import IOBluetooth

// MARK: - Plugin
public class SwiftFlutterBluetoothClassicPlugin: NSObject, FlutterPlugin {
  private let methodChannel: FlutterMethodChannel
  private let stateChannel: FlutterEventChannel
  private let connectionChannel: FlutterEventChannel
  private let dataChannel: FlutterEventChannel

  private let stateStreamHandler = BluetoothStateStreamHandler()
  private let connectionStreamHandler = BluetoothConnectionStreamHandler()
  private let dataStreamHandler = BluetoothDataStreamHandler()

  private var bluetoothManager: MacBluetoothManager?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = SwiftFlutterBluetoothClassicPlugin(registrar: registrar)
    registrar.addMethodCallDelegate(instance, channel: instance.methodChannel)
  }

  init(registrar: FlutterPluginRegistrar) {
    methodChannel = FlutterMethodChannel(name: "com.flutter_bluetooth_classic.plugin/flutter_bluetooth_classic", binaryMessenger: registrar.messenger)
    stateChannel = FlutterEventChannel(name: "com.flutter_bluetooth_classic.plugin/flutter_bluetooth_classic_state", binaryMessenger: registrar.messenger)
    connectionChannel = FlutterEventChannel(name: "com.flutter_bluetooth_classic.plugin/flutter_bluetooth_classic_connection", binaryMessenger: registrar.messenger)
    dataChannel = FlutterEventChannel(name: "com.flutter_bluetooth_classic.plugin/flutter_bluetooth_classic_data", binaryMessenger: registrar.messenger)

    super.init()

    stateChannel.setStreamHandler(stateStreamHandler)
    connectionChannel.setStreamHandler(connectionStreamHandler)
    dataChannel.setStreamHandler(dataStreamHandler)

    bluetoothManager = MacBluetoothManager(
      stateHandler: stateStreamHandler,
      connectionHandler: connectionStreamHandler,
      dataHandler: dataStreamHandler
    )
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isBluetoothSupported":
      result(IOBluetoothHostController.default() != nil)

    case "isBluetoothEnabled":
      bluetoothManager?.isBluetoothEnabled(completion: result)

    case "enableBluetooth":
      // macOS doesn't allow programmatic enabling of Bluetooth
      result(FlutterError(code: "UNSUPPORTED",
                         message: "Cannot enable Bluetooth programmatically on macOS",
                         details: nil))

    case "getPairedDevices":
      bluetoothManager?.getPairedDevices(completion: result)

    case "getDiscoveredDevices":
      bluetoothManager?.getDiscoveredDevices(completion: result)

    case "startDiscovery":
      bluetoothManager?.startDiscovery(completion: result)

    case "stopDiscovery":
      bluetoothManager?.stopDiscovery(completion: result)

    case "connect":
      guard let args = call.arguments as? [String: Any],
            let address = args["address"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENT",
                           message: "Device address is required",
                           details: nil))
        return
      }
      bluetoothManager?.connect(address: address, completion: result)

    case "disconnect":
      bluetoothManager?.disconnect(completion: result)

    case "sendData":
      guard let args = call.arguments as? [String: Any],
            let rawData = args["data"] else {
        result(FlutterError(code: "INVALID_ARGUMENT",
                           message: "Data is required",
                           details: nil))
        return
      }

      var dataBytes: Data?
      if let dataList = rawData as? [Int] {
        // Handle List<Int>
        let bytes = dataList.map { UInt8($0) }
        dataBytes = Data(bytes)
      } else if let flutterData = rawData as? FlutterStandardTypedData {
        // Handle FlutterStandardTypedData (byte array)
        dataBytes = flutterData.data
      } else if let data = rawData as? Data {
        // Handle Data directly
        dataBytes = data
      } else {
        result(FlutterError(code: "INVALID_ARGUMENT",
                           message: "Unsupported data type",
                           details: nil))
        return
      }

      guard let data = dataBytes else {
        result(FlutterError(code: "INVALID_ARGUMENT",
                           message: "Failed to convert data",
                           details: nil))
        return
      }

      bluetoothManager?.sendData(data: data, completion: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

// MARK: - Stream Handlers
class BluetoothStateStreamHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func sendEvent(_ event: [String: Any]) {
    eventSink?(event)
  }
}

class BluetoothConnectionStreamHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func sendEvent(_ event: [String: Any]) {
    eventSink?(event)
  }
}

class BluetoothDataStreamHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func sendEvent(_ data: Data) {
    eventSink?(FlutterStandardTypedData(bytes: data))
  }
}

// MARK: - Bluetooth Manager
class MacBluetoothManager: NSObject {
  private let stateHandler: BluetoothStateStreamHandler
  private let connectionHandler: BluetoothConnectionStreamHandler
  private let dataHandler: BluetoothDataStreamHandler

  private var deviceInquiry: IOBluetoothDeviceInquiry?
  private var connectedDevice: IOBluetoothDevice?
  private var rfcommChannel: IOBluetoothRFCOMMChannel?
  private var discoveredDevices: [IOBluetoothDevice] = []
  private var pairedDevices: [IOBluetoothDevice] = []

  init(stateHandler: BluetoothStateStreamHandler,
       connectionHandler: BluetoothConnectionStreamHandler,
       dataHandler: BluetoothDataStreamHandler) {
    self.stateHandler = stateHandler
    self.connectionHandler = connectionHandler
    self.dataHandler = dataHandler
    super.init()

    // Monitor Bluetooth availability
    NotificationCenter.default.addObserver(self,
                                         selector: #selector(bluetoothAvailabilityChanged(_:)),
                                         name: .IOBluetoothHostControllerPoweredOn,
                                         object: nil)
    NotificationCenter.default.addObserver(self,
                                         selector: #selector(bluetoothAvailabilityChanged(_:)),
                                         name: .IOBluetoothHostControllerPoweredOff,
                                         object: nil)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func bluetoothAvailabilityChanged(_ notification: Notification) {
    let isEnabled = IOBluetoothHostController.default()?.powerState == .on
    stateHandler.sendEvent([
      "state": isEnabled ? "on" : "off",
      "isAvailable": true
    ])
  }

  func isBluetoothEnabled(completion: @escaping (Bool) -> Void) {
    let powerState = IOBluetoothHostController.default()?.powerState
    completion(powerState == .on)
  }

  func getPairedDevices(completion: @escaping ([[String: Any]]) -> Void) {
    guard let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
      completion([])
      return
    }

    let devices = pairedDevices.map { device -> [String: Any] in
      return [
        "name": device.name ?? "Unknown",
        "address": device.addressString ?? "",
        "isConnected": device.isConnected(),
        "type": "classic"
      ]
    }
    completion(devices)
  }

  func getDiscoveredDevices(completion: @escaping ([[String: Any]]) -> Void) {
    let devices = discoveredDevices.map { device -> [String: Any] in
      return [
        "name": device.name ?? "Unknown",
        "address": device.addressString ?? "",
        "isConnected": device.isConnected(),
        "type": "classic"
      ]
    }
    completion(devices)
  }

  func startDiscovery(completion: @escaping (Bool) -> Void) {
    deviceInquiry = IOBluetoothDeviceInquiry(inquiryLength: 10)
    deviceInquiry?.delegate = self
    discoveredDevices.removeAll()

    let success = deviceInquiry?.start() ?? false
    completion(success)
  }

  func stopDiscovery(completion: @escaping (Bool) -> Void) {
    let success = deviceInquiry?.stop() ?? false
    deviceInquiry = nil
    completion(success)
  }

  func connect(address: String, completion: @escaping (Bool) -> Void) {
    guard let device = IOBluetoothDevice(addressString: address) else {
      completion(false)
      return
    }

    connectedDevice = device

    // First check if device is paired, if not, attempt to pair
    if !device.isPaired() {
      // Attempt to pair with the device
      let pairingResult = device.performSDPQuery()
      if pairingResult != kIOReturnSuccess {
        completion(false)
        return
      }
    }

    // Open RFCOMM channel
    let result = device.openRFCOMMChannelSync(&rfcommChannel, withChannelID: 1, delegate: self)
    completion(result == kIOReturnSuccess)
  }

  func disconnect(completion: @escaping (Bool) -> Void) {
    if let channel = rfcommChannel {
      channel.close()
      rfcommChannel = nil
    }
    connectedDevice = nil
    completion(true)
  }

  func sendData(data: Data, completion: @escaping (Bool) -> Void) {
    guard let channel = rfcommChannel else {
      completion(false)
      return
    }

    var dataToSend = data
    let result = dataToSend.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> IOReturn in
      return channel.writeSync(bytes.baseAddress!, length: UInt16(data.count))
    }
    completion(result == kIOReturnSuccess)
  }
}

// MARK: - Device Inquiry Delegate
extension MacBluetoothManager: IOBluetoothDeviceInquiryDelegate {
  func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry, device: IOBluetoothDevice) {
    discoveredDevices.append(device)

    let deviceInfo: [String: Any] = [
      "event": "deviceFound",
      "device": [
        "name": device.name ?? "Unknown",
        "address": device.addressString ?? "",
        "isConnected": device.isConnected(),
        "type": "classic"
      ]
    ]
    stateHandler.sendEvent(deviceInfo)
  }

  func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry, error: IOReturn, aborted: Bool) {
    // Discovery complete
  }
}

// MARK: - RFCOMM Channel Delegate
extension MacBluetoothManager: IOBluetoothRFCOMMChannelDelegate {
  func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel, data dataPointer: UnsafeMutableRawPointer, length: Int) {
    let data = Data(bytes: dataPointer, count: length)
    dataHandler.sendEvent(data)
  }

  func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel) {
    connectionHandler.sendEvent([
      "isConnected": false,
      "device": connectedDevice?.addressString ?? ""
    ])
    self.rfcommChannel = nil
    connectedDevice = nil
  }
}