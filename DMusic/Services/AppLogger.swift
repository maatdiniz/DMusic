import Foundation

/// Gravador contínuo de logs da aplicação para arquivo local (`Documents/console.log`).
/// Utiliza um pipe tee POSIX para duplicar stdout e stderr:
/// 1. Mantém a saída em tempo real no console do Xcode.
/// 2. Grava todas as mensagens (prints do Swift, erros do sistema, C/C++ runtime e logs do AVFoundation) no disco.
final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()
    static let logFilename = "console.log"
    static let logUpdatedNotification = Notification.Name("AppLoggerDidUpdateNotification")

    private var isStarted = false
    private let logQueue = DispatchQueue(label: "app.dmusic.logger", qos: .utility)
    private var logURL: URL?
    private var lastNotificationTime: TimeInterval = 0

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true

        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent(Self.logFilename)
        self.logURL = url

        // Limita o tamanho do arquivo a 5MB para economizar espaço de armazenamento
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64, size > 5 * 1024 * 1024 {
            try? FileManager.default.removeItem(at: url)
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        guard let fileHandle = try? FileHandle(forWritingTo: url) else { return }
        fileHandle.seekToEndOfFile()

        let origStderr = dup(STDERR_FILENO)

        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else { return }

        // Redireciona stderr e stdout para a ponta de escrita do pipe
        dup2(pipeFDs[1], STDERR_FILENO)
        dup2(pipeFDs[1], STDOUT_FILENO)
        close(pipeFDs[1])

        let readFD = pipeFDs[0]

        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let header = "\n=== DMusic Session Started: \(timestamp) ===\n"
        if let hData = header.data(using: .utf8) {
            fileHandle.write(hData)
        }

        logQueue.async { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let bytesRead = read(readFD, &buffer, buffer.count)
                if bytesRead <= 0 { break }

                // 1. Repassa para o console do Xcode em tempo real
                buffer.withUnsafeBufferPointer { ptr in
                    if let base = ptr.baseAddress {
                        _ = write(origStderr, base, bytesRead)
                    }
                }

                // 2. Grava no arquivo no disco
                let data = Data(buffer[0..<bytesRead])
                fileHandle.write(data)

                // 3. Notifica a UI em tempo real (com throttle suave de 300ms)
                let now = Date().timeIntervalSince1970
                if let self, now - self.lastNotificationTime > 0.3 {
                    self.lastNotificationTime = now
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: AppLogger.logUpdatedNotification, object: nil)
                    }
                }
            }
        }
    }

    /// Lê o log completo em texto bruto (retorna até os últimos 200KB para fluidez de rolagem)
    func readLog() -> String {
        guard let url = logURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(Self.logFilename),
              let data = try? Data(contentsOf: url) else {
            return ""
        }
        let maxBytes = 200 * 1024
        let slice = data.count > maxBytes ? data.suffix(maxBytes) : data
        return String(decoding: slice, as: UTF8.self)
    }

    /// Limpa o arquivo de log do console
    func clearLog() {
        guard let url = logURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(Self.logFilename) else { return }
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let header = "=== DMusic Log Reiniciado: \(timestamp) ===\n"
        try? header.write(to: url, atomically: true, encoding: .utf8)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: AppLogger.logUpdatedNotification, object: nil)
        }
    }
}
