import CoreTelephony
import Flutter
import UIKit

/// What the eSIM pages ask of the phone (`ly.dftr.cards/esim`).
///
/// `device` answers the hardware model (no permission needed), the system
/// version and the system's own word on eSIM support. `install` opens Apple's
/// universal link for an eSIM: from iOS 17.4 the system shows its own "Add eSIM"
/// sheet with no QR and nothing to type. Adding a plan from inside the app
/// (`CTCellularPlanProvisioning.addPlan`) needs a carrier entitlement Apple does
/// not grant resellers, so this link is the way.
enum EsimBridge {
  /// The only place the channel will send a customer: a link from the relay opens
  /// the system's eSIM screen, or nothing.
  private static let installHost = "esimsetup.apple.com"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "ly.dftr.cards/esim", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "device":
        result(device())
      case "install":
        guard let text = (call.arguments as? [String: Any])?["url"] as? String,
          let url = URL(string: text),
          url.scheme == "https",
          url.host == installHost
        else {
          result(false)
          return
        }
        UIApplication.shared.open(url, options: [:]) { opened in result(opened) }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func device() -> [String: Any] {
    #if targetEnvironment(simulator)
      let simulator = true
    #else
      let simulator = false
    #endif
    return [
      "platform": "ios",
      "model": hardwareModel(),
      "os_version": UIDevice.current.systemVersion,
      "supports_esim": supportsESIM(),
      "simulator": simulator,
      // Apple's universal link opens the system's install sheet from iOS 17.4.
      "direct_install": isAtLeast17_4(),
    ]
  }

  private static func supportsESIM() -> Bool {
    if #available(iOS 16.0, *) {
      return CTCellularPlanProvisioning().supportsEmbeddedSIM
    }
    return CTCellularPlanProvisioning().supportsCellularPlan()
  }

  private static func isAtLeast17_4() -> Bool {
    if #available(iOS 17.4, *) { return true }
    return false
  }

  /// "iPhone13,2", as Airalo's compatibility check wants it.
  private static func hardwareModel() -> String {
    if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
      return simulated
    }
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { buffer in
      String(cString: buffer.bindMemory(to: CChar.self).baseAddress!)
    }
  }
}
