//
//  CalibrationProfileStore.swift
//  foodcourt
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
                calibration: calibration
            )
        }
        guard profiles.count == session.cameras.count else { throw CalibrationError.invalidProfile }
        return CalibrationProfile(
            schemaVersion: CalibrationProfile.currentSchemaVersion,
            worldBoundsM: PixelSize(width: session.venueWidthM, height: session.venueHeightM),
            floorplan: FloorplanProfile(
                sourceName: session.usesScaledCanvas ? "Canvas berskala" : (session.floorPlanName ?? "Floor plan"),
                pixelSize: floorSize,
                usesCanvas: session.usesScaledCanvas
            ),
            homographyFloorToWorld: floorToWorld,
            homographyWorldToFloor: worldToFloor,
            cameras: profiles
        )
    }

    static func apply(_ profile: CalibrationProfile, to session: AnalysisSession) throws {
        guard profile.schemaVersion == CalibrationProfile.currentSchemaVersion else { throw CalibrationError.invalidProfile }
        guard profile.worldBoundsM.width > 0, profile.worldBoundsM.height > 0 else { throw CalibrationError.invalidProfile }
        session.widthM = Self.number(profile.worldBoundsM.width)
        session.heightM = Self.number(profile.worldBoundsM.height)
        session.usesScaledCanvas = profile.floorplan.usesCanvas
        if !profile.floorplan.usesCanvas {
            session.floorPlanName = profile.floorplan.sourceName
            session.floorPlanPixelSize = profile.floorplan.pixelSize
        }

        for index in session.cameras.indices {
            let camera = session.cameras[index]
            guard let saved = profile.cameras.first(where: { $0.cameraID == camera.id || $0.label == camera.label }) else { continue }
            guard saved.imageSize.isValid, saved.calibration.cameraPointsPx.count == saved.calibration.floorPointsPx.count else { continue }
            session.cameras[index].referenceFrameSeconds = saved.referenceFrameSeconds
            session.cameras[index].framePixelSize = saved.imageSize
            session.cameras[index].imagePoints = saved.calibration.cameraPointsPx.map {
                NormPoint(x: Self.clamp($0.x / saved.imageSize.width), y: Self.clamp($0.y / saved.imageSize.height))
            }
            session.cameras[index].planePoints = saved.calibration.floorPointsPx.map {
                NormPoint(x: Self.clamp($0.x / profile.floorplan.pixelSize.width), y: Self.clamp($0.y / profile.floorplan.pixelSize.height))
            }
            session.cameras[index].calibration = saved.calibration
        }
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
}
