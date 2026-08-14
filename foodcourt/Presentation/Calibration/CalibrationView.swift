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
    @Environment(Sidecar.self) private var sidecar

    @State private var selectedCameraIndex = 0
    @State private var floorPlanImage: NSImage?
    @State private var cameraFrameImage: NSImage?
    @State private var isLoadingFrame = false
    @State private var message: String?
    @State private var reloadToken = UUID()
    @State private var savedProfiles: [SavedCalibrationProfile] = []
    @State private var activeProfileID: UUID?
    @State private var showsProfileHistory = false
    @State private var showsCalibrationWarningConfirmation = false
    @State private var personPreview: CalibrationPreviewResponseDTO?
    @State private var personPreviewToken: String?
    @State private var personDetectionRefreshToken = UUID()
    @State private var personDetectionRequestID = UUID()
    @State private var isDetectingPerson = false
    @State private var personDetectionError: String?

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
            await refreshPersonDetection(forceSample: true)
        }
        .task(id: personDetectionRefreshToken) {
            await refreshPersonDetection(forceSample: false)
        }
        .task { reloadProfileHistory() }
        .onChange(of: selectedCameraIndex) { _, _ in
            resetPersonDetectionCache()
            reloadToken = UUID()
        }
        .sheet(isPresented: $showsProfileHistory) {
            CalibrationProfileHistorySheet(
                profiles: savedProfiles,
                activeProfileID: activeProfileID,
                onLoad: { loadSavedProfile($0) },
                onExport: { exportProfile($0) },
                onDelete: { deleteProfile($0) }
            )
        }
        .alert("Calibration has warnings", isPresented: $showsCalibrationWarningConfirmation) {
            Button("Continue") { router.next() }
            Button("Check Again", role: .cancel) {}
        } message: {
            Text(calibrationWarningText)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "camera.metering.none")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No cameras yet").font(.headline)
            Text("Import a video in the previous step first.")
                .font(.callout)
                .foregroundStyle(.secondary)
            GhostButton(title: "Go to Import", systemImage: "chevron.left") { router.back() }
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

                    if session.allCalibrated {
                        TableAnnotationEditor(
                            image: session.usesScaledCanvas ? nil : floorPlanImage,
                            sourceSize: session.usesScaledCanvas ? nil : session.floorPlanPixelSize?.cgSize
                        )
                        .frame(minHeight: 390 * scale)
                    }
                }
                .spad(Space.xl, [.horizontal, .top])
                .padding(.bottom, Space.xl)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            WizardFooter(onBack: { router.back() }) {
                PrimaryButton(
                    title: session.allCalibrated ? "Calibration Done" : "Calibrate All Cameras",
                    systemImage: "checkmark.seal",
                    enabled: session.allCalibrated
                ) {
                    continueAfterCalibration()
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.m * scale) {
            SectionHeader(
                title: "Calibration",
                subtitle: "Pick the same floor points on the CCTV frame and the floor plan. Use 4–8 free point pairs."
            )
            HStack(spacing: Space.s) {
                ForEach(Array(session.cameras.enumerated()), id: \.element.id) { index, camera in
                    Button {
                        selectedCameraIndex = index
                    } label: {
                        HStack(spacing: Space.s) {
                            let quality = camera.calibration?.quality ?? .invalid
                            Image(systemName: quality == .good ? "checkmark.circle.fill" : (quality == .warning ? "exclamationmark.triangle.fill" : "camera"))
                                .foregroundStyle(index == selectedIndex ? .white : calibrationQualityColor(quality))
                            Text(camera.label)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, Space.m)
                        .padding(.vertical, Space.s)
                        .foregroundStyle(index == selectedIndex ? Theme.onAccent : Color.primary)
                        .background(index == selectedIndex ? Theme.accentFill : Color.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select \(camera.label)")
                }
                Spacer()
                profileMenu
                    .buttonStyle(.bordered)
                Button("Save Profile", systemImage: "tray.and.arrow.down") { saveProfile() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSaveProfile)
            }
        }
    }

    private var profileMenu: some View {
        Menu {
            if savedProfiles.isEmpty {
                Text("No saved profiles yet")
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
            Button("Import from File…", systemImage: "square.and.arrow.down") { importProfile() }
            Button("Export Selected Profile…", systemImage: "square.and.arrow.up") {
                if let profile = activeProfile { exportProfile(profile) }
            }
            .disabled(activeProfile == nil)
            Button("Manage History…", systemImage: "clock.arrow.circlepath") {
                showsProfileHistory = true
            }
            .disabled(savedProfiles.isEmpty)
        } label: {
            Text(activeProfile?.displayName ?? "Calibration Profile")
                .lineLimit(1)
        }
        .help("Choose a saved profile or import one from a file")
    }

    private var activeProfile: SavedCalibrationProfile? {
        savedProfiles.first { $0.id == activeProfileID }
    }

    private var canSaveProfile: Bool {
        session.allCalibrated && (session.usesScaledCanvas || session.floorPlanURL != nil)
    }

    private var calibrationWarningText: String {
        session.cameras.compactMap { camera in
            guard let calibration = camera.calibration,
                  calibration.quality == .warning else { return nil }
            return "\(camera.label): \(calibration.qualityWarnings.joined(separator: " "))"
        }.joined(separator: "\n")
    }

    private func continueAfterCalibration() {
        guard session.allCalibrated else { return }
        if calibrationWarningText.isEmpty {
            router.next()
        } else {
            showsCalibrationWarningConfirmation = true
        }
    }

    private var canvases: some View {
        let camera = selectedCamera
        let calibration = camera?.calibration
        return HStack(spacing: Space.m * scale) {
            CalibrationCanvas(
                title: "CCTV Frame — \(camera?.label ?? "")",
                subtitle: cameraDetectionSubtitle,
                image: cameraFrameImage,
                sourceSize: camera?.framePixelSize?.cgSize,
                points: camera?.imagePoints ?? [],
                projectedPoints: [],
                detectionMarkers: cameraDetectionMarkers,
                accent: Theme.accent,
                canInteract: cameraFrameImage != nil,
                canvasAccessory: personDetectionAccessory,
                footerAccessory: nil,
                emptyState: AnyView(
                    ContentUnavailableView(
                        "Frame not available yet",
                        systemImage: "video.slash",
                        description: Text("Select a video in the Import step or wait for the frame to load.")
                    )
                ),
                onAdd: { addCameraPoint($0) },
                onMovePoint: { index, point, isFinal in
                    moveCameraPoint(at: index, to: point, isFinal: isFinal)
                },
                onDeletePair: { deletePair(at: $0) }
            )
            CalibrationCanvas(
                title: session.usesScaledCanvas ? "Scaled Canvas" : (session.floorPlanName ?? "Floor Plan"),
                subtitle: floorDetectionSubtitle,
                image: session.usesScaledCanvas ? nil : floorPlanImage,
                sourceSize: session.usesScaledCanvas ? nil : session.floorPlanPixelSize?.cgSize,
                points: camera?.planePoints ?? [],
                projectedPoints: validationPoints(calibration),
                detectionMarkers: floorDetectionMarkers,
                accent: .orange,
                canInteract: session.usesScaledCanvas || floorPlanImage != nil,
                canvasAccessory: floorPlanCanvasAction,
                footerAccessory: AnyView(floorSourcePicker),
                emptyState: AnyView(
                    ContentUnavailableView(
                        "Floor plan not available yet",
                        systemImage: "photo.badge.plus",
                        description: Text("Click Upload to choose a floor plan image or PDF.")
                    )
                ),
                onAdd: { addPlanePoint($0) },
                onMovePoint: { index, point, isFinal in
                    movePlanePoint(at: index, to: point, isFinal: isFinal)
                },
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
                FieldLabel(text: "Reference Frame")
                if let camera {
                    let range = referenceRange(for: camera)
                    Slider(
                        value: Binding(
                            get: { clamp(session.cameras[selectedIndex].referenceFrameSeconds, to: range) },
                            set: { value in
                                session.cameras[selectedIndex].referenceFrameSeconds = clamp(value, to: range)
                                resetPersonDetectionCache()
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
                    FieldLabel(text: "Point Pairs")
                    Spacer()
                    Text("\(camera?.imagePoints.count ?? 0)/8")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                pointActionButton("Reset Camera", systemImage: "arrow.counterclockwise", enabled: canUndoCameraPoint) {
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
                FieldLabel(text: "Camera Status")
                ForEach(session.cameras) { item in
                    HStack(spacing: Space.s) {
                        let quality = item.calibration?.quality ?? .invalid
                        Image(systemName: quality == .good ? "checkmark.circle.fill" : (quality == .warning ? "exclamationmark.triangle.fill" : "xmark.circle"))
                            .foregroundStyle(calibrationQualityColor(quality))
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
            FieldLabel(text: "Validation")
            if let calibration {
                HStack {
                    Text("Status").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(calibration.quality.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(calibrationQualityColor(calibration.quality))
                }
                metric("Median", String(format: "%.3f m", calibration.metrics.medianErrorM))
                metric("P95", String(format: "%.3f m", calibration.metrics.p95ErrorM))
                metric("Inlier", "\(calibration.metrics.inliers)/\(calibration.metrics.points)")
            } else {
                Text("Add at least four point pairs to compute the homography.")
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

    private func calibrationQualityColor(_ quality: CalibrationQuality) -> Color {
        switch quality {
        case .good: return .green
        case .warning: return .orange
        case .invalid: return .red
        }
    }

    private func addCameraPoint(_ point: CGPoint) {
        guard session.cameras.indices.contains(selectedIndex) else { return }
        let camera = session.cameras[selectedIndex]
        guard camera.imagePoints.count < HomographySolver.maximumPoints else {
            message = "Failed: maximum of 8 point pairs per camera."; return
        }
        guard camera.imagePoints.count == camera.planePoints.count else {
            message = "Click the matching point on the floor plan first."; return
        }
        session.cameras[selectedIndex].imagePoints.append(NormPoint(x: point.x, y: point.y))
        invalidateCalibration(for: selectedIndex)
        message = "CCTV point \(camera.imagePoints.count + 1) added. Click the matching point on the floor plan."
    }

    private func addPlanePoint(_ point: CGPoint) {
        guard session.cameras.indices.contains(selectedIndex) else { return }
        let camera = session.cameras[selectedIndex]
        guard camera.planePoints.count < camera.imagePoints.count else {
            message = "Start a new pair by clicking a point on the CCTV frame."; return
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

    private func moveCameraPoint(at pointIndex: Int, to point: CGPoint, isFinal: Bool) {
        guard session.cameras.indices.contains(selectedIndex),
              session.cameras[selectedIndex].imagePoints.indices.contains(pointIndex) else { return }
        session.cameras[selectedIndex].imagePoints[pointIndex].x = point.x
        session.cameras[selectedIndex].imagePoints[pointIndex].y = point.y
        invalidateCalibration(for: selectedIndex)
        if isFinal {
            recalculateSelectedCamera()
            if session.cameras[selectedIndex].calibration?.isValid == true {
                message = "CCTV point \(pointIndex + 1) moved without changing its pair."
            }
        }
    }

    private func movePlanePoint(at pointIndex: Int, to point: CGPoint, isFinal: Bool) {
        guard session.cameras.indices.contains(selectedIndex),
              session.cameras[selectedIndex].planePoints.indices.contains(pointIndex) else { return }
        session.cameras[selectedIndex].planePoints[pointIndex].x = point.x
        session.cameras[selectedIndex].planePoints[pointIndex].y = point.y
        invalidateCalibration(for: selectedIndex)
        if isFinal {
            recalculateSelectedCamera()
            if session.cameras[selectedIndex].calibration?.isValid == true {
                message = "Floor plan point \(pointIndex + 1) moved without changing its pair."
            }
        }
    }

    private func resetSelectedCamera() {
        guard session.cameras.indices.contains(selectedIndex) else { return }
        session.cameras[selectedIndex].imagePoints = []
        session.cameras[selectedIndex].planePoints = []
        invalidateCalibration(for: selectedIndex)
        message = "Points for \(session.cameras[selectedIndex].label) were reset."
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
        message = "Last CCTV point removed."
    }

    private func undoFloorPlanPoint() {
        guard canUndoFloorPlanPoint else { return }
        session.cameras[selectedIndex].planePoints.removeLast()
        invalidateCalibration(for: selectedIndex)
        message = "Last floor plan point removed. Pick its replacement on the floor plan."
    }

    private func invalidateCalibration(for index: Int) {
        guard session.cameras.indices.contains(index) else { return }
        session.cameras[index].calibration = nil
        personPreview = nil
        personDetectionError = nil
        activeProfileID = nil
    }

    private func referenceRange(for camera: SessionCamera) -> ClosedRange<Double> {
        let sourceUpper = max(0, camera.durationSec - camera.timeOffsetSec)
        let offsetLower = max(0, -camera.timeOffsetSec)
        let lower = min(max(offsetLower, session.trimStartSec), sourceUpper)
        let requestedUpper = session.trimEndSec > lower ? session.trimEndSec : sourceUpper
        let upper = min(max(lower, requestedUpper), sourceUpper)
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
            message = "Failed: the CCTV frame cannot be read yet."; return
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
                venueHeightM: session.venueHeightM,
                cameraImageSize: frameSize
            )
            let metrics = session.cameras[selectedIndex].calibration?.metrics
            let quality = session.cameras[selectedIndex].calibration?.quality.rawValue ?? "Invalid"
            message = "Calibration \(quality): \(metrics?.inliers ?? 0)/\(metrics?.points ?? 0) inliers."
            personDetectionRefreshToken = UUID()
        } catch {
            session.cameras[selectedIndex].calibration = nil
            message = "Failed: \(error.localizedDescription)"
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
        message = "Floor plan updated. Every camera needs to be recalibrated."
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
        .accessibilityLabel("Use \(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func selectScaledCanvas() {
        guard !session.usesScaledCanvas else { return }
        session.usesScaledCanvas = true
        invalidateAllCalibrations()
        message = "Using the scaled canvas. Every camera needs to be recalibrated."
    }

    private func selectFloorPlan() {
        guard session.usesScaledCanvas else { return }
        session.usesScaledCanvas = false
        invalidateAllCalibrations()
        if session.floorPlanURL == nil {
            message = "Upload a floor plan to start placing points on it."
        } else {
            message = "Using the saved floor plan. Every camera needs to be recalibrated."
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
            message = "Profile \(saved.displayName) saved to history."
        } catch {
            message = "Failed: \(error.localizedDescription)"
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
            message = "Failed: \(error.localizedDescription)"
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
            resetPersonDetectionCache()
            reloadToken = UUID()
            message = validCount == session.cameras.count
                ? "All cameras are valid (\(validCount)/\(session.cameras.count)). Re-check the points if the footage changes."
                : "\(validCount)/\(session.cameras.count) cameras valid."
        } catch {
            message = "Failed: \(error.localizedDescription)"
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
            message = "Profile exported to \(url.lastPathComponent)."
        } catch {
            message = "Failed: \(error.localizedDescription)"
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
            message = "Profile \(profile.displayName) removed from history."
        } catch {
            message = "Failed: \(error.localizedDescription)"
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
            message = "Failed to load history: \(error.localizedDescription)"
        }
    }

    private func chooseLegacyFloorPlan(for profile: CalibrationProfile) throws -> URL {
        let panel = NSOpenPanel()
        panel.message = "Select the floor plan that was used when this profile was created."
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
            throw CalibrationError.cameraMismatch("floor plan size differs from the profile")
        }
        return url
    }

    private func confirmProfileReplacement() -> Bool {
        let hasCalibrationWork = session.cameras.contains {
            !$0.imagePoints.isEmpty || !$0.planePoints.isEmpty || $0.calibration != nil
        }
        guard hasCalibrationWork else { return true }
        let alert = NSAlert()
        alert.messageText = "Replace the current calibration?"
        alert.informativeText = "The points and calibration currently shown will be replaced by the selected profile."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace Profile")
        alert.addButton(withTitle: "Cancel")
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
        let sourceTime = camera.referenceFrameSeconds + camera.timeOffsetSec
        let image = await VideoFrameLoader.image(url: url, at: sourceTime)
        guard selectedCamera?.id == expectedID else { return }
        cameraFrameImage = image
        if let image {
            let size = pixelSize(of: image)
            if size.isValid { session.cameras[selectedIndex].framePixelSize = size }
        }
        isLoadingFrame = false
    }

    private var previewMarkers: [PreviewMarkerDTO] {
        guard let cameraID = selectedCamera?.id.uuidString else { return [] }
        return personPreview?.cameras.first(where: { $0.cameraId == cameraID })?.markers ?? []
    }

    private var cameraDetectionMarkers: [CalibrationDetectionMarker] {
        previewMarkers.compactMap { marker in
            guard marker.bboxNorm.count == 4 else { return nil }
            let rect = CGRect(
                x: marker.bboxNorm[0],
                y: marker.bboxNorm[1],
                width: marker.bboxNorm[2] - marker.bboxNorm[0],
                height: marker.bboxNorm[3] - marker.bboxNorm[1]
            )
            return CalibrationDetectionMarker(
                id: marker.id,
                label: marker.identityLabel,
                point: CGPoint(x: rect.midX, y: rect.maxY),
                bbox: rect,
                confidence: marker.confidence,
                isOutside: false
            )
        }
    }

    private var floorDetectionMarkers: [CalibrationDetectionMarker] {
        previewMarkers.map { marker in
            let rawX = marker.worldX / max(0.01, session.venueWidthM)
            let rawY = marker.worldY / max(0.01, session.venueHeightM)
            let outside = !(0...1).contains(rawX) || !(0...1).contains(rawY)
            return CalibrationDetectionMarker(
                id: marker.id,
                label: marker.identityLabel,
                point: CGPoint(
                    x: min(0.985, max(0.015, rawX)),
                    y: min(0.985, max(0.015, rawY))
                ),
                bbox: nil,
                confidence: marker.confidence,
                isOutside: outside
            )
        }
    }

    private var cameraDetectionSubtitle: String {
        if isLoadingFrame { return "Loading frame…" }
        if isDetectingPerson { return "Running person detection on this frame…" }
        if let personDetectionError { return personDetectionError }
        if personPreview != nil {
            return previewMarkers.isEmpty
                ? "No people detected. Click the frame to continue calibrating."
                : "\(previewMarkers.count) people detected. Drag the numbered markers to correct the calibration."
        }
        return "Click to add a pair, or drag a numbered marker to move it."
    }

    private var floorDetectionSubtitle: String {
        guard personPreview != nil else {
            return "The whole image is mapped to \(session.widthM) × \(session.heightM) m."
        }
        let outside = floorDetectionMarkers.filter(\.isOutside).count
        if outside > 0 {
            return "\(previewMarkers.count) foot points · \(outside) outside the floor plan, check the calibration."
        }
        return "\(previewMarkers.count) foot points projected. Calibration markers can be dragged in any order."
    }

    private var personDetectionAccessory: AnyView? {
        guard selectedCamera?.calibration?.isValid == true else { return nil }
        return AnyView(
            HStack(spacing: Space.s) {
                if isDetectingPerson { ProgressView().controlSize(.small) }
                Button("Deteksi Ulang", systemImage: "person.crop.rectangle") {
                    resetPersonDetectionCache()
                    personDetectionRefreshToken = UUID()
                }
                .buttonStyle(.bordered)
                .disabled(isDetectingPerson)
            }
            .padding(4)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.s))
        )
    }

    @MainActor
    private func refreshPersonDetection(forceSample: Bool) async {
        guard let camera = selectedCamera,
              camera.calibration?.isValid == true,
              cameraFrameImage != nil else {
            personPreview = nil
            personDetectionError = nil
            isDetectingPerson = false
            return
        }
        let expectedCameraID = camera.id
        let expectedGlobalTime = camera.referenceFrameSeconds
        let expectedCalibration = camera.calibration
        let requestID = UUID()
        personDetectionRequestID = requestID
        isDetectingPerson = true
        personDetectionError = nil
        defer {
            if personDetectionRequestID == requestID { isDetectingPerson = false }
        }
        do {
            let cameraDTO = try EngineRequestBuilder.camera(
                camera,
                globalStart: expectedGlobalTime,
                duration: nil
            )
            let api = EngineAPI(http: sidecar.http)
            let result: CalibrationPreviewResponseDTO
            if !forceSample, let token = personPreviewToken {
                result = try await api.reprojectCalibrationPreview(
                    CalibrationReprojectRequestDTO(
                        token: token,
                        venue: EngineRequestBuilder.venue(from: session),
                        cameras: [cameraDTO]
                    )
                )
            } else {
                result = try await api.calibrationPreview(
                    CalibrationPreviewRequestDTO(
                        venue: EngineRequestBuilder.venue(from: session),
                        cameras: [cameraDTO],
                        globalTimeSec: expectedGlobalTime
                    )
                )
            }
            try Task.checkCancellation()
            guard personDetectionRequestID == requestID,
                  selectedCamera?.id == expectedCameraID,
                  selectedCamera?.referenceFrameSeconds == expectedGlobalTime,
                  selectedCamera?.calibration == expectedCalibration else { return }
            guard result.camera(matching: cameraDTO) != nil else {
                throw EngineError.job(
                    "The detection response does not match the active camera or homography. Re-run detection."
                )
            }
            personPreview = result
            personPreviewToken = result.token
        } catch is CancellationError {
            return
        } catch EngineError.http(404, _) {
            guard personDetectionRequestID == requestID else { return }
            personDetectionError = "The detection endpoint is not active. Restart the latest backend."
        } catch {
            guard personDetectionRequestID == requestID else { return }
            personDetectionError = "Detection failed: \(error.localizedDescription)"
        }
    }

    private func resetPersonDetectionCache() {
        personPreview = nil
        personPreviewToken = nil
        personDetectionError = nil
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
                    Text("Calibration History").font(.title2.bold())
                    Text("All snapshots are stored locally together with their floor plan.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if profiles.isEmpty {
                ContentUnavailableView(
                    "No Profiles Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Saved profiles will appear here.")
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
                                    Text("Active")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            Text("\(profile.cameraCount) cameras • \(profile.sourceName) • \(profile.savedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Load") {
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
                        .help("Export profile")
                        Button(role: .destructive) {
                            deletionCandidate = profile
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete profile")
                    }
                    .padding(.vertical, Space.xs)
                }
            }
        }
        .padding(Space.l)
        .frame(minWidth: 720, minHeight: 430)
        .alert(
            "Delete this calibration profile?",
            isPresented: Binding(
                get: { deletionCandidate != nil },
                set: { if !$0 { deletionCandidate = nil } }
            ),
            presenting: deletionCandidate
        ) { profile in
            Button("Delete", role: .destructive) {
                onDelete(profile)
                deletionCandidate = nil
            }
            Button("Cancel", role: .cancel) { deletionCandidate = nil }
        } message: { profile in
            Text("\(profile.displayName) and its floor plan copy will be removed from history.")
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

private struct CalibrationDetectionMarker: Identifiable {
    let id: String
    let label: String
    let point: CGPoint
    let bbox: CGRect?
    let confidence: Double
    let isOutside: Bool
}

private struct CalibrationCanvas: View {
    let title: String
    let subtitle: String
    let image: NSImage?
    let sourceSize: CGSize?
    let points: [NormPoint]
    let projectedPoints: [ValidationPoint]
    let detectionMarkers: [CalibrationDetectionMarker]
    let accent: Color
    let canInteract: Bool
    let canvasAccessory: AnyView?
    let footerAccessory: AnyView?
    let emptyState: AnyView?
    let onAdd: (CGPoint) -> Void
    let onMovePoint: (Int, CGPoint, Bool) -> Void
    let onDeletePair: (Int) -> Void

    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var basePan: CGSize = .zero
    @State private var hoveredIndex: Int?
    @State private var dragCandidateIndex: Int?
    @State private var draggedPointIndex: Int?

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
                PointMarker(
                    number: index + 1,
                    color: accent,
                    deleteMode: hoveredIndex == index && draggedPointIndex != index,
                    isDragging: draggedPointIndex == index
                )
                    .position(x: point.x * size.width, y: point.y * size.height)
                    .onHover { hoveredIndex = $0 ? index : nil }
            }
            ForEach(Array(projectedPoints.enumerated()), id: \.element.id) { index, point in
                ProjectedMarker(number: index + 1, isInlier: point.isInlier)
                    .position(x: point.point.x * size.width, y: point.point.y * size.height)
            }
            ForEach(detectionMarkers) { marker in
                DetectionMarkerView(marker: marker, canvasSize: size)
            }
        }
        .clipShape(Rectangle())
    }

    private func interactionGesture(rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard canInteract else { return }
                let distance = hypot(value.translation.width, value.translation.height)
                let candidate: Int? = {
                    if let dragCandidateIndex { return dragCandidateIndex }
                    guard let start = normalizedPoint(value.startLocation, in: rect) else { return nil }
                    let found = nearestPoint(to: start, in: rect)
                    dragCandidateIndex = found
                    return found
                }()
                if let candidate, distance > 1 {
                    draggedPointIndex = candidate
                    if let normalized = normalizedPoint(value.location, in: rect, clamped: true) {
                        onMovePoint(candidate, normalized, false)
                    }
                } else if candidate == nil, distance > 6, zoom > 1 {
                    pan = clampedPan(CGSize(width: basePan.width + value.translation.width, height: basePan.height + value.translation.height), rect: rect)
                }
            }
            .onEnded { value in
                guard canInteract else { return }
                defer {
                    dragCandidateIndex = nil
                    draggedPointIndex = nil
                }
                if let draggedPointIndex {
                    if let normalized = normalizedPoint(value.location, in: rect, clamped: true) {
                        onMovePoint(draggedPointIndex, normalized, true)
                    }
                    return
                }
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

    private func normalizedPoint(_ point: CGPoint, in rect: CGRect, clamped: Bool = false) -> CGPoint? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = ((point.x - rect.midX - pan.width) / zoom) + rect.midX
        let y = ((point.y - rect.midY - pan.height) / zoom) + rect.midY
        let normalized = CGPoint(x: (x - rect.minX) / rect.width, y: (y - rect.minY) / rect.height)
        if clamped {
            return CGPoint(
                x: min(1, max(0, normalized.x)),
                y: min(1, max(0, normalized.y))
            )
        }
        guard rect.contains(CGPoint(x: x, y: y)) else { return nil }
        return normalized
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

private struct DetectionMarkerView: View {
    let marker: CalibrationDetectionMarker
    let canvasSize: CGSize

    var body: some View {
        ZStack {
            if let bbox = marker.bbox {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.cyan, lineWidth: 2)
                    .frame(
                        width: max(2, bbox.width * canvasSize.width),
                        height: max(2, bbox.height * canvasSize.height)
                    )
                    .position(x: bbox.midX * canvasSize.width, y: bbox.midY * canvasSize.height)
            }
            VStack(spacing: 2) {
                Text(marker.isOutside ? "\(marker.label) · outside" : marker.label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(marker.isOutside ? Color.red : Color.cyan, in: Capsule())
                Circle()
                    .fill(marker.isOutside ? Color.red : Color.cyan)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
            .position(x: marker.point.x * canvasSize.width, y: marker.point.y * canvasSize.height)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .allowsHitTesting(false)
        .help("\(marker.label) · confidence \(Int((marker.confidence * 100).rounded()))%")
    }
}

private struct PointMarker: View {
    let number: Int
    let color: Color
    let deleteMode: Bool
    let isDragging: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isDragging ? Color.green : (deleteMode ? Color.red : color))
                .frame(width: (deleteMode || isDragging) ? 26 : 22, height: (deleteMode || isDragging) ? 26 : 22)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
            if isDragging {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
            } else if deleteMode { Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.white) }
            else { Text("\(number)").font(.caption2.bold()).foregroundStyle(.white) }
        }
        .shadow(radius: 1)
        .help("Drag to move point \(number) • click to delete its pair")
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
