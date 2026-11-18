import AVFoundation
import Foundation
import os

/// Captures microphone audio and runs `MicAnalyzer` on a background queue.
///
/// `start()` and `stop()` can block for a long time inside CoreAudio (for example on the Simulator
/// while macOS decides whether it may use the Mac's microphone), so call them off the main thread.
final class MicListener: @unchecked Sendable {
    static let log = Logger(subsystem: "com.rochan.indianpiano", category: "mic")

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.rochan.indianpiano.mic-analysis", qos: .userInteractive)
    private var analyzer: MicAnalyzer?
    private let hopSize = 1024

    private(set) var isRunning = false
    var gateRMS: Float = 0.01 {
        didSet { let gate = gateRMS; queue.async { self.analyzer?.gateRMS = gate } }
    }

    /// Called on the main queue for every analysed frame.
    var onFrame: (@MainActor (MicFrameResult) -> Void)?

    func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "MicListener", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."])
        }
        let sampleRate = format.sampleRate
        let gate = gateRMS
        queue.sync { analyzer = MicAnalyzer(sampleRate: sampleRate, hopSize: hopSize, gateRMS: gate) }

        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(hopSize), format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            self.queue.async { self.ingest(samples) }
        }
        // Keep the input node pulled without sending the microphone to the speaker.
        engine.mainMixerNode.outputVolume = 0
        engine.connect(input, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        isRunning = true
        Self.log.info("Microphone started at \(sampleRate, privacy: .public) Hz")
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        queue.async { self.analyzer?.reset() }
        Self.log.info("Microphone stopped")
    }

    func suppress(for seconds: TimeInterval) {
        queue.async { self.analyzer?.suppress(seconds: seconds) }
    }

    private func ingest(_ samples: [Float]) {
        guard let analyzer else { return }
        for result in analyzer.process(samples) {
            if let onset = result.noteOnset, let estimate = result.estimate {
                Self.log.info("Detected note \(onset, privacy: .public) (\(String(format: "%.1f", estimate.frequency), privacy: .public) Hz, confidence \(String(format: "%.2f", estimate.confidence), privacy: .public), rms \(String(format: "%.3f", result.rms), privacy: .public))")
            }
            publish(result)
        }
    }

    private func publish(_ result: MicFrameResult) {
        guard let onFrame else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { onFrame(result) } }
    }
}
