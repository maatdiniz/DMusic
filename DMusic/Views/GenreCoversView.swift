import SwiftUI

/// Biblioteca de capas: todas as famílias de gênero, cada uma com ▶ e ⚡. Toque na capa para ver os subgêneros.
struct GenreCoversView: View {
    let genres: [GenreInfo]
    let library: GenreLibrary
    let onStart: (GenreFamily, Bool) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        let counts = GenreLibrary.familyCounts(genres)
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(counts, id: \.family) { item in
                    NavigationLink {
                        GenreInventoryView(genres: genres, library: library, only: item.family)
                    } label: {
                        GenreCoverTile(family: item.family, count: item.count, width: 108,
                                       onPlay: { onStart(item.family, false) },
                                       onAutomix: { onStart(item.family, true) })
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            NavigationLink {
                GenreInventoryView(genres: genres, library: library)
            } label: {
                Label("Ajustar tags de gênero", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                    .padding(.vertical, 10).padding(.horizontal, 16)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
        }
        .navigationTitle("Gêneros")
        .navigationBarTitleDisplayMode(.inline)
        .playerBottomSpace()
    }
}
