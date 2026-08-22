//
//  EngineAPI.swift
//  foodcourt
//
//  Created by Shafa Tiara on 04/08/26.
//

import Foundation

// MARK: Request DTO

struct PointDTO: Codable { let x: Double; let y: Double }
struct NormalizedRectDTO: Codable { let x: Double; let y: Double; let width: Double; let height: Double }
struct TableAnnotationDTO: Codable {
    let id: String
    let label: String
    let rectNormalized: NormalizedRectDTO
    let verified: Bool
}

struct VenueDTO: Codable {
    let widthM: Double
    let heightM: Double
    let name: String
    let type: String
    let floorPlanPath: String?
    let tables: [TableAnnotationDTO]?
}

struct CalibrationDTO: Codable {
    let homographyNormToWorld: [[Double]]
    let inlierMask: [Bool]
    let medianErrorM: Double
    let p95ErrorM: Double
    let inliers: Int
    let points: Int
}

struct CameraDTO: Codable {
    let cameraId: String
    let label: String
    let videoPath: String
    let calibrationFingerprint: String
    let frameWidth: Int
    let frameHeight: Int
    let imagePoints: [PointDTO]
    let planePoints: [PointDTO]
    let startSec: Double
    let durationSec: Double?
    let timeOffsetSec: Double
    let calibration: CalibrationDTO?
}

struct JobOptionsDTO: Codable { let renderVideos: Bool }

struct JobRequestDTO: Codable {
    let venue: VenueDTO
    let mode: String
    let cameras: [CameraDTO]
    let options: JobOptionsDTO
}

// MARK: Response DTO

struct CreateJobResponse: Codable { let jobId: String }

struct ProgressDTO: Codable {
    let jobId: String
    let status: String       // queued | running | done | error
    let stage: String
    let fraction: Double
    let error: String?
}

struct SummaryDTO: Codable {
    let totalVisitors: Int
    let avgDwellSeconds: Int
    let peakOccupancy: Int
    let captureRate: Double
}

struct RectDTO: Codable { let x: Double; let y: Double; let w: Double; let h: Double }
struct ZoneDTO: Codable { let code: String; let visits: Int; let share: Double; let rect: RectDTO }
struct StopDTO: Codable { let label: String; let x: Double; let y: Double; let dwellSeconds: Int }
struct OccDTO: Codable { let minute: Int; let count: Int; let second: Int? }
struct OverlayDTO: Codable { let cam: String; let uri: String }

struct BlobDTO: Codable { let x: Double; let y: Double; let intensity: Double; let radius: Double }
struct PathPointDTO: Codable { let x: Double; let y: Double; let t: Double }
struct PathTraceDTO: Codable { let points: [PathPointDTO]; let hue: Double }

struct ArtifactsDTO: Codable {
    let heatmapImage: String?
    let pathVideo: String?
    let combinedVideo: String?
    let overlayVideos: [OverlayDTO]?
    let fusionDiagnostics: String?
}

struct IdentityQualityDTO: Codable {
    let globalIds: Int
    let localStitches: Int
    let overlapMerges: Int
    let handoverMerges: Int
    let unmatchedTracklets: Int
    let filteredTracklets: Int
    let highConfidence: Int
    let mediumConfidence: Int
    let lowConfidence: Int
    let singleCamera: Int
    let calibrationWarnings: [String]
}

struct JobResultDTO: Codable {
    let jobId: String
    let venue: VenueDTO
    let summary: SummaryDTO
    let zones: [ZoneDTO]
    let stopPoints: [StopDTO]
    let occupancy: [OccDTO]
    let blobs: [BlobDTO]?
    let paths: [PathTraceDTO]?
    let observations: [[Double]]?
    let artifacts: ArtifactsDTO
    let trajectories: String?
    let identityQuality: IdentityQualityDTO?
}

// MARK: Calibration preview DTO

struct CalibrationPreviewRequestDTO: Codable {
    let venue: VenueDTO
    let cameras: [CameraDTO]
    let globalTimeSec: Double
}

struct CalibrationReprojectRequestDTO: Codable {
    let token: String
    let venue: VenueDTO
    let cameras: [CameraDTO]
}

struct PreviewMarkerDTO: Codable, Identifiable {
    var id: String { "\(cameraIndex)-\(localId)" }
    let cameraIndex: Int
    let localId: Int
    let identityLabel: String
    let globalId: Int?
    let bboxNorm: [Double]
    let confidence: Double
    let worldX: Double
    let worldY: Double
    let identityScore: Double?
    let identityLevel: String
}

struct PreviewCameraDTO: Codable, Identifiable {
    var id: String { cameraId }
    let cameraIndex: Int
    let cameraId: String
    let label: String
    let videoPath: String
    let calibrationFingerprint: String
    let sourceTimeSec: Double
    let frameWidth: Int
    let frameHeight: Int
    let frameJpegBase64: String
    let markers: [PreviewMarkerDTO]
}

struct PreviewMatchDTO: Codable, Identifiable {
    var id: String { "\(cameraALocalId)-\(cameraBLocalId)" }
    let cameraALocalId: Int
    let cameraBLocalId: Int
    let similarity: Double?
    let distanceM: Double
    let uncertaintyGateM: Double
    let score: Double?
    let decision: String
    let reason: String
}

struct CalibrationPreviewResponseDTO: Codable {
    let token: String
    let globalTimeSec: Double
    let cameras: [PreviewCameraDTO]
    let matches: [PreviewMatchDTO]
    let calibrationWarnings: [String]
    let inferenceWarnings: [String]

    /// Resolusi dan timestamp hasil seek boleh sedikit berbeda dari frame UI.
    /// Identitas kamera + fingerprint H adalah kontrak authoritative untuk marker.
    func camera(matching request: CameraDTO) -> PreviewCameraDTO? {
        cameras.first {
            $0.cameraId == request.cameraId
                && $0.calibrationFingerprint == request.calibrationFingerprint
        }
    }
}

// MARK: API

struct EngineAPI {
    let http: HTTPClient

    func createJob(_ req: JobRequestDTO) async throws -> String {
        let r: CreateJobResponse = try await http.post("/jobs", body: req)
        return r.jobId
    }

    func progress(_ id: String) async throws -> ProgressDTO {
        try await http.get("/jobs/\(id)/progress")
    }

    func result(_ id: String) async throws -> JobResultDTO {
        try await http.get("/jobs/\(id)/result")
    }

    func calibrationPreview(_ request: CalibrationPreviewRequestDTO) async throws -> CalibrationPreviewResponseDTO {
        try await http.post("/calibration-preview/sample", body: request, timeout: 120)
    }

    func reprojectCalibrationPreview(_ request: CalibrationReprojectRequestDTO) async throws -> CalibrationPreviewResponseDTO {
        try await http.post("/calibration-preview/reproject", body: request, timeout: 30)
    }
}
