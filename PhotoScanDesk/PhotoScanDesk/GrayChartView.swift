import SwiftUI

struct GrayChartView: View {
    let chart: ChartReference
    @ObservedObject var model: DeskModel
    @State private var target: DKCGrayTarget = .gray18
    @State private var selection: CGRect?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("DKC-Pro Gray Balance").font(.headline)
                Spacer()
                Picker("Gray target", selection: $target) {
                    ForEach(DKCGrayTarget.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 230)
            }
            .padding()
            Divider()
            GeometryReader { geometry in
                if let image = NSImage(data: chart.data) {
                    let scale = min(geometry.size.width / image.size.width, geometry.size.height / image.size.height)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    Image(nsImage: image)
                        .resizable().frame(width: size.width, height: size.height)
                        .overlay(alignment: .topLeading) {
                            if let selection {
                                Rectangle().stroke(.yellow, lineWidth: 2)
                                    .background(.yellow.opacity(0.15))
                                    .frame(width: selection.width * size.width, height: selection.height * size.height)
                                    .offset(x: selection.minX * size.width, y: selection.minY * size.height)
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                            guard !model.busy else { return }
                            let x0 = min(1, max(0, value.startLocation.x / size.width))
                            let y0 = min(1, max(0, value.startLocation.y / size.height))
                            let x1 = min(1, max(0, value.location.x / size.width))
                            let y1 = min(1, max(0, value.location.y / size.height))
                            selection = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
                        })
                        .help("Select the interior of a neutral gray patch")
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
            .padding(16)
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            if let error = model.error { Text(error).foregroundStyle(.red).padding() }
            HStack {
                Button("Cancel") { model.chartReference = nil }.disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Use Gray Sample", systemImage: "checkmark") {
                    if let selection { model.calibrateGray(target: target, selection: selection) }
                }
                .disabled(selection == nil || model.busy || !model.connected)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 760, height: 620)
        .interactiveDismissDisabled(model.busy)
    }
}
