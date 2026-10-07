import SwiftUI

struct CropReviewView: View {
    let review: CropReview
    @ObservedObject var model: DeskModel
    @State private var boundary: PrintBoundary
    @State private var candidate = -1
    init(review: CropReview, model: DeskModel) {
        self.review = review; self.model = model
        _boundary = State(initialValue: review.candidates.first ?? .manual)
        _candidate = State(initialValue: review.candidates.isEmpty ? -1 : 0)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Print Boundary").font(.headline)
                Spacer()
                Picker("Boundary", selection: $candidate) {
                    Text("Manual").tag(-1)
                    ForEach(review.candidates.indices, id: \.self) { Text("Detected \($0 + 1)").tag($0) }
                }
                .frame(width: 200)
                .disabled(model.busy)
                .onChange(of: candidate) { _, index in
                    if index >= 0 { boundary = review.candidates[index] }
                }
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
                        Path { path in
                            let points = boundary.corners.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                            path.addLines(points); path.closeSubpath()
                        }
                        .stroke(boundary.valid ? .yellow : .red, lineWidth: 2)
                        .allowsHitTesting(false)
                        ForEach(0..<4, id: \.self) { index in
                            Circle().fill(.yellow).overlay(Circle().stroke(.black, lineWidth: 1))
                                .frame(width: 18, height: 18)
                                .position(x: boundary.corners[index].x * size.width, y: boundary.corners[index].y * size.height)
                                .gesture(DragGesture(coordinateSpace: .named("crop-image")).onChanged { value in
                                    guard !model.busy else { return }
                                    candidate = -1
                                    boundary.corners[index] = CGPoint(x: min(1, max(0, value.location.x / size.width)),
                                                                     y: min(1, max(0, value.location.y / size.height)))
                                })
                                .help(["Top left", "Top right", "Bottom right", "Bottom left"][index])
                        }
                    }
                    .coordinateSpace(name: "crop-image")
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .padding(20).background(Color(nsColor: .textBackgroundColor))
            Divider()
            if let error = model.error { Text(error).foregroundStyle(.red).padding() }
            HStack {
                Button("Cancel") { model.cropReview = nil }.disabled(model.busy)
                Text("Edges trim slightly inside the boundary.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Save Crop", systemImage: "crop") { model.saveCrop(boundary) }
                    .disabled(model.busy || !boundary.valid).keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 760, height: 620)
        .interactiveDismissDisabled(model.busy)
    }
}
