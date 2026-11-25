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
    private(set) var hasLoadedOnce = false

    private var activeLoadTask: Task<Void, Never>?

    func loadIfNeeded(client: SubsonicClient) async {
        if hasLoadedOnce { return }
        await load(client: client)
    }

    func load(client: SubsonicClient) async {
        if let existing = activeLoadTask {
            await existing.value
            return
        }
        let task = Task { @MainActor in
            isLoading = true
            errorMessage = nil
            defer {
                isLoading = false
                hasLoadedOnce = true
                activeLoadTask = nil
            }
            do {
                async let n = client.albumList(type: "newest")
                async let r = client.albumList(type: "recent")
                async let x = client.albumList(type: "random")
                (newest, recent, random) = try await (n, r, x)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        activeLoadTask = task
        await task.value
    }

    func reset() {
        activeLoadTask?.cancel()
        activeLoadTask = nil
        newest = []
        recent = []
        random = []
        isLoading = false
        errorMessage = nil
        hasLoadedOnce = false
    }
}
