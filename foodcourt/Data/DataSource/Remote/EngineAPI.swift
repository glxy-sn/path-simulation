//
//  EngineAPI.swift
//  foodcourt
//
//  Created by Shafa Tiara on 04/08/26.
//

import Foundation

// ============================================================
//  EngineAPI — DTO (cocok dengan models.py Python) + panggilan endpoint.
//  Taruh di: Foodcourt/Sources/Data/DataSource/Remote/EngineAPI.swift
// ============================================================

// MARK: Request DTO

struct PointDTO: Codable { let x: Double; let y: Double }

struct VenueDTO: Codable {
    let widthM: Double
    let heightM: Double
    let name: String
    let type: String
    let floorPlanPath: String?
}

struct CameraDTO: Codable {
    let label: String
    let videoPath: String
    let imagePoints: [PointDTO]
    let planePoints: [PointDTO]
    let startSec: Double
    let durationSec: Double?
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
struct OccDTO: Codable { let minute: Int; let count: Int }
struct OverlayDTO: Codable { let cam: String; let uri: String }

struct BlobDTO: Codable { let x: Double; let y: Double; let intensity: Double; let radius: Double }
struct PathPointDTO: Codable { let x: Double; let y: Double; let t: Double }
struct PathTraceDTO: Codable { let points: [PathPointDTO]; let hue: Double }

struct ArtifactsDTO: Codable {
    let heatmapImage: String?
    let pathVideo: String?
    let combinedVideo: String?
    let overlayVideos: [OverlayDTO]
}

struct JobResultDTO: Codable {
    let jobId: String
    let venue: VenueDTO
    let summary: SummaryDTO
    let zones: [ZoneDTO]
    let stopPoints: [StopDTO]
    let occupancy: [OccDTO]
    let blobs: [BlobDTO]
    let paths: [PathTraceDTO]
    let artifacts: ArtifactsDTO
    let trajectories: String?
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
}
