import Foundation

/// Turns a stream of per-frame pitch estimates into discrete note events.
///
/// A note is reported once its pitch has been stable for `stableFrames` frames. The same pitch is
/// reported again only after silence or a fresh attack (a sudden jump in loudness), so a decaying
/// piano note isn't counted twice while repeated notes still are.
struct NoteOnsetTracker {
    var gateRMS: Float = 0.01
    var attackRatio: Float = 1.6
    var stableFrames = 2
    var minimumConfidence = 0.8

    private var candidate: Int?
    private var candidateCount = 0
    private var reported: Int?
    private var recentRMS: [Float] = []

    init(gateRMS: Float = 0.01) {
        self.gateRMS = gateRMS
    }

    /// Returns true when this frame looks like a new key strike.
    private(set) var lastFrameWasAttack = false
    /// Increments on every key strike, so readings can be tied to the strike that caused them.
    private(set) var attackCount = 0
    private(set) var framesSinceAttack = 1_000

    mutating func process(_ estimate: PitchEstimate?, rms: Float) -> Int? {
        defer {
            recentRMS.append(rms)
            if recentRMS.count > 3 { recentRMS.removeFirst() }
        }
        lastFrameWasAttack = false
        framesSinceAttack += 1

        if rms < gateRMS * 0.6 {
            reset()
            return nil
        }
        // Over notes that are still ringing, a strike's loudness rises across two or three frames,
        // so compare with the quietest recent frame; the refractory period stops one strike counting twice.
        let quietestRecent = recentRMS.min() ?? 0
        let stillRising = rms > (recentRMS.last ?? 0) * 1.1
        if rms > gateRMS && rms > quietestRecent * attackRatio && stillRising && framesSinceAttack >= 3 {
            lastFrameWasAttack = true
            attackCount += 1
            framesSinceAttack = 0
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
