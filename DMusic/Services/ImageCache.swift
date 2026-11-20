import UIKit

nonisolated private final class MemoryImageBox: @unchecked Sendable {
    let cache = NSCache<NSString, UIImage>()
}

/// Cache de capas em memória + disco, sem limite de tamanho (capas são pequenas).
/// A URL muda a cada chamada (salt), então a chave é o id da capa + tamanho.
actor ImageCache {
    static let shared = ImageCache()
    private let memBox = MemoryImageBox()
    private var protectedIds: Set<String> = []
    private let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func setProtected(_ ids: Set<String>) { protectedIds = ids }

    nonisolated func cachedImage(id: String, size: Int) -> UIImage? {
        let name = "\(id)-\(size)".replacingOccurrences(of: "/", with: "_")
        return memBox.cache.object(forKey: name as NSString)
    }

    func image(id: String, size: Int, client: SubsonicClient?) async -> UIImage? {
        let name = "\(id)-\(size)".replacingOccurrences(of: "/", with: "_")
        let key = name as NSString
        if let hit = memBox.cache.object(forKey: key) { return hit }
        let file = dir.appendingPathComponent(name)
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            memBox.cache.setObject(img, forKey: key)
            return img
        }
        guard let client, let url = client.coverArtURL(id: id, size: size),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let img = UIImage(data: data) else { return nil }
        memBox.cache.setObject(img, forKey: key)
        try? data.write(to: file)
        return img
    }

    private func files() -> [(url: URL, coverId: String, size: Int64)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.map { u in
            let name = u.lastPathComponent
            let coverId = name.lastIndex(of: "-").map { String(name[..<$0]) } ?? name
            return (u, coverId, Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
    }

    func usage() -> Int64 { files().reduce(0) { $0 + $1.size } }

    /// Limpa as capas, exceto as de músicas baixadas.
    func clear() {
        for f in files() where !protectedIds.contains(f.coverId) { try? FileManager.default.removeItem(at: f.url) }
        memBox.cache.removeAllObjects()
    }
}
