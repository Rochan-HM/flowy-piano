import Accelerate
import Foundation

struct PitchEstimate: Equatable, Sendable {
    var frequency: Double
    /// 0...1, where 1 is a perfectly periodic signal (1 - YIN aperiodicity).
    var confidence: Double

    var midi: Double { MIDINote.midi(forFrequency: frequency) }
    var nearestMIDI: Int { Int(midi.rounded()) }
    /// Deviation from the nearest equal-tempered note, in cents.
    var cents: Double { (midi - midi.rounded()) * 100 }
}

/// Monophonic pitch detection with the YIN algorithm (de Cheveigné & Kawahara, 2002).
struct YINPitchDetector: Sendable {
    var sampleRate: Double
    var threshold: Double = 0.12
    var minFrequency: Double = 50
    var maxFrequency: Double = 4200
    /// Frames quieter than this RMS are treated as silence.
    var silenceRMS: Float = 0.002

    func detect(_ samples: [Float]) -> PitchEstimate? {
        samples.withUnsafeBufferPointer { detect($0) }
    }

    func detect(_ samples: UnsafeBufferPointer<Float>) -> PitchEstimate? {
        let count = samples.count
        guard count >= 64, let base = samples.baseAddress else { return nil }

        var meanSquare: Float = 0
        vDSP_measqv(base, 1, &meanSquare, vDSP_Length(count))
        guard sqrt(meanSquare) >= silenceRMS else { return nil }

        let window = count / 2
        let tauMax = min(window - 1, Int(sampleRate / minFrequency))
        let tauMin = max(2, Int(sampleRate / maxFrequency))
        guard tauMax > tauMin + 2 else { return nil }

        // Difference function d(tau) = e(0) + e(tau) - 2 r(tau), with energies over `window` samples.
        var difference = [Double](repeating: 0, count: tauMax + 1)
        var energyAt0: Float = 0
        vDSP_svesq(base, 1, &energyAt0, vDSP_Length(window))
        var energyAtTau = Double(energyAt0)
        for tau in 1...tauMax {
            let leaving = Double(base[tau - 1])
            let entering = Double(base[tau + window - 1])
            energyAtTau += entering * entering - leaving * leaving
            var correlation: Float = 0
            vDSP_dotpr(base, 1, base + tau, 1, &correlation, vDSP_Length(window))
            difference[tau] = max(0, Double(energyAt0) + energyAtTau - 2 * Double(correlation))
        }

        // Cumulative mean normalized difference.
        var normalized = [Double](repeating: 1, count: tauMax + 1)
        var runningSum = 0.0
        for tau in 1...tauMax {
            runningSum += difference[tau]
            normalized[tau] = runningSum > 0 ? difference[tau] * Double(tau) / runningSum : 1
        }

        var chosen: Int?
        var tau = tauMin
        while tau <= tauMax {
            if normalized[tau] < threshold {
                while tau + 1 <= tauMax && normalized[tau + 1] < normalized[tau] { tau += 1 }
                chosen = tau
                break
            }
            tau += 1
        }
        if chosen == nil {
            let range = tauMin...tauMax
            if let best = range.min(by: { normalized[$0] < normalized[$1] }), normalized[best] < 0.3 {
                chosen = best
            }
        }
        guard let best = chosen else { return nil }

        var refined = Double(best)
        if best > 1 && best < tauMax {
            let left = normalized[best - 1], center = normalized[best], right = normalized[best + 1]
            let denominator = left - 2 * center + right
            if abs(denominator) > 1e-12 { refined += 0.5 * (left - right) / denominator }
        }
        let frequency = sampleRate / refined
        guard frequency >= minFrequency, frequency <= maxFrequency else { return nil }
        return PitchEstimate(frequency: frequency, confidence: max(0, min(1, 1 - normalized[best])))
    }
}
