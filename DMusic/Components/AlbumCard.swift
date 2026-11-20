import SwiftUI

struct AlbumCard: View {
    let album: Album
    var width: CGFloat? = nil
    var badge: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                CoverArtView(coverArt: album.coverArt, size: 300, cornerRadius: 10)
                    .frame(width: width, height: width)
                    .frame(maxWidth: width == nil ? .infinity : nil)
                if let badge {
                    Text(badge.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(6)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(album.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(ArtistParser.displayString(from: album.artist))
                        .lineLimit(1)
                    if let y = album.year {
                        Text("• \(String(y))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}
