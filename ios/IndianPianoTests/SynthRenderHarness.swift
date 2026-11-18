import XCTest
@testable import IndianPiano

/// Offline renders for listening to and measuring the synth outside the app.
///
/// Skipped unless `SYNTH_RENDER_OUT` names an output folder (pass `TEST_RUNNER_SYNTH_RENDER_OUT=…` to
/// `xcodebuild test`). `SYNTH_RENDER_SCORE` adds a Listen-mode render of that score file, both hands
/// with the other hand on, at `SYNTH_RENDER_TEMPO` (default 0.7). Each render writes a float WAV and
/// a JSON file with the output peak and the render time of every audio block.
final class SynthRenderHarness: XCTestCase {
    private let sampleRate = 48_000.0
    /// The device's I/O buffer at the app's preferred 5 ms.
    private let blockFrames = 256
    private let base = 10.0

    private var outputFolder: URL? {
        ProcessInfo.processInfo.environment["SYNTH_RENDER_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func testRenderDenseChords() throws {
        guard let folder = outputFolder else { throw XCTSkip("Set SYNTH_RENDER_OUT to render") }
        var events: [(time: Double, on: Bool, midi: Int, velocity: Float)] = []
        func chord(_ notes: [Int], at time: Double, length: Double, velocity: Float = DemoSchedule.velocity) {
            for midi in notes {
                events.append((time, true, midi, velocity))
                events.append((time + length, false, midi, 0))
            }
        }
        // A 12-note two-hand chord held for two seconds.
        chord([36, 43, 48, 52, 55, 60, 64, 67, 72, 76, 79, 84], at: 0.2, length: 2)
        // Ten-note chords restruck every eighth note at 120 bpm, over a held bass octave.
        chord([29, 41], at: 2.6, length: 3.2)
        for index in 0..<12 {
            chord([53, 57, 60, 65, 69, 72, 77, 81], at: 2.6 + Double(index) * 0.25, length: 0.22)
        }
        // Fast two-hand arpeggios with long tails: more notes ring than there are voices.
        for index in 0..<64 {
            let midi = 40 + (index * 7) % 48
            events.append((6.2 + Double(index) * 0.045, true, midi, DemoSchedule.velocity))
            events.append((6.2 + Double(index) * 0.045 + 1.5, false, midi, 0))
        }
        try render(name: "dense-chords", seconds: 10.5, events: events, folder: folder)
    }

    func testRenderScore() async throws {
        guard let folder = outputFolder else { throw XCTSkip("Set SYNTH_RENDER_OUT to render") }
        guard let path = ProcessInfo.processInfo.environment["SYNTH_RENDER_SCORE"] else { throw XCTSkip("Set SYNTH_RENDER_SCORE to render a score") }
        let tempo = ProcessInfo.processInfo.environment["SYNTH_RENDER_TEMPO"].flatMap(Double.init) ?? 0.7
        let score = try await ScoreImportService.shared.importScore(at: URL(fileURLWithPath: path))
        let demo = DemoSchedule.events(notes: score.notes, hands: [.left, .right], accompaniment: true, tempoScale: tempo)
        let events = demo.map { (time: $0.time + 0.2, on: $0.kind == .noteOn, midi: $0.midi, velocity: $0.velocity) }
        try render(name: "score", seconds: (events.last?.time ?? 0) + 2.5, events: events, folder: folder)
    }

    /// Hands events to the core 0.15 s ahead from a 60 Hz tick, as Listen mode does, and renders in device-sized blocks.
    private func render(name: String, seconds: Double, events: [(time: Double, on: Bool, midi: Int, velocity: Float)], folder: URL) throws {
        let core = SynthCore(maxVoices: 32)
        core.setSampleRate(Float(sampleRate))
        let sorted = events.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
        var signal = [Float](repeating: 0, count: Int(seconds * sampleRate))
        var blockMicros: [Double] = []
        var cursor = 0
        var nextTick = 0.0
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        signal.withUnsafeMutableBufferPointer { buffer in
            var start = 0
            while start < buffer.count {
                let now = Double(start) / sampleRate
                while now >= nextTick {
                    while cursor < sorted.count, sorted[cursor].time <= nextTick + 0.15 {
                        let event = sorted[cursor]
                        core.enqueue(event.on ? .noteOn : .noteOff, midi: event.midi, velocity: event.velocity, at: base + event.time)
                        cursor += 1
                    }
                    nextTick += 1.0 / 60
                }
                let frames = min(blockFrames, buffer.count - start)
                let began = mach_absolute_time()
                core.render(into: buffer.baseAddress! + start, frames: frames, time: base + now)
                let ticks = mach_absolute_time() - began
                blockMicros.append(Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000)
                start += frames
            }
        }

        try writeWAV(signal, to: folder.appendingPathComponent("\(name).wav"))
        let sortedMicros = blockMicros.sorted()
        let budget = Double(blockFrames) / sampleRate * 1_000_000
        let noise = SynthSignalCheck.highBandNoise(signal, sampleRate: sampleRate)
        var stats: [String: Any] = [
            "name": name,
            "seconds": seconds,
            "events": events.count,
            "peak": Double(signal.map(abs).max() ?? 0),
            "samplesAtFullScale": signal.filter { abs($0) >= 0.99 }.count,
            "highBandShareDB": noise.shareDB,
            "loudestHighBandMillisecondDBFS": noise.loudestFrameDBFS,
            "noisyMilliseconds": noise.framesAbove(-60),
            "blockBudgetMicros": budget,
            "blockMicrosMean": blockMicros.reduce(0, +) / Double(max(1, blockMicros.count)),
            "blockMicrosP99": sortedMicros.isEmpty ? 0 : sortedMicros[Int(Double(sortedMicros.count - 1) * 0.99)],
            "blockMicrosMax": sortedMicros.last ?? 0,
            "blocksOverHalfBudget": blockMicros.filter { $0 > budget / 2 }.count,
            "blocks": blockMicros.count,
        ]
        stats.merge(extraStatistics(core)) { $1 }
        let json = try JSONSerialization.data(withJSONObject: stats, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: folder.appendingPathComponent("\(name).json"))
    }

    private func extraStatistics(_ core: SynthCore) -> [String: Any] {
        ["mostVoicesSounding": core.statistics.mostVoicesSounding,
         "voicesStolen": core.statistics.voicesStolen,
         "lowestLimiterGain": Double(core.statistics.lowestLimiterGain)]
    }

    private func writeWAV(_ samples: [Float], to url: URL) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 4)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(3)); append(UInt16(1)); append(UInt32(sampleRate)); append(UInt32(sampleRate) * 4)
        append(UInt16(4)); append(UInt16(32))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }
}
