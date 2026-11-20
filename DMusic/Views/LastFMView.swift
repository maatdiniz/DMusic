import SwiftUI

struct LastFMView: View {
    @Environment(ScrobbleManager.self) private var scrobbler
    @Environment(AudioPlayerManager.self) private var player
    @State private var apiKey = ""
    @State private var secret = ""
    @State private var username = ""
    @State private var password = ""
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        @Bindable var scrobbler = scrobbler
        Form {
            if scrobbler.isLastFMConnected {
                Section("Conta") {
                    LabeledContent("Conectado como", value: scrobbler.lastfmUser ?? "")
                    Toggle("Enviar scrobbles ao Last.fm", isOn: $scrobbler.lastfmEnabled)
                    Button("Desconectar", role: .destructive) { scrobbler.disconnectLastFM() }
                }
            } else {
                Section {
                    TextField("API Key", text: $apiKey)
                    SecureField("Shared Secret", text: $secret)
                    TextField("Usuário Last.fm", text: $username).textContentType(.username)
                    SecureField("Senha Last.fm", text: $password).textContentType(.password)
                } header: { Text("Conectar") }
                  footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("O Last.fm exige uma API Key própria (gratuita). Crie em:")
                        Link("last.fm/api/account/create", destination: URL(string: "https://www.last.fm/api/account/create")!)
                        Text("A senha é usada só para obter a sessão e não é armazenada.")
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack { Spacer(); if loading { ProgressView() } else { Text("Conectar").fontWeight(.semibold) }; Spacer() }
                    }
                    .disabled(loading || apiKey.isEmpty || secret.isEmpty || username.isEmpty || password.isEmpty)
                }
            }

            Section {
                Toggle("Enviar só o artista principal", isOn: $scrobbler.usePrimaryArtistOnly)
                Toggle("Limpar extras do título (feat., Remaster...)", isOn: $scrobbler.stripTitleExtras)
                Toggle("Limpar extras do álbum (Deluxe, Edition...)", isOn: $scrobbler.stripAlbumExtras)
                Toggle("Limpar resíduos de arquivo (01 -, .flac...)", isOn: $scrobbler.cleanFileArtifacts)
            } header: { Text("Tratamento de Tags") }
              footer: { Text("Usa o array estruturado de artistas do OpenSubsonic/Navidrome, envia Album Artist e número da faixa separados, normaliza acentos em UTF-8 (NFC) e evita que participações criem artistas duplicados no Last.fm.") }

            if let current = player.currentSong {
                let preview = scrobbler.cleanedTags(for: current)
                Section("Prévia da faixa atual no Last.fm") {
                    LabeledContent("Faixa", value: preview.title)
                    LabeledContent("Artista", value: preview.artist)
                    if let alb = preview.album { LabeledContent("Álbum", value: alb) }
                    if let aa = preview.albumArtist { LabeledContent("Artista do Álbum", value: aa) }
                    if let tn = preview.trackNumber { LabeledContent("Nº da faixa", value: "\(tn)") }
                }
            }

            Section {
                Toggle("Enviar também ao Navidrome", isOn: $scrobbler.sendToNavidrome)
            } header: { Text("Destinos") }
              footer: { Text("Se o seu Navidrome já envia ao Last.fm por conta própria, desative o Last.fm aqui (ou lá) para não duplicar os scrobbles.") }

            Section {
                LabeledContent("Aguardando envio", value: "\(scrobbler.pending.count)")
                LabeledContent("Last.fm", value: "\(scrobbler.pendingLastFM)")
                LabeledContent("Navidrome", value: "\(scrobbler.pendingNavidrome)")
                LabeledContent("Rede", value: scrobbler.isOnline ? "Online" : "Offline")
                if let e = scrobbler.lastError { Text(e).font(.footnote).foregroundStyle(.red) }
                Button {
                    Task { await scrobbler.flush() }
                } label: {
                    HStack { Text("Enviar agora"); if scrobbler.isFlushing { Spacer(); ProgressView() } }
                }
                .disabled(scrobbler.pending.isEmpty || scrobbler.isFlushing)
                if !scrobbler.pending.isEmpty {
                    Button("Descartar fila", role: .destructive) { scrobbler.clearPending() }
                }
            } header: { Text("Fila offline") }
              footer: { Text("Faixas ouvidas sem rede ficam guardadas com o horário real e são enviadas automaticamente quando a conexão voltar. Uma faixa conta após 50% ou 4 minutos tocados (mínimo 30 s de duração).") }
        }
        .navigationTitle("Last.fm e Scrobbles")
        .navigationBarTitleDisplayMode(.inline)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .onAppear { apiKey = scrobbler.apiKey; secret = scrobbler.secret }
    }

    private func connect() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            try await scrobbler.connectLastFM(apiKey: apiKey, secret: secret, username: username, password: password)
            password = ""
        } catch { self.error = error.localizedDescription }
    }
}
