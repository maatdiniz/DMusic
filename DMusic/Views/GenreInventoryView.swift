import SwiftUI

/// Central de gêneros: famílias e subgêneros da biblioteca, cada um com botão de tocar e de tocar com Automix.
/// Uma tag pode valer para mais de uma família; o menu ••• de cada tag ajusta isso manualmente.
struct GenreInventoryView: View {
    let genres: [GenreInfo]
    let library: GenreLibrary
    var only: GenreFamily? = nil
    @Environment(AuthViewModel.self) private var auth
    @Environment(AudioPlayerManager.self) private var player
    @State private var revision = 0
    @State private var starting = false
    @State private var notice: String?

    private struct Entry: Identifiable {
        let genre: GenreInfo
        let sub: String?
        var id: String { genre.value + (sub ?? "") }
    }

    private struct Group: Identifiable {
        let family: GenreFamily
        let entries: [Entry]
        var id: String { family.id }
    }

    private var groups: [Group] {
        _ = revision
        var byFamily: [GenreFamily: [Entry]] = [:]
        for g in genres {
            let tags = GenreTaxonomy.tags(forTag: g.value)
            for t in (tags.isEmpty ? [GenreTag(family: .other, sub: nil)] : Array(tags)) {
                byFamily[t.family, default: []].append(Entry(genre: g, sub: t.sub))
            }
        }
        return GenreFamily.allCases.compactMap { fam in
            if let only, fam != only { return nil }
            guard let items = byFamily[fam], !items.isEmpty else { return nil }
            return Group(family: fam, entries: items.sorted { ($0.genre.songCount ?? 0) > ($1.genre.songCount ?? 0) })
        }
        .sorted { total($0) > total($1) }
    }

    private func total(_ g: Group) -> Int { g.entries.reduce(0) { $0 + ($1.genre.songCount ?? 0) } }

    var body: some View {
        List {
            Section {
                Text("Toque em ▶ para tocar o gênero embaralhado, ou em ⚡ para tocar com Automix. Uma tag pode valer para mais de uma família, e uma música com várias tags entra em todas.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.entries) { e in
                        HStack(spacing: 10) {
                            Menu {
                                tagMenu(e.genre.value)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.genre.value.isEmpty ? "(vazio)" : e.genre.value).foregroundStyle(.primary)
                                    HStack(spacing: 6) {
                                        if let sub = e.sub { Text(sub) }
                                        Text("\(e.genre.songCount ?? 0) músicas")
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            playButtons(title: e.sub ?? e.genre.value, family: group.family, sub: e.sub)
                        }
                    }
                } header: {
                    HStack {
                        Text(group.family.rawValue)
                        Spacer()
                        playButtons(title: group.family.rawValue, family: group.family, sub: nil)
                            .textCase(nil)
                    }
                } footer: {
                    if !group.family.neighbors.isEmpty {
                        Text("Vizinhas: " + group.family.neighbors.map(\.rawValue).joined(separator: ", "))
                    }
                }
            }
        }
        .navigationTitle(only?.rawValue ?? "Gêneros")
        .navigationBarTitleDisplayMode(.inline)
        .playerBottomSpace()
        .overlay { if starting { ProgressView().controlSize(.large) } }
        .task { if let c = auth.client { await library.load(client: c) } }
        .alert("Pool ampliado", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    @ViewBuilder
    private func tagMenu(_ tag: String) -> some View {
        ForEach(GenreFamily.allCases) { fam in
            Button {
                toggle(fam, for: tag)
            } label: {
                if GenreTaxonomy.tags(forTag: tag).contains(where: { $0.family == fam }) {
                    Label(fam.rawValue, systemImage: "checkmark")
                } else {
                    Text(fam.rawValue)
                }
            }
        }
        Button("Restaurar automático", systemImage: "arrow.uturn.backward") {
            GenreOverrides.shared.set(nil, forTag: tag)
            library.reclassify()
            revision += 1
        }
    }

    private func playButtons(title: String, family: GenreFamily, sub: String?) -> some View {
        HStack(spacing: 8) {
            Button { start(title, family, sub, automix: false) } label: {
                Image(systemName: "play.fill").frame(width: 34, height: 30)
            }
            Button { start(title, family, sub, automix: true) } label: {
                Image(systemName: "bolt.fill").frame(width: 34, height: 30)
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
        .background(Color.white.opacity(0.10), in: Capsule())
        .disabled(starting)
    }

    private func toggle(_ fam: GenreFamily, for tag: String) {
        var current = Set(GenreTaxonomy.tags(forTag: tag).map(\.family))
        if current.contains(fam) { current.remove(fam) } else { current.insert(fam) }
        GenreOverrides.shared.set(current.isEmpty ? [.other] : Array(current), forTag: tag)
        library.reclassify()
        revision += 1
    }

    private func start(_ title: String, _ family: GenreFamily, _ sub: String?, automix: Bool) {
        guard let client = auth.client else { return }
        Task {
            starting = true
            defer { starting = false }
            notice = await library.startMix(title: title, family: family, sub: sub, automix: automix, client: client, player: player)
        }
    }
}
