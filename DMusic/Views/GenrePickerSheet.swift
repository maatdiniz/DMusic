import SwiftUI

/// Pedido para ajustar os gêneros de uma música ou de um álbum inteiro.
struct GenrePickerRequest: Identifiable {
    let id = UUID()
    let title: String
    let songs: [Song]
    /// Preenchido quando o ajuste vale para o álbum todo.
    let albumId: String?
}

extension GenreTaxonomy {
    /// Nomes das famílias de uma música (ou da maioria das faixas de um grupo), em ordem de contagem.
    static func familyLabels(for songs: [Song], limit: Int = 3) -> [String] {
        var counts: [GenreFamily: Int] = [:]
        for s in songs { for f in Set(tags(for: s).map(\.family)) { counts[f, default: 0] += 1 } }
        let threshold = max(1, (songs.count + 1) / 2)
        return counts.filter { $0.value >= threshold && $0.key != .other }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { $0.key.rawValue }
    }
}

/// Escolha manual das famílias de gênero. Alimenta os modos de gênero e o pool do Automix.
struct GenrePickerSheet: View {
    let request: GenrePickerRequest
    @Environment(\.dismiss) private var dismiss
    @State private var revision = 0

    private var detectedText: String {
        var seen: [String] = []
        for s in request.songs {
            for raw in ([s.genre] + (s.genres ?? []).map { Optional($0.name) }).compactMap({ $0 }) where !raw.isEmpty && !seen.contains(raw) {
                seen.append(raw)
            }
        }
        return seen.isEmpty ? "Nenhum gênero na tag do arquivo" : seen.prefix(4).joined(separator: " • ")
    }

    /// Ligada quando todas as faixas do pedido estão na família.
    private func isOn(_ fam: GenreFamily) -> Bool {
        _ = revision
        return request.songs.allSatisfy { GenreTaxonomy.tags(for: $0).contains { $0.family == fam } }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(detectedText).font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text(request.albumId != nil ? "Tags do álbum" : "Tag do arquivo")
                }
                Section {
                    ForEach(GenreFamily.allCases.filter { $0 != .other }) { fam in
                        Button {
                            GenreAssignments.shared.set(fam, enabled: !isOn(fam), songs: request.songs, albumId: request.albumId)
                            revision += 1
                        } label: {
                            HStack(spacing: 12) {
                                DMusicMark(color: fam.tint).frame(width: 24, height: 24)
                                Text(fam.rawValue).foregroundStyle(.primary)
                                Spacer()
                                if isOn(fam) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(fam.tint)
                                } else {
                                    Image(systemName: "circle").foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                } header: {
                    Text(request.albumId != nil ? "Incluir o álbum em" : "Incluir a música em")
                } footer: {
                    Text("Uma faixa pode estar em várias famílias. O Automix e os mixes por gênero usam essas escolhas para montar a fila.")
                }
                Section {
                    Button("Restaurar automático", systemImage: "arrow.uturn.backward") {
                        GenreAssignments.shared.reset(songs: request.songs, albumId: request.albumId)
                        revision += 1
                    }
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
