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

/// Draws a Sansora render model with native views (CONTRACT §8), following the
/// editor preview (packages/ui/src/Paywalls.tsx, paywalls.css).
public struct SansoraPaywallView: View {
    @ObservedObject var vm: PaywallViewModel
    @State private var closeVisible = false
    @State private var browserURL: IdentifiedURL?
    @State private var page = 0
    @Environment(\.openURL) private var openURL
    @Environment(\.layoutDirection) private var layoutDirection

    public init(model: PaywallViewModel) { self.vm = model }

    private var m: RenderModel { vm.model }
    private var palette: PaywallDefinition.Palette { m.palette }
    private var bg: Color { Color(hex: palette.background) }
    private var surface: Color { Color(hex: palette.surface) }
    private var text: Color { Color(hex: palette.text) }
    private var muted: Color { Color(hex: palette.muted) }
    private var accent: Color { Color(hex: palette.accent) }
    /// The page on screen, or nil for a one-page paywall.
    private var currentPage: RenderModel.Page? {
        guard let pages = m.pages, !pages.isEmpty else { return nil }
        return pages[min(page, pages.count - 1)]
    }
    private var shownBlocks: [RenderModel.Block] { currentPage?.blocks ?? m.blocks }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if vm.isPreview {
                    Text("Preview · purchases are off").sf(11, .bold).foregroundColor(muted).frame(maxWidth: .infinity)
                }
                ForEach(Array(shownBlocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
                if let next = currentPage?.nextLabel { nextView(next) }
            }
            .padding(.top, 22)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundColor(text)
        .background(bg.ignoresSafeArea())
        .preferredColorScheme(m.theme == .dark ? .dark : .light)
        .environment(\.layoutDirection, m.direction == "rtl" ? .rightToLeft : layoutDirection)
        .task(id: closeDelay) {
            guard let delay = closeDelay else { return }
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) }
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { closeVisible = true } }
        }
        #if canImport(SafariServices) && canImport(UIKit)
        .sheet(item: $browserURL) { item in SafariView(url: item.url).ignoresSafeArea() }
        #endif
    }

    private var closeDelay: Int? {
        for b in shownBlocks { if case let .close(_, d) = b { return d } }
        return nil
    }

    @ViewBuilder
    private func blockView(_ block: RenderModel.Block) -> some View {
        switch block {
        case let .close(position, _): closeView(position)
        case let .hero(height, url): heroView(height: height, url: url)
        case let .headline(t, sub): headlineView(t, sub)
        case let .benefits(items): benefitsView(items)
        case let .plans(plans): plansView(plans)
        case let .trialTimeline(steps): timelineView(steps)
        case let .testimonials(items): testimonialsView(items)
        case let .faq(items): faqView(items)
        case let .comparison(cols, rows): comparisonView(cols, rows)
        case let .cta(label, enabled): ctaView(label, enabled: enabled)
        case let .legal(t, terms, privacy, restore): legalView(t, terms: terms, privacy: privacy, restore: restore)
        }
    }

    // MARK: Blocks

    private func closeView(_ position: PaywallDefinition.Position) -> some View {
        HStack {
            if position == .right { Spacer(minLength: 0) }
            Button(action: { vm.close() }) {
                Text("✕").sf(15).foregroundColor(muted)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(surface))
                    .contentShape(Rectangle().inset(by: -8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(m.labels?.close ?? "Close"))
            .opacity(closeVisible ? 1 : 0)
            .disabled(!closeVisible)
            .accessibilityHidden(!closeVisible)
            if position == .left { Spacer(minLength: 0) }
        }
    }

    private func heroView(height: Int, url: String?) -> some View {
        let gradient = LinearGradient(colors: [Color(hex: palette.hero), accent],
                                      startPoint: UnitPoint(x: 0.329, y: 0.03), endPoint: UnitPoint(x: 0.671, y: 0.97))
        return ZStack {
            gradient
            if let url, url.hasPrefix("https://"), let u = URL(string: url) {
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
                    Text("✓").sf(11).foregroundColor(.white)
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
                            Text(plan.priceLine ?? m.labels?.unavailablePrice ?? RenderModel.unavailablePrice).sf(12).foregroundColor(muted)
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
        Button(action: { withAnimation(.easeOut(duration: 0.2)) { page += 1 } }) {
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
