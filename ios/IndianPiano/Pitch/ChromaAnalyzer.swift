import Accelerate
import Foundation

/// 12-bin pitch-class profile (chroma) from an FFT, used to recognise chords played with both hands.
final class ChromaAnalyzer {
    let sampleRate: Double
    let size: Int
    private let log2n: vDSP_Length
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private let lowestBin: Int
    private let highestBin: Int

    init(sampleRate: Double, size: Int = 8192, minFrequency: Double = 60, maxFrequency: Double = 2500) {
        precondition(size > 0 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.sampleRate = sampleRate
        self.size = size
        log2n = vDSP_Length(log2(Double(size)))
        fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        let binWidth = sampleRate / Double(size)
        lowestBin = max(2, Int(minFrequency / binWidth))
        highestBin = min(size / 2 - 2, Int(maxFrequency / binWidth))
    }

    /// Returns 12 values normalised so the strongest pitch class is 1 (all zeros for silence).
    /// Uses the most recent `size` samples; shorter input is zero-padded. Each spectral peak is
    /// assigned to the pitch class of its interpolated frequency, so window leakage around low
    /// notes doesn't bleed into neighbouring semitones.
    func chroma(of samples: [Float]) -> [Float] {
        chroma(fromSpectrum: spectrum(of: samples))
    }

    /// Hann-windowed FFT magnitudes (`size / 2` bins) of the most recent `size` samples.
    func spectrum(of samples: [Float]) -> [Float] {
        var frame = [Float](repeating: 0, count: size)
        let take = min(samples.count, size)
        if take > 0 {
            frame.replaceSubrange((size - take)..<size, with: samples[(samples.count - take)...])
        }
        vDSP.multiply(frame, window, result: &frame)

        let half = size / 2
        var inputReal = [Float](repeating: 0, count: half)
        var inputImag = [Float](repeating: 0, count: half)
        var outputReal = [Float](repeating: 0, count: half)
        var outputImag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        inputReal.withUnsafeMutableBufferPointer { inReal in
            inputImag.withUnsafeMutableBufferPointer { inImag in
                outputReal.withUnsafeMutableBufferPointer { outReal in
                    outputImag.withUnsafeMutableBufferPointer { outImag in
                        var input = DSPSplitComplex(realp: inReal.baseAddress!, imagp: inImag.baseAddress!)
                        var output = DSPSplitComplex(realp: outReal.baseAddress!, imagp: outImag.baseAddress!)
                        frame.withUnsafeBytes { raw in
                            vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &input, 1, vDSP_Length(half))
                        }
                        fft.forward(input: input, output: &output)
                        magnitudes.withUnsafeMutableBufferPointer { mags in
                            vDSP_zvabs(&output, 1, mags.baseAddress!, 1, vDSP_Length(half))
                        }
                    }
                }
            }
        }

        return magnitudes
    }

    /// Pitch-class profile of a magnitude spectrum: each peak goes to the pitch class of its
    /// interpolated frequency, so window leakage doesn't bleed into neighbouring semitones.
    func chroma(fromSpectrum magnitudes: [Float]) -> [Float] {
        let half = size / 2
        guard magnitudes.count == half else { return [Float](repeating: 0, count: 12) }
        var chroma = [Float](repeating: 0, count: 12)
        let floor = (magnitudes[lowestBin...highestBin].max() ?? 0) * 0.02
        let binWidth = sampleRate / Double(size)
        if floor > 0 {
            for bin in lowestBin...highestBin {
                let center = magnitudes[bin]
                guard center > floor, center > magnitudes[bin - 1], center >= magnitudes[bin + 1] else { continue }
                let left = log(Double(max(magnitudes[bin - 1], 1e-12)))
                let middle = log(Double(center))
                let right = log(Double(max(magnitudes[bin + 1], 1e-12)))
                let denominator = left - 2 * middle + right
                let offset = abs(denominator) > 1e-12 ? 0.5 * (left - right) / denominator : 0
                let midi = MIDINote.midi(forFrequency: (Double(bin) + offset) * binWidth)
                guard abs(midi - midi.rounded()) < 0.4 else { continue }
                chroma[MIDINote.pitchClass(Int(midi.rounded()))] += center
            }
        }
        let peak = chroma.max() ?? 0
        guard peak > 1e-6 else { return chroma }
        return chroma.map { $0 / peak }
    }

    /// Whether a chroma vector is consistent with the expected pitch classes sounding together:
    /// every expected class must be clearly present and together they must dominate the frame.
    static func matches(_ chroma: [Float], expected pitchClasses: Set<Int>, minimumLevel: Float = 0.3, minimumShare: Float = 0.5) -> Bool {
        guard chroma.count == 12, !pitchClasses.isEmpty, (chroma.max() ?? 0) > 0 else { return false }
        for pitchClass in pitchClasses where chroma[pitchClass] < minimumLevel { return false }
        let total = chroma.reduce(0, +)
        let expectedEnergy = pitchClasses.reduce(Float(0)) { $0 + chroma[$1] }
        return total > 0 && expectedEnergy / total >= minimumShare
    }

    /// Pitch classes above `level`, strongest first.
    static func activePitchClasses(_ chroma: [Float], level: Float = 0.5) -> [Int] {
        chroma.indices.filter { chroma[$0] >= level }.sorted { chroma[$0] > chroma[$1] }
    }
}
