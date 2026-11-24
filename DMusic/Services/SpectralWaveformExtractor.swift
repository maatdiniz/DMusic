import Foundation
import AVFoundation
import Accelerate

/// Coluna espectral RGB estilo Rekordbox (3 bytes por fatia de 20 ms = 50 colunas/segundo).
nonisolated struct SpectralColumn: Sendable {
    let low: UInt8   // 20–250 Hz (Graves / Bumbos)
    let mid: UInt8   // 250–2500 Hz (Médios / Vocais)
    let high: UInt8  // 2500–16000 Hz (Agudos / Hi-hats)
}

/// Dados pré-processados de uma faixa para renderização a 60 FPS no Espectrograma estilo Rekordbox.
nonisolated struct TrackSpectralData: Sendable {
    let songId: String
    let duration: Double
    let columnsPerSecond: Double
    let columns: [SpectralColumn]
    let beats: [Double]      // Timestamps (s) de cada batida
    let downbeats: [Double]  // Timestamps (s) do Beat 1 de cada compasso
}

/// Extrai e cacheia em disco (`Caches/waveforms/<songId>.wf`) o espectrograma RGB de 3 bandas
/// e a grade de batidas (beats/downbeats) usando Accelerate (`vDSP` FFT) fora da Main Thread.
actor SpectralWaveformExtractor {
    static let shared = SpectralWaveformExtractor()
    static let columnsPerSecond: Double = 50.0 // 20 ms por coluna

    private var memoryCache: [String: TrackSpectralData] = [:]
    private var inFlight: [String: Task<TrackSpectralData?, Never>] = [:]
    private let cacheDir: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("waveforms", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheDir = dir
    }

    func cached(songId: String) -> TrackSpectralData? {
        memoryCache[songId]
    }

    func loadOrExtract(songId: String, fileURL: URL, bpmHint: Double) async -> TrackSpectralData? {
        if let hit = memoryCache[songId] { return hit }
        if let task = inFlight[songId] { return await task.value }

        let diskURL = cacheDir.appendingPathComponent("\(safeFilename(songId)).wf")
        let task = Task.detached(priority: .utility) { () -> TrackSpectralData? in
            if let fromDisk = Self.readFromDisk(url: diskURL, songId: songId) {
                return fromDisk
            }
            guard let extracted = Self.extract(songId: songId, fileURL: fileURL, bpmHint: bpmHint) else {
                return nil
            }
            Self.writeToDisk(extracted, to: diskURL)
            return extracted
        }
        inFlight[songId] = task
        let result = await task.value
        inFlight[songId] = nil
        if let result {
            // Mantém no máximo 16 faixas em RAM (~500 KB total)
            if memoryCache.count >= 16, let firstKey = memoryCache.keys.first {
                memoryCache.removeValue(forKey: firstKey)
            }
            memoryCache[songId] = result
        }
        return result
    }

    private func safeFilename(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    // MARK: - Extração FFT 3 Bandas (vDSP) + Beatgrid

    nonisolated private static func extract(songId: String, fileURL: URL, bpmHint: Double) -> TrackSpectralData? {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
        let sr = file.processingFormat.sampleRate
        let totalFrames = file.length
        guard sr >= 8_000, totalFrames > 2_048 else { return nil }
        let duration = Double(totalFrames) / sr

        let hopFrames = max(64, Int(round(sr / columnsPerSecond)))
        let fftSize = 1024
        let halfN = fftSize / 2
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Índices de bins para 3 bandas Rekordbox: Low (20–250 Hz), Mid (250–2500 Hz), High (2500–16000 Hz)
        let binHz = sr / Double(fftSize)
        let lowStart = max(1, Int(floor(20.0 / binHz)))
        let lowEnd = min(halfN - 1, max(lowStart + 1, Int(round(250.0 / binHz))))
        let midEnd = min(halfN - 1, max(lowEnd + 1, Int(round(2500.0 / binHz))))
        let highEnd = min(halfN - 1, max(midEnd + 1, Int(round(16000.0 / binHz))))

        let readChunkFrames = AVAudioFrameCount(max(Int(sr * 4.0), fftSize * 4))
        guard let pcmBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: readChunkFrames) else {
            return nil
        }

        let estimatedCols = Int(ceil(duration * columnsPerSecond)) + 8
        var rawLow: [Float] = []
        var rawMid: [Float] = []
        var rawHigh: [Float] = []
        rawLow.reserveCapacity(estimatedCols)
        rawMid.reserveCapacity(estimatedCols)
        rawHigh.reserveCapacity(estimatedCols)

        var ring = [Float]()
        ring.reserveCapacity(Int(readChunkFrames) + fftSize)
        var monoChunk = [Float](repeating: 0, count: Int(readChunkFrames))
        var windowed = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: halfN)
        var imag = [Float](repeating: 0, count: halfN)
        var mags = [Float](repeating: 0, count: halfN)

        file.framePosition = 0
        while file.framePosition < totalFrames {
            pcmBuf.frameLength = 0
            do {
                try file.read(into: pcmBuf, frameCount: readChunkFrames)
            } catch {
                break
            }
            let n = Int(pcmBuf.frameLength)
            guard n > 0, let chData = pcmBuf.floatChannelData else { break }
            let chCount = Int(pcmBuf.format.channelCount)

            if chCount == 1 {
                memcpy(&monoChunk, chData[0], n * MemoryLayout<Float>.size)
            } else {
                memset(&monoChunk, 0, n * MemoryLayout<Float>.size)
                var scale: Float = 1.0 / Float(chCount)
                for c in 0..<chCount {
                    vDSP_vsma(chData[c], 1, &scale, monoChunk, 1, &monoChunk, 1, vDSP_Length(n))
                }
            }
            ring.append(contentsOf: monoChunk[0..<n])

            var offset = 0
            while offset + fftSize <= ring.count {
                ring.withUnsafeBufferPointer { rPtr in
                    vDSP_vmul(rPtr.baseAddress! + offset, 1, hann, 1, &windowed, 1, vDSP_Length(fftSize))
                }
                real.withUnsafeMutableBufferPointer { rePtr in
                    imag.withUnsafeMutableBufferPointer { imPtr in
                        var split = DSPSplitComplex(realp: rePtr.baseAddress!, imagp: imPtr.baseAddress!)
                        windowed.withUnsafeBytes { raw in
                            let cptr = raw.bindMemory(to: DSPComplex.self).baseAddress!
                            vDSP_ctoz(cptr, 2, &split, 1, vDSP_Length(halfN))
                        }
                        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(halfN))
                    }
                }

                var lSum: Float = 0
                var mSum: Float = 0
                var hSum: Float = 0
                mags.withUnsafeBufferPointer { mPtr in
                    let base = mPtr.baseAddress!
                    vDSP_sve(base + lowStart, 1, &lSum, vDSP_Length(max(1, lowEnd - lowStart)))
                    vDSP_sve(base + lowEnd, 1, &mSum, vDSP_Length(max(1, midEnd - lowEnd)))
                    vDSP_sve(base + midEnd, 1, &hSum, vDSP_Length(max(1, highEnd - midEnd)))
                }

                rawLow.append(sqrt(max(lSum, 0) / Float(max(1, lowEnd - lowStart))))
                rawMid.append(sqrt(max(mSum, 0) / Float(max(1, midEnd - lowEnd))))
                rawHigh.append(sqrt(max(hSum, 0) / Float(max(1, highEnd - midEnd))))
                offset += hopFrames
            }
            if offset > 0 {
                ring.removeFirst(offset)
            }
        }

        let colCount = rawLow.count
        guard colCount > 10 else { return nil }

        // Normalização por percentil 98% (evita que 1 pico isolado esmague toda a onda visual)
        func normScale(_ arr: [Float]) -> Float {
            let sorted = arr.sorted()
            let p98 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.98))]
            return p98 > 1e-6 ? (1.0 / p98) : 1.0
        }
        let sL = normScale(rawLow)
        let sM = normScale(rawMid)
        let sH = normScale(rawHigh)

        var columns: [SpectralColumn] = []
        columns.reserveCapacity(colCount)
        for i in 0..<colCount {
            // Curva gamma 0.72 dá leitura punchy estilo Rekordbox
            let l = UInt8(min(255, max(0, Int(pow(min(rawLow[i] * sL, 1.0), 0.72) * 255.0))))
            let m = UInt8(min(255, max(0, Int(pow(min(rawMid[i] * sM, 1.0), 0.75) * 255.0))))
            let h = UInt8(min(255, max(0, Int(pow(min(rawHigh[i] * sH, 1.0), 0.75) * 255.0))))
            columns.append(SpectralColumn(low: l, mid: m, high: h))
        }

        // Constroi grade de batidas (beats & downbeats) travada nos picos reais de grave (`rawLow`)
        let (beats, downbeats) = buildBeatgrid(rawLow: rawLow, duration: duration, bpmHint: bpmHint)

        return TrackSpectralData(
            songId: songId,
            duration: duration,
            columnsPerSecond: columnsPerSecond,
            columns: columns,
            beats: beats,
            downbeats: downbeats
        )
    }

    /// Constrói a grade de batidas alinhando a fase do BPM real aos picos de fluxo de grave (`rawLow`).
    nonisolated private static func buildBeatgrid(rawLow: [Float], duration: Double, bpmHint: Double) -> ([Double], [Double]) {
        let bpm = (bpmHint >= 60.0 && bpmHint <= 210.0) ? bpmHint : 124.0
        let beatSec = 60.0 / bpm
        let n = rawLow.count
        guard n > 50, duration > 2.0 else { return ([], []) }

        // Fluxo positivo de graves (ataques de bumbo)
        var flux = [Float](repeating: 0, count: n)
        for i in 1..<n {
            flux[i] = max(0, rawLow[i] - rawLow[i - 1])
        }

        // Busca a melhor fase inicial `phase in [0, beatSec)` que maximiza a soma do fluxo de bumbos na grade
        let phaseSteps = 60
        var bestPhase = 0.0
        var bestPhaseScore = -1.0
        for p in 0..<phaseSteps {
            let phase = (Double(p) / Double(phaseSteps)) * beatSec
            var score = 0.0
            var t = phase
            while t < duration {
                let idx = Int(round(t * columnsPerSecond))
                if idx >= 0 && idx < n {
                    score += Double(flux[idx])
                }
                t += beatSec
            }
            if score > bestPhaseScore {
                bestPhaseScore = score
                bestPhase = phase
            }
        }

        var beats: [Double] = []
        beats.reserveCapacity(Int(duration / beatSec) + 2)
        var t = bestPhase
        while t < duration {
            beats.append(t)
            t += beatSec
        }

        // Escolhe qual dos 4 beats do compasso (0..3) tem maior energia média para marcar os downbeats
        var bestBarOffset = 0
        var bestBarEnergy = -1.0
        for off in 0..<4 {
            var sum = 0.0
            var cnt = 0
            var i = off
            while i < beats.count {
                let idx = Int(round(beats[i] * columnsPerSecond))
                if idx >= 0 && idx < n {
                    sum += Double(rawLow[idx]) + Double(flux[idx]) * 1.5
                    cnt += 1
                }
                i += 4
            }
            let avg = cnt > 0 ? sum / Double(cnt) : 0
            if avg > bestBarEnergy {
                bestBarEnergy = avg
                bestBarOffset = off
            }
        }

        var downbeats: [Double] = []
        var i = bestBarOffset
        while i < beats.count {
            downbeats.append(beats[i])
            i += 4
        }
        return (beats, downbeats)
    }

    // MARK: - Cache Binário Compacto em Disco (.wf)

    nonisolated private static let fileMagic: UInt32 = 0x444D5746 // "DMWF"

    nonisolated private static func writeToDisk(_ data: TrackSpectralData, to url: URL) {
        var out = Data()
        var magic = fileMagic
        var dur = data.duration
        var cps = data.columnsPerSecond
        var colCount = UInt32(data.columns.count)
        var beatCount = UInt32(data.beats.count)
        var dbCount = UInt32(data.downbeats.count)

        out.append(Data(bytes: &magic, count: 4))
        out.append(Data(bytes: &dur, count: 8))
        out.append(Data(bytes: &cps, count: 8))
        out.append(Data(bytes: &colCount, count: 4))
        out.append(Data(bytes: &beatCount, count: 4))
        out.append(Data(bytes: &dbCount, count: 4))

        out.reserveCapacity(out.count + data.columns.count * 3 + (data.beats.count + data.downbeats.count) * 4)
        for c in data.columns {
            out.append(c.low)
            out.append(c.mid)
            out.append(c.high)
        }
        for b in data.beats {
            var f = Float(b)
            out.append(Data(bytes: &f, count: 4))
        }
        for d in data.downbeats {
            var f = Float(d)
            out.append(Data(bytes: &f, count: 4))
        }
        try? out.write(to: url, options: .atomic)
    }

    nonisolated private static func readFromDisk(url: URL, songId: String) -> TrackSpectralData? {
        guard let raw = try? Data(contentsOf: url), raw.count >= 32 else { return nil }
        return raw.withUnsafeBytes { ptr -> TrackSpectralData? in
            guard let base = ptr.baseAddress else { return nil }
            let magic = base.load(fromByteOffset: 0, as: UInt32.self)
            guard magic == fileMagic else { return nil }
            let dur = base.loadUnaligned(fromByteOffset: 4, as: Double.self)
            let cps = base.loadUnaligned(fromByteOffset: 12, as: Double.self)
            let colCount = Int(base.loadUnaligned(fromByteOffset: 20, as: UInt32.self))
            let beatCount = Int(base.loadUnaligned(fromByteOffset: 24, as: UInt32.self))
            let dbCount = Int(base.loadUnaligned(fromByteOffset: 28, as: UInt32.self))

            let expected = 32 + colCount * 3 + (beatCount + dbCount) * 4
            guard raw.count == expected, colCount > 0 else { return nil }

            var columns: [SpectralColumn] = []
            columns.reserveCapacity(colCount)
            var off = 32
            for _ in 0..<colCount {
                let l = base.load(fromByteOffset: off, as: UInt8.self)
                let m = base.load(fromByteOffset: off + 1, as: UInt8.self)
                let h = base.load(fromByteOffset: off + 2, as: UInt8.self)
                columns.append(SpectralColumn(low: l, mid: m, high: h))
                off += 3
            }

            var beats: [Double] = []
            beats.reserveCapacity(beatCount)
            for _ in 0..<beatCount {
                let f = base.loadUnaligned(fromByteOffset: off, as: Float.self)
                beats.append(Double(f))
                off += 4
            }

            var downbeats: [Double] = []
            downbeats.reserveCapacity(dbCount)
            for _ in 0..<dbCount {
                let f = base.loadUnaligned(fromByteOffset: off, as: Float.self)
                downbeats.append(Double(f))
                off += 4
            }

            return TrackSpectralData(
                songId: songId,
                duration: dur,
                columnsPerSecond: cps,
                columns: columns,
                beats: beats,
                downbeats: downbeats
            )
        }
    }
}
