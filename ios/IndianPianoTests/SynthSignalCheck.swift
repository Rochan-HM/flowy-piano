import Foundation

/// Measures what the ear hears as static or crackle in synth output: energy far above every partial
/// the synth plays. Clean notes (up to the 7th harmonic of C6, about 7.3 kHz) leave the band above
/// 12 kHz nearly empty; clipping, saturation and clicks from voices cut off mid-wave fill it.
enum SynthSignalCheck {
    struct HighBandNoise {
        /// High-band energy relative to the whole signal's.
        var shareDB: Double
        /// RMS of the high band in each 1 ms frame, in dB full scale.
        var frameDBFS: [Double]

        var loudestFrameDBFS: Double { frameDBFS.max() ?? -200 }
        func framesAbove(_ dbfs: Double) -> Int { frameDBFS.filter { $0 > dbfs }.count }
    }

    static func highBandNoise(_ signal: [Float], sampleRate: Double, cutoff: Double = 12_000) -> HighBandNoise {
        // Fourth-order Butterworth high-pass: two biquads.
        var sections = [Section(cutoff: cutoff, q: 0.541_196, sampleRate: sampleRate),
                        Section(cutoff: cutoff, q: 1.306_563, sampleRate: sampleRate)]
        let frameLength = max(1, Int(sampleRate / 1_000))
        var frames: [Double] = []
        var total = 0.0, high = 0.0, frameEnergy = 0.0
        for (index, sample) in signal.enumerated() {
            var value = Double(sample)
            total += value * value
            for section in sections.indices { value = sections[section].process(value) }
            high += value * value
            frameEnergy += value * value
            if (index + 1) % frameLength == 0 {
                frames.append(10 * log10(max(frameEnergy / Double(frameLength), 1e-20)))
                frameEnergy = 0
            }
        }
        return HighBandNoise(shareDB: 10 * log10(max(high, 1e-20) / max(total, 1e-20)), frameDBFS: frames)
    }

    private struct Section {
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        init(cutoff: Double, q: Double, sampleRate: Double) {
            let w0 = 2 * Double.pi * cutoff / sampleRate
            let alpha = sin(w0) / (2 * q)
            let a0 = 1 + alpha
            let c = cos(w0)
            b0 = (1 + c) / 2 / a0
            b1 = -(1 + c) / a0
            b2 = b0
            a1 = -2 * c / a0
            a2 = (1 - alpha) / a0
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }
}
