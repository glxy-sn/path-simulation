//
//  EngineProcessingService.swift
//  foodcourt
//
//  Created by Shafa Tiara on 04/08/26.
//

import Foundation
import CoreGraphics

struct EngineProcessingService: ProcessingService {
    let api: EngineAPI
    let sidecar: Sidecar

    private let palette: [UInt] = [0x5457D6, 0xF59E0B, 0x22C55E, 0xEC4899, 0x14B8A6, 0x3B82F6]

    @MainActor
    func run(_ session: AnalysisSession) -> AsyncThrowingStream<ProcessingUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    guard await sidecar.waitUntilReady() else { throw EngineError.notReady }

                    let req = try buildRequest(session)
                    let jobId = try await api.createJob(req)

                    while true {
                        try Task.checkCancellation()
                        let p = try await api.progress(jobId)
                        if p.status == "error" { throw EngineError.job(p.error ?? "job gagal") }
                        continuation.yield(.progress(stage: p.stage, fraction: p.fraction))
                        if p.status == "done" { break }
                        try await Task.sleep(for: .milliseconds(500))
                    }

                    let dto = try await api.result(jobId)
                    continuation.yield(.finished(map(dto)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    @MainActor
    private func buildRequest(_ s: AnalysisSession) throws -> JobRequestDTO {
        guard !s.cameras.isEmpty else { throw EngineError.job("Belum ada kamera.") }
        let duration = max(0, s.trimEndSec - s.trimStartSec)

        let cams = try s.cameras.map { cam -> CameraDTO in
            guard let url = cam.url else { throw EngineError.job("Kamera \"\(cam.label)\" tidak punya file video.") }
            guard cam.imagePoints.count == 4, cam.planePoints.count == 4 else {
                throw EngineError.job("Kalibrasi kamera \"\(cam.label)\" belum lengkap (butuh 4 titik).")
            }
            return CameraDTO(
                label: cam.label,
                videoPath: url.path,
                imagePoints: cam.imagePoints.map { PointDTO(x: $0.x, y: $0.y) },
                planePoints: cam.planePoints.map { PointDTO(x: $0.x, y: $0.y) },
                startSec: s.trimStartSec,
                durationSec: duration > 0 ? duration : nil
            )
        }

        let venue = VenueDTO(widthM: s.venueWidthM, heightM: s.venueHeightM,
                             name: s.venueName, type: s.venueType.rawValue)
        return JobRequestDTO(
            venue: venue,
            mode: s.mode == .lengkap ? "lengkap" : "cepat",
            cameras: cams,
            options: JobOptionsDTO(renderVideos: true)
        )
    }

    @MainActor
    private func map(_ dto: JobResultDTO) -> AnalysisResult {
        let zones = dto.zones.enumerated().map { i, z in
            ZoneRank(rank: i + 1, code: z.code, visits: z.visits, share: z.share,
                     rect: CGRect(x: z.rect.x, y: z.rect.y, width: z.rect.w, height: z.rect.h),
                     colorHex: palette[i % palette.count])
        }
        let stops = dto.stopPoints.map { StopPoint(name: $0.label, dwellSeconds: $0.dwellSeconds) }
        let occ = dto.occupancy.map { OccupancyPoint(minute: $0.minute, count: $0.count) }
        let summary = VenueSummary(
            totalVisitors: dto.summary.totalVisitors,
            avgDwellSeconds: dto.summary.avgDwellSeconds,
            peakOccupancy: dto.summary.peakOccupancy,
            captureRate: dto.summary.captureRate
        )
        let overlays: [(cam: String, url: URL)] = dto.artifacts.overlayVideos.compactMap {
            guard let u = artifactURL($0.uri) else { return nil }
            return (cam: $0.cam, url: u)
        }
        return AnalysisResult(
            summary: summary, zones: zones, stops: stops, occupancy: occ,
            heatmapURL: artifactURL(dto.artifacts.heatmapImage),
            pathVideoURL: artifactURL(dto.artifacts.pathVideo),
            combinedVideoURL: artifactURL(dto.artifacts.combinedVideo),
            overlayVideos: overlays
        )
    }

    /// `file:///.../heatmap.png`  ->  `http://127.0.0.1:8765/artifacts?path=/.../heatmap.png`
    @MainActor
    private func artifactURL(_ uri: String?) -> URL? {
        guard let uri else { return nil }
        guard uri.hasPrefix("file://") else { return URL(string: uri) }
        let raw = String(uri.dropFirst("file://".count))
        let path = raw.removingPercentEncoding ?? raw
        var comps = URLComponents(url: sidecar.baseURL, resolvingAgainstBaseURL: false)
        comps?.path = "/artifacts"
        comps?.queryItems = [URLQueryItem(name: "path", value: path)]
        return comps?.url
    }
}
