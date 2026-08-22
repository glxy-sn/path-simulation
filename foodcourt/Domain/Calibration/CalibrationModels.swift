//
//  CalibrationModels.swift
//  foodcourt
//
//  Created by Shafa Tiara on 07/08/26.
//

import Foundation
import CoreGraphics

struct PixelSize: Codable, Hashable {
    var width: Double
    var height: Double

    init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    init(_ size: CGSize) {
        self.init(width: size.width, height: size.height)
    }

    var cgSize: CGSize { CGSize(width: width, height: height) }
    var isValid: Bool { width > 0 && height > 0 }
}

struct CalibrationPoint: Codable, Hashable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        self.init(x: point.x, y: point.y)
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        x = try container.decode(Double.self)
        y = try container.decode(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
    }
}

struct Matrix3x3: Codable, Hashable {
    var values: [[Double]]

    init(_ values: [[Double]]) {
        self.values = values
    }

    static let identity = Matrix3x3([[1, 0, 0], [0, 1, 0], [0, 0, 1]])

    subscript(row: Int, column: Int) -> Double {
        get { values[row][column] }
        set { values[row][column] = newValue }
    }

    var isFiniteAndInvertible: Bool {
        guard values.count == 3, values.allSatisfy({ $0.count == 3 }),
              values.flatMap({ $0 }).allSatisfy(\.isFinite) else { return false }
        let determinant =
            self[0, 0] * (self[1, 1] * self[2, 2] - self[1, 2] * self[2, 1])
            - self[0, 1] * (self[1, 0] * self[2, 2] - self[1, 2] * self[2, 0])
            + self[0, 2] * (self[1, 0] * self[2, 1] - self[1, 1] * self[2, 0])
        return determinant.isFinite && abs(determinant) > 1e-12
    }

    init(from decoder: Decoder) throws {
        values = try decoder.singleValueContainer().decode([[Double]].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

struct CalibrationMetrics: Codable, Hashable {
    var medianErrorM: Double
    var p95ErrorM: Double
    var inliers: Int
    var points: Int
    var cameraCoverage: Double? = nil
    var floorCoverage: Double? = nil

    static let empty = CalibrationMetrics(medianErrorM: 0, p95ErrorM: 0, inliers: 0, points: 0)

    enum CodingKeys: String, CodingKey {
        case medianErrorM = "median_error_m"
        case p95ErrorM = "p95_error_m"
        case cameraCoverage = "camera_coverage"
        case floorCoverage = "floor_coverage"
        case inliers, points
    }
}

enum CalibrationQuality: String {
    case good = "Good"
    case warning = "Warning"
    case invalid = "Invalid"
}

struct CameraCalibration: Codable, Hashable {
    var homographyCameraToWorld: Matrix3x3
    var cameraPointsPx: [CalibrationPoint]
    var floorPointsPx: [CalibrationPoint]
    var floorPointsM: [CalibrationPoint]
    var projectedFloorPointsPx: [CalibrationPoint]
    var inlierMask: [Bool]
    var reprojectionErrorsM: [Double]
    var metrics: CalibrationMetrics

    var isValid: Bool {
        metrics.points >= 4 && metrics.inliers >= 4 && homographyCameraToWorld.isFiniteAndInvertible
    }

    var qualityWarnings: [String] {
        guard isValid else { return ["Invalid matrix or inlier count."] }
        var warnings: [String] = []
        let ratio = metrics.points > 0 ? Double(metrics.inliers) / Double(metrics.points) : 0
        if ratio < 0.75 { warnings.append("Inlier ratio is below 75%.") }
        if metrics.medianErrorM > 0.15 { warnings.append("Median error is above 0.15 m.") }
        if metrics.p95ErrorM > 0.40 { warnings.append("P95 error is above 0.40 m.") }
        if let coverage = metrics.cameraCoverage, coverage < 0.10 {
            warnings.append("CCTV point spread is below 10% of the frame.")
        }
        if let coverage = metrics.floorCoverage, coverage < 0.15 {
            warnings.append("Floor plan point spread is below 15% of the area.")
        }
        return warnings
    }

    var quality: CalibrationQuality {
        guard isValid else { return .invalid }
        return qualityWarnings.isEmpty ? .good : .warning
    }

    enum CodingKeys: String, CodingKey {
        case homographyCameraToWorld = "H_cam_to_world"
        case cameraPointsPx = "camera_points_px"
        case floorPointsPx = "floor_points_px"
        case floorPointsM = "floor_points_m"
        case projectedFloorPointsPx = "projected_floor_points_px"
        case inlierMask = "inlier_mask"
        case reprojectionErrorsM = "reprojection_errors_m"
        case metrics
    }
}

struct CalibrationProfile: Codable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int
    var profileID: UUID?
    var displayName: String?
    var savedAt: Date?
    var venueName: String?
    var worldBoundsM: PixelSize
    var floorplan: FloorplanProfile
    var homographyFloorToWorld: Matrix3x3
    var homographyWorldToFloor: Matrix3x3
    var cameras: [CameraCalibrationProfile]
    /// Optional menjaga profil schema 1/2 tetap dapat didekode.
    var tables: [TableAnnotation]?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case profileID = "profile_id"
        case displayName = "display_name"
        case savedAt = "saved_at"
        case venueName = "venue_name"
        case worldBoundsM = "world_bounds_m"
        case floorplan
        case homographyFloorToWorld = "H_floor_to_world"
        case homographyWorldToFloor = "H_world_to_floor"
        case cameras
        case tables
    }
}

struct FloorplanProfile: Codable {
    var sourceName: String
    var pixelSize: PixelSize
    var usesCanvas: Bool
    var assetFileName: String?

    enum CodingKeys: String, CodingKey {
        case sourceName = "source_name"
        case pixelSize = "pixel_size"
        case usesCanvas = "uses_canvas"
        case assetFileName = "asset_file_name"
    }
}

struct CameraCalibrationProfile: Codable {
    var cameraID: UUID
    var label: String
    var referenceFrameSeconds: Double
    var timeOffsetSec: Double? = nil
    var imageSize: PixelSize
    var sourceFileName: String?
    var calibration: CameraCalibration

    enum CodingKeys: String, CodingKey {
        case cameraID = "camera_id"
        case label
        case referenceFrameSeconds = "reference_frame_seconds"
        case timeOffsetSec = "time_offset_sec"
        case imageSize = "image_size"
        case sourceFileName = "source_file_name"
        case calibration
    }
}

enum CalibrationError: LocalizedError, Equatable {
    case invalidVenueSize
    case invalidImageSize
    case unequalPointCounts
    case tooFewPoints
    case tooManyPoints
    case duplicatePoints
    case degeneratePoints
    case noValidModel
    case invalidProfile
    case missingFloorPlan
    case cameraMismatch(String)

    var errorDescription: String? {
        switch self {
        case .invalidVenueSize: return "Venue width and length must be greater than 0 meters."
        case .invalidImageSize: return "Invalid image or frame size."
        case .unequalPointCounts: return "The number of CCTV and floor plan points must match."
        case .tooFewPoints: return "Each camera needs at least 4 point pairs."
        case .tooManyPoints: return "Maximum of 8 point pairs per camera."
        case .duplicatePoints: return "Some points are too close together or duplicated."
        case .degeneratePoints: return "These points cannot form a homography. Spread them across the floor area."
        case .noValidModel: return "Homography could not be found. Check the point pairs and try again."
        case .invalidProfile: return "The calibration profile does not match the current session."
        case .missingFloorPlan: return "The profile requires its saved floor plan file."
        case .cameraMismatch(let detail): return "Profile cameras do not match: \(detail)"
        }
    }
}
