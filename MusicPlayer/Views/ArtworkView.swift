import SwiftUI

struct ArtworkView: View {
    let track: Track?
    var size: CGFloat = 52
    var cornerRadius: CGFloat = 12

    private var colors: [Color] {
        let seed = abs((track?.title ?? "Music").hashValue)
        let palettes: [[Color]] = [
            [.indigo, .purple],
            [.blue, .cyan],
            [.orange, .pink],
            [.mint, .teal]
        ]
        return palettes[seed % palettes.count]
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle()
                .fill(.black.opacity(0.18))
                .frame(width: size * 0.62)
            Circle()
                .stroke(.white.opacity(0.32), lineWidth: max(1, size * 0.025))
                .frame(width: size * 0.43)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.2, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: colors[0].opacity(0.25), radius: size * 0.12, y: size * 0.06)
        .accessibilityHidden(true)
    }
}
