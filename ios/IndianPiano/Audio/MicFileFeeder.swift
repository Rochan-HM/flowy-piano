import AVFoundation
import Foundation

/// Streams an audio file through the microphone analysis in real time, exactly as if the
/// microphone had heard it. Used for automated end-to-end lessons with recorded piano audio.
final class MicFileFeeder: @unchecked Sendable {
    private var task: Task<Void, Never>?

    func start(url: URL, onFrame: @escaping @MainActor (MicFrameResult) -> Void, onFinish: @escaping @MainActor () -> Void) throws {
        stop()
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "MicFileFeeder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't allocate an audio buffer."])
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else {
            throw NSError(domain: "MicFileFeeder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format."])
        }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: frameCount)
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for index in 0..<frameCount { mono[index] += samples[index] / Float(channelCount) }
        }
        let sampleRate = format.sampleRate
        MicListener.log.info("Feeding \(url.lastPathComponent, privacy: .public) (\(String(format: "%.1f", Double(frameCount) / sampleRate), privacy: .public) s) into the microphone pipeline")

        task = Task.detached(priority: .userInitiated) {
            let analyzer = MicAnalyzer(sampleRate: sampleRate)
            let chunk = 1024
            let start = ProcessInfo.processInfo.systemUptime
            var offset = 0
            while offset < frameCount, !Task.isCancelled {
                let end = min(frameCount, offset + chunk)
                for result in analyzer.process(Array(mono[offset..<end])) {
                    if let onset = result.noteOnset, let estimate = result.estimate {
                        MicListener.log.info("Detected note \(onset, privacy: .public) (\(String(format: "%.1f", estimate.frequency), privacy: .public) Hz, confidence \(String(format: "%.2f", estimate.confidence), privacy: .public), rms \(String(format: "%.3f", result.rms), privacy: .public)) [file]")
                    }
                    await onFrame(result)
                }
                offset = end
                let wait = start + Double(offset) / sampleRate - ProcessInfo.processInfo.systemUptime
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }
            await onFinish()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
