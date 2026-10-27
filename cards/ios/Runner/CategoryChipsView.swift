import Flutter
import SwiftUI
import UIKit

// A row of Liquid Glass chips (the shelf's categories, My Cards' filters),
// drawn by the system: Apple's pattern for controls that float on content.
// Flutter places it (shared/native_glass_chips.dart, `NativeGlassChips`)
// and tells it what to show over `cards/category_chips_<id>`: "update" with
// the chips, the chosen one, the tint, light or dark, the reading direction
// and the room at either end; it answers "select" with the chip's key.

struct CategoryChip: Equatable {
  let key: String
  let label: String
  let symbol: String
}

final class CategoryChipsModel: ObservableObject {
  @Published var chips: [CategoryChip] = []
  @Published var selected = ""
  @Published var tint = Color.accentColor
  @Published var dark = false
  @Published var rtl = true
  /// Extra room at either end: the system side column the row runs under.
  /// Room before the first chip and after the last.
  @Published var gutter: CGFloat = 20
  @Published var leading: CGFloat = 0
  @Published var trailing: CGFloat = 0

  var onSelect: (String) -> Void = { _ in }

  func apply(_ args: [String: Any]) {
    if let rows = args["chips"] as? [[String: Any]] {
      chips = rows.map {
        CategoryChip(
          key: $0["key"] as? String ?? "",
          label: $0["label"] as? String ?? "",
          symbol: $0["symbol"] as? String ?? "square.stack")
      }
    }
    if let key = args["selected"] as? String { selected = key }
    if let argb = args["tint"] as? Int { tint = Color(uiColor: UIColor(argb: argb)) }
    if let isDark = args["dark"] as? Bool { dark = isDark }
    if let isRtl = args["rtl"] as? Bool { rtl = isRtl }
    if let room = args["gutter"] as? Double { gutter = CGFloat(room) }
    if let inset = args["leading"] as? Double { leading = CGFloat(inset) }
    if let inset = args["trailing"] as? Double { trailing = CGFloat(inset) }
  }
}

@available(iOS 26.0, *)
struct CategoryChipsView: View {
  @ObservedObject var model: CategoryChipsModel
  var body: some View {
    ScrollViewReader { reader in
      ScrollView(.horizontal, showsIndicators: false) {
        // No merging: each chip keeps its own glass, so choosing one never
        // morphs the row.
        GlassEffectContainer(spacing: 0) {
          HStack(spacing: 8) {
            ForEach(model.chips, id: \.key) { chip in
              chipButton(chip).id(chip.key)
            }
          }
          .padding(.leading, model.gutter + model.leading)
          .padding(.trailing, model.gutter + model.trailing)
          .padding(.vertical, 6)
        }
      }
      .scrollClipDisabled()
      // Made afresh when a page above closes: open on the chosen chip.
      .onAppear { reader.scrollTo(model.selected, anchor: .center) }
      .onChange(of: model.selected) { _, key in
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
          reader.scrollTo(key, anchor: .center)
        }
      }
    }
    .environment(\.layoutDirection, model.rtl ? .rightToLeft : .leftToRight)
    .environment(\.colorScheme, model.dark ? .dark : .light)
  }

  // Every chip wears the same glass and the same type, chosen or not: only
  // the tint behind the label and the label's colour change, so the glass is
  // never rebuilt and nothing moves. (Swapping the glass's kind or the
  // weight made the chip re-lay itself out and drop its icon mid-change.)
  @ViewBuilder
  private func chipButton(_ chip: CategoryChip) -> some View {
    let chosen = chip.key == model.selected
    Button {
      model.onSelect(chip.key)
    } label: {
      Label(chip.label, systemImage: chip.symbol)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(chosen ? model.tint : Color.primary)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background {
          Capsule()
            .fill(model.tint.opacity(chosen ? 0.18 : 0))
            .padding(2)
        }
        .contentShape(Capsule())
        .animation(.easeInOut(duration: 0.22), value: chosen)
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: .capsule)
    .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
  }
}

final class CategoryChipsPlatformView: NSObject, FlutterPlatformView {
  private let container = UIView()
  private let model = CategoryChipsModel()
  private let channel: FlutterMethodChannel
  private var host: UIViewController?

  init(frame: CGRect, viewId: Int64, args: Any?, messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "cards/category_chips_\(viewId)", binaryMessenger: messenger)
    super.init()
    container.frame = frame
    container.backgroundColor = .clear
    if let params = args as? [String: Any] {
      model.apply(params)
    }
    model.onSelect = { [weak self] key in
      self?.channel.invokeMethod("select", arguments: key)
    }
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "update", let params = call.arguments as? [String: Any], let self {
        self.model.apply(params)
        self.host?.overrideUserInterfaceStyle = self.model.dark ? .dark : .light
      }
      result(nil)
    }
    if #available(iOS 26.0, *) {
      let hosting = UIHostingController(rootView: CategoryChipsView(model: model))
      hosting.view.backgroundColor = .clear
      hosting.view.frame = container.bounds
      hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      hosting.overrideUserInterfaceStyle = model.dark ? .dark : .light
      container.addSubview(hosting.view)
      host = hosting
    }
  }

  func view() -> UIView { container }
}

final class CategoryChipsFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?)
    -> FlutterPlatformView
  {
    CategoryChipsPlatformView(frame: frame, viewId: viewId, args: args, messenger: messenger)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}
