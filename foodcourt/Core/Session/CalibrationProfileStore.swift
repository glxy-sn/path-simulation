//
//  CalibrationProfileStore.swift
//  foodcourt
//
//  Created by Shafa Tiara on 07/08/26.
//

import Foundation

enum CalibrationProfileStore {
    static func exportProfile(from session: AnalysisSession) throws -> CalibrationProfile {
        guard session.venueWidthM > 0, session.venueHeightM > 0 else { throw CalibrationError.invalidVenueSize }
        let floorSize = session.calibrationFloorSize
        let floorToWorld = try HomographySolver.floorToWorld(
            floorSize: floorSize,
            venueWidthM: session.venueWidthM,
            venueHeightM: session.venueHeightM
        )
        let worldToFloor = try HomographySolver.invert(floorToWorld)
        let profiles = session.cameras.compactMap { camera -> CameraCalibrationProfile? in
            guard let calibration = camera.calibration, let imageSize = camera.framePixelSize else { return nil }
            return CameraCalibrationProfile(
                cameraID: camera.id,
                label: camera.label,
                referenceFrameSeconds: camera.referenceFrameSeconds,
                imageSize: imageSize,
                sourceFileName: camera.url?.lastPathComponent,
                calibration: calibration
            )
        }
        guard profiles.count == session.cameras.count else { throw CalibrationError.invalidProfile }
        return CalibrationProfile(
            schemaVersion: CalibrationProfile.currentSchemaVersion,
            profileID: nil,
            displayName: nil,
            savedAt: nil,
            venueName: session.venueName.isEmpty ? nil : session.venueName,
            worldBoundsM: PixelSize(width: session.venueWidthM, height: session.venueHeightM),
            floorplan: FloorplanProfile(
                sourceName: session.usesScaledCanvas ? "Canvas berskala" : (session.floorPlanName ?? "Floor plan"),
                pixelSize: floorSize,
                usesCanvas: session.usesScaledCanvas,
                assetFileName: nil
            ),
            homographyFloorToWorld: floorToWorld,
            homographyWorldToFloor: worldToFloor,
            cameras: profiles
        )
    }

    @discardableResult
    static func apply(_ profile: CalibrationProfile, floorPlanURL: URL?, to session: AnalysisSession) throws -> Int {
        guard (1...CalibrationProfile.currentSchemaVersion).contains(profile.schemaVersion) else { throw CalibrationError.invalidProfile }
        guard profile.worldBoundsM.width > 0, profile.worldBoundsM.height > 0 else { throw CalibrationError.invalidProfile }
        guard profile.floorplan.pixelSize.isValid else { throw CalibrationError.invalidProfile }
        guard profile.cameras.count == session.cameras.count, !session.cameras.isEmpty else {
            throw CalibrationError.cameraMismatch("jumlah kamera berbeda")
        }
        if !profile.floorplan.usesCanvas {
            guard let floorPlanURL, FileManager.default.fileExists(atPath: floorPlanURL.path) else {
                throw CalibrationError.missingFloorPlan
            }
        }

        let matches = try match(profile.cameras, to: session.cameras)
        var stagedCameras = session.cameras
        for (sessionIndex, profileIndex) in matches {
            let saved = profile.cameras[profileIndex]
            let current = stagedCameras[sessionIndex]
            guard saved.imageSize.isValid,
                  saved.calibration.cameraPointsPx.count == saved.calibration.floorPointsPx.count else {
                throw CalibrationError.invalidProfile
            }
            let frameSize = current.framePixelSize?.isValid == true ? current.framePixelSize! : saved.imageSize
            guard compatibleAspectRatio(frameSize, saved.imageSize) else {
                throw CalibrationError.cameraMismatch("rasio resolusi \(current.label) berbeda")
            }

            let imagePoints = saved.calibration.cameraPointsPx.map {
                NormPoint(x: clamp($0.x / saved.imageSize.width), y: clamp($0.y / saved.imageSize.height))
            }
            let planePoints = saved.calibration.floorPointsPx.map {
                NormPoint(x: clamp($0.x / profile.floorplan.pixelSize.width), y: clamp($0.y / profile.floorplan.pixelSize.height))
            }
            let recalibrated = try HomographySolver.calibrate(
                cameraPointsPx: imagePoints.map { CalibrationPoint(x: $0.x * frameSize.width, y: $0.y * frameSize.height) },
                floorPointsPx: planePoints.map {
                    CalibrationPoint(x: $0.x * profile.floorplan.pixelSize.width, y: $0.y * profile.floorplan.pixelSize.height)
                },
                floorSize: profile.floorplan.pixelSize,
                venueWidthM: profile.worldBoundsM.width,
                venueHeightM: profile.worldBoundsM.height
            )
            guard recalibrated.isValid else { throw CalibrationError.invalidProfile }
            stagedCameras[sessionIndex].referenceFrameSeconds = max(0, saved.referenceFrameSeconds)
            stagedCameras[sessionIndex].framePixelSize = frameSize
            stagedCameras[sessionIndex].imagePoints = imagePoints
            stagedCameras[sessionIndex].planePoints = planePoints
            stagedCameras[sessionIndex].calibration = recalibrated
        }

        session.widthM = Self.number(profile.worldBoundsM.width)
        session.heightM = Self.number(profile.worldBoundsM.height)
        session.usesScaledCanvas = profile.floorplan.usesCanvas
        session.floorPlanURL = profile.floorplan.usesCanvas ? nil : floorPlanURL
        session.floorPlanName = profile.floorplan.usesCanvas ? nil : profile.floorplan.sourceName
        session.floorPlanPixelSize = profile.floorplan.usesCanvas ? nil : profile.floorplan.pixelSize
        session.cameras = stagedCameras
        return stagedCameras.filter(\.isCalibrated).count
    }

    static func apply(_ profile: CalibrationProfile, to session: AnalysisSession) throws {
        try apply(profile, floorPlanURL: session.floorPlanURL, to: session)
    }

    static func encode(_ profile: CalibrationProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profile)
    }

    static func decode(_ data: Data) throws -> CalibrationProfile {
        try JSONDecoder().decode(CalibrationProfile.self, from: data)
    }

    private static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    private static func match(
        _ savedCameras: [CameraCalibrationProfile],
        to cameras: [SessionCamera]
    ) throws -> [(Int, Int)] {
        var unused = Set(savedCameras.indices)
        var result: [(Int, Int)] = []
        for index in cameras.indices {
            let camera = cameras[index]
            let exactID = unused.first { savedCameras[$0].cameraID == camera.id }
            let fileName = camera.url?.lastPathComponent.lowercased()
            let fileMatches = unused.filter {
                guard let savedName = savedCameras[$0].sourceFileName?.lowercased(), let fileName else { return false }
                return savedName == fileName
            }
            let normalizedLabel = normalize(camera.label)
            let labelMatches = unused.filter { normalize(savedCameras[$0].label) == normalizedLabel }
            let matched: Int?
            if let exactID { matched = exactID }
            else if fileMatches.count == 1 { matched = fileMatches.first }
            else if labelMatches.count == 1 { matched = labelMatches.first }
            else if unused.contains(index), compatibleAspectRatio(camera.framePixelSize, savedCameras[index].imageSize) { matched = index }
            else { matched = nil }
            guard let matched else { throw CalibrationError.cameraMismatch(camera.label) }
            unused.remove(matched)
            result.append((index, matched))
        }
        guard unused.isEmpty else { throw CalibrationError.cameraMismatch("ada kamera profil yang tidak terpakai") }
        return result
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func compatibleAspectRatio(_ lhs: PixelSize?, _ rhs: PixelSize) -> Bool {
        guard let lhs, lhs.isValid, rhs.isValid else { return true }
        let first = lhs.width / lhs.height
        let second = rhs.width / rhs.height
        return abs(first - second) / max(first, second) <= 0.02
    }
}
