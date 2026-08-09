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

    static let empty = CalibrationMetrics(medianErrorM: 0, p95ErrorM: 0, inliers: 0, points: 0)

    enum CodingKeys: String, CodingKey {
        case medianErrorM = "median_error_m"
        case p95ErrorM = "p95_error_m"
        case inliers, points
    }
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

    var isValid: Bool { metrics.points >= 4 && metrics.inliers >= 4 }

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
    static let currentSchemaVersion = 2

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
    var imageSize: PixelSize
    var sourceFileName: String?
    var calibration: CameraCalibration

    enum CodingKeys: String, CodingKey {
        case cameraID = "camera_id"
        case label
        case referenceFrameSeconds = "reference_frame_seconds"
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
        case .invalidVenueSize: return "Lebar dan panjang venue harus lebih dari 0 meter."
        case .invalidImageSize: return "Ukuran gambar atau frame tidak valid."
        case .unequalPointCounts: return "Jumlah titik CCTV dan denah harus sama."
        case .tooFewPoints: return "Setiap kamera membutuhkan minimal 4 pasangan titik."
        case .tooManyPoints: return "Maksimum 8 pasangan titik untuk setiap kamera."
        case .duplicatePoints: return "Ada titik yang terlalu berdekatan atau duplikat."
        case .degeneratePoints: return "Susunan titik tidak dapat membentuk homografi. Sebarkan titik pada area lantai."
        case .noValidModel: return "Homografi gagal ditemukan. Periksa pasangan titik dan coba lagi."
        case .invalidProfile: return "Profil kalibrasi tidak cocok dengan sesi saat ini."
        case .missingFloorPlan: return "Profil membutuhkan file floor plan yang tersimpan."
        case .cameraMismatch(let detail): return "Kamera pada profil tidak cocok: \(detail)"
        }
    }
}
