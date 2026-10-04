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
    @EnvironmentObject private var player: MusicPlayerViewModel

    private var isCurrentTrack: Bool { player.currentTrack?.id == track.id }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ArtworkView(track: track, size: 50, cornerRadius: 14)
                VStack(alignment: .leading, spacing: 4) {
                    if isCurrentTrack {
                        MarqueeText(text: track.title, font: .body.weight(.semibold))
                            .frame(height: 20)
                    } else {
                        Text(track.title).font(.body.weight(.semibold)).lineLimit(1)
                    }
                    Text(track.artist).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.68)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                if let trailingText {
                    Text(trailingText).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                if isCurrentTrack {
                    PlayingBarsIcon(isAnimating: player.isPlaying)
                } else {
                    Image(systemName: "play.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MarqueeText: View {
    let text: String
    let font: Font
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var animationStart = Date()

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let overflow = max(textWidth - containerWidth, 0)
                let leadingPause = 0.8
                let spacing: CGFloat = 36
                let travel = textWidth + spacing
                let travelDuration = max(Double(travel / 26), 0.1)
                let cycle = leadingPause + travelDuration
                let elapsed = max(timeline.date.timeIntervalSince(animationStart), 0)
                let phase = elapsed.truncatingRemainder(dividingBy: cycle)
                let progress = min(max((phase - leadingPause) / travelDuration, 0), 1)
                HStack(spacing: spacing) {
                    measuredText
                    if overflow > 0 { measuredText }
                }
                .offset(x: overflow > 0 ? -travel * CGFloat(progress) : 0)
            }
            .onAppear {
                containerWidth = proxy.size.width
                animationStart = Date()
            }
            .onChange(of: proxy.size.width) { containerWidth = $0 }
        }
        .clipped()
    }

    private var measuredText: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { textWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { textWidth = $0 }
                }
            }
    }
}

private struct PlayingBarsIcon: View {
    let isAnimating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !isAnimating)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate * 8)
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(Color.purple)
                        .frame(width: 2.5, height: isAnimating ? [8.0, 14.0, 10.0][(step + index) % 3] : 8)
                }
            }
            .frame(width: 16, height: 18)
        }
        .accessibilityLabel(isAnimating ? "Playing" : "Paused")
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
