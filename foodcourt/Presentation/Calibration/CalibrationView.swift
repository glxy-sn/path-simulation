//
//  CalibrationView.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI
import AppKit
import AVFoundation
import PDFKit
import UniformTypeIdentifiers

struct CalibrationView: View {
    @Environment(\.uiScale) private var scale
    @Environment(AppRouter.self) private var router
    @Environment(AnalysisSession.self) private var session

    @State private var selectedCameraIndex = 0
    @State private var floorPlanImage: NSImage?
    @State private var cameraFrameImage: NSImage?
    @State private var isLoadingFrame = false
    @State private var message: String?
    @State private var reloadToken = UUID()
    @State private var savedProfiles: [SavedCalibrationProfile] = []
    @State private var activeProfileID: UUID?
    @State private var showsProfileHistory = false

    private var selectedIndex: Int {
        min(max(0, selectedCameraIndex), max(0, session.cameras.count - 1))
    }

    private var selectedCamera: SessionCamera? {
        guard session.cameras.indices.contains(selectedIndex) else { return nil }
        return session.cameras[selectedIndex]
    }

    var body: some View {
        Group {
            if session.cameras.isEmpty { emptyState }
            else { calibrationContent }
        }
        .task(id: reloadToken) {
            await refreshImages()
        }
        .task { reloadProfileHistory() }
        .onChange(of: selectedCameraIndex) { _, _ in reloadToken = UUID() }
        .sheet(isPresented: $showsProfileHistory) {
            CalibrationProfileHistorySheet(
                profiles: savedProfiles,
                activeProfileID: activeProfileID,
                onLoad: { loadSavedProfile($0) },
                onExport: { exportProfile($0) },
                onDelete: { deleteProfile($0) }
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "camera.metering.none")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Belum ada kamera").font(.headline)
            Text("Import video dulu di langkah sebelumnya.")
                .font(.callout)
                .foregroundStyle(.secondary)
            GhostButton(title: "Ke Import", systemImage: "chevron.left") { router.back() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var calibrationContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l * scale) {
                    header

                    canvases
                        .frame(height: 360 * scale)

                    inspector
                }
                .spad(Space.xl, [.horizontal, .top])
                .padding(.bottom, Space.xl)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            WizardFooter(onBack: { router.back() }) {
                PrimaryButton(
                    title: session.allCalibrated ? "Kalibrasi Selesai" : "Kalibrasi Semua Kamera",
                    systemImage: "checkmark.seal",
                    enabled: session.allCalibrated
                ) {
                    router.next()
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.m * scale) {
            SectionHeader(
                title: "Kalibrasi",
                subtitle: "Pilih titik lantai yang sama pada CCTV dan denah. Gunakan 4–8 pasangan titik bebas."
            )
            HStack(spacing: Space.s) {
                ForEach(Array(session.cameras.enumerated()), id: \.element.id) { index, camera in
                    Button {
                        selectedCameraIndex = index
                    } label: {
                        HStack(spacing: Space.s) {
                            Image(systemName: camera.isCalibrated ? "checkmark.circle.fill" : "camera")
                                .foregroundStyle(camera.isCalibrated ? .green : (index == selectedIndex ? .white : .secondary))
                            Text(camera.label)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, Space.m)
                        .padding(.vertical, Space.s)
                        .foregroundStyle(index == selectedIndex ? Color.white : Color.primary)
                        .background(index == selectedIndex ? Theme.accent : Color.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Pilih \(camera.label)")
                }
                Spacer()
                profileMenu
                    .buttonStyle(.bordered)
                Button("Simpan Profil", systemImage: "tray.and.arrow.down") { saveProfile() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSaveProfile)
            }
        }
    }

    private var profileMenu: some View {
        Menu {
            if savedProfiles.isEmpty {
                Text("Belum ada profil tersimpan")
            } else {
                ForEach(savedProfiles) { profile in
                    Button {
                        loadSavedProfile(profile)
                    } label: {
                        if activeProfileID == profile.id {
                            Label(profile.displayName, systemImage: "checkmark")
                        } else {
                            Text(profile.displayName)
                        }
                    }
                }
                Divider()
            }
            Button("Impor dari File…", systemImage: "square.and.arrow.down") { importProfile() }
            Button("Ekspor Profil Terpilih…", systemImage: "square.and.arrow.up") {
                if let profile = activeProfile { exportProfile(profile) }
            }
            .disabled(activeProfile == nil)
            Button("Kelola Riwayat…", systemImage: "clock.arrow.circlepath") {
                showsProfileHistory = true
            }
            .disabled(savedProfiles.isEmpty)
        } label: {
            Text(activeProfile?.displayName ?? "Profil Kalibrasi")
                .lineLimit(1)
        }
        .help("Pilih profil tersimpan atau impor profil dari file")
    }

    private var activeProfile: SavedCalibrationProfile? {
        savedProfiles.first { $0.id == activeProfileID }
    }

    private var canSaveProfile: Bool {
        session.allCalibrated && (session.usesScaledCanvas || session.floorPlanURL != nil)
    }

    private var canvases: some View {
        let camera = selectedCamera
        let calibration = camera?.calibration
        return HStack(spacing: Space.m * scale) {
            CalibrationCanvas(
                title: "Frame CCTV — \(camera?.label ?? "")",
                subtitle: isLoadingFrame ? "Memuat frame…" : "Klik titik lantai, lalu klik pasangan yang sama di denah.",
                image: cameraFrameImage,
                sourceSize: camera?.framePixelSize?.cgSize,
                points: camera?.imagePoints ?? [],
                projectedPoints: [],
                accent: Theme.accent,
                canInteract: cameraFrameImage != nil,
                canvasAccessory: nil,
                footerAccessory: nil,
                emptyState: AnyView(
                    ContentUnavailableView(
                        "Frame belum tersedia",
                        systemImage: "video.slash",
                        description: Text("Pilih video pada langkah Import atau tunggu frame dimuat.")
                    )
                ),
                onAdd: { addCameraPoint($0) },
                onDeletePair: { deletePair(at: $0) }
            )
            CalibrationCanvas(
                title: session.usesScaledCanvas ? "Canvas Berskala" : (session.floorPlanName ?? "Floor Plan"),
                subtitle: "Seluruh gambar dipetakan ke \(session.widthM) × \(session.heightM) m.",
                image: session.usesScaledCanvas ? nil : floorPlanImage,
                sourceSize: session.usesScaledCanvas ? nil : session.floorPlanPixelSize?.cgSize,
                points: camera?.planePoints ?? [],
                projectedPoints: validationPoints(calibration),
                accent: .orange,
                canInteract: session.usesScaledCanvas || floorPlanImage != nil,
                canvasAccessory: floorPlanCanvasAction,
                footerAccessory: AnyView(floorSourcePicker),
                emptyState: AnyView(
                    ContentUnavailableView(
                        "Floor plan belum tersedia",
                        systemImage: "photo.badge.plus",
                        description: Text("Klik Upload untuk memilih gambar atau PDF floor plan.")
                    )
                ),
                onAdd: { addPlanePoint($0) },
                onDeletePair: { deletePair(at: $0) }
            )
        }
    }

    private var inspector: some View {
        let camera = selectedCamera
        let calibration = camera?.calibration
        return ViewThatFits(in: .horizontal) {
            regularInspector(camera: camera, calibration: calibration)
                .frame(minWidth: 920)
            compactInspector(camera: camera, calibration: calibration)
        }
    }

    private func regularInspector(camera: SessionCamera?, calibration: CameraCalibration?) -> some View {
        HStack(alignment: .top, spacing: Space.m * scale) {
            referenceFramePanel(camera, height: panelHeight(172))
            pointPairsPanel(camera, height: panelHeight(172))
            validationPanel(calibration, height: panelHeight(172))
            cameraStatusPanel(height: panelHeight(172))
        }
    }

    private func compactInspector(camera: SessionCamera?, calibration: CameraCalibration?) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: Space.m * scale), GridItem(.flexible())],
            alignment: .leading,
            spacing: Space.m * scale
        ) {
            referenceFramePanel(camera, height: panelHeight(164))
            pointPairsPanel(camera, height: panelHeight(164))
            validationPanel(calibration, height: panelHeight(164))
            cameraStatusPanel(height: panelHeight(164))
        }
    }

    private func referenceFramePanel(_ camera: SessionCamera?, height: CGFloat) -> some View {
        inspectorPanel(height: height) {
            VStack(alignment: .leading, spacing: Space.s) {
                FieldLabel(text: "Frame Referensi")
                if let camera {
                    let range = referenceRange(for: camera)
                    Slider(
                        value: Binding(
                            get: { clamp(session.cameras[selectedIndex].referenceFrameSeconds, to: range) },
                            set: { value in
                                session.cameras[selectedIndex].referenceFrameSeconds = clamp(value, to: range)
                                invalidateCalibration(for: selectedIndex)
                                reloadToken = UUID()
                            }
                    ),
                    in: range
                )
                    HStack {
                        Text(timecode(clamp(session.cameras[selectedIndex].referenceFrameSeconds, to: range)))
                        Spacer()
                        Text("\(timecode(range.lowerBound)) – \(timecode(range.upperBound))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pointPairsPanel(_ camera: SessionCamera?, height: CGFloat) -> some View {
        inspectorPanel(height: height) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    FieldLabel(text: "Pasangan Titik")
                    Spacer()
                    Text("\(camera?.imagePoints.count ?? 0)/8")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                pointActionButton("Reset Kamera", systemImage: "arrow.counterclockwise", enabled: canUndoCameraPoint) {
                    resetSelectedCamera()
                }
                pointActionButton("Undo CCTV", systemImage: "arrow.uturn.backward", enabled: canUndoCameraPoint) {
                    undoCameraPoint()
                }
                pointActionButton("Undo Floor plan", systemImage: "arrow.uturn.backward", enabled: canUndoFloorPlanPoint) {
                    undoFloorPlanPoint()
                }
            }
        }
    }

    private func pointActionButton(
        _ title: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.s)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.42)
    }

    private func validationPanel(_ calibration: CameraCalibration?, height: CGFloat) -> some View {
        inspectorPanel(height: height) { metricContent(calibration) }
    }

    private func cameraStatusPanel(height: CGFloat) -> some View {
        inspectorPanel(height: height) {
            VStack(alignment: .leading, spacing: Space.s) {
                FieldLabel(text: "Status Kamera")
                ForEach(session.cameras) { item in
                    HStack(spacing: Space.s) {
                        Image(systemName: item.isCalibrated ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isCalibrated ? .green : .secondary)
                        Text(item.label).font(.callout).lineLimit(1)
                        Spacer()
                    }
                }
            }
        }
    }

    private func panelHeight(_ base: CGFloat) -> CGFloat {
        min(base * scale, base + 16)
    }

    private func inspectorPanel<Content: View>(height: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .card(padding: Space.m)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }

    @ViewBuilder
    private func metricContent(_ calibration: CameraCalibration?) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            FieldLabel(text: "Validasi")
            if let calibration {
                metric("Median", String(format: "%.3f m", calibration.metrics.medianErrorM))
                metric("P95", String(format: "%.3f m", calibration.metrics.p95ErrorM))
                metric("Inlier", "\(calibration.metrics.inliers)/\(calibration.metrics.points)")
            } else {
                Text("Tambahkan minimal empat pasangan titik untuk menghitung homografi.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospacedDigit().weight(.medium))
        }
    }

    private func addCameraPoint(_ point: CGPoint) {
        guard session.cameras.indices.contains(selectedIndex) else { return }
        let camera = session.cameras[selectedIndex]
        guard camera.imagePoints.count < HomographySolver.maximumPoints else {
            message = "Gagal: maksimum 8 pasangan titik per kamera."; return
        }
        guard camera.imagePoints.count == camera.planePoints.count else {
            message = "Klik pasangan titik di denah terlebih dahulu."; return
        }
        session.cameras[selectedIndex].imagePoints.append(NormPoint(x: point.x, y: point.y))
        invalidateCalibration(for: selectedIndex)
        message = "Titik CCTV \(camera.imagePoints.count + 1) ditambahkan. Klik pasangan yang sama di denah."
    }

    private func addPlanePoint(_ point: CGPoint) {
        guard session.cameras.indices.contains(selectedIndex) else { return }
        let camera = session.cameras[selectedIndex]
        guard camera.planePoints.count < camera.imagePoints.count else {
            message = "Mulai pasangan baru dengan klik titik pada CCTV."; return
        }
        session.cameras[selectedIndex].planePoints.append(NormPoint(x: point.x, y: point.y))
        recalculateSelectedCamera()
    }

    private func deletePair(at index: Int) {
        guard session.cameras.indices.contains(selectedIndex) else { return }
        guard session.cameras[selectedIndex].imagePoints.indices.contains(index),
              session.cameras[selectedIndex].planePoints.indices.contains(index) else { return }
        session.cameras[selectedIndex].imagePoints.remove(at: index)
        session.cameras[selectedIndex].planePoints.remove(at: index)
        invalidateCalibration(for: selectedIndex)
        recalculateSelectedCamera()
    }

    private func resetSelectedCamera() {
        guard session.cameras.indices.contains(selectedIndex) else { return }
        session.cameras[selectedIndex].imagePoints = []
        session.cameras[selectedIndex].planePoints = []
        invalidateCalibration(for: selectedIndex)
        message = "Titik \(session.cameras[selectedIndex].label) direset."
    }

    private var canUndoCameraPoint: Bool {
        guard session.cameras.indices.contains(selectedIndex) else { return false }
        return !session.cameras[selectedIndex].imagePoints.isEmpty
    }

    private var canUndoFloorPlanPoint: Bool {
        guard session.cameras.indices.contains(selectedIndex) else { return false }
        let camera = session.cameras[selectedIndex]
        return !camera.planePoints.isEmpty && camera.imagePoints.count == camera.planePoints.count
    }

    private func undoCameraPoint() {
        guard session.cameras.indices.contains(selectedIndex) else { return }
        let imageCount = session.cameras[selectedIndex].imagePoints.count
        let floorCount = session.cameras[selectedIndex].planePoints.count
        guard imageCount > 0 else { return }

        session.cameras[selectedIndex].imagePoints.removeLast()
        if imageCount == floorCount {
            session.cameras[selectedIndex].planePoints.removeLast()
        }
        invalidateCalibration(for: selectedIndex)
        recalculateSelectedCamera()
        message = "Titik CCTV terakhir dihapus."
    }

    private func undoFloorPlanPoint() {
        guard canUndoFloorPlanPoint else { return }
        session.cameras[selectedIndex].planePoints.removeLast()
        invalidateCalibration(for: selectedIndex)
        message = "Titik floor plan terakhir dihapus. Pilih titik penggantinya di denah."
    }

    private func invalidateCalibration(for index: Int) {
        guard session.cameras.indices.contains(index) else { return }
        session.cameras[index].calibration = nil
        activeProfileID = nil
    }

    private func referenceRange(for camera: SessionCamera) -> ClosedRange<Double> {
        let upperLimit = max(0, camera.durationSec)
        let lower = min(max(0, session.trimStartSec), upperLimit)
        let requestedUpper = session.trimEndSec > lower ? session.trimEndSec : upperLimit
        let upper = min(max(lower, requestedUpper), upperLimit)
        return lower...upper
    }

    private func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    private func constrainReferenceFramesToTrim() {
        for index in session.cameras.indices {
            session.cameras[index].referenceFrameSeconds = clamp(
                session.cameras[index].referenceFrameSeconds,
                to: referenceRange(for: session.cameras[index])
            )
        }
    }

    private func recalculateSelectedCamera() {
        guard session.cameras.indices.contains(selectedIndex) else { return }
        let camera = session.cameras[selectedIndex]
        guard camera.imagePoints.count == camera.planePoints.count else { return }
        guard camera.imagePoints.count >= HomographySolver.minimumPoints else { return }
        guard let frameSize = camera.framePixelSize, frameSize.isValid else {
            message = "Gagal: frame CCTV belum dapat dibaca."; return
        }
        let cameraPoints = camera.imagePoints.map {
            CalibrationPoint(x: $0.x * frameSize.width, y: $0.y * frameSize.height)
        }
        let floorSize = session.calibrationFloorSize
        let floorPoints = camera.planePoints.map {
            CalibrationPoint(x: $0.x * floorSize.width, y: $0.y * floorSize.height)
        }
        do {
            session.cameras[selectedIndex].calibration = try HomographySolver.calibrate(
                cameraPointsPx: cameraPoints,
                floorPointsPx: floorPoints,
                floorSize: floorSize,
                venueWidthM: session.venueWidthM,
                venueHeightM: session.venueHeightM
            )
            let metrics = session.cameras[selectedIndex].calibration?.metrics
            message = "Kalibrasi valid: \(metrics?.inliers ?? 0)/\(metrics?.points ?? 0) inlier."
        } catch {
            session.cameras[selectedIndex].calibration = nil
            message = "Gagal: \(error.localizedDescription)"
        }
    }

    private func validationPoints(_ calibration: CameraCalibration?) -> [ValidationPoint] {
        guard let calibration else { return [] }
        let floorSize = session.calibrationFloorSize
        return calibration.projectedFloorPointsPx.enumerated().map { index, point in
            ValidationPoint(
                point: CGPoint(x: point.x / floorSize.width, y: point.y / floorSize.height),
                isInlier: calibration.inlierMask.indices.contains(index) ? calibration.inlierMask[index] : false
            )
        }
    }

    private func chooseFloorPlan() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .pdf, .image]
        guard panel.runModal() == .OK, let url = panel.url, let image = loadFloorPlanImage(url) else { return }
        floorPlanImage = image
        session.floorPlanURL = url
        session.floorPlanName = url.lastPathComponent
        session.floorPlanPixelSize = pixelSize(of: image)
        session.usesScaledCanvas = false
        invalidateAllCalibrations()
        message = "Denah diperbarui. Kalibrasi tiap kamera perlu dihitung ulang."
    }

    private var floorSourcePicker: some View {
        HStack(spacing: Space.s) {
            floorSourceRadio(title: "Canvas", selected: session.usesScaledCanvas) {
                selectScaledCanvas()
            }
            floorSourceRadio(title: "Floor plan", selected: !session.usesScaledCanvas) {
                selectFloorPlan()
            }
        }
        .font(.caption.weight(.medium))
    }

    private func floorSourceRadio(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                Text(title).foregroundStyle(selected ? Color.primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Gunakan \(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func selectScaledCanvas() {
        guard !session.usesScaledCanvas else { return }
        session.usesScaledCanvas = true
        invalidateAllCalibrations()
        message = "Menggunakan Canvas Berskala. Kalibrasi tiap kamera perlu dihitung ulang."
    }

    private func selectFloorPlan() {
        guard session.usesScaledCanvas else { return }
        session.usesScaledCanvas = false
        invalidateAllCalibrations()
        if session.floorPlanURL == nil {
            message = "Unggah floor plan untuk mulai memberi titik pada denah."
        } else {
            message = "Menggunakan floor plan tersimpan. Kalibrasi tiap kamera perlu dihitung ulang."
        }
    }

    private var floorPlanCanvasAction: AnyView? {
        guard !session.usesScaledCanvas else { return nil }
        let hasFloorPlan = floorPlanImage != nil
        return AnyView(
            Button(hasFloorPlan ? "Update" : "Upload", systemImage: hasFloorPlan ? "arrow.triangle.2.circlepath" : "photo") {
                chooseFloorPlan()
            }
            .buttonStyle(.bordered)
        )
    }

    private func saveProfile() {
        do {
            let saved = try CalibrationProfileLibrary.save(session: session)
            reloadProfileHistory()
            activeProfileID = saved.id
            message = "Profil \(saved.displayName) disimpan ke riwayat."
        } catch {
            message = "Gagal: \(error.localizedDescription)"
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.json, .foodcourtCalibrationProfile]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try CalibrationProfileLibrary.inspectImport(at: url)
            var attachedFloorPlanURL: URL?
            if !imported.profile.floorplan.usesCanvas, imported.floorPlanURL == nil {
                attachedFloorPlanURL = try chooseLegacyFloorPlan(for: imported.profile)
            }
            guard confirmProfileReplacement() else { return }
            let saved = try CalibrationProfileLibrary.importProfile(
                imported,
                attachedFloorPlanURL: attachedFloorPlanURL
            )
            reloadProfileHistory()
            applySavedProfile(saved)
        } catch {
            message = "Gagal: \(error.localizedDescription)"
        }
    }

    private func loadSavedProfile(_ profile: SavedCalibrationProfile) {
        guard activeProfileID != profile.id else { return }
        guard confirmProfileReplacement() else { return }
        applySavedProfile(profile)
    }

    private func applySavedProfile(_ profile: SavedCalibrationProfile) {
        do {
            let loaded = try CalibrationProfileLibrary.load(profile)
            let validCount = try CalibrationProfileStore.apply(
                loaded.profile,
                floorPlanURL: loaded.floorPlanURL,
                to: session
            )
            activeProfileID = profile.id
            reloadToken = UUID()
            message = validCount == session.cameras.count
                ? "Semua kamera valid (\(validCount)/\(session.cameras.count)). Periksa kembali titik bila video berubah."
                : "\(validCount)/\(session.cameras.count) kamera valid."
        } catch {
            message = "Gagal: \(error.localizedDescription)"
        }
    }

    private func exportProfile(_ profile: SavedCalibrationProfile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.foodcourtCalibrationProfile]
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = safeFileName(profile.displayName) + ".\(CalibrationProfileLibrary.packageExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CalibrationProfileLibrary.export(profile, to: url)
            message = "Profil diekspor ke \(url.lastPathComponent)."
        } catch {
            message = "Gagal: \(error.localizedDescription)"
        }
    }

    private func deleteProfile(_ profile: SavedCalibrationProfile) {
        do {
            let wasActive = activeProfileID == profile.id
            let detachedFloorPlanURL = wasActive
                ? try CalibrationProfileLibrary.detachedFloorPlanCopy(for: profile)
                : nil
            try CalibrationProfileLibrary.delete(profile)
            if wasActive {
                if detachedFloorPlanURL != nil { session.floorPlanURL = detachedFloorPlanURL }
                activeProfileID = nil
            }
            reloadProfileHistory()
            message = "Profil \(profile.displayName) dihapus dari riwayat."
        } catch {
            message = "Gagal: \(error.localizedDescription)"
        }
    }

    private func reloadProfileHistory() {
        do {
            savedProfiles = try CalibrationProfileLibrary.list()
            if let activeProfileID, !savedProfiles.contains(where: { $0.id == activeProfileID }) {
                self.activeProfileID = nil
            }
        } catch {
            savedProfiles = []
            message = "Gagal memuat riwayat: \(error.localizedDescription)"
        }
    }

    private func chooseLegacyFloorPlan(for profile: CalibrationProfile) throws -> URL {
        let panel = NSOpenPanel()
        panel.message = "Pilih floor plan yang digunakan saat profil ini dibuat."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .pdf, .image]
        guard panel.runModal() == .OK, let url = panel.url else {
            throw CalibrationProfileLibraryError.missingFloorPlan
        }
        guard let image = loadFloorPlanImage(url) else { throw CalibrationError.invalidImageSize }
        let selectedSize = pixelSize(of: image)
        let expected = profile.floorplan.pixelSize
        guard abs(selectedSize.width - expected.width) <= 1,
              abs(selectedSize.height - expected.height) <= 1 else {
            throw CalibrationError.cameraMismatch("ukuran floor plan berbeda dari profil")
        }
        return url
    }

    private func confirmProfileReplacement() -> Bool {
        let hasCalibrationWork = session.cameras.contains {
            !$0.imagePoints.isEmpty || !$0.planePoints.isEmpty || $0.calibration != nil
        }
        guard hasCalibrationWork else { return true }
        let alert = NSAlert()
        alert.messageText = "Ganti kalibrasi saat ini?"
        alert.informativeText = "Titik dan hasil kalibrasi yang sedang tampil akan diganti oleh profil yang dipilih."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Ganti Profil")
        alert.addButton(withTitle: "Batal")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func safeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        return value.components(separatedBy: invalid).joined(separator: "-")
    }

    private func invalidateAllCalibrations() {
        for index in session.cameras.indices { session.cameras[index].calibration = nil }
        activeProfileID = nil
    }

    @MainActor
    private func refreshImages() async {
        constrainReferenceFramesToTrim()
        if let url = session.floorPlanURL { floorPlanImage = loadFloorPlanImage(url) }
        else { floorPlanImage = nil }
        guard let camera = selectedCamera, let url = camera.url else {
            cameraFrameImage = nil; return
        }
        isLoadingFrame = true
        let expectedID = camera.id
        let image = await VideoFrameLoader.image(url: url, at: camera.referenceFrameSeconds)
        guard selectedCamera?.id == expectedID else { return }
        cameraFrameImage = image
        if let image {
            let size = pixelSize(of: image)
            if size.isValid { session.cameras[selectedIndex].framePixelSize = size }
        }
        isLoadingFrame = false
    }

    private func loadFloorPlanImage(_ url: URL) -> NSImage? {
        if url.pathExtension.lowercased() == "pdf", let page = PDFDocument(url: url)?.page(at: 0) {
            return page.thumbnail(of: NSSize(width: 2400, height: 2400), for: .mediaBox)
        }
        return NSImage(contentsOf: url)
    }

    private func pixelSize(of image: NSImage) -> PixelSize {
        if let rep = image.representations.first(where: { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }) {
            return PixelSize(width: Double(rep.pixelsWide), height: Double(rep.pixelsHigh))
        }
        return PixelSize(image.size)
    }
}

private struct CalibrationProfileHistorySheet: View {
    let profiles: [SavedCalibrationProfile]
    let activeProfileID: UUID?
    let onLoad: (SavedCalibrationProfile) -> Void
    let onExport: (SavedCalibrationProfile) -> Void
    let onDelete: (SavedCalibrationProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var deletionCandidate: SavedCalibrationProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Riwayat Kalibrasi").font(.title2.bold())
                    Text("Semua snapshot disimpan lokal bersama floor plan-nya.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Selesai") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if profiles.isEmpty {
                ContentUnavailableView(
                    "Belum Ada Profil",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Profil yang disimpan akan muncul di sini.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(profiles) { profile in
                    HStack(spacing: Space.m) {
                        Image(systemName: profile.usesCanvas ? "square.grid.3x3" : "photo")
                            .frame(width: 24)
                            .foregroundStyle(activeProfileID == profile.id ? Theme.accent : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Space.xs) {
                                Text(profile.displayName).font(.headline).lineLimit(1)
                                if activeProfileID == profile.id {
                                    Text("Aktif")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            Text("\(profile.cameraCount) kamera • \(profile.sourceName) • \(profile.savedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Muat") {
                            dismiss()
                            DispatchQueue.main.async { onLoad(profile) }
                        }
                        .buttonStyle(.bordered)
                        Button {
                            onExport(profile)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .help("Ekspor profil")
                        Button(role: .destructive) {
                            deletionCandidate = profile
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Hapus profil")
                    }
                    .padding(.vertical, Space.xs)
                }
            }
        }
        .padding(Space.l)
        .frame(minWidth: 720, minHeight: 430)
        .alert(
            "Hapus profil kalibrasi?",
            isPresented: Binding(
                get: { deletionCandidate != nil },
                set: { if !$0 { deletionCandidate = nil } }
            ),
            presenting: deletionCandidate
        ) { profile in
            Button("Hapus", role: .destructive) {
                onDelete(profile)
                deletionCandidate = nil
            }
            Button("Batal", role: .cancel) { deletionCandidate = nil }
        } message: { profile in
            Text("\(profile.displayName) dan salinan floor plan-nya akan dihapus dari riwayat.")
        }
    }
}

private extension UTType {
    static let foodcourtCalibrationProfile = UTType(
        exportedAs: "com.tiara.foodcourt.calibration-profile",
        conformingTo: .package
    )
}

private enum VideoFrameLoader {
    static func image(url: URL, at seconds: Double) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
            guard let frame = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
            return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
        }.value
    }
}

private struct ValidationPoint: Identifiable {
    let id = UUID()
    let point: CGPoint
    let isInlier: Bool
}

private struct CalibrationCanvas: View {
    let title: String
    let subtitle: String
    let image: NSImage?
    let sourceSize: CGSize?
    let points: [NormPoint]
    let projectedPoints: [ValidationPoint]
    let accent: Color
    let canInteract: Bool
    let canvasAccessory: AnyView?
    let footerAccessory: AnyView?
    let emptyState: AnyView?
    let onAdd: (CGPoint) -> Void
    let onDeletePair: (Int) -> Void

    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var basePan: CGSize = .zero
    @State private var hoveredIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            GeometryReader { geo in
                let rect = fittedRect(in: geo.size)
                ZStack {
                    scene(size: rect.size)
                        .frame(width: rect.width, height: rect.height)
                        .scaleEffect(zoom)
                        .offset(pan)
                        .position(x: rect.midX, y: rect.midY)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(interactionGesture(rect: rect))
                .simultaneousGesture(magnifyGesture(rect: rect))
                .overlay(alignment: .bottomTrailing) {
                    controls(rect: rect).padding(Space.s)
                }
                .overlay(alignment: .topTrailing) {
                    canvasAccessory?.padding(Space.s)
                }
                .overlay(alignment: .bottomLeading) {
                    footerAccessory?.padding(Space.s)
                }
                .overlay {
                    if !canInteract, let emptyState { emptyState }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    @ViewBuilder
    private func scene(size: CGSize) -> some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                ZStack {
                    Color.primary.opacity(0.035)
                    GridBackground()
                }
            }
            if points.count >= 2 {
                Path { path in
                    let values = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                    path.addLines(values)
                }
                .stroke(accent.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                PointMarker(number: index + 1, color: accent, deleteMode: hoveredIndex == index)
                    .position(x: point.x * size.width, y: point.y * size.height)
                    .onHover { hoveredIndex = $0 ? index : nil }
            }
            ForEach(Array(projectedPoints.enumerated()), id: \.element.id) { index, point in
                ProjectedMarker(number: index + 1, isInlier: point.isInlier)
                    .position(x: point.point.x * size.width, y: point.point.y * size.height)
            }
        }
        .clipShape(Rectangle())
    }

    private func interactionGesture(rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard canInteract else { return }
                let distance = hypot(value.translation.width, value.translation.height)
                if distance > 6, zoom > 1 {
                    pan = clampedPan(CGSize(width: basePan.width + value.translation.width, height: basePan.height + value.translation.height), rect: rect)
                }
            }
            .onEnded { value in
                guard canInteract else { return }
                let distance = hypot(value.translation.width, value.translation.height)
                if distance > 6, zoom > 1 { basePan = pan; return }
                guard let normalized = normalizedPoint(value.location, in: rect) else { return }
                if let index = nearestPoint(to: normalized, in: rect) { onDeletePair(index) }
                else { onAdd(normalized) }
            }
    }

    private func magnifyGesture(rect: CGRect) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = min(5, max(1, baseZoom * value.magnification))
                pan = clampedPan(pan, rect: rect)
            }
            .onEnded { _ in
                baseZoom = zoom
                if zoom == 1 { pan = .zero; basePan = .zero } else { basePan = pan }
            }
    }

    private func controls(rect: CGRect) -> some View {
        HStack(spacing: Space.s) {
            Button { setZoom(zoom - 0.5, rect: rect) } label: { Image(systemName: "minus") }
            Text("\(Int((zoom * 100).rounded()))%")
                .font(.caption.monospacedDigit()).frame(width: 38)
            Button { setZoom(zoom + 0.5, rect: rect) } label: { Image(systemName: "plus") }
            Button {
                zoom = 1; baseZoom = 1; pan = .zero; basePan = .zero
            } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Space.s)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }

    private func fittedRect(in container: CGSize) -> CGRect {
        let source = sourceSize ?? CGSize(width: 4, height: 3)
        guard source.width > 0, source.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let factor = min(container.width / source.width, container.height / source.height)
        let size = CGSize(width: source.width * factor, height: source.height * factor)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func normalizedPoint(_ point: CGPoint, in rect: CGRect) -> CGPoint? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = ((point.x - rect.midX - pan.width) / zoom) + rect.midX
        let y = ((point.y - rect.midY - pan.height) / zoom) + rect.midY
        guard rect.contains(CGPoint(x: x, y: y)) else { return nil }
        return CGPoint(x: (x - rect.minX) / rect.width, y: (y - rect.minY) / rect.height)
    }

    private func nearestPoint(to point: CGPoint, in rect: CGRect) -> Int? {
        let hitRadius = 15 / max(zoom, 1)
        return points.indices.min { first, second in
            let firstDistance = hypot((points[first].x - point.x) * rect.width, (points[first].y - point.y) * rect.height)
            let secondDistance = hypot((points[second].x - point.x) * rect.width, (points[second].y - point.y) * rect.height)
            return firstDistance < secondDistance
        }.flatMap { index in
            let distance = hypot((points[index].x - point.x) * rect.width, (points[index].y - point.y) * rect.height)
            return distance <= hitRadius ? index : nil
        }
    }

    private func clampedPan(_ value: CGSize, rect: CGRect) -> CGSize {
        let maxX = rect.width * (zoom - 1) / 2
        let maxY = rect.height * (zoom - 1) / 2
        return CGSize(width: min(max(value.width, -maxX), maxX), height: min(max(value.height, -maxY), maxY))
    }

    private func setZoom(_ value: CGFloat, rect: CGRect) {
        zoom = min(5, max(1, value)); baseZoom = zoom
        pan = clampedPan(pan, rect: rect); basePan = pan
    }
}

private struct PointMarker: View {
    let number: Int
    let color: Color
    let deleteMode: Bool

    var body: some View {
        ZStack {
            Circle().fill(deleteMode ? Color.red : color).frame(width: deleteMode ? 26 : 22, height: deleteMode ? 26 : 22)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
            if deleteMode { Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.white) }
            else { Text("\(number)").font(.caption2.bold()).foregroundStyle(.white) }
        }
        .shadow(radius: 1)
        .help("Klik untuk menghapus pasangan titik \(number)")
    }
}

private struct ProjectedMarker: View {
    let number: Int
    let isInlier: Bool

    var body: some View {
        ZStack {
            Circle().strokeBorder(isInlier ? .green : .red, lineWidth: 2).frame(width: 18, height: 18)
            Path { path in
                path.move(to: CGPoint(x: -7, y: 0)); path.addLine(to: CGPoint(x: 7, y: 0))
                path.move(to: CGPoint(x: 0, y: -7)); path.addLine(to: CGPoint(x: 0, y: 7))
            }
            .stroke(isInlier ? .green : .red, lineWidth: 1.5)
            Text("\(number)").font(.system(size: 8, weight: .bold)).foregroundStyle(isInlier ? .green : .red).offset(y: -14)
        }
        .allowsHitTesting(false)
        .help(isInlier ? "Proyeksi inlier" : "Proyeksi outlier")
    }
}

private struct GridBackground: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for index in 0...10 {
                let x = size.width * CGFloat(index) / 10
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for index in 0...8 {
                let y = size.height * CGFloat(index) / 8
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.secondary.opacity(0.16)), lineWidth: 1)
        }
    }
}
