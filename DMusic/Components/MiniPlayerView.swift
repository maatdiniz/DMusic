import SwiftUI

struct MiniPlayerView: View {
    @Environment(AudioPlayerManager.self) private var player

    private let cardFill = Color(red: 0.095, green: 0.10, blue: 0.118)

    var body: some View {
        if let song = player.currentSong {
            let maxTime = max(player.effectiveScrubberEndTime, 1.0)
            let progress = min(max(player.currentTime / maxTime, 0), 1)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    CoverArtView(coverArt: song.coverArt, size: 100, cornerRadius: 7)
                        .frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(ArtistParser.displayString(for: song))
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.60))
                            .lineLimit(1)
                    }
                    Spacer()
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                    }
                    Button { player.next() } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .frame(width: 32, height: 34)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                        Rectangle()
                            .fill(.white)
                            .frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 2)
            }
            .buttonStyle(.plain)
            .background(cardFill)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.7)
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
            .onTapGesture { player.showNowPlaying = true }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

extension View {
    /// Fixa o MiniPlayer logo acima da barra de abas.
    func miniPlayerInset() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerView() }
    }
}

extension View {
    /// Folga extra no fim de listas/rolagens para que o MiniPlayer não cubra o último item.
    func playerBottomSpace() -> some View {
        modifier(PlayerBottomSpace())
    }
}

private struct PlayerBottomSpace: ViewModifier {
    @Environment(AudioPlayerManager.self) private var player
    func body(content: Content) -> some View {
        content.contentMargins(.bottom, player.currentSong == nil ? 0 : 80, for: .scrollContent)
    }
}
