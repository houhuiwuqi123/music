import SwiftUI

struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.11), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 20, y: 10)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 24) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }
}

struct DarkBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.03, blue: 0.055)
            RadialGradient(colors: [.purple.opacity(0.24), .clear], center: .topLeading, startRadius: 20, endRadius: 430)
            RadialGradient(colors: [.blue.opacity(0.18), .clear], center: .bottomTrailing, startRadius: 30, endRadius: 500)
        }
        .ignoresSafeArea()
    }
}

struct TrackRow: View {
    let track: Track
    var trailingText: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ArtworkView(track: track, size: 50, cornerRadius: 14)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title).font(.body.weight(.semibold)).lineLimit(1)
                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let trailingText {
                    Text(trailingText).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Image(systemName: "play.fill").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold())
            Spacer()
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
