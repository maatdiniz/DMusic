import SwiftUI

struct CoverArtView: View {
    let coverArt: String?
    var size: Int = 300
    var cornerRadius: CGFloat = 8

    @Environment(AuthViewModel.self) private var auth
    @State private var image: UIImage?

    var body: some View {
        let resolvedImage = image ?? coverArt.flatMap { ImageCache.shared.cachedImage(id: $0, size: size) }
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let resolvedImage {
                    Image(uiImage: resolvedImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: coverArt) {
            guard let coverArt else {
                image = nil
                return
            }
            if let syncHit = ImageCache.shared.cachedImage(id: coverArt, size: size) {
                image = syncHit
            } else {
                image = nil
                image = await ImageCache.shared.image(id: coverArt, size: size, client: auth.client)
            }
        }
    }

    private var placeholder: some View {
        LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Image(systemName: "music.note").font(.system(size: 28, weight: .light)).foregroundStyle(.white.opacity(0.35)))
    }
}
