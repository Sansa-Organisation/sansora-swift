import SwiftUI
#if canImport(SafariServices) && canImport(UIKit)
import SafariServices
#endif

/// State of one paywall on screen. Created by the SDK for `register` and the
/// `.sansoraPaywall` modifier; `SansoraPaywallView` draws it.
@MainActor
public final class PaywallViewModel: ObservableObject, Identifiable {
    public nonisolated let id = UUID()
    @Published public private(set) var model: RenderModel
    @Published public internal(set) var purchasing = false
    @Published public internal(set) var restoring = false
    /// A private preview: purchases and restores are off and nothing is recorded.
    @Published public internal(set) var isPreview = false
    /// The store's prices are on their way (at most about 3 s): price lines show a placeholder
    /// instead of “Price unavailable” (CONTRACT §8). The purchase button stays off until a price is known.
    @Published public internal(set) var pricesLoading = false
    /// The store's answer (or the time limit) has been applied.
    var pricesSettled = false

    var onSelect: (String) -> Void = { _ in }
    var onPurchase: () -> Void = {}
    var onRestore: () -> Void = {}
    var onClose: () -> Void = {}

    /// A view model that only draws (no store, no events), e.g. for previews.
    public init(model: RenderModel) { self.model = model }

    func update(_ m: RenderModel) { model = m }

    func select(_ productId: String) { if !purchasing { onSelect(productId) } }
    func purchase() { if !purchasing && !restoring && model.purchasable { onPurchase() } }
    func restore() { if !purchasing && !restoring { onRestore() } }
    func close() { onClose() }
}

extension Color {
    init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v = UInt32(s, radix: 16) ?? 0
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: 1)
    }
}

/// System font at a size that follows Dynamic Type.
struct ScaledFont: ViewModifier {
    @ScaledMetric var size: CGFloat
    var weight: Font.Weight
    init(_ size: CGFloat, _ weight: Font.Weight, relativeTo style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
    }
    func body(content: Content) -> some View { content.font(.system(size: size, weight: weight)) }
}

extension View {
    func sf(_ size: CGFloat, _ weight: Font.Weight = .regular, _ style: Font.TextStyle = .body) -> some View {
        modifier(ScaledFont(size, weight, relativeTo: style))
    }
}

/// The close button a page uses: its first close block (one per page; others are not drawn).
struct PaywallClose: Equatable {
    var position: PaywallDefinition.Position
    var delaySeconds: Int
    var style: RenderModel.CloseStyle
    var label: String?
    var bar: RenderModel.Bar?
}

/// One page split into the regions of CONTRACT §8 (0.3.0): the close button (floating, in the top bar or in a row),
/// the blocks drawn in the scrolling content, and those pinned to the bottom with the next button.
struct PaywallPageLayout: Equatable {
    var close: PaywallClose?
    /// In order, with the close block when its style is `row`.
    var content: [RenderModel.Block] = []
    var pinned: [RenderModel.Block] = []
    var nextLabel: String?
    var align: RenderModel.Align

    init(blocks: [RenderModel.Block], nextLabel: String?, align: RenderModel.Align) {
        self.nextLabel = nextLabel
        self.align = align
        for block in blocks {
            if case let .close(position, delay, style, label, bar) = block {
                guard close == nil else { continue }
                close = PaywallClose(position: position, delaySeconds: delay, style: style, label: label, bar: bar)
                if style == .row { content.append(block) }
            } else if block.placement?.pinned == true {
                pinned.append(block)
            } else {
                content.append(block)
            }
        }
    }

    var hasTopBar: Bool { close?.style == .bar }
    var floatingClose: PaywallClose? { close?.style == .overlay ? close : nil }
    var hasPinnedArea: Bool { !pinned.isEmpty || nextLabel != nil }
}

/// The bottom of the content in the scroll view's coordinate space.
private struct ContentBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The natural height of the pinned area.
private struct PinnedHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The widths of the top bar's side items, so the center item stays centered on the screen.
private struct BarSideWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Draws a Sansora render model with native views (CONTRACT §8), following the
/// editor preview (packages/ui/src/Paywalls.tsx, paywalls.css).
///
/// Layout (0.3.0): the top bar (a close button with style `bar`), the content, which scrolls and sits by `align`
/// when it is shorter than the space, and the pinned area (pinned blocks and the next button). A floating close
/// (style `overlay`) is drawn above all three.
public struct SansoraPaywallView: View {
    @ObservedObject var vm: PaywallViewModel
    @State private var closeVisible = false
    /// When the paywall appeared: a page's close button shows `delaySeconds` after it.
    @State private var appearedAt: Date?
    @State private var browserURL: IdentifiedURL?
    @State private var page = 0
    @State private var pinnedHeight: CGFloat = 0
    @Environment(\.openURL) private var openURL
    @Environment(\.layoutDirection) private var layoutDirection

    public init(model: PaywallViewModel) { self.vm = model }

    private static let scrollSpace = "sansora.paywall.content"

    private var m: RenderModel { vm.model }
    private var palette: PaywallDefinition.Palette { m.palette }
    private var bg: Color { Color(hex: palette.background) }
    private var surface: Color { Color(hex: palette.surface) }
    private var text: Color { Color(hex: palette.text) }
    private var muted: Color { Color(hex: palette.muted) }
    private var accent: Color { Color(hex: palette.accent) }
    private var pageIndex: Int { min(page, max(0, (m.pages?.count ?? 1) - 1)) }
    /// The page on screen, or nil for a one-page paywall.
    private var currentPage: RenderModel.Page? {
        guard let pages = m.pages, !pages.isEmpty else { return nil }
        return pages[pageIndex]
    }
    private var layout: PaywallPageLayout {
        PaywallPageLayout(blocks: currentPage?.blocks ?? m.blocks, nextLabel: currentPage?.nextLabel, align: currentPage?.align ?? m.align)
    }

    public var body: some View {
        GeometryReader { root in
            let layout = self.layout
            VStack(spacing: 0) {
                if layout.hasTopBar, let close = layout.close { topBar(close, width: root.size.width) }
                contentArea(layout)
                if layout.hasPinnedArea { pinnedArea(layout, limit: root.size.height / 2) }
            }
            .overlay(alignment: layout.floatingClose?.position == .left ? .topLeading : .topTrailing) {
                if let close = layout.floatingClose {
                    closeButton(close)
                        .padding(.top, 16)
                        .padding(close.position == .left ? .leading : .trailing, 16)
                        .accessibilitySortPriority(1)
                }
            }
        }
        .foregroundColor(text)
        .background(bg.ignoresSafeArea())
        .preferredColorScheme(m.theme == .dark ? .dark : .light)
        .environment(\.layoutDirection, m.direction == "rtl" ? .rightToLeft : layoutDirection)
        .task(id: "\(pageIndex):\(layout.close?.delaySeconds ?? -1)") { await showClose(delay: layout.close?.delaySeconds) }
        #if canImport(SafariServices) && canImport(UIKit)
        .sheet(item: $browserURL) { item in SafariView(url: item.url).ignoresSafeArea() }
        #endif
    }

    /// Shows the page's close button `delay` seconds after the paywall appeared (at once when that has passed).
    private func showClose(delay: Int?) async {
        let start = appearedAt ?? Date()
        if appearedAt == nil { appearedAt = start }
        guard let delay else { return }
        let remaining = Double(delay) - Date().timeIntervalSince(start)
        if remaining > 0 {
            closeVisible = false
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { closeVisible = true } }
    }

    private func goBack() { withAnimation(.easeOut(duration: 0.2)) { page = max(0, pageIndex - 1) } }
    private func goNext() { withAnimation(.easeOut(duration: 0.2)) { page = pageIndex + 1 } }

    // MARK: Regions

    /// Padding 22 top (8 below a top bar), 20 sides, 18 bottom (12 above a pinned area); gap 14 plus each block's
    /// `spaceBefore`. Scrolls when taller than its space, else sits by `align`.
    private func contentArea(_ layout: PaywallPageLayout) -> some View {
        GeometryReader { space in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if vm.isPreview {
                        Text("Preview · purchases are off").sf(11, .bold).foregroundColor(muted).frame(maxWidth: .infinity)
                    }
                    ForEach(Array(layout.content.enumerated()), id: \.offset) { i, block in
                        contentBlock(block, first: i == 0, layout: layout)
                    }
                }
                .padding(.top, layout.hasTopBar ? 8 : 22)
                .padding(.horizontal, 20)
                .padding(.bottom, layout.hasPinnedArea ? 12 : 18)
                .frame(maxWidth: .infinity, minHeight: space.size.height, alignment: Self.alignment(layout.align))
                .background(GeometryReader { g in
                    Color.clear.preference(key: ContentBottomKey.self, value: g.frame(in: .named(Self.scrollSpace)).maxY)
                })
            }
            .coordinateSpace(name: Self.scrollSpace)
            // The pinned area's hairline, while content is under it.
            .overlayPreferenceValue(ContentBottomKey.self) { bottom in
                if layout.hasPinnedArea && bottom > space.size.height + 0.5 {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle().fill(muted.opacity(0.2)).frame(height: 1)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
        // A new page starts at its top.
        .id(pageIndex)
    }

    private static func alignment(_ align: RenderModel.Align) -> Alignment {
        switch align {
        case .top: return .topLeading
        case .center: return .leading
        case .bottom: return .bottomLeading
        }
    }

    @ViewBuilder
    private func contentBlock(_ block: RenderModel.Block, first: Bool, layout: PaywallPageLayout) -> some View {
        let gap = CGFloat((first && !vm.isPreview ? 0 : 14) + (block.placement?.spaceBefore ?? 0))
        // The first block keeps clear of a floating close button, unless it is a hero.
        let clear: Edge.Set = {
            guard first, let close = layout.floatingClose else { return [] }
            if case .hero = block { return [] }
            return close.position == .left ? .leading : .trailing
        }()
        blockView(block)
            .padding(clear, 36)
            .padding(.top, gap)
    }

    /// Padding 12 top, 20 sides, 18 bottom; gap 10 plus each block's `spaceBefore`; then the next button. It does not
    /// scroll, unless it would take more than `limit` (half the screen, with very large text): then it scrolls on its own.
    private func pinnedArea(_ layout: PaywallPageLayout, limit: CGFloat) -> some View {
        let stack = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(layout.pinned.enumerated()), id: \.offset) { i, block in
                blockView(block).padding(.top, CGFloat((i == 0 ? 0 : 10) + (block.placement?.spaceBefore ?? 0)))
            }
            if let next = layout.nextLabel { nextView(next).padding(.top, layout.pinned.isEmpty ? 0 : 10) }
        }
        .padding(.top, 12)
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in Color.clear.preference(key: PinnedHeightKey.self, value: g.size.height) })
        return Group {
            if pinnedHeight > limit {
                ScrollView { stack }.frame(height: limit)
            } else {
                stack
            }
        }
        .background(bg)
        .onPreferenceChange(PinnedHeightKey.self) { pinnedHeight = $0 }
    }

    /// Height 44, padding 0×16. The close button takes the slot on its side; the center item is centered on the screen.
    private func topBar(_ close: PaywallClose, width: CGFloat) -> some View {
        let bar = close.bar ?? RenderModel.Bar()
        let closeLeads = close.position == .left
        let inner = max(0, width - 32)
        // Side items stay out of the middle third when there is a center item.
        let sideLimit = max(28, bar.center == nil ? (inner - 8) / 2 : inner / 3 - 8)
        return HStack(spacing: 0) {
            barSide(closeLeads ? nil : bar.leading, close: closeLeads ? close : nil, alignment: .leading, limit: sideLimit)
            Spacer(minLength: 8)
            barSide(closeLeads ? bar.trailing : nil, close: closeLeads ? nil : close, alignment: .trailing, limit: sideLimit)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .overlayPreferenceValue(BarSideWidthKey.self) { side in
            if let center = bar.center {
                barItem(center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, side > 0 ? side + 8 : 0)
            }
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
    }

    private func barSide(_ item: RenderModel.BarItem?, close: PaywallClose?, alignment: Alignment, limit: CGFloat) -> some View {
        ZStack {
            if let close { closeButton(close) } else if let item { barItem(item) }
        }
        .background(GeometryReader { g in Color.clear.preference(key: BarSideWidthKey.self, value: g.size.width) })
        .frame(maxWidth: limit, alignment: alignment)
    }

    @ViewBuilder
    private func barItem(_ item: RenderModel.BarItem) -> some View {
        switch item {
        case let .back(label):
            Button(action: goBack) {
                // Icons keep their size inside the fixed circle; Dynamic Type scales the words around them.
                Text("‹").font(.system(size: 15)).foregroundColor(muted)
                    .flipsForRightToLeftLayoutDirection(true)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(surface))
                    .contentShape(Rectangle().inset(by: -8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(label))
        case let .restore(label):
            Button(action: { vm.restore() }) {
                Text(label).sf(13, .semibold).foregroundColor(muted).lineLimit(1)
                    .opacity(vm.restoring ? 0 : 1)
                    .overlay { if vm.restoring { ProgressView().scaleEffect(0.6) } }
                    .frame(minHeight: 28)
                    .contentShape(Rectangle().inset(by: -8))
            }
            .buttonStyle(.plain)
            .disabled(vm.purchasing || vm.restoring)
            .accessibilityLabel(Text(label))
        case let .text(value):
            Text(value).sf(13, .semibold).foregroundColor(text).lineLimit(1).truncationMode(.tail)
        case let .progress(index, count, label):
            HStack(spacing: 6) {
                ForEach(0..<max(0, count), id: \.self) { i in
                    Circle().fill(i == index ? accent : muted.opacity(0.4)).frame(width: 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
        case let .image(url, height):
            if url.hasPrefix("https://"), let u = URL(string: url) { BarImage(url: u, height: CGFloat(height)) }
        }
    }

    // MARK: Blocks

    @ViewBuilder
    private func blockView(_ block: RenderModel.Block) -> some View {
        switch block {
        case let .close(position, delay, style, label, bar):
            closeRow(PaywallClose(position: position, delaySeconds: delay, style: style, label: label, bar: bar))
        case let .hero(height, url, _): heroView(height: height, url: url)
        case let .headline(t, sub, _): headlineView(t, sub)
        case let .benefits(items, _): benefitsView(items)
        case let .plans(plans, _): plansView(plans)
        case let .trialTimeline(steps, _): timelineView(steps)
        case let .testimonials(items, _): testimonialsView(items)
        case let .faq(items, _): faqView(items)
        case let .comparison(cols, rows, _): comparisonView(cols, rows)
        case let .cta(label, enabled, _): ctaView(label, enabled: enabled)
        case let .legal(t, terms, privacy, restore, _): legalView(t, terms: terms, privacy: privacy, restore: restore)
        }
    }

    /// Style `row`: the button at the leading (`left`) or trailing (`right`) edge of its own row.
    private func closeRow(_ close: PaywallClose) -> some View {
        HStack {
            if close.position == .right { Spacer(minLength: 0) }
            closeButton(close)
            if close.position == .left { Spacer(minLength: 0) }
        }
    }

    /// The ✕ circle, or the close `label` as a text button (bar and row); hidden until `delaySeconds`.
    private func closeButton(_ close: PaywallClose) -> some View {
        Button(action: { vm.close() }) {
            if let label = close.label {
                Text(label).sf(15, .semibold).foregroundColor(muted).lineLimit(1)
                    .padding(.horizontal, 4)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle().inset(by: -8))
            } else {
                Text("✕").font(.system(size: 15)).foregroundColor(muted)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(surface))
                    .contentShape(Rectangle().inset(by: -8))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(close.label ?? m.labels?.close ?? "Close"))
        .opacity(closeVisible ? 1 : 0)
        .disabled(!closeVisible)
        .accessibilityHidden(!closeVisible)
    }

    /// Only in the model with an image (0.3.0); the gradient shows while it loads or if it fails.
    private func heroView(height: Int, url: String) -> some View {
        let gradient = LinearGradient(colors: [Color(hex: palette.hero), accent],
                                      startPoint: UnitPoint(x: 0.329, y: 0.03), endPoint: UnitPoint(x: 0.671, y: 0.97))
        return ZStack {
            gradient
            if url.hasPrefix("https://"), let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    if case .success(let image) = phase { image.resizable().scaledToFill() } else { Color.clear }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: CGFloat(height))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityHidden(true)
    }

    private func headlineView(_ t: String, _ sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(t).sf(26, .bold, .title)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let sub { Text(sub).sf(14).foregroundColor(muted).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func benefitsView(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 8) {
                    Text("✓").font(.system(size: 11)).foregroundColor(.white)
                        .frame(width: 18, height: 18).background(Circle().fill(accent))
                        .accessibilityHidden(true)
                    Text(item).sf(14).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func plansView(_ plans: [RenderModel.Plan]) -> some View {
        VStack(spacing: 8) {
            ForEach(plans, id: \.productId) { plan in
                Button(action: { vm.select(plan.productId) }) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(plan.title).sf(14, .bold)
                            priceLineView(plan.priceLine)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let badge = plan.badge {
                            Text(badge).sf(11, .bold).lineLimit(1).foregroundColor(bg)
                                .padding(.vertical, 2).padding(.horizontal, 8)
                                .background(Capsule().fill(accent))
                        }
                    }
                    .foregroundColor(text)
                    .padding(.vertical, 12).padding(.horizontal, 14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(plan.selected ? accent : muted.opacity(0.33), lineWidth: plan.selected ? 2 : 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(plan.selected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    @ViewBuilder
    private func priceLineView(_ line: String?) -> some View {
        if let line {
            Text(line).sf(12).foregroundColor(muted)
        } else if vm.pricesLoading {
            // A bar in the price line's place until the store answers (CONTRACT §8): 96 wide,
            // as tall as the line less 2 above and below.
            Text(verbatim: " ").sf(12).hidden()
                .frame(width: 96, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(muted.opacity(0.2)).padding(.vertical, 2))
                .accessibilityHidden(true)
        } else {
            Text(m.labels?.unavailablePrice ?? RenderModel.unavailablePrice).sf(12).foregroundColor(muted)
        }
    }

    private func timelineView(_ steps: [RenderModel.Step]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                (Text(s.label).bold() + Text(" · \(s.text)")).sf(12).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func testimonialsView(_ items: [PaywallDefinition.Quote]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, q in
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.quote).sf(13).fixedSize(horizontal: false, vertical: true)
                    Text(q.author).sf(13).foregroundColor(muted)
                }
                .padding(.vertical, 10).padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(surface))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func faqView(_ items: [PaywallDefinition.Question]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, q in
                VStack(alignment: .leading, spacing: 0) {
                    Text(q.question).sf(13, .bold).fixedSize(horizontal: false, vertical: true)
                    Text(q.answer).sf(13).foregroundColor(muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func comparisonView(_ cols: [String], _ rows: [PaywallDefinition.ComparisonRow]) -> some View {
        let colWidth: CGFloat = 56
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("").frame(maxWidth: .infinity, alignment: .leading)
                Text(cols.first ?? "Free").sf(13, .bold).foregroundColor(muted).frame(width: colWidth)
                Text(cols.count > 1 ? cols[1] : "Pro").sf(13, .bold).frame(width: colWidth)
            }
            .padding(.vertical, 4)
            .accessibilityHidden(true)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 0) {
                    Text(r.feature).sf(13).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 2)
                    Text(r.free ? "✓" : "—").sf(13).frame(width: colWidth)
                    Text(r.pro ? "✓" : "—").sf(13).foregroundColor(accent).frame(width: colWidth)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(r.feature): \(cols.first ?? "Free") \(r.free ? "yes" : "no"), \(cols.count > 1 ? cols[1] : "Pro") \(r.pro ? "yes" : "no")"))
            }
        }
    }

    private func nextView(_ label: String) -> some View {
        Button(action: goNext) {
            Text(label).sf(14, .bold)
                .foregroundColor(bg)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(accent))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private func ctaView(_ label: String, enabled: Bool) -> some View {
        Button(action: { vm.purchase() }) {
            ZStack {
                Text(label).sf(14, .bold).opacity(vm.purchasing ? 0 : 1)
                if vm.purchasing { ProgressView().progressViewStyle(.circular).tint(bg) }
            }
            .foregroundColor(bg)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(accent))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || vm.purchasing || vm.restoring)
        // One layer, so the label keeps its contrast against the fill at 50%.
        .compositingGroup()
        .opacity(enabled ? 1 : 0.5)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(vm.purchasing ? "In progress" : ""))
    }

    private func legalView(_ t: String, terms: String?, privacy: String?, restore: Bool) -> some View {
        VStack(spacing: 4) {
            if !t.isEmpty {
                Text(t).sf(11).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                link(m.labels?.terms ?? "Terms", url: terms)
                Text("·").sf(11).accessibilityHidden(true)
                link(m.labels?.privacy ?? "Privacy", url: privacy)
                if restore {
                    Text("·").sf(11).accessibilityHidden(true)
                    Button(action: { vm.restore() }) {
                        if vm.restoring { ProgressView().scaleEffect(0.6) } else { Text(m.labels?.restore ?? "Restore purchases").underline().sf(11) }
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.purchasing || vm.restoring)
                }
            }
        }
        .foregroundColor(muted)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func link(_ title: String, url: String?) -> some View {
        if let url, url.hasPrefix("https://"), let u = URL(string: url) {
            Button(action: { open(u) }) { Text(title).underline().sf(11) }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isLink)
        } else {
            Text(title).sf(11)
        }
    }

    private func open(_ url: URL) {
        #if canImport(SafariServices) && canImport(UIKit)
        browserURL = IdentifiedURL(url: url)
        #else
        openURL(url)
        #endif
    }
}

/// A top bar image: height `height`, width by its aspect up to 120. Nothing is drawn while it loads or if it fails.
struct BarImage: View {
    let url: URL
    let height: CGFloat
    @State private var loaded: Loaded?

    struct Loaded { let image: Image; let aspect: CGFloat }

    var body: some View {
        ZStack {
            if let loaded {
                let width = min(height * loaded.aspect, 120)
                loaded.image.resizable().frame(width: width, height: width / loaded.aspect)
            }
        }
        .accessibilityHidden(true)
        .task(id: url) { loaded = await Self.load(url) }
    }

    static func load(_ url: URL) async -> Loaded? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
        #if canImport(UIKit)
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        return Loaded(image: Image(uiImage: image), aspect: image.size.width / image.size.height)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        return Loaded(image: Image(nsImage: image), aspect: image.size.width / image.size.height)
        #else
        return nil
        #endif
    }
}

struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

#if canImport(SafariServices) && canImport(UIKit)
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
#endif
