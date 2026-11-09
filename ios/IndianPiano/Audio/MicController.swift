import AVFoundation
import Foundation
import Observation

/// Main-actor front end for the microphone: permission, start/stop, and published readings.
@MainActor
@Observable
final class MicController {
    enum Status: Equatable {
        case off
        case requesting
        case listening
        case denied
        case failed(String)
    }

    private(set) var status: Status = .off
    /// Input level 0...1 (roughly -60 dBFS ... 0 dBFS).
    private(set) var level: Float = 0
    private(set) var heardNote: Int?
    private(set) var heardPitchClasses: [Int] = []

    @ObservationIgnored var onNote: ((Int) -> Void)?
    @ObservationIgnored var onChroma: (([Float]) -> Void)?
    @ObservationIgnored private let listener = MicListener()
    @ObservationIgnored private var lastAttack: TimeInterval = 0
    @ObservationIgnored private var lastNoteTime: TimeInterval = 0

    var isListening: Bool { status == .listening }

    var permissionDescription: String {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return "Allowed"
        case .denied: return "Denied — enable it in Settings › Privacy › Microphone"
        case .undetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    func toggle() async {
        switch status {
        case .listening: stop()
        case .requesting: break
        default: await start()
        }
    }

    func dismissFailure() {
        switch status {
        case .failed, .denied: status = .off
        default: break
        }
    }

    var failureMessage: String? {
        if case let .failed(message) = status { return message }
        if status == .denied { return "Microphone access is off. Enable it in Settings › Privacy & Security › Microphone." }
        return nil
    }

    func start() async {
        guard !isListening else { return }
        status = .requesting
        let granted: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted: granted = true
        case .denied: granted = false
        default: granted = await AVAudioApplication.requestRecordPermission()
        }
        guard granted else {
            status = .denied
            return
        }
        listener.onFrame = { [weak self] result in self?.handle(result) }

        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.status == .requesting else { return }
            self.status = .failed(Self.notRespondingMessage)
        }
        // Opening the input device can block inside CoreAudio, so keep it off the main thread.
        let listener = self.listener
        let failure: String? = await Task.detached(priority: .userInitiated) {
            AudioSessionConfigurator.configure(recording: true)
            do {
                try listener.start()
                return nil
            } catch {
                AudioSessionConfigurator.configure(recording: false)
                return error.localizedDescription
            }
        }.value
        watchdog.cancel()
        status = failure.map(Status.failed) ?? .listening
    }

    static let notRespondingMessage = """
        The microphone isn't responding. In the iOS Simulator, macOS must also let Simulator use \
        the Mac's microphone (System Settings › Privacy & Security › Microphone).
        """

    func stop() {
        let listener = self.listener
        Task.detached(priority: .userInitiated) {
            listener.stop()
            AudioSessionConfigurator.configure(recording: false)
        }
        status = .off
        level = 0
        heardNote = nil
        heardPitchClasses = []
    }

    func suppress(for seconds: TimeInterval) {
        guard isListening else { return }
        listener.suppress(for: seconds)
    }

    private func handle(_ result: MicFrameResult) {
        let now = ProcessInfo.processInfo.systemUptime
        let decibels = 20 * log10(max(result.rms, 1e-6))
        let normalized = max(0, min(1, (decibels + 60) / 60))
        level = max(normalized, level * 0.85)

        if result.isAttack { lastAttack = now }
        if let note = result.noteOnset {
            heardNote = note
            lastNoteTime = now
            onNote?(note)
        } else if now - lastNoteTime > 1.5 {
            heardNote = nil
        }
        if let chroma = result.chroma {
            heardPitchClasses = Array(ChromaAnalyzer.activePitchClasses(chroma, level: 0.6).prefix(4))
            // Only trust chords shortly after a key strike, so a ringing chord doesn't match the next step.
            if now - lastAttack < 0.3 { onChroma?(chroma) }
        }
    }
}
