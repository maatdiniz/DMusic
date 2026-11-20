import SwiftUI

struct AddToPlaylistSheet: View {
    let songs: [Song]
    @Environment(AuthViewModel.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [Playlist] = []
    @State private var newName = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Nova playlist") {
                    HStack {
                        TextField("Nome", text: $newName)
                        Button("Criar") { run { try await $0.createPlaylist(name: newName, songIds: songs.map(\.id)) } }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    }
                }
                Section("Adicionar a") {
                    ForEach(playlists) { pl in
                        Button { run { try await $0.addToPlaylist(id: pl.id, songIds: songs.map(\.id)) } } label: {
                            HStack { Text(pl.name); Spacer(); Text("\(pl.songCount ?? 0)").foregroundStyle(.secondary) }
                        }.disabled(busy)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle(songs.count == 1 ? "Adicionar à playlist" : "Adicionar \(songs.count) faixas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
            .task { if let c = auth.client { playlists = (try? await c.playlists()) ?? [] } }
        }
        .preferredColorScheme(.dark)
    }

    private func run(_ op: @escaping (SubsonicClient) async throws -> Void) {
        guard let c = auth.client else { return }
        busy = true
        Task {
            do { try await op(c); dismiss() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
