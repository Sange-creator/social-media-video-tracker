import SwiftUI
import UIKit

enum TrackerPalette {
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let raised = Color(uiColor: .tertiarySystemGroupedBackground)
    static let line = Color(uiColor: .separator).opacity(0.45)
    static let muted = Color(uiColor: .secondaryLabel)
    static let accent = Color(uiColor: .systemBlue)
    static let success = Color(uiColor: .systemGreen)
    static let warning = Color(uiColor: .systemOrange)
    static let danger = Color(uiColor: .systemRed)
}

struct StatusPill: View {
    let status: VideoStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.tint)
                .frame(width: 6, height: 6)
            Text(status.title.capitalized)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(status.tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(status.tint.opacity(0.12), in: Capsule())
    }
}

struct FilterChip: View {
    let title: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Text(title.capitalized).lineLimit(1)
            Image(systemName: selected ? "xmark" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 13)
        .frame(height: 36)
        .background(selected ? TrackerPalette.accent : TrackerPalette.surface, in: Capsule())
        .overlay { Capsule().stroke(TrackerPalette.line, lineWidth: selected ? 0 : 0.5) }
    }
}

struct TrackerSectionLabel: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(TrackerPalette.muted)
            }
        }
    }
}

struct TrackerMetric: View {
    let value: String
    let label: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
            Text(label)
                .font(.footnote)
                .foregroundStyle(TrackerPalette.muted)
        }
    }
}

struct TrackerActionButtonStyle: ButtonStyle {
    enum Kind: Equatable {
        case primary
        case secondary
        case quiet
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(background.opacity(configuration.isPressed ? 0.78 : 1))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(border, lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .sensoryFeedback(
                .impact(flexibility: .soft, intensity: 0.65),
                trigger: configuration.isPressed
            ) { oldValue, newValue in
                !oldValue && newValue
            }
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: .primary
        case .quiet: TrackerPalette.muted
        }
    }

    private var background: Color {
        switch kind {
        case .primary: TrackerPalette.accent
        case .secondary: Color(uiColor: .secondarySystemFill)
        case .quiet: .clear
        }
    }

    private var border: Color {
        switch kind {
        case .primary: TrackerPalette.accent
        case .secondary, .quiet: TrackerPalette.line
        }
    }
}

/// Gives card rows and icon-only controls the same unmistakable press response
/// as native iOS controls without adding a permanent button background.
struct TrackerPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
            .sensoryFeedback(
                .impact(flexibility: .soft, intensity: 0.45),
                trigger: configuration.isPressed
            ) { oldValue, newValue in
                !oldValue && newValue
            }
    }
}

extension View {
    func trackerCard(padding cardPadding: CGFloat = 16) -> some View {
        padding(cardPadding)
            .background(
                TrackerPalette.surface,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(TrackerPalette.line, lineWidth: 0.5)
            }
    }

    func trackerScreen() -> some View {
        background(TrackerPalette.canvas.ignoresSafeArea())
    }

    func trackerListStyle() -> some View {
        scrollContentBackground(.hidden)
            .background(TrackerPalette.canvas)
    }
}

extension VideoStatus {
    var tint: Color {
        switch self {
        case .available: TrackerPalette.muted
        case .assigned: TrackerPalette.warning
        case .downloaded: TrackerPalette.accent
        case .uploaded: TrackerPalette.success
        }
    }
}

struct AccountIdentityIcon: View {
    let symbol: String
    let colorHex: String
    var size: CGFloat = 48
    var badge: String?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.34, weight: .medium))
            .foregroundStyle(Color(hex: colorHex))
            .frame(width: size, height: size)
            .background(Color(hex: colorHex).opacity(0.11))
            .clipShape(Circle())
            .overlay {
                Circle().stroke(Color(hex: colorHex).opacity(0.16), lineWidth: 0.5)
            }
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Text(badge)
                        .font(.system(size: max(8, size * 0.18), weight: .semibold, design: .monospaced))
                        .foregroundStyle(TrackerPalette.muted)
                        .frame(minWidth: size * 0.38, minHeight: size * 0.38)
                        .padding(.horizontal, 2)
                        .background(TrackerPalette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4).stroke(TrackerPalette.line, lineWidth: 1)
                        }
                        .offset(x: size * 0.10, y: size * 0.10)
                }
            }
    }
}

struct VideoThumbnailView: View {
    @EnvironmentObject private var state: AppState
    let video: VideoAsset
    var width: CGFloat = 108
    var height: CGFloat = 144

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(TrackerPalette.raised)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(TrackerPalette.muted)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(TrackerPalette.line, lineWidth: 1)
        }
        .task(id: video.thumbnailLink) {
            image = await state.thumbnailImage(for: video)
        }
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

struct AccountIconPicker: View {
    @Binding var symbol: String
    @Binding var colorHex: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a symbol")
                .font(.caption.weight(.semibold))
                .foregroundStyle(TrackerPalette.muted)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(AccountIconCatalog.symbols, id: \.self) { option in
                        Button {
                            symbol = option
                        } label: {
                            Image(systemName: option)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(symbol == option ? .white : TrackerPalette.muted)
                                .frame(width: 42, height: 42)
                                .background(
                                    symbol == option
                                        ? Color(hex: colorHex)
                                        : TrackerPalette.raised
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(
                                            symbol == option ? .white.opacity(0.45) : TrackerPalette.line,
                                            lineWidth: 1
                                        )
                                }
                        }
                        .buttonStyle(TrackerPressButtonStyle())
                    }
                }
            }

            Text("Choose a color")
                .font(.caption.weight(.semibold))
                .foregroundStyle(TrackerPalette.muted)

            HStack(spacing: 12) {
                ForEach(AccountIconCatalog.colors, id: \.self) { option in
                    Button {
                        colorHex = option
                    } label: {
                        Circle()
                            .fill(Color(hex: option))
                            .frame(width: 30, height: 30)
                            .overlay {
                                if colorHex == option {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                }
                            }
                            .overlay {
                                Circle().stroke(.white.opacity(colorHex == option ? 0.75 : 0.12), lineWidth: 2)
                            }
                    }
                    .buttonStyle(TrackerPressButtonStyle())
                }
            }
        }
    }
}

extension String {
    var humanized: String {
        replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
