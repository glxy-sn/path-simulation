import SwiftUI
import AppKit

struct FloorBoundsEditor: View {
    let image: NSImage?
    var onEditingEnded: () -> Void = {}
    @Environment(AnalysisSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Floor boundaries").font(.headline)
                Spacer()
                Button("Reset") {
                    session.floorBounds = FloorBounds()
                    onEditingEnded()
                }
            }
            Text("Drag each edge. These boundaries apply to all cameras. Points outside stay on the nearest boundary.")
                .font(.caption).foregroundStyle(.secondary)
            GeometryReader { geometry in
                let size = image?.size ?? NSSize(width: max(session.venueWidthM, 1), height: max(session.venueHeightM, 1))
                let available = CGSize(width: max(1, geometry.size.width - 40), height: max(1, geometry.size.height - 40))
                let fit = min(available.width / size.width, available.height / size.height)
                let width = size.width * fit
                let height = size.height * fit
                let x = (geometry.size.width - width) / 2
                let y = (geometry.size.height - height) / 2
                let b = session.floorBounds
                ZStack(alignment: .topLeading) {
                    if let image {
                        Image(nsImage: image).resizable().frame(width: width, height: height).offset(x: x, y: y)
                    } else {
                        Rectangle().fill(.quaternary).frame(width: width, height: height).offset(x: x, y: y)
                    }
                    Path { path in
                        path.addRect(CGRect(x: x, y: y, width: width, height: height))
                        path.addRect(CGRect(x: x + b.left * width, y: y + b.top * height,
                                            width: (b.right-b.left)*width, height: (b.bottom-b.top)*height))
                    }.fill(.black.opacity(0.35), style: FillStyle(eoFill: true))
                    Rectangle().stroke(.orange, lineWidth: 3)
                        .frame(width: (b.right-b.left)*width, height: (b.bottom-b.top)*height)
                        .offset(x: x+b.left*width, y: y+b.top*height)
                    handle("left", at: CGPoint(x: x+b.left*width, y: y+(b.top+b.bottom)/2*height), origin: CGPoint(x:x,y:y), size: CGSize(width:width,height:height))
                    handle("right", at: CGPoint(x: x+b.right*width, y: y+(b.top+b.bottom)/2*height), origin: CGPoint(x:x,y:y), size: CGSize(width:width,height:height))
                    handle("top", at: CGPoint(x: x+(b.left+b.right)/2*width, y: y+b.top*height), origin: CGPoint(x:x,y:y), size: CGSize(width:width,height:height))
                    handle("bottom", at: CGPoint(x: x+(b.left+b.right)/2*width, y: y+b.bottom*height), origin: CGPoint(x:x,y:y), size: CGSize(width:width,height:height))
                }.coordinateSpace(name: "floorBounds")
            }
        }.padding(12)
    }

    private func handle(_ edge: String, at point: CGPoint, origin: CGPoint, size: CGSize) -> some View {
        Image(systemName: edge == "left" || edge == "right" ? "arrow.left.and.right" : "arrow.up.and.down")
            .foregroundStyle(.black).frame(width: 34, height: 34)
            .background(.white, in: Circle()).overlay(Circle().stroke(.black, lineWidth: 2))
            .position(point)
            .accessibilityLabel("\(edge) floor boundary")
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("floorBounds"))
                .onChanged { value in
                    let x = min(1, max(0, (value.location.x-origin.x)/size.width))
                    let y = min(1, max(0, (value.location.y-origin.y)/size.height))
                    var b = session.floorBounds
                    switch edge {
                    case "left": b.left = min(x, b.right-0.02)
                    case "right": b.right = max(x, b.left+0.02)
                    case "top": b.top = min(y, b.bottom-0.02)
                    default: b.bottom = max(y, b.top+0.02)
                    }
                    session.floorBounds = b
                }
                .onEnded { _ in onEditingEnded() })
    }
}
