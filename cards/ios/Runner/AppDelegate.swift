import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // The iPhone Duo's side tab bar, drawn by the system (SideTabBarView).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CardsSideTabBar") {
      registrar.register(
        SideTabBarFactory(messenger: registrar.messenger()), withId: "cards/side_tab_bar")
    }
    // The shelf's categories as native glass chips (CategoryChipsView).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CardsCategoryChips") {
      registrar.register(
        CategoryChipsFactory(messenger: registrar.messenger()), withId: "cards/category_chips")
    }
  }
}
