import Foundation

@MainActor
enum EngineRequestBuilder {
    static func venue(from session: AnalysisSession) -> VenueDTO {
        VenueDTO(
            widthM: session.venueWidthM,
            heightM: session.venueHeightM,
            name: session.venueName,
            type: session.venueType.rawValue,
            floorPlanPath: session.usesScaledCanvas ? nil : session.floorPlanURL?.path
        )
    }

    static func synchronizedRange(
        cameras: [SessionCamera],
        requestedStart: Double,
        requestedEnd: Double
    ) -> (start: Double, end: Double)? {
        guard !cameras.isEmpty else { return nil }
        var start = max(0, requestedStart)
        var end = requestedEnd
        for camera in cameras {
            start = max(start, -camera.timeOffsetSec)
            if camera.durationSec > 0 {
                end = min(end, camera.durationSec - camera.timeOffsetSec)
            }
        }
        guard start.isFinite, end.isFinite, end > start else { return nil }
        return (start, end)
    }

    static func camera(
        _ camera: SessionCamera,
        globalStart: Double,
        duration: Double?
    ) throws -> CameraDTO {
        guard let url = camera.url else {
            throw EngineError.job("Kamera \"\(camera.label)\" tidak punya file video.")
        }
        guard camera.imagePoints.count >= 4,
              camera.imagePoints.count == camera.planePoints.count else {
            throw EngineError.job("Kalibrasi kamera \"\(camera.label)\" belum lengkap (butuh ≥4 pasang titik).")
        }
        guard let calibration = camera.calibration, calibration.isValid,
              let frameSize = camera.framePixelSize, frameSize.isValid else {
            throw EngineError.job("Kalibrasi kamera \"\(camera.label)\" invalid atau ukuran frame tidak tersedia.")
        }
        let normalized: Matrix3x3
        do {
            normalized = try HomographySolver.normalizedImageToWorld(
                pixelToWorld: calibration.homographyCameraToWorld,
                imageSize: frameSize
            )
        } catch {
            throw EngineError.job(
                "Matriks kalibrasi kamera \"\(camera.label)\" invalid: \(error.localizedDescription)"
            )
        }
        return CameraDTO(
            cameraId: camera.id.uuidString,
            label: camera.label,
            videoPath: url.path,
            calibrationFingerprint: calibrationFingerprint(
                cameraID: camera.id,
                homographyNormToWorld: normalized,
                frameSize: frameSize
            ),
            frameWidth: Int(frameSize.width.rounded()),
            frameHeight: Int(frameSize.height.rounded()),
            imagePoints: camera.imagePoints.map { PointDTO(x: $0.x, y: $0.y) },
            planePoints: camera.planePoints.map { PointDTO(x: $0.x, y: $0.y) },
            startSec: globalStart,
            durationSec: duration,
            timeOffsetSec: camera.timeOffsetSec,
            calibration: CalibrationDTO(
                homographyNormToWorld: normalized.values,
                inlierMask: calibration.inlierMask,
                medianErrorM: calibration.metrics.medianErrorM,
                p95ErrorM: calibration.metrics.p95ErrorM,
                inliers: calibration.metrics.inliers,
                points: calibration.metrics.points
            )
        )
    }

    static func calibrationFingerprint(
        cameraID: UUID,
        homographyNormToWorld: Matrix3x3,
        frameSize: PixelSize
    ) -> String {
        let matrix = homographyNormToWorld.values
            .flatMap { $0 }
            .map { String($0.bitPattern, radix: 16) }
            .joined(separator: ".")
        return [
            cameraID.uuidString,
            String(frameSize.width.bitPattern, radix: 16),
            String(frameSize.height.bitPattern, radix: 16),
            matrix
        ].joined(separator: "|")
    }
}
