import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isImporterPresented = false

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
                        isImporterPresented = true
                    } label: {
                        Label("Import from Files…", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("importButton")
                } header: {
                    Text("Your scores")
                }
                Section {
                    Label("Photo or PDF of sheet music", systemImage: "doc.viewfinder")
                    Label("Learn from an audio recording", systemImage: "waveform")
                } header: {
                    Text("Coming later")
                } footer: {
                    Text("Sheet-music recognition and audio transcription will plug into the same import pipeline.")
                }
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isImporterPresented = true
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
                allowedContentTypes: ScoreImportService.shared.allowedContentTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case let .success(urls):
                    guard let url = urls.first else { return }
                    Task {
                        await model.importFile(url)
                        if model.errorMessage == nil { dismiss() }
                    }
                case let .failure(error):
                    model.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func row(_ entry: SongEntry) -> some View {
        Button {
            Task {
                await model.select(entry)
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.isBundled ? "music.note" : "doc.richtext")
                    .foregroundStyle(Theme.saffron)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.body.weight(.semibold))
                    Text(entry.subtitle).font(.caption).foregroundStyle(.secondary)
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
