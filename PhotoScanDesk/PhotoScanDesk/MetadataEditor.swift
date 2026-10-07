import SwiftUI

struct MetadataEditor: View {
    @ObservedObject var model: DeskModel
    @State private var draft: DocumentMetadata
    @State private var labels: String
    @State private var people: String
    init(model: DeskModel) {
        self.model = model
        _draft = State(initialValue: model.document)
        _labels = State(initialValue: model.document.labels.joined(separator: ", "))
        _people = State(initialValue: model.document.people.joined(separator: ", "))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scan Metadata").font(.headline)
            TextField("Title", text: $draft.title)
            TextField("Original date: YYYY, YYYY-MM, YYYY-MM-DD, or blank", text: $draft.date)
            Toggle("Approximate date", isOn: $draft.approximate)
            TextField("Original time (optional): HH:mm:ss", text: $draft.time)
            Text("Time requires an exact day. Partial or approximate dates stay in metadata.json without an invented datetime.").font(.caption).foregroundStyle(.secondary)
            TextField("Labels, separated by commas", text: $labels)
            TextField("People, separated by commas", text: $people)
            Text("Description / notes")
            TextEditor(text: $draft.notes).frame(height: 100)
            if let error = model.error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { model.showMetadata = false }
                Spacer()
                Button("Save") {
                    draft.labels = list(labels); draft.people = list(people)
                    model.saveMetadata(draft)
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 540).disabled(model.busy)
            .interactiveDismissDisabled(model.busy)
    }
    private func list(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
