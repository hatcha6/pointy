import Flutter
import SwiftUI
import UIKit

// The tab bar the app stands in the system's side column on the iPhone Duo,
// drawn wholly by the system: a Liquid Glass capsule of tabs whose selection
// is a tinted glass pill that slides between them, and search apart in its
// own round glass beneath, as Apple's own apps set them there. Flutter places
// it (cards_tab_bar.dart, `CardsNativeSideTabBar`) and tells it what to show
// over the channel `cards/side_tab_bar_<id>`: "update" with the tabs, the
// chosen one, the tint and light or dark; it answers "select" and "search".

/// One tab: its SF Symbol, plain and chosen, and its name for VoiceOver.
struct SideTab: Equatable {
  let plain: String
  let chosen: String
  let label: String
}

final class SideTabBarModel: ObservableObject {
  @Published var tabs: [SideTab] = []
  @Published var selected = 0
  @Published var tint = Color.accentColor
  @Published var dark = false
  @Published var search = false
  @Published var searchLabel = ""

  var onSelect: (Int) -> Void = { _ in }
  var onSearch: () -> Void = {}

  func apply(_ args: [String: Any]) {
    if let rows = args["tabs"] as? [[String: Any]] {
      tabs = rows.map {
        SideTab(
          plain: $0["plain"] as? String ?? "circle",
          chosen: $0["chosen"] as? String ?? "circle.fill",
          label: $0["label"] as? String ?? "")
      }
    }
    if let index = args["selected"] as? Int { selected = index }
    if let argb = args["tint"] as? Int { tint = Color(uiColor: UIColor(argb: argb)) }
    if let isDark = args["dark"] as? Bool { dark = isDark }
    if let hasSearch = args["search"] as? Bool { search = hasSearch }
    if let label = args["searchLabel"] as? String { searchLabel = label }
  }
}

@available(iOS 26.0, *)
struct SideTabBarView: View {
  @ObservedObject var model: SideTabBarModel
  @Namespace private var glass

  /// Apple's bar button size on the iPhone Duo's column.
  static let size: CGFloat = 48
  static let searchGap: CGFloat = 10

  var body: some View {
    VStack(spacing: Self.searchGap) {
      GlassEffectContainer(spacing: 0) {
        VStack(spacing: 0) {
          ForEach(Array(model.tabs.enumerated()), id: \.offset) { index, tab in
            tabButton(index: index, tab: tab)
          }
        }
        .glassEffect(.regular.interactive(), in: .capsule)
      }
      if model.search {
        Button(action: model.onSearch) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: Self.size, height: Self.size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(model.searchLabel)
      }
    }
    .animation(.spring(response: 0.38, dampingFraction: 0.78), value: model.selected)
    .environment(\.colorScheme, model.dark ? .dark : .light)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func tabButton(index: Int, tab: SideTab) -> some View {
    let chosen = index == model.selected
    Button {
      model.onSelect(index)
    } label: {
      Image(systemName: chosen ? tab.chosen : tab.plain)
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(chosen ? model.tint : Color.primary)
        .frame(width: Self.size, height: Self.size)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // The selection: a tinted glass pill that moves to the chosen tab.
    .background {
      if chosen {
        Color.clear
          .glassEffect(.regular.tint(model.tint.opacity(0.28)), in: .capsule)
          .padding(3)
          .glassEffectID("selection", in: glass)
          .matchedGeometryEffect(id: "selection", in: glass)
      }
    }
    .accessibilityLabel(tab.label)
    .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
  }
}

final class SideTabBarPlatformView: NSObject, FlutterPlatformView {
  private let container = UIView()
  private let model = SideTabBarModel()
  private let channel: FlutterMethodChannel
  private var host: UIViewController?

  init(frame: CGRect, viewId: Int64, args: Any?, messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "cards/side_tab_bar_\(viewId)", binaryMessenger: messenger)
    super.init()
    container.frame = frame
    container.backgroundColor = .clear
    // The glass grows a little when pressed: let it.
    container.clipsToBounds = false
    if let params = args as? [String: Any] {
      model.apply(params)
    }
    model.onSelect = { [weak self] index in
      self?.channel.invokeMethod("select", arguments: index)
    }
    model.onSearch = { [weak self] in
      self?.channel.invokeMethod("search", arguments: nil)
    }
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "update", let params = call.arguments as? [String: Any], let self {
        self.model.apply(params)
        self.host?.overrideUserInterfaceStyle = self.model.dark ? .dark : .light
      }
      result(nil)
    }
    if #available(iOS 26.0, *) {
      let hosting = UIHostingController(rootView: SideTabBarView(model: model))
      hosting.view.backgroundColor = .clear
      hosting.view.clipsToBounds = false
      hosting.view.frame = container.bounds
      hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      hosting.overrideUserInterfaceStyle = model.dark ? .dark : .light
      container.addSubview(hosting.view)
      host = hosting
    }
  }

  func view() -> UIView { container }
}

final class SideTabBarFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?)
    -> FlutterPlatformView
  {
    SideTabBarPlatformView(frame: frame, viewId: viewId, args: args, messenger: messenger)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

extension UIColor {
  /// From Flutter's 0xAARRGGBB.
  convenience init(argb: Int) {
    self.init(
      red: CGFloat((argb >> 16) & 0xFF) / 255,
      green: CGFloat((argb >> 8) & 0xFF) / 255,
      blue: CGFloat(argb & 0xFF) / 255,
      alpha: CGFloat((argb >> 24) & 0xFF) / 255)
  }
}
