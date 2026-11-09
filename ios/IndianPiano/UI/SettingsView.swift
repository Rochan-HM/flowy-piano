import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Picker("Note names", selection: $model.notation) {
                        ForEach(NotationSystem.allCases) { system in
                            Text("\(system.title) (\(system.sample))").tag(system)
                        }
                    }
                    Picker("Indian system for the toggle", selection: $model.indianSystem) {
                        Text("Carnatic (Ri1 Ri2 Ga2 …)").tag(NotationSystem.carnatic)
                        Text("Hindustani (komal / tivra)").tag(NotationSystem.hindustani)
                    }
                    Picker("Sa (tonic)", selection: $model.saPitchClass) {
                        ForEach(0..<12, id: \.self) { Text(MIDINote.keyNames[$0]).tag($0) }
                    }
                    Picker("Labels on keys", selection: $model.keyLabelMode) {
                        ForEach(KeyLabelMode.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Notation")
                } footer: {
                    Text(notationFooter)
                }

                Section("Lesson") {
                    Toggle("Show finger numbers", isOn: $model.showFingerNumbers)
                    Toggle("App plays the other hand in tempo mode", isOn: $model.playOtherHand)
                    Stepper(value: Binding(get: { model.lesson.tempoScale }, set: { model.setTempoScale($0) }), in: 0.25...1.5, step: 0.05) {
                        LabeledContent("Tempo mode speed", value: "\(Int((model.lesson.tempoScale * 100).rounded()))%")
                    }
                }

                Section {
                    Toggle("Accept the right note in any octave", isOn: $model.micOctaveTolerant)
                    LabeledContent("Permission", value: model.mic.permissionDescription)
                } header: {
                    Text("Microphone")
                } footer: {
                    Text("Single notes are recognised with YIN pitch detection; chords in both-hands mode use a 12-tone chroma match. Keys tapped on screen always count.")
                }

                Section("Keyboard & sound") {
                    Toggle("Play sound", isOn: $model.soundEnabled)
                    Stepper(value: $model.visibleWhiteKeys, in: 8...36) {
                        LabeledContent("Visible white keys", value: "\(model.visibleWhiteKeys)")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var notationFooter: String {
        switch model.notation {
        case .western:
            return "Letter names with octave numbers on C (C4 = middle C)."
        case .carnatic:
            return "Carnatic swaras with variant numbers. Enharmonic names (Ri3/Ga2, Ga1/Ri2, Da3/Ni2, Ni1/Da2) follow the score's spelling. A dot above means the upper octave, below means the lower octave."
        case .hindustani:
            return "Komal swaras are underlined and tivra Ma has a stroke above. A dot above means the upper octave, below means the lower octave."
        }
    }
}
