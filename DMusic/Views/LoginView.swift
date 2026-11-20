import SwiftUI

struct LoginView: View {
    @Environment(AuthViewModel.self) private var auth
    @FocusState private var focus: Field?
    enum Field { case url, user, pass }

    var body: some View {
        @Bindable var auth = auth
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 72)).foregroundStyle(Color.accentColor).padding(.top, 60)
                VStack(spacing: 4) {
                    Text("DMusic").font(.largeTitle.bold())
                    Text("Conecte-se ao seu servidor Navidrome").foregroundStyle(.secondary)
                }
                VStack(spacing: 12) {
                    field { TextField("URL do servidor (http://100.x.x.x:4533)", text: $auth.serverURL)
                        .keyboardType(.URL).textContentType(.URL).focused($focus, equals: .url)
                        .submitLabel(.next).onSubmit { focus = .user } }
                    field { TextField("Usuário", text: $auth.username)
                        .textContentType(.username).focused($focus, equals: .user)
                        .submitLabel(.next).onSubmit { focus = .pass } }
                    field { SecureField("Senha", text: $auth.password)
                        .textContentType(.password).focused($focus, equals: .pass)
                        .submitLabel(.go).onSubmit { Task { await auth.connect() } } }
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()

                if let error = auth.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.red).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    focus = nil
                    Task { await auth.connect() }
                } label: {
                    ZStack {
                        if auth.isLoading { ProgressView().tint(.white) } else { Text("Conectar").fontWeight(.semibold) }
                    }
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.white)
                }
                .disabled(auth.isLoading)
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.black.ignoresSafeArea())
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(14)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
