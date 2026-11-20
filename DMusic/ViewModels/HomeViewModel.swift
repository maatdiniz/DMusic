import Foundation
import Observation

@Observable
@MainActor
final class HomeViewModel {
    var newest: [Album] = []
    var recent: [Album] = []
    var random: [Album] = []
    var isLoading = false
    var errorMessage: String?

    func load(client: SubsonicClient) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let n = client.albumList(type: "newest")
            async let r = client.albumList(type: "recent")
            async let x = client.albumList(type: "random")
            (newest, recent, random) = try await (n, r, x)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
