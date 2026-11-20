import Foundation

/// Gravador contínuo de logs da aplicação para arquivo local (`Documents/console.log`).
/// Utiliza um pipe tee POSIX para duplicar stdout e stderr:
/// 1. Mantém a saída em tempo real no console do Xcode.
/// 2. Grava todas as mensagens (prints do Swift, erros do sistema, C/C++ runtime e logs do AVFoundation) no disco.
final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()
    static let logFilename = "console.log"

    private var isStarted = false
    private let logQueue = DispatchQueue(label: "app.dmusic.logger", qos: .utility)

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true

        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let logURL = docs.appendingPathComponent(Self.logFilename)

        // Limita o tamanho do arquivo a 5MB para economizar espaço de armazenamento
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? Int64, size > 5 * 1024 * 1024 {
            try? FileManager.default.removeItem(at: logURL)
        }

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        guard let fileHandle = try? FileHandle(forWritingTo: logURL) else { return }
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

        logQueue.async {
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
            }
        }
    }
}
