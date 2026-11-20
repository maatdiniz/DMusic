import Foundation
import Observation

@Observable
@MainActor
final class AuthViewModel {
    var serverURL = ""
    var username = ""
    var password = ""
    var isLoading = false
    var errorMessage: String?
    private(set) var client: SubsonicClient?

    var isLoggedIn: Bool { client != nil }

    private enum Key { static let url = "server_url", user = "username", pass = "password" }

    init() {
        let d = UserDefaults.standard
        serverURL = d.string(forKey: Key.url) ?? ""
        username = d.string(forKey: Key.user) ?? ""
        if let pass = KeychainStore.get(Key.pass), !serverURL.isEmpty, !username.isEmpty {
            password = pass
            client = SubsonicClient(serverURL: serverURL, username: username, password: pass)
        }
    }

    func connect() async {
        let url = SubsonicClient.normalize(serverURL)
        let user = username.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, !user.isEmpty, !password.isEmpty else {
            errorMessage = "Preencha servidor, usuário e senha."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let candidate = SubsonicClient(serverURL: url, username: user, password: password)
        do {
            try await candidate.ping()
            serverURL = url
            username = user
            UserDefaults.standard.set(url, forKey: Key.url)
            UserDefaults.standard.set(user, forKey: Key.user)
            KeychainStore.set(password, for: Key.pass)
            client = candidate
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func logout() {
        KeychainStore.remove(Key.pass)
        password = ""
        client = nil
    }
}
