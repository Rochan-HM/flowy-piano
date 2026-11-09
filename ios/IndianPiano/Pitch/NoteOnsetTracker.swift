import Foundation

/// Turns a stream of per-frame pitch estimates into discrete note events.
///
/// A note is reported once its pitch has been stable for `stableFrames` frames. The same pitch is
/// reported again only after silence or a fresh attack (a sudden jump in loudness), so a decaying
/// piano note isn't counted twice while repeated notes still are.
struct NoteOnsetTracker {
    var gateRMS: Float = 0.01
    var attackRatio: Float = 1.8
    var stableFrames = 2
    var minimumConfidence = 0.8

    private var candidate: Int?
    private var candidateCount = 0
    private var reported: Int?
    private var previousRMS: Float = 0

    init(gateRMS: Float = 0.01) {
        self.gateRMS = gateRMS
    }

    /// Returns true when this frame looks like a new key strike.
    private(set) var lastFrameWasAttack = false

    mutating func process(_ estimate: PitchEstimate?, rms: Float) -> Int? {
        defer { previousRMS = rms }
        lastFrameWasAttack = false

        if rms < gateRMS * 0.6 {
            reset()
            return nil
        }
        if rms > gateRMS && rms > previousRMS * attackRatio {
            lastFrameWasAttack = true
            reported = nil
            candidate = nil
            candidateCount = 0
        }
        guard rms >= gateRMS, let estimate, estimate.confidence >= minimumConfidence else {
            candidate = nil
            candidateCount = 0
            return nil
        }

        let note = estimate.nearestMIDI
        if note == candidate {
            candidateCount += 1
        } else {
            candidate = note
            candidateCount = 1
        }
        guard candidateCount >= stableFrames, note != reported else { return nil }
        reported = note
        return note
    }

    mutating func reset() {
        candidate = nil
        candidateCount = 0
        reported = nil
    }
}
