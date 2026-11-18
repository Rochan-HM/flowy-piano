#!/usr/bin/env swift
// Renders a performance plan to a WAV file with a sampled acoustic grand piano (Apple's built-in
// General MIDI sound bank on macOS), using AVAudioEngine's offline rendering.
//
// Usage: swift render_piano.swift plan.json out.wav
// plan.json: {"events": [{"time": 1.0, "midis": [60, 64], "duration": 0.6, "velocity": 90}], "tail": 1.5}
import AVFoundation

struct Event: Decodable {
    var time: Double
    var midis: [Int]
    var duration: Double
    var velocity: Int?
}

struct Plan: Decodable {
    var events: [Event]
    var tail: Double?
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: render_piano.swift plan.json out.wav\n".utf8))
    exit(2)
}
let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
let sampleRate = 44_100.0

let engine = AVAudioEngine()
let sampler = AVAudioUnitSampler()
engine.attach(sampler)
engine.connect(sampler, to: engine.mainMixerNode, format: nil)
let soundBank = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
try sampler.loadSoundBankInstrument(at: soundBank, program: 0,
                                    bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: UInt8(kAUSampler_DefaultBankLSB))

let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
let chunk: AVAudioFrameCount = 256
try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
try engine.start()

struct Action {
    var sample: Int
    var isOn: Bool
    var note: UInt8
    var velocity: UInt8
}
var actions: [Action] = []
for event in plan.events {
    for midi in event.midis {
        let velocity = UInt8(max(1, min(127, event.velocity ?? 90)))
        actions.append(Action(sample: Int(event.time * sampleRate), isOn: true, note: UInt8(midi), velocity: velocity))
        actions.append(Action(sample: Int((event.time + event.duration) * sampleRate), isOn: false, note: UInt8(midi), velocity: 0))
    }
}
actions.sort { $0.sample == $1.sample ? (!$0.isOn && $1.isOn) : $0.sample < $1.sample }
let end = plan.events.map { $0.time + $0.duration }.max() ?? 0
let totalFrames = Int((end + (plan.tail ?? 1.5)) * sampleRate)

// The file is flushed when the AVAudioFile is released, so keep it inside a function scope.
func render(to url: URL) throws {
    var settings = format.settings
    settings[AVLinearPCMIsNonInterleaved] = false
    let output = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk)!
    var position = 0
    var next = 0
    while position < totalFrames {
        while next < actions.count, actions[next].sample <= position {
            let action = actions[next]
            if action.isOn {
                sampler.startNote(action.note, withVelocity: action.velocity, onChannel: 0)
            } else {
                sampler.stopNote(action.note, onChannel: 0)
            }
            next += 1
        }
        let frames = AVAudioFrameCount(min(Int(chunk), totalFrames - position))
        guard try engine.renderOffline(frames, to: buffer) == .success else {
            throw NSError(domain: "render", code: 1, userInfo: [NSLocalizedDescriptionKey: "render failed at frame \(position)"])
        }
        try output.write(from: buffer)
        position += Int(frames)
    }
}
try render(to: URL(fileURLWithPath: arguments[2]))
engine.stop()
print("wrote \(arguments[2]): \(String(format: "%.1f", Double(totalFrames) / sampleRate)) s, \(plan.events.count) events")
