import SwiftUI

struct CropReviewView: View {
    let review: CropReview
    @ObservedObject var model: DeskModel
    @State private var boundaries: [PrintBoundary]
    @State private var selected = 0
    private var selectionError: String? {
        do { try PrintCrop.validateSelection(boundaries); return nil }
        catch { return error.localizedDescription }
    }
    init(review: CropReview, model: DeskModel) {
        self.review = review; self.model = model
        _boundaries = State(initialValue: review.candidates.isEmpty ? [.manual] :
            (review.isRevision ? Array(review.candidates.prefix(1)) : review.candidates))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(review.isRevision ? "Print Boundary" : "Review Prints").font(.headline)
                Spacer()
                Picker("Print", selection: $selected) {
                    ForEach(boundaries.indices, id: \.self) { Text("Print \($0 + 1)").tag($0) }
                }.frame(width: 160).disabled(model.busy || boundaries.isEmpty)
                Button("Add Print") { boundaries.append(.manual); selected = boundaries.count - 1 }
                    .disabled(model.busy || review.isRevision)
                Button("Remove") {
                    boundaries.remove(at: selected); selected = max(0, min(selected, boundaries.count - 1))
                }.disabled(model.busy || boundaries.isEmpty || review.isRevision)
            }
            .padding()
            Divider()
            if review.candidates.isEmpty {
                Text("No print detected. These are starting handles; place all four on the print corners.")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            }
            GeometryReader { geometry in
                let image = review.preview
                let scale = min(geometry.size.width / CGFloat(image.width), geometry.size.height / CGFloat(image.height))
                let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                    .overlay {
                        ForEach(boundaries.indices, id: \.self) { printIndex in
                            Path { path in
                                let points = boundaries[printIndex].corners.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                                path.addLines(points); path.closeSubpath()
                            }
                            .stroke(boundaries[printIndex].valid ? (printIndex == selected ? Color.yellow : Color.cyan) : Color.red, lineWidth: 2)
                            .allowsHitTesting(false)
                            Text("\(printIndex + 1)").font(.headline).padding(4).background(.black.opacity(0.7)).foregroundStyle(.white)
                                .position(x: boundaries[printIndex].corners[0].x * size.width + 16,
                                          y: boundaries[printIndex].corners[0].y * size.height + 16)
                                .onTapGesture { if !model.busy { selected = printIndex } }
                        }
                        if boundaries.indices.contains(selected) {
                            ForEach(0..<4, id: \.self) { index in
                                Circle().fill(.yellow).overlay(Circle().stroke(.black, lineWidth: 1))
                                    .frame(width: 18, height: 18)
                                    .position(x: boundaries[selected].corners[index].x * size.width, y: boundaries[selected].corners[index].y * size.height)
                                    .gesture(DragGesture(coordinateSpace: .named("crop-image")).onChanged { value in
                                        guard !model.busy else { return }
                                        boundaries[selected].corners[index] = CGPoint(x: min(1, max(0, value.location.x / size.width)),
                                                                                     y: min(1, max(0, value.location.y / size.height)))
                                    })
                                    .help(["Top left", "Top right", "Bottom right", "Bottom left"][index])
                            }
                        }
                    }
                    .coordinateSpace(name: "crop-image")
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .padding(20).background(Color(nsColor: .textBackgroundColor))
            Divider()
            if let selectionError { Text(selectionError).font(.callout).foregroundStyle(.red).padding(8) }
            if let error = model.error { Text(error).foregroundStyle(.red).padding() }
            HStack {
                Button("Cancel") { model.cropReview = nil }.disabled(model.busy)
                Button("Skip Crop", action: model.skipCrop).disabled(model.busy)
                Text("Edges trim slightly inside the boundary.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(review.isRevision ? "Accept Crop" : "Extract \(boundaries.count) Prints", systemImage: "crop") {
                    if review.isRevision { model.saveCrop(boundaries[0]) }
                    else { model.extractPrints(boundaries) }
                }
                    .disabled(model.busy || selectionError != nil).keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 760, height: 620)
        .interactiveDismissDisabled(model.busy)
    }
}
