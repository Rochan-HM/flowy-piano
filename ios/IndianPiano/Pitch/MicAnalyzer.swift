import Accelerate
import Foundation

struct MicFrameResult: Sendable {
    var rms: Float
    var estimate: PitchEstimate?
    /// Set when the onset tracker decides a new note was played.
    var noteOnset: Int?
    /// Pitch-class profile; computed every other frame and on key strikes.
    var chroma: [Float]?
    var isAttack: Bool
}

/// The microphone analysis pipeline without any audio I/O: buffers incoming samples and, every
/// hop, runs YIN pitch detection, onset tracking and (for chords) chroma analysis.
final class MicAnalyzer {
    let sampleRate: Double
    let frameSize: Int
    let hopSize: Int
    let chromaSize: Int
    var gateRMS: Float {
        didSet { tracker.gateRMS = gateRMS }
    }

    private let detector: YINPitchDetector
    private let chromaAnalyzer: ChromaAnalyzer
    private var tracker: NoteOnsetTracker
    private var history: [Float] = []
    private var pendingSinceLastHop = 0
    private var frameCounter = 0
    private var suppressedFrames = 0

    init(sampleRate: Double, frameSize: Int = 2048, hopSize: Int = 1024, chromaSize: Int = 8192, gateRMS: Float = 0.01) {
        self.sampleRate = sampleRate
        self.frameSize = frameSize
        self.hopSize = hopSize
        self.chromaSize = chromaSize
        self.gateRMS = gateRMS
        detector = YINPitchDetector(sampleRate: sampleRate)
        chromaAnalyzer = ChromaAnalyzer(sampleRate: sampleRate, size: chromaSize)
        tracker = NoteOnsetTracker(gateRMS: gateRMS)
    }

    /// Ignore input for a while (e.g. while the app's own synth is sounding).
    func suppress(seconds: TimeInterval) {
        suppressedFrames = max(suppressedFrames, Int(seconds * sampleRate / Double(hopSize)))
    }

    func reset() {
        history = []
        pendingSinceLastHop = 0
        tracker.reset()
    }

    /// Appends samples and returns one result per completed hop.
    func process(_ samples: [Float]) -> [MicFrameResult] {
        history.append(contentsOf: samples)
        if history.count > chromaSize * 2 { history.removeFirst(history.count - chromaSize) }
        pendingSinceLastHop += samples.count
        var results: [MicFrameResult] = []
        while pendingSinceLastHop >= hopSize {
            pendingSinceLastHop -= hopSize
            if let result = analyzeFrame(endingAt: history.count - pendingSinceLastHop) { results.append(result) }
        }
        return results
    }

    private func analyzeFrame(endingAt end: Int) -> MicFrameResult? {
        guard end >= frameSize else { return nil }
        let frame = Array(history[(end - frameSize)..<end])
        var meanSquare: Float = 0
        frame.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress!, 1, &meanSquare, vDSP_Length(frameSize)) }
        let rms = sqrt(meanSquare)

        if suppressedFrames > 0 {
            suppressedFrames -= 1
            tracker.reset()
            return MicFrameResult(rms: rms, estimate: nil, noteOnset: nil, chroma: nil, isAttack: false)
        }

        let estimate = rms >= gateRMS * 0.6 ? detector.detect(frame) : nil
        let onset = tracker.process(estimate, rms: rms)
        frameCounter += 1

        var chroma: [Float]?
        if rms >= gateRMS, frameCounter % 2 == 0 || tracker.lastFrameWasAttack, end >= chromaSize / 2 {
            chroma = chromaAnalyzer.chroma(of: Array(history[max(0, end - chromaSize)..<end]))
        }
        return MicFrameResult(rms: rms, estimate: estimate, noteOnset: onset, chroma: chroma, isAttack: tracker.lastFrameWasAttack)
    }
}
