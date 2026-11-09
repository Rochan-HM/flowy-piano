import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    private enum FilePickerMode { case score, sheetMusic }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isImporterPresented = false
    @State private var pickerMode = FilePickerMode.score
    @State private var isScannerPresented = false
    @State private var photoSelection: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Included songs") {
                    ForEach(model.library.bundled) { row($0) }
                }
                Section {
                    if model.library.imported.isEmpty {
                        Text("Import MusicXML (.musicxml, .xml, .mxl) or MIDI (.mid) files from the Files app.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.library.imported) { row($0) }
                        .onDelete { offsets in
                            for index in offsets { model.library.delete(model.library.imported[index]) }
                        }
                    Button {
                        openFilePicker(.score)
                    } label: {
                        Label("Import from Files…", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("importButton")
                } header: {
                    Text("Your scores")
                }
                sheetMusicSection
                Section {
                    Label("Learn from an audio recording", systemImage: "waveform")
                } header: {
                    Text("Coming later")
                }
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        openFilePicker(.score)
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("importToolbarButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: pickerMode == .score ? ScoreImportService.shared.allowedContentTypes : [.pdf, .image],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case let .success(urls):
                    guard let url = urls.first else { return }
                    if pickerMode == .score {
                        Task {
                            await model.importFile(url)
                            if model.errorMessage == nil { dismiss() }
                        }
                    } else {
                        recognizeFile(url)
                    }
                case let .failure(error):
                    model.errorMessage = error.localizedDescription
                }
            }
            .fullScreenCover(isPresented: $isScannerPresented) {
                DocumentScannerView(
                    onScan: { images in
                        isScannerPresented = false
                        guard !images.isEmpty else { return }
                        model.recognize(RecognitionPages.uploads(fromImages: images, name: "Scanned score"), name: "Scanned score")
                    },
                    onCancel: { isScannerPresented = false },
                    onError: { error in
                        isScannerPresented = false
                        model.errorMessage = error.localizedDescription
                    }
                )
                .ignoresSafeArea()
            }
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                photoSelection = []
                Task { await recognizePhotos(items) }
            }
        }
    }

    @ViewBuilder
    private var sheetMusicSection: some View {
        Section {
            if model.isRecognitionReady {
                if DocumentScannerView.isAvailable {
                    Button {
                        isScannerPresented = true
                    } label: {
                        Label("Scan pages with the camera", systemImage: "doc.viewfinder")
                    }
                    .disabled(isRecognizing)
                }
                PhotosPicker(selection: $photoSelection, maxSelectionCount: 12, matching: .images) {
                    Label("Photos of a score…", systemImage: "photo.on.rectangle")
                }
                .disabled(isRecognizing)
                Button {
                    openFilePicker(.sheetMusic)
                } label: {
                    Label("PDF or image file…", systemImage: "doc.richtext")
                }
                .disabled(isRecognizing)
                .accessibilityIdentifier("recognizeFileButton")
            } else {
                Button {
                    dismiss()
                    model.isSettingsPresented = true
                } label: {
                    Label("Set up sheet music recognition in Settings", systemImage: "gearshape")
                }
            }
            if case let .working(progress, name) = model.recognitionStatus {
                HStack(spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reading “\(name)”").font(.subheadline.weight(.semibold))
                        Text(statusText(progress)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) { model.cancelRecognition() }
                }
                .accessibilityIdentifier("recognitionProgress")
            }
        } header: {
            Text("Printed sheet music")
        } footer: {
            Text("Photos and PDFs are sent to your recognition server and come back as a score with the right and left hands separated. Finger numbers printed in the music aren't recognized.")
        }
    }

    private var isRecognizing: Bool {
        if case .working = model.recognitionStatus { return true }
        return false
    }

    private func statusText(_ progress: RecognitionProgress) -> String {
        switch progress.phase {
        case .uploading: return "Uploading…"
        case .queued: return "Waiting for the server…"
        case .recognizing:
            return progress.pagesTotal > 1 ? "Recognizing page \(min(progress.pagesDone + 1, progress.pagesTotal)) of \(progress.pagesTotal)…" : "Recognizing the music (about 10–20 s per page)…"
        case .downloading: return "Loading the score…"
        }
    }

    private func openFilePicker(_ mode: FilePickerMode) {
        pickerMode = mode
        isImporterPresented = true
    }

    private func recognizeFile(_ url: URL) {
        do {
            model.recognize(try RecognitionPages.uploads(fromFile: url), name: url.deletingPathExtension().lastPathComponent)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func recognizePhotos(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                images.append(image)
            }
        }
        guard !images.isEmpty else {
            model.errorMessage = "The selected photos couldn't be loaded."
            return
        }
        model.recognize(RecognitionPages.uploads(fromImages: images, name: "Photographed score"), name: "Photographed score")
    }

    private func row(_ entry: SongEntry) -> some View {
        Button {
            Task {
                await model.select(entry)
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.isBundled ? "music.note" : (entry.subtitle.hasPrefix("Scanned") ? "doc.viewfinder" : "doc.richtext"))
                    .foregroundStyle(Theme.saffron)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.body.weight(.semibold))
                    Text(entry.subtitle).font(.caption).foregroundStyle(.secondary)
                    if let notes = entry.notes, !notes.isEmpty {
                        Label(notes.joined(separator: " "), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.saffron)
                            .lineLimit(3)
                    }
                }
                Spacer()
                if entry.id == model.currentSong?.id {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.correct)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("song-\(entry.id)")
    }
}
