// Monitor visual do backfill de voz do mix-analyzer (analyze_library.py --vocals-backfill).
// Lê o log do processo, mostra progresso/ETA/velocidade e permite pausar/retomar.
// Compilar: ./build_monitor.sh   (gera "DMusic Monitor.app" nesta pasta)

import AppKit
import SwiftUI

// MARK: - Leitura do log e do processo

struct TrackEvent: Identifiable, Equatable {
    let id: Int
    let title: String
    let serverOK: Bool
}

struct MonitorSnapshot: Equatable {
    var device = "—"
    var total = 0
    var position = 0          // posição na lista (inclui faixas puladas por já estarem prontas)
    var completed = 0         // faixas processadas por este processo
    var errors = 0
    var serverFailures = 0
    var logRatePerMin: Double = 0
    var recent: [TrackEvent] = []
    var lastError: String?
    var finished = false
    var totalMinutes: Double?   // duração informada na linha "concluído: N faixas em X min"

    // Faixas puladas (já prontas) não geram linha no log: ao concluir, a fila inteira foi resolvida
    var fraction: Double { finished ? 1 : (total > 0 ? min(Double(position) / Double(total), 1) : 0) }
}

struct ProcessInfoSnapshot: Equatable {
    var pid: Int32?
    var cpuPercent: Double = 0
    var memoryMB: Double = 0
    var elapsedSec: Double = 0
    var isStopped = false
}

enum LogParser {
    private static let header = try! NSRegularExpression(pattern: #"Backfill de voz \[([^\]]+)\]: (\d+) faixas"#)
    private static let ok = try! NSRegularExpression(
        pattern: #"^\[(\S+)[^\]]* (\d+)/(\d+)\] voz ok \| srv:(\w+) \| ([\d.]+) faixas/min \| (.+)$"#
    )
    private static let err = try! NSRegularExpression(pattern: #"^\[[^\]]* (\d+)/(\d+)\] ERRO (.+)$"#)
    private static let done = try! NSRegularExpression(pattern: #"concluído: \d+ faixas em ([\d.]+) min"#)

    static func parse(_ text: String) -> MonitorSnapshot {
        var s = MonitorSnapshot()
        var recent: [TrackEvent] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            let range = NSRange(line.startIndex..., in: line)
            if let m = header.firstMatch(in: line, range: range) {
                s.device = String(line[Range(m.range(at: 1), in: line)!])
                s.total = Int(line[Range(m.range(at: 2), in: line)!]) ?? 0
            } else if let m = ok.firstMatch(in: line, range: range) {
                s.position = Int(line[Range(m.range(at: 2), in: line)!]) ?? s.position
                s.total = Int(line[Range(m.range(at: 3), in: line)!]) ?? s.total
                let srvOK = line[Range(m.range(at: 4), in: line)!] == "ok"
                if !srvOK { s.serverFailures += 1 }
                s.logRatePerMin = Double(line[Range(m.range(at: 5), in: line)!]) ?? s.logRatePerMin
                s.completed += 1
                let path = String(line[Range(m.range(at: 6), in: line)!])
                let title = (path as NSString).lastPathComponent
                recent.append(TrackEvent(id: s.position, title: (title as NSString).deletingPathExtension, serverOK: srvOK))
            } else if let m = err.firstMatch(in: line, range: range) {
                s.position = Int(line[Range(m.range(at: 1), in: line)!]) ?? s.position
                s.errors += 1
                s.lastError = String(line[Range(m.range(at: 3), in: line)!])
            } else if line.contains("concluído") {
                s.finished = true
                if let m = done.firstMatch(in: line, range: range) {
                    s.totalMinutes = Double(line[Range(m.range(at: 1), in: line)!])
                }
            }
        }
        s.recent = Array(recent.suffix(6).reversed())
        return s
    }
}

enum ProcessProbe {
    /// PID do Python do backfill (ignora os wrappers `caffeinate` e `nice`).
    static func find() -> ProcessInfoSnapshot {
        // `comm` do ps vem truncado em 16 caracteres: o executável é identificado pelo 1º termo de `args`
        guard let out = run("/bin/ps", ["-axo", "pid=,stat=,%cpu=,rss=,etime=,args="]) else { return .init() }
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard cols.count == 6 else { continue }
            let args = String(cols[5])
            let executable = (args.split(separator: " ").first.map(String.init) ?? "").lowercased()
            guard args.contains("--vocals-backfill"), executable.hasSuffix("python") || executable.contains("python3") else { continue }
            var p = ProcessInfoSnapshot()
            p.pid = Int32(cols[0])
            p.isStopped = cols[1].hasPrefix("T")
            p.cpuPercent = Double(cols[2]) ?? 0
            p.memoryMB = (Double(cols[3]) ?? 0) / 1024
            p.elapsedSec = parseEtime(String(cols[4]))
            return p
        }
        return .init()
    }

    /// `ps etime` = [[dd-]hh:]mm:ss
    static func parseEtime(_ s: String) -> Double {
        var days = 0.0, rest = Substring(s)
        if let dash = s.firstIndex(of: "-") {
            days = Double(s[..<dash]) ?? 0
            rest = s[s.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").compactMap { Double($0) }
        let secs = parts.reversed().enumerated().reduce(0.0) { $0 + $1.element * pow(60, Double($1.offset)) }
        return days * 86400 + secs
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Estado observável

@MainActor
@Observable
final class MonitorModel {
    let logURL: URL
    var snapshot = MonitorSnapshot()
    var process = ProcessInfoSnapshot()
    var loadAverage: Double = 0
    /// Amostras (tempo, posição) para a velocidade dos últimos 10 minutos (mais estável que a média do log).
    private var samples: [(Date, Int)] = []
    private var timer: Timer?
    private var notifiedFinish = false

    init(logURL: URL) {
        self.logURL = logURL
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var isRunning: Bool { process.pid != nil }
    var isPaused: Bool { process.isStopped }

    /// Faixas/min na janela recente; cai para a média do log no começo.
    var ratePerMin: Double {
        guard let first = samples.first, let last = samples.last,
              last.0.timeIntervalSince(first.0) >= 90, last.1 > first.1 else { return snapshot.logRatePerMin }
        return Double(last.1 - first.1) / last.0.timeIntervalSince(first.0) * 60
    }

    var etaSeconds: Double? {
        let remaining = snapshot.total - snapshot.position
        guard !snapshot.finished, remaining > 0, ratePerMin > 0.01, !isPaused else { return nil }
        return Double(remaining) / ratePerMin * 60
    }

    var statusText: String {
        if snapshot.finished { return "Concluído" }
        if !isRunning { return "Parado" }
        return isPaused ? "Pausado" : "Processando"
    }

    var statusColor: Color {
        if snapshot.finished { return .green }
        if !isRunning { return .red }
        return isPaused ? .orange : .blue
    }

    func refresh() {
        if let text = try? String(contentsOf: logURL, encoding: .utf8) {
            snapshot = LogParser.parse(text)
        }
        process = ProcessProbe.find()
        var load = [0.0, 0.0, 0.0]
        getloadavg(&load, 3)
        loadAverage = load[0]

        let now = Date()
        if samples.last?.1 != snapshot.position || samples.isEmpty {
            samples.append((now, snapshot.position))
        }
        // Mantém só os últimos 10 min (sem ler `samples` de dentro de um closure que o modifica: isso abortava
        // o app por conflito de exclusividade assim que a primeira amostra passava de 10 min)
        while samples.count > 2, let first = samples.first, now.timeIntervalSince(first.0) > 600 {
            samples.removeFirst()
        }

        let dock = NSApplication.shared.dockTile
        dock.badgeLabel = snapshot.total > 0 ? "\(Int((snapshot.fraction * 100).rounded()))%" : nil

        if snapshot.finished && !notifiedFinish {
            notifiedFinish = true
            dock.badgeLabel = "✓"
            ProcessProbe.run("/usr/bin/osascript", ["-e",
                "display notification \"\(snapshot.completed) faixas com voz por compasso enviadas ao servidor.\" with title \"DMusic — análise de voz concluída\" sound name \"Glass\""])
        }
    }

    func togglePause() {
        guard let pid = process.pid else { return }
        kill(pid, isPaused ? SIGCONT : SIGSTOP)
        refresh()
    }

    func openLog() {
        NSWorkspace.shared.open(logURL)
    }
}

// MARK: - Interface

struct MonitorView: View {
    @State var model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            progressSection
            statsGrid
            currentSection
            footer
        }
        .padding(20)
        .frame(width: 460)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Análise de voz por compasso")
                    .font(.title3.weight(.semibold))
                Text("demucs · \(model.snapshot.device.uppercased())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(model.statusText, systemImage: "circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(model.statusColor)
                .labelStyle(StatusLabelStyle())
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressBar(fraction: model.snapshot.fraction, color: model.statusColor)
            HStack {
                Text(model.snapshot.finished
                     ? "\(model.snapshot.total) de \(model.snapshot.total) faixas (\(model.snapshot.completed) processadas agora)"
                     : "\(model.snapshot.position) de \(model.snapshot.total) faixas")
                Spacer()
                Text(model.snapshot.fraction, format: .percent.precision(.fractionLength(1)))
                    .monospacedDigit()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var statsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
            GridRow {
                stat("Tempo restante", etaText, detail: finishTimeText)
                stat("Velocidade", String(format: "%.1f faixas/min", model.ratePerMin))
            }
            GridRow {
                if let minutes = model.snapshot.totalMinutes, model.snapshot.finished {
                    stat("Duração total", format(seconds: minutes * 60))
                } else {
                    stat("Decorrido", format(seconds: model.process.elapsedSec))
                }
                stat("Erros", "\(model.snapshot.errors)",
                     detail: model.snapshot.serverFailures > 0 ? "\(model.snapshot.serverFailures) envios ao servidor falharam" : "servidor ok")
            }
            GridRow {
                stat("CPU do processo", String(format: "%.0f%%", model.process.cpuPercent),
                     detail: String(format: "%.1f GB de RAM", model.process.memoryMB / 1024))
                stat("Carga do Mac", String(format: "%.1f", model.loadAverage),
                     detail: "\(ProcessInfo.processInfo.activeProcessorCount) núcleos")
            }
        }
    }

    private var currentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Últimas concluídas")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if model.snapshot.recent.isEmpty {
                Text("Aguardando a primeira faixa…")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            ForEach(model.snapshot.recent) { track in
                HStack(spacing: 6) {
                    Image(systemName: track.serverOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(track.serverOK ? .green : .orange)
                    Text(track.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.callout)
            }
            if let err = model.snapshot.lastError {
                Text("Último erro: \(err)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(model.isPaused ? "Retomar" : "Pausar", systemImage: model.isPaused ? "play.fill" : "pause.fill") {
                model.togglePause()
            }
            .disabled(!model.isRunning)
            .help("Pausar libera CPU/GPU para outras tarefas; retomar continua de onde parou.")
            Button("Abrir log", systemImage: "doc.text") { model.openLog() }
            Spacer()
            Text("atualiza a cada 2 s")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func stat(_ title: String, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.medium))
                .monospacedDigit()
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minWidth: 180, alignment: .leading)
    }

    private var etaText: String {
        if model.snapshot.finished { return "—" }
        if model.isPaused { return "pausado" }
        guard let eta = model.etaSeconds else { return "calculando…" }
        return format(seconds: eta)
    }

    private var finishTimeText: String? {
        guard let eta = model.etaSeconds else { return nil }
        let end = Date().addingTimeInterval(eta)
        return "termina por volta de " + end.formatted(date: Calendar.current.isDateInToday(end) ? .omitted : .abbreviated, time: .shortened)
    }

    private func format(seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min \(s % 60) s"
    }
}

struct ProgressBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(geo.size.width * fraction, fraction > 0 ? 8 : 0))
                    .animation(.easeOut(duration: 0.4), value: fraction)
            }
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityLabel("Progresso")
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 7))
            configuration.title
        }
    }
}

// MARK: - App

@main
struct MixMonitorApp: App {
    private let logURL: URL = {
        let args = Array(CommandLine.arguments.dropFirst())
        let positional = args.enumerated().filter { i, a in !a.hasPrefix("-") && (i == 0 || args[i - 1] != "--snapshot") }
        return URL(fileURLWithPath: positional.first?.element ?? "/tmp/dmix/vocals_mps.log")
    }()

    init() {
        // `--snapshot saida.png`: renderiza a janela num PNG e sai (conferência sem permissão de gravação de tela)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let view = MonitorView(model: MonitorModel(logURL: logURL))
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let cg = renderer.cgImage,
               let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            exit(0)
        }
    }

    var body: some Scene {
        Window("DMusic Monitor", id: "monitor") {
            MonitorView(model: MonitorModel(logURL: logURL))
        }
        .windowResizability(.contentSize)
    }
}
