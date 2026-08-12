import SwiftUI

/// Editor rectangle meja pada koordinat floorplan 0...1.
struct TableAnnotationEditor: View {
    @Environment(AnalysisSession.self) private var session

    let image: NSImage?
    let sourceSize: CGSize?

    @State private var adding = false
    @State private var selectedID: UUID?
    @State private var draftStart: CGPoint?
    @State private var draftRect: CGRect?
    @State private var message: String?
    @State private var editStartRect: CGRect?

    var body: some View {
        @Bindable var session = session
        return VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Anotasi Meja").font(.headline)
                    Text("Klik Tambah Meja, lalu drag dari satu sudut ke sudut berlawanan. Anotasi tersimpan bersama profil kalibrasi.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(adding ? "Batalkan" : "Tambah Meja", systemImage: adding ? "xmark" : "rectangle.badge.plus") {
                    adding.toggle()
                    draftRect = nil
                    draftStart = nil
                    message = nil
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(alignment: .top, spacing: Space.m) {
                canvas
                    .frame(minHeight: 300)

                VStack(alignment: .leading, spacing: Space.s) {
                    Text("Meja").font(.headline)
                    if session.tableAnnotations.isEmpty {
                        Text("Belum ada meja.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        List(selection: $selectedID) {
                            ForEach(session.tableAnnotations) { table in
                                Text(table.label).tag(Optional(table.id))
                            }
                        }
                        .frame(minHeight: 150)
                    }
                    if let index = selectedIndex {
                        TextField("Nama meja", text: $session.tableAnnotations[index].label)
                            .textFieldStyle(.roundedBorder)
                        Button("Hapus Meja", systemImage: "trash", role: .destructive) {
                            session.tableAnnotations.remove(at: index)
                            selectedID = nil
                        }
                    }
                    if let message {
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    Text("Kapasitas kursi tidak dihitung karena tidak tersedia pada data.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 230)
            }
        }
        .card(padding: Space.m)
    }

    private var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return session.tableAnnotations.firstIndex { $0.id == selectedID }
    }

    private var canvas: some View {
        GeometryReader { geo in
            let rect = fittedRect(in: geo.size)
            ZStack {
                Color.primary.opacity(0.025)
                if let image {
                    Image(nsImage: image)
                        .resizable().interpolation(.high)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                } else {
                    TableGridBackground()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }

                ForEach(session.tableAnnotations) { table in
                    tableRectangle(table, fitted: rect)
                }

                if let draftRect {
                    Rectangle()
                        .fill(Theme.accent.opacity(0.18))
                        .overlay(Rectangle().stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [5, 3])))
                        .frame(width: draftRect.width * rect.width, height: draftRect.height * rect.height)
                        .position(x: rect.minX + draftRect.midX * rect.width,
                                  y: rect.minY + draftRect.midY * rect.height)
                }

                if adding {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .gesture(addGesture(fitted: rect))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).stroke(Theme.hairline))
        }
    }

    @ViewBuilder
    private func tableRectangle(_ table: TableAnnotation, fitted: CGRect) -> some View {
        let rect = table.rectNormalized
        let selected = selectedID == table.id
        ZStack {
            Rectangle()
                .fill(Theme.accent.opacity(selected ? 0.24 : 0.14))
                .overlay(Rectangle().stroke(selected ? Theme.accent : Color.orange, lineWidth: selected ? 3 : 2))
            Text(table.label)
                .font(.caption2.weight(.semibold))
                .padding(4)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .frame(width: rect.width * fitted.width, height: rect.height * fitted.height)
        .position(x: fitted.minX + rect.midX * fitted.width,
                  y: fitted.minY + rect.midY * fitted.height)
        .contentShape(Rectangle())
        .onTapGesture { selectedID = table.id; adding = false }
        .gesture(moveGesture(tableID: table.id, fitted: fitted))
        .overlay {
            if selected {
                cornerHandles(tableID: table.id, fitted: fitted)
            }
        }
    }

    private func cornerHandles(tableID: UUID, fitted: CGRect) -> some View {
        GeometryReader { geo in
            ForEach(Corner.allCases, id: \.self) { corner in
                Circle()
                    .fill(.background)
                    .stroke(Theme.accent, lineWidth: 2)
                    .frame(width: 12, height: 12)
                    .position(corner.position(in: geo.size))
                    .gesture(resizeGesture(tableID: tableID, corner: corner, fitted: fitted))
            }
        }
    }

    private func addGesture(fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = normalized(value.startLocation, fitted: fitted)
                let current = normalized(value.location, fitted: fitted)
                draftStart = start
                draftRect = rectangle(from: start, to: current)
            }
            .onEnded { value in
                defer { draftStart = nil; draftRect = nil }
                let distance = hypot(value.translation.width, value.translation.height)
                guard distance >= 12, let candidate = draftRect else {
                    message = "Drag minimal 12 pt untuk membuat meja."
                    return
                }
                guard validate(candidate, excluding: nil) else { return }
                let table = TableAnnotation(label: "Meja \(session.tableAnnotations.count + 1)", rectNormalized: candidate)
                session.tableAnnotations.append(table)
                selectedID = table.id
                adding = false
                message = nil
            }
    }

    private func moveGesture(tableID: UUID, fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard !adding, let index = session.tableAnnotations.firstIndex(where: { $0.id == tableID }) else { return }
                selectedID = tableID
                let base = editStartRect ?? session.tableAnnotations[index].rectNormalized
                if editStartRect == nil { editStartRect = base }
                var rect = base
                rect.origin.x += value.translation.width / fitted.width
                rect.origin.y += value.translation.height / fitted.height
                rect.origin.x = min(max(0, rect.origin.x), 1 - rect.width)
                rect.origin.y = min(max(0, rect.origin.y), 1 - rect.height)
                if validate(rect, excluding: tableID, report: false) {
                    session.tableAnnotations[index].rectNormalized = rect
                }
            }
            .onEnded { _ in editStartRect = nil }
    }

    private func resizeGesture(tableID: UUID, corner: Corner, fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let index = session.tableAnnotations.firstIndex(where: { $0.id == tableID }) else { return }
                let base = editStartRect ?? session.tableAnnotations[index].rectNormalized
                if editStartRect == nil { editStartRect = base }
                var rect = base
                let dx = value.translation.width / fitted.width
                let dy = value.translation.height / fitted.height
                corner.resize(&rect, dx: dx, dy: dy)
                rect = rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                if validate(rect, excluding: tableID, report: false) {
                    session.tableAnnotations[index].rectNormalized = rect
                }
            }
            .onEnded { _ in editStartRect = nil }
    }

    private func validate(_ rect: CGRect, excluding id: UUID?, report: Bool = true) -> Bool {
        let area = rect.width * session.venueWidthM * rect.height * session.venueHeightM
        if rect.width <= 0 || rect.height <= 0 || area < 0.1 {
            if report { message = "Ukuran meja minimal 0,1 m²." }
            return false
        }
        if session.tableAnnotations.contains(where: { $0.id != id && $0.rectNormalized.intersection(rect).area > 0.000001 }) {
            if report { message = "Meja tidak boleh bertumpang tindih." }
            return false
        }
        return true
    }

    private func normalized(_ point: CGPoint, fitted: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (point.x - fitted.minX) / fitted.width)),
                y: min(1, max(0, (point.y - fitted.minY) / fitted.height)))
    }

    private func rectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    private func fittedRect(in container: CGSize) -> CGRect {
        let source = sourceSize ?? CGSize(width: max(session.venueWidthM, 1), height: max(session.venueHeightM, 1))
        let factor = min(container.width / source.width, container.height / source.height)
        let size = CGSize(width: source.width * factor, height: source.height * factor)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

private enum Corner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    func position(in size: CGSize) -> CGPoint {
        switch self {
        case .topLeft: return .zero
        case .topRight: return CGPoint(x: size.width, y: 0)
        case .bottomLeft: return CGPoint(x: 0, y: size.height)
        case .bottomRight: return CGPoint(x: size.width, y: size.height)
        }
    }

    func resize(_ rect: inout CGRect, dx: CGFloat, dy: CGFloat) {
        switch self {
        case .topLeft: rect.origin.x += dx; rect.size.width -= dx; rect.origin.y += dy; rect.size.height -= dy
        case .topRight: rect.size.width += dx; rect.origin.y += dy; rect.size.height -= dy
        case .bottomLeft: rect.origin.x += dx; rect.size.width -= dx; rect.size.height += dy
        case .bottomRight: rect.size.width += dx; rect.size.height += dy
        }
    }
}

private struct TableGridBackground: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 24
            var path = Path()
            stride(from: CGFloat.zero, through: size.width, by: step).forEach {
                path.move(to: CGPoint(x: $0, y: 0)); path.addLine(to: CGPoint(x: $0, y: size.height))
            }
            stride(from: CGFloat.zero, through: size.height, by: step).forEach {
                path.move(to: CGPoint(x: 0, y: $0)); path.addLine(to: CGPoint(x: size.width, y: $0))
            }
            context.stroke(path, with: .color(Color.secondary.opacity(0.16)), lineWidth: 0.5)
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
