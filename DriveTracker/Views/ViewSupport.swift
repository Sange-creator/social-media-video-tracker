import SwiftUI
import UIKit

enum TrackerPalette {
    static let canvas = Color(red: 9/255, green: 10/255, blue: 15/255)
    static let surface = Color(red: 19/255, green: 22/255, blue: 34/255)
    static let raised = Color(red: 26/255, green: 30/255, blue: 44/255)
    static let elevated = Color(red: 34/255, green: 39/255, blue: 57/255)
    static let line = Color(white: 1.0).opacity(0.08)
    static let cardBorder = Color(white: 1.0).opacity(0.10)
    static let muted = Color(red: 148/255, green: 163/255, blue: 184/255)
    static let textPrimary = Color(red: 248/255, green: 250/255, blue: 252/255)
    static let accent = Color(red: 56/255, green: 189/255, blue: 248/255)
    static let success = Color(red: 52/255, green: 211/255, blue: 153/255)
    static let warning = Color(red: 251/255, green: 191/255, blue: 36/255)
    static let danger = Color(red: 248/255, green: 113/255, blue: 113/255)
}

struct RadialQuotaProgress: View {
    let completed: Int
    let quota: Int
    var size: CGFloat = 58
    var lineWidth: CGFloat = 5.5
    var showLabel: Bool = true

    private var progress: Double {
        guard quota > 0 else { return 0 }
        return min(1.0, Double(completed) / Double(quota))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(TrackerPalette.line, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: CGFloat(progress))
                .stroke(
                    LinearGradient(
                        colors: [TrackerPalette.accent, TrackerPalette.success],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            if showLabel {
                VStack(spacing: 0) {
                    Text("\(completed)")
                        .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                        .foregroundStyle(TrackerPalette.textPrimary)
                    Text("/\(quota)")
                        .font(.system(size: size * 0.18, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TrackerPalette.muted)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

struct StatusPill: View {
    let status: VideoStatus

    var body: some View {
        let tint = status.tint
        HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(status.title.capitalized)
                .font(.system(size: 9.5, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
        .overlay {
            Capsule().stroke(tint.opacity(0.25), lineWidth: 0.5)
        }
    }
}

struct FilterChip: View {
    let title: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title.capitalized).lineLimit(1)
            Image(systemName: selected ? "checkmark" : "chevron.down")
                .font(.system(size: 8, weight: .bold))
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(selected ? Color(hex: "#090A0F") : TrackerPalette.textPrimary)
        .padding(.horizontal, 13)
        .frame(height: 34)
        .background(selected ? TrackerPalette.accent : TrackerPalette.surface, in: Capsule())
        .overlay {
            Capsule().stroke(selected ? Color.clear : TrackerPalette.line, lineWidth: 0.5)
        }
    }
}

struct TrackerSectionLabel: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(TrackerPalette.muted)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(TrackerPalette.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(TrackerPalette.accent.opacity(0.10), in: Capsule())
            }
        }
    }
}

struct TrackerMetric: View {
    let value: String
    let label: String
    var tint: Color = TrackerPalette.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(.title3, design: .rounded).monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(TrackerPalette.muted)
        }
    }
}

struct TrackerActionButtonStyle: ButtonStyle {
    enum Kind: Equatable {
        case primary
        case secondary
        case quiet
        case danger
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(background.opacity(configuration.isPressed ? 0.82 : 1))
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
        case .primary: Color(hex: "#090A0F")
        case .secondary: TrackerPalette.textPrimary
        case .quiet: TrackerPalette.muted
        case .danger: TrackerPalette.danger
        }
    }

    private var background: Color {
        switch kind {
        case .primary: TrackerPalette.accent
        case .secondary: TrackerPalette.surface
        case .quiet: .clear
        case .danger: TrackerPalette.danger.opacity(0.15)
        }
    }

    private var border: Color {
        switch kind {
        case .primary: TrackerPalette.accent.opacity(0.5)
        case .secondary: TrackerPalette.line
        case .quiet: .clear
        case .danger: TrackerPalette.danger.opacity(0.3)
        }
    }
}

/// Gives card rows and icon-only controls an instant responsive press state
/// without allocating animations or haptic loops during scroll gestures.
struct TrackerPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.65 : 1.0)
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
        case .available: TrackerPalette.accent
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
        let color = Color(hex: colorHex)
        Image(systemName: symbol)
            .font(.system(size: size * 0.34, weight: .bold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14))
            .clipShape(Circle())
            .overlay {
                Circle().stroke(color.opacity(0.28), lineWidth: 0.5)
            }
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Text(badge)
                        .font(.system(size: max(8, size * 0.18), weight: .bold, design: .monospaced))
                        .foregroundStyle(TrackerPalette.muted)
                        .frame(minWidth: size * 0.38, minHeight: size * 0.38)
                        .padding(.horizontal, 3)
                        .background(TrackerPalette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4).stroke(TrackerPalette.line, lineWidth: 0.5)
                        }
                        .offset(x: size * 0.08, y: size * 0.08)
                }
            }
    }
}

struct VideoThumbnailView: View {
    @EnvironmentObject private var state: AppState
    let video: VideoAsset
    var width: CGFloat? = 108
    var height: CGFloat? = 144
    var cornerRadius: CGFloat = 12

    @State private var image: UIImage?

    init(
        video: VideoAsset,
        width: CGFloat? = 108,
        height: CGFloat? = 144,
        cornerRadius: CGFloat = 12
    ) {
        self.video = video
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        _image = State(initialValue: ThumbnailService.shared.cachedImage(for: video.identityKey))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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

            // Flat scrim keeps scrolling on the fast compositing path.
            Color.black.opacity(image == nil ? 0 : 0.18)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: video.identityKey) {
            if image == nil {
                image = await ThumbnailService.shared.thumbnailImage(
                    for: video,
                    api: state.api,
                    currentUserID: state.auth.userID
                )
            }
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
                                .foregroundStyle(symbol == option ? Color(hex: "#090A0F") : TrackerPalette.muted)
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
                                            symbol == option ? Color.white.opacity(0.45) : TrackerPalette.line,
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
