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

    // Palet warna zona (dipetakan per-rank; senada dengan UI).
    private let palette: [UInt] = [0x5457D6, 0xF59E0B, 0x22C55E, 0xEC4899, 0x14B8A6, 0x3B82F6]

    func run(_ session: AnalysisSession) -> AsyncThrowingStream<ProcessingUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
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
                    continuation.yield(.finished(petakan(dto)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: build request

    private func buildRequest(_ s: AnalysisSession) throws -> JobRequestDTO {
        guard !s.cameras.isEmpty else { throw EngineError.job("Belum ada kamera.") }
        let duration = max(0, s.trimEndSec - s.trimStartSec)

        let cams = try s.cameras.map { cam -> CameraDTO in
            guard let url = cam.url else { throw EngineError.job("Kamera \"\(cam.label)\" tidak punya file video.") }
            // Kalibrasi hanya diwajibkan di Mode Lengkap. Di Mode Cepat layar
            // kalibrasi memang dilewati, jadi syarat titik di sini membuat
            // Mode Cepat mustahil dijalankan sama sekali.
            //
            // Syaratnya `isCalibrated` — SAMA dengan yang dipakai layar
            // Kalibrasi untuk menampilkan centang hijau. Sebelumnya di sini
            // ditulis `imagePoints.count == 4`, persis empat, padahal layar
            // Kalibrasi menyilakan 4–8 pasangan dan solvernya juga menerima
            // sampai 8. Akibatnya kalibrasi dengan 7 pasangan — sudah
            // tervalidasi, galat median 0,108 m, dua kamera bercentang hijau —
            // ditolak di langkah Proses dengan alasan "belum lengkap". Dua
            // layar yang menilai hal yang sama dengan syarat berbeda selalu
            // berakhir begini, jadi sekarang keduanya membaca satu syarat.
            if s.mode == .lengkap {
                guard cam.isCalibrated else {
                    throw EngineError.job(
                        "Kalibrasi kamera \"\(cam.label)\" belum sahih — butuh minimal "
                        + "4 pasangan titik yang cocok. Kembali ke langkah Kalibrasi.")
                }
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

    // MARK: map hasil -> model UI

    /// Dipakai juga oleh layar Riwayat untuk membuka hasil lama.
    func petakan(_ dto: JobResultDTO) -> AnalysisResult {
        var hasil = petakanSatu(label: nil, summary: dto.summary, zones: dto.zones,
                                stopPoints: dto.stopPoints, occupancy: dto.occupancy,
                                artifacts: dto.artifacts, extra: dto.extra)

        // Tiap sudut kamera dipetakan dengan jalur yang sama persis, supaya
        // kamera kedua tidak diam-diam kehilangan zona, jejak, atau galat.
        if let cams = dto.cameras, cams.count > 1 {
            hasil.perKamera = cams.map {
                petakanSatu(label: $0.label, summary: $0.summary, zones: $0.zones,
                            stopPoints: $0.stopPoints, occupancy: $0.occupancy,
                            artifacts: $0.artifacts, extra: $0.extra)
            }
        }
        if let g = dto.gabungan {
            hasil.puncakGabungan = g.peakOccupancy
            hasil.okupansiGabungan = (g.occupancy ?? []).map {
                OccupancyPoint(minute: $0.minute, count: $0.count)
            }
            hasil.catatanGabungan = g.catatan
        }
        return hasil
    }

    private func petakanSatu(label: String?, summary s: SummaryDTO, zones zs: [ZoneDTO],
                             stopPoints: [StopDTO], occupancy: [OccDTO],
                             artifacts: ArtifactsDTO, extra: ExtraDTO?) -> AnalysisResult {
        let dto = (summary: s, zones: zs, stopPoints: stopPoints,
                   occupancy: occupancy, artifacts: artifacts, extra: extra)
        let zones = dto.zones.enumerated().map { i, z in
            ZoneRank(rank: i + 1, code: z.code, visits: z.visits, share: z.share,
                     rect: CGRect(x: z.rect.x, y: z.rect.y, width: z.rect.w, height: z.rect.h),
                     colorHex: z.colorHex ?? palette[i % palette.count])
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
            guard let u = URL(string: $0.uri) else { return nil }
            return (cam: $0.cam, url: u)
        }
        var hasil = AnalysisResult(
            summary: summary, zones: zones, stops: stops, occupancy: occ,
            heatmapURL: dto.artifacts.heatmapImage.flatMap(URL.init(string:)),
            latarURL: dto.artifacts.frameLatar.flatMap(URL.init(string:)),
            pathVideoURL: dto.artifacts.pathVideo.flatMap(URL.init(string:)),
            overlayVideos: overlays
        )

        hasil.label = label ?? ""
        guard let x = dto.extra else { return hasil }

        hasil.blobs = (x.blobs ?? []).map {
            HeatBlob(x: $0.x, y: $0.y, intensity: $0.intensity, radius: $0.radius)
        }
        hasil.paths = (x.paths ?? []).map { p in
            PathTrace(points: p.points.compactMap {
                $0.count >= 2 ? CGPoint(x: $0[0], y: $0[1]) : nil
            }, hue: p.hue)
        }
        if let g = x.grid { hasil.grid = (w: g.w, h: g.h, total: g.total, sel: g.sel) }
        hasil.jejak = (x.jejak ?? [:]).mapValues { titik in
            titik.compactMap { $0.count >= 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        }
        hasil.jejakWaktu = (x.jejakWaktu ?? [:]).mapValues { titik in
            titik.compactMap { t -> (frame: Int, titik: CGPoint)? in
                guard t.count >= 3 else { return nil }
                return (Int(t[0]), CGPoint(x: t[1], y: t[2]))
            }
        }
        hasil.jejakLangkah = x.jejakLangkah ?? 20
        hasil.occupancySatuan = x.occupancySatuan ?? "menit"
        hasil.fpsSumber = x.sumber?.fps_sumber ?? 0
        hasil.frameDiproses = x.sumber?.frame_diproses ?? 0
        hasil.namaVideo = x.sumber?.video ?? ""
        if let w = x.sumber?.lebar, let h = x.sumber?.tinggi, w > 0, h > 0 {
            hasil.rasioVideo = Double(w) / Double(h)
        }
        hasil.totalVisitorsGalat = x.totalVisitorsGalat
        hasil.avgDwellGalat = x.avgDwellGalat
        hasil.galatSumber = x.galatSumber
        hasil.captureRateVenueIni = x.captureRateVenueIni ?? false
        hasil.diagnostik = x.diagnostik?.catatan
        hasil.folder = x.folder.map { URL(fileURLWithPath: $0) }
        hasil.catatan = x.catatan ?? []
        hasil.label = label ?? ""
        return hasil
    }
}
