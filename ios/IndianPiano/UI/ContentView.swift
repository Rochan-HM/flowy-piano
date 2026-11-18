import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GeometryReader { proxy in
            // Short (phone landscape) screens split the space; tall ones cap the keyboard so keys
            // keep piano-like proportions and give the rest to the lesson panel.
            let available = proxy.size.height - 36 - 22 - 6 * 3 - 6
            let keyboardHeight = min(360, available - min(260, max(130, available * 0.46)))
            let panelHeight = min(340, available - keyboardHeight)
            VStack(spacing: 6) {
                TopBar()
                    .frame(height: 36)
                LessonPanel()
                    .frame(height: panelHeight)
                Spacer(minLength: 0)
                KeyboardNavigator()
                    .frame(height: 22)
                PianoKeyboardView()
                    .frame(height: keyboardHeight)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $model.isLibraryPresented) {
            LibraryView().environment(model)
        }
        .sheet(isPresented: $model.isSettingsPresented) {
            SettingsView().environment(model)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Imported from your scan", isPresented: Binding(
            get: { model.errorMessage == nil && !model.importNotes.isEmpty },
            set: { if !$0 { model.importNotes = [] } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.importNotes.joined(separator: "\n\n"))
        }
        .alert("Microphone unavailable", isPresented: Binding(
            get: { model.errorMessage == nil && model.mic.failureMessage != nil },
            set: { if !$0 { model.mic.dismissFailure() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.mic.failureMessage ?? "")
        }
    }
}
