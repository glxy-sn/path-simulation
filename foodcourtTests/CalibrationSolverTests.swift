//
//  CalibrationSolverTests.swift
//  foodcourtTests
//

import XCTest
@testable import foodcourt

final class CalibrationSolverTests: XCTestCase {
    private let floorSize = PixelSize(width: 1000, height: 750)
    private let venueWidth = 10.0
    private let venueHeight = 7.5

    func testFourPairsRecoverKnownHomography() throws {
        let pairs = try calibrationPairs(count: 4)
        let result = try HomographySolver.calibrate(
            cameraPointsPx: pairs.camera,
            floorPointsPx: pairs.floor,
            floorSize: floorSize,
            venueWidthM: venueWidth,
            venueHeightM: venueHeight
        )

        XCTAssertEqual(result.metrics.inliers, 4)
        XCTAssertLessThan(result.metrics.medianErrorM, 0.000_001)
        XCTAssertEqual(result.projectedFloorPointsPx.count, 4)
        XCTAssertEqual(result.projectedFloorPointsPx[2].x, pairs.floor[2].x, accuracy: 0.001)
        XCTAssertEqual(result.projectedFloorPointsPx[2].y, pairs.floor[2].y, accuracy: 0.001)
    }

    func testRANSACRejectsOutlierFromSevenPairs() throws {
        var pairs = try calibrationPairs(count: 7)
        pairs.floor[6].x += 180
        pairs.floor[6].y -= 110
        let result = try HomographySolver.calibrate(
            cameraPointsPx: pairs.camera,
            floorPointsPx: pairs.floor,
            floorSize: floorSize,
            venueWidthM: venueWidth,
            venueHeightM: venueHeight
        )

        XCTAssertEqual(result.metrics.inliers, 6)
        XCTAssertFalse(result.inlierMask[6])
        XCTAssertGreaterThan(result.reprojectionErrorsM[6], HomographySolver.inlierThresholdM)
    }

    func testRejectsInvalidPointSets() throws {
        let pairs = try calibrationPairs(count: 4)
        XCTAssertThrowsError(try HomographySolver.calibrate(
            cameraPointsPx: Array(pairs.camera.prefix(3)),
            floorPointsPx: Array(pairs.floor.prefix(3)),
            floorSize: floorSize,
            venueWidthM: venueWidth,
            venueHeightM: venueHeight
        ))
        XCTAssertThrowsError(try HomographySolver.calibrate(
            cameraPointsPx: pairs.camera,
            floorPointsPx: Array(pairs.floor.prefix(3)),
            floorSize: floorSize,
            venueWidthM: venueWidth,
            venueHeightM: venueHeight
        ))
        var duplicate = pairs.camera
        duplicate[3] = duplicate[0]
        XCTAssertThrowsError(try HomographySolver.calibrate(
            cameraPointsPx: duplicate,
            floorPointsPx: pairs.floor,
            floorSize: floorSize,
            venueWidthM: venueWidth,
            venueHeightM: venueHeight
        ))
    }

    func testFullFloorplanMapsToVenueBounds() throws {
        let floorToWorld = try HomographySolver.floorToWorld(
            floorSize: floorSize,
            venueWidthM: venueWidth,
            venueHeightM: venueHeight
        )
        let world = HomographySolver.transform([
            CalibrationPoint(x: 0, y: 0),
            CalibrationPoint(x: floorSize.width, y: floorSize.height)
        ], with: floorToWorld)
        XCTAssertEqual(world[0].x, 0, accuracy: 0.000_001)
        XCTAssertEqual(world[0].y, 0, accuracy: 0.000_001)
        XCTAssertEqual(world[1].x, venueWidth, accuracy: 0.000_001)
        XCTAssertEqual(world[1].y, venueHeight, accuracy: 0.000_001)
    }

    func testProfileRoundTrip() throws {
        let pairs = try calibrationPairs(count: 4)
        let calibration = try HomographySolver.calibrate(
            cameraPointsPx: pairs.camera,
            floorPointsPx: pairs.floor,
            floorSize: floorSize,
            venueWidthM: venueWidth,
            venueHeightM: venueHeight
        )
        let profile = CalibrationProfile(
            schemaVersion: CalibrationProfile.currentSchemaVersion,
            worldBoundsM: PixelSize(width: venueWidth, height: venueHeight),
            floorplan: FloorplanProfile(sourceName: "denah.png", pixelSize: floorSize, usesCanvas: false),
            homographyFloorToWorld: try HomographySolver.floorToWorld(floorSize: floorSize, venueWidthM: venueWidth, venueHeightM: venueHeight),
            homographyWorldToFloor: try HomographySolver.invert(HomographySolver.floorToWorld(floorSize: floorSize, venueWidthM: venueWidth, venueHeightM: venueHeight)),
            cameras: [CameraCalibrationProfile(cameraID: UUID(), label: "Camera 1", referenceFrameSeconds: 12, imageSize: PixelSize(width: 1920, height: 1080), calibration: calibration)]
        )
        let decoded = try CalibrationProfileStore.decode(CalibrationProfileStore.encode(profile))
        XCTAssertEqual(decoded.schemaVersion, profile.schemaVersion)
        XCTAssertEqual(decoded.cameras.first?.calibration.metrics, profile.cameras.first?.calibration.metrics)
    }

    private func calibrationPairs(count: Int) throws -> (camera: [CalibrationPoint], floor: [CalibrationPoint]) {
        let camera = [
            CalibrationPoint(x: 130, y: 100), CalibrationPoint(x: 700, y: 140),
            CalibrationPoint(x: 1100, y: 420), CalibrationPoint(x: 240, y: 610),
            CalibrationPoint(x: 880, y: 670), CalibrationPoint(x: 1530, y: 280),
            CalibrationPoint(x: 530, y: 390), CalibrationPoint(x: 1700, y: 760)
        ]
        let homography = Matrix3x3([
            [0.0065, 0.0011, 0.35],
            [-0.0008, 0.0078, 0.42],
            [0.0000014, -0.0000009, 1]
        ])
        let world = HomographySolver.transform(camera, with: homography)
        let worldToFloor = try HomographySolver.invert(
            HomographySolver.floorToWorld(floorSize: floorSize, venueWidthM: venueWidth, venueHeightM: venueHeight)
        )
        return (Array(camera.prefix(count)), Array(HomographySolver.transform(world, with: worldToFloor).prefix(count)))
    }
}
