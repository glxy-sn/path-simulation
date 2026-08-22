import Foundation
import CoreGraphics

@MainActor
enum EngineRequestBuilder {
    static func venue(from session: AnalysisSession) -> VenueDTO {
        VenueDTO(
            widthM: session.venueWidthM,
            heightM: session.venueHeightM,
            name: session.venueName,
            type: session.venueType.rawValue,
            floorPlanPath: session.usesScaledCanvas ? nil : session.floorPlanURL?.path,
            tables: session.tableAnnotations.map {
                TableAnnotationDTO(
                    id: $0.id.uuidString,
                    label: $0.label,
                    rectNormalized: NormalizedRectDTO(
                        x: $0.rectNormalized.minX,
                        y: $0.rectNormalized.minY,
                        width: $0.rectNormalized.width,
                        height: $0.rectNormalized.height
                    ),
                    verified: $0.verified
                )
            }
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
            throw EngineError.job("Camera \"\(camera.label)\" has no video file.")
        }
        guard camera.imagePoints.count >= 4,
              camera.imagePoints.count == camera.planePoints.count else {
            throw EngineError.job("Calibration for camera \"\(camera.label)\" is incomplete (needs ≥4 point pairs).")
        }
        guard let calibration = camera.calibration, calibration.isValid,
              let frameSize = camera.framePixelSize, frameSize.isValid else {
            throw EngineError.job("Calibration for camera \"\(camera.label)\" is invalid or the frame size is unavailable.")
        }
        let normalized: Matrix3x3
        do {
            normalized = try HomographySolver.normalizedImageToWorld(
                pixelToWorld: calibration.homographyCameraToWorld,
                imageSize: frameSize
            )
        } catch {
            throw EngineError.job(
                "Calibration matrix for camera \"\(camera.label)\" is invalid: \(error.localizedDescription)"
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
