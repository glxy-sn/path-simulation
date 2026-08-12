import XCTest
import CoreGraphics
@testable import foodcourt

final class CalibrationSolverTests: XCTestCase {
    func testCombinedJobResultDecodesObservationsAndIdentityQuality() throws {
        let data = try JSONSerialization.data(withJSONObject: jobResultPayload(
            observations: [[7, 0.25, 0.75, 12.5]],
            identityQuality: [
                "globalIds": 1, "localStitches": 2, "overlapMerges": 3,
                "handoverMerges": 4, "unmatchedTracklets": 5, "filteredTracklets": 6,
                "highConfidence": 7, "mediumConfidence": 8, "lowConfidence": 9,
                "singleCamera": 10, "calibrationWarnings": ["warning"]
            ],
            fusionDiagnostics: "file:///tmp/fusion_diagnostics.json"
        ))

        let decoded = try JSONDecoder().decode(JobResultDTO.self, from: data)
        XCTAssertEqual(decoded.observations?.first, [7, 0.25, 0.75, 12.5])
        XCTAssertEqual(decoded.identityQuality?.globalIds, 1)
        XCTAssertEqual(decoded.artifacts.fusionDiagnostics, "file:///tmp/fusion_diagnostics.json")
    }

    func testLegacyJobResultWithoutMergedOptionalFieldsStillDecodes() throws {
        let data = try JSONSerialization.data(withJSONObject: jobResultPayload())
        let decoded = try JSONDecoder().decode(JobResultDTO.self, from: data)
        XCTAssertNil(decoded.observations)
        XCTAssertNil(decoded.identityQuality)
        XCTAssertNil(decoded.artifacts.fusionDiagnostics)
    }

    func testLegacySavedAnalysisWithoutObservationsAndCustomZonesStillDecodes() throws {
        let payload: [String: Any] = [
            "venueName": "Legacy", "venueType": "Pujasera", "widthM": 10.0, "heightM": 7.5,
            "startSec": 0.0, "durationSec": 60.0, "cameraCount": 1, "usesScaledCanvas": true,
            "totalVisitors": 0, "avgDwellSeconds": 0, "peakOccupancy": 0, "captureRate": 0.0,
            "zones": [], "stops": [], "occupancy": [], "blobs": [], "paths": [], "overlays": []
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(SavedAnalysis.self, from: data)
        XCTAssertNil(decoded.observations)
        XCTAssertNil(decoded.customZones)
        XCTAssertNil(decoded.identityQuality)
        XCTAssertNil(decoded.jobId)
        XCTAssertNil(decoded.tables)
    }

    @MainActor
    func testVenueRequestCarriesRectangleTableAnnotation() throws {
        let session = AnalysisSession()
        session.venueName = "Venue"
        session.widthM = "10"
        session.heightM = "8"
        session.tableAnnotations = [
            TableAnnotation(label: "Meja 1", rectNormalized: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.25))
        ]
        let venue = EngineRequestBuilder.venue(from: session)
        XCTAssertEqual(venue.tables?.count, 1)
        XCTAssertEqual(venue.tables?.first?.label, "Meja 1")
        XCTAssertEqual(try XCTUnwrap(venue.tables?.first?.rectNormalized.width), 0.3, accuracy: 1e-10)
    }

    func testLegacyCalibrationProfileWithoutTablesDecodes() throws {
        let floor = FloorplanProfile(
            sourceName: "Canvas", pixelSize: PixelSize(width: 1000, height: 1000),
            usesCanvas: true, assetFileName: nil
        )
        let profile = CalibrationProfile(
            schemaVersion: 2,
            profileID: UUID(), displayName: "Legacy", savedAt: .now, venueName: "Venue",
            worldBoundsM: PixelSize(width: 10, height: 7.5), floorplan: floor,
            homographyFloorToWorld: .identity, homographyWorldToFloor: .identity,
            cameras: [], tables: nil
        )
        let encoded = try JSONEncoder().encode(profile)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "tables")
        let decoded = try JSONDecoder().decode(
            CalibrationProfile.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(decoded.tables)
    }

    @MainActor
    func testSynchronizedRangeAccountsForPerCameraOffsets() throws {
        let cameras = [
            SessionCamera(label: "A", durationSec: 100, timeOffsetSec: 2.0),
            SessionCamera(label: "B", durationSec: 80, timeOffsetSec: -1.0)
        ]
        let range = try XCTUnwrap(
            EngineRequestBuilder.synchronizedRange(
                cameras: cameras,
                requestedStart: 0,
                requestedEnd: 100
            )
        )
        XCTAssertEqual(range.start, 1, accuracy: 1e-10)
        XCTAssertEqual(range.end, 81, accuracy: 1e-10)
    }

    @MainActor
    func testSessionTimelineAndTrimRespectOffsets() {
        let session = AnalysisSession()
        session.cameras = [
            SessionCamera(label: "A", durationSec: 100, timeOffsetSec: 2.0),
            SessionCamera(label: "B", durationSec: 80, timeOffsetSec: -1.0)
        ]
        session.trimStartSec = 0
        session.trimEndSec = 100
        session.normalizeTrim()
        XCTAssertEqual(session.timelineMin, 1, accuracy: 1e-10)
        XCTAssertEqual(session.timelineMax, 81, accuracy: 1e-10)
        XCTAssertEqual(session.trimStartSec, 1, accuracy: 1e-10)
        XCTAssertEqual(session.trimEndSec, 81, accuracy: 1e-10)
    }

    @MainActor
    func testCameraRequestCarriesOffsetWithoutChangingGlobalStart() throws {
        let normalizedPoints = [
            NormPoint(x: 0, y: 0), NormPoint(x: 1, y: 0),
            NormPoint(x: 1, y: 1), NormPoint(x: 0, y: 1)
        ]
        let camera = SessionCamera(
            label: "A",
            url: URL(fileURLWithPath: "/tmp/camera.mp4"),
            imagePoints: normalizedPoints,
            planePoints: normalizedPoints,
            timeOffsetSec: 1.25,
            framePixelSize: PixelSize(width: 1920, height: 1080),
            calibration: validCalibration()
        )
        let request = try EngineRequestBuilder.camera(camera, globalStart: 7, duration: 12)
        XCTAssertEqual(request.cameraId, camera.id.uuidString)
        XCTAssertEqual(request.frameWidth, 1920)
        XCTAssertEqual(request.frameHeight, 1080)
        XCTAssertFalse(request.calibrationFingerprint.isEmpty)
        XCTAssertEqual(request.startSec, 7, accuracy: 1e-10)
        XCTAssertEqual(request.timeOffsetSec, 1.25, accuracy: 1e-10)
    }

    @MainActor
    func testCalibrationFingerprintChangesWithHomography() throws {
        let cameraID = UUID()
        let frameSize = PixelSize(width: 1920, height: 1080)
        let first = EngineRequestBuilder.calibrationFingerprint(
            cameraID: cameraID,
            homographyNormToWorld: .identity,
            frameSize: frameSize
        )
        let second = EngineRequestBuilder.calibrationFingerprint(
            cameraID: cameraID,
            homographyNormToWorld: Matrix3x3([[1, 0, 0.1], [0, 1, 0], [0, 0, 1]]),
            frameSize: frameSize
        )
        XCTAssertNotEqual(first, second)
    }

    func testPreviewIdentityAllowsBackendSeekAndFrameMetadataDifferences() throws {
        let request = previewCameraRequest(cameraID: "camera-2", fingerprint: "h-v2")
        let response = CalibrationPreviewResponseDTO(
            token: "token",
            globalTimeSec: 600,
            cameras: [
                PreviewCameraDTO(
                    cameraIndex: 0,
                    cameraId: "camera-2",
                    label: "Kamera 2",
                    videoPath: "/resolved/path/camera.mp4",
                    calibrationFingerprint: "h-v2",
                    sourceTimeSec: 599.96,
                    frameWidth: 4608,
                    frameHeight: 2592,
                    frameJpegBase64: "",
                    markers: []
                )
            ],
            matches: [],
            calibrationWarnings: [],
            inferenceWarnings: []
        )

        XCTAssertNotNil(response.camera(matching: request))
    }

    func testPreviewIdentityRejectsAnotherHomography() throws {
        let request = previewCameraRequest(cameraID: "camera-2", fingerprint: "h-v3")
        let response = CalibrationPreviewResponseDTO(
            token: "token",
            globalTimeSec: 600,
            cameras: [
                PreviewCameraDTO(
                    cameraIndex: 0,
                    cameraId: "camera-2",
                    label: "Kamera 2",
                    videoPath: "/tmp/camera.mp4",
                    calibrationFingerprint: "h-v2",
                    sourceTimeSec: 600,
                    frameWidth: 2304,
                    frameHeight: 1296,
                    frameJpegBase64: "",
                    markers: []
                )
            ],
            matches: [],
            calibrationWarnings: [],
            inferenceWarnings: []
        )

        XCTAssertNil(response.camera(matching: request))
    }

    func testLegacyCameraProfileWithoutOffsetDecodesAsNil() throws {
        let profile = CameraCalibrationProfile(
            cameraID: UUID(),
            label: "Legacy",
            referenceFrameSeconds: 12,
            imageSize: PixelSize(width: 1920, height: 1080),
            sourceFileName: "camera.mp4",
            calibration: validCalibration()
        )
        let encoded = try JSONEncoder().encode(profile)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "time_offset_sec")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(CameraCalibrationProfile.self, from: legacy)
        XCTAssertNil(decoded.timeOffsetSec)
    }

    func testNormalizedHomographyIsResolutionIndependent() throws {
        let fullResolution = PixelSize(width: 4608, height: 2592)
        let pixelToWorld = Matrix3x3([
            [10 / fullResolution.width, 0, 0],
            [0, 7.5 / fullResolution.height, 0],
            [0, 0, 1]
        ])
        let normalized = try HomographySolver.normalizedImageToWorld(
            pixelToWorld: pixelToWorld,
            imageSize: fullResolution
        )
        let world = try XCTUnwrap(
            HomographySolver.transform(CalibrationPoint(x: 0.5, y: 0.5), with: normalized)
        )
        XCTAssertEqual(world.x, 5, accuracy: 1e-10)
        XCTAssertEqual(world.y, 3.75, accuracy: 1e-10)
    }

    func testOutlierIsExcludedByRobustCalibration() throws {
        let source = [
            point(100, 100), point(500, 100), point(900, 100), point(100, 500),
            point(900, 500), point(100, 900), point(500, 900), point(900, 900)
        ]
        var floor = source
        floor[7] = point(50, 950)
        let result = try HomographySolver.calibrate(
            cameraPointsPx: source,
            floorPointsPx: floor,
            floorSize: PixelSize(width: 1000, height: 1000),
            venueWidthM: 10,
            venueHeightM: 10,
            cameraImageSize: PixelSize(width: 1000, height: 1000)
        )
        XCTAssertEqual(result.metrics.inliers, 7)
        XCTAssertFalse(result.inlierMask[7])
    }

    func testCoverageWarningThresholds() throws {
        let clustered = [point(10, 10), point(50, 10), point(50, 50), point(10, 50)]
        let result = try HomographySolver.calibrate(
            cameraPointsPx: clustered,
            floorPointsPx: clustered,
            floorSize: PixelSize(width: 1000, height: 1000),
            venueWidthM: 10,
            venueHeightM: 10,
            cameraImageSize: PixelSize(width: 1000, height: 1000)
        )
        XCTAssertEqual(result.quality, .warning)
        XCTAssertLessThan(try XCTUnwrap(result.metrics.cameraCoverage), 0.10)
        XCTAssertLessThan(try XCTUnwrap(result.metrics.floorCoverage), 0.15)
    }

    func testSingularNormalizedConversionIsRejected() {
        XCTAssertThrowsError(
            try HomographySolver.normalizedImageToWorld(
                pixelToWorld: Matrix3x3([[0, 0, 0], [0, 0, 0], [0, 0, 0]]),
                imageSize: PixelSize(width: 1920, height: 1080)
            )
        )
    }

    private func point(_ x: Double, _ y: Double) -> CalibrationPoint {
        CalibrationPoint(x: x, y: y)
    }

    private func validCalibration() -> CameraCalibration {
        let corners = [point(0, 0), point(1, 0), point(1, 1), point(0, 1)]
        return CameraCalibration(
            homographyCameraToWorld: .identity,
            cameraPointsPx: corners,
            floorPointsPx: corners,
            floorPointsM: corners,
            projectedFloorPointsPx: corners,
            inlierMask: [true, true, true, true],
            reprojectionErrorsM: [0, 0, 0, 0],
            metrics: CalibrationMetrics(medianErrorM: 0, p95ErrorM: 0, inliers: 4, points: 4)
        )
    }

    private func previewCameraRequest(cameraID: String, fingerprint: String) -> CameraDTO {
        CameraDTO(
            cameraId: cameraID,
            label: "Kamera 2",
            videoPath: "/tmp/camera.mp4",
            calibrationFingerprint: fingerprint,
            frameWidth: 2304,
            frameHeight: 1296,
            imagePoints: [],
            planePoints: [],
            startSec: 600,
            durationSec: nil,
            timeOffsetSec: 0,
            calibration: nil
        )
    }

    private func jobResultPayload(
        observations: [[Double]]? = nil,
        identityQuality: [String: Any]? = nil,
        fusionDiagnostics: String? = nil
    ) -> [String: Any] {
        var artifacts: [String: Any] = ["overlayVideos": []]
        if let fusionDiagnostics { artifacts["fusionDiagnostics"] = fusionDiagnostics }
        var payload: [String: Any] = [
            "jobId": "job", "venue": ["widthM": 10.0, "heightM": 7.5, "name": "Venue", "type": "Pujasera"],
            "summary": ["totalVisitors": 0, "avgDwellSeconds": 0, "peakOccupancy": 0, "captureRate": 0.0],
            "zones": [], "stopPoints": [], "occupancy": [], "blobs": [], "paths": [],
            "artifacts": artifacts
        ]
        if let observations { payload["observations"] = observations }
        if let identityQuality { payload["identityQuality"] = identityQuality }
        return payload
    }
}
