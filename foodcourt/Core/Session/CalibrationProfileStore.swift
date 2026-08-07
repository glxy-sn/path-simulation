//
//  CalibrationProfileStore.swift
//  foodcourt
//

import Foundation

enum CalibrationProfileStore {
    static func exportProfile(from session: AnalysisSession) throws -> CalibrationProfile {
        guard session.venueWidthM > 0, session.venueHeightM > 0 else { throw CalibrationError.invalidVenueSize }
        let floorSize = session.calibrationFloorSize
        let floorToWorld = try HomographySolver.floorToWorld(
            floorSize: floorSize,
            venueWidthM: session.venueWidthM,
            venueHeightM: session.venueHeightM
        )
        let worldToFloor = try HomographySolver.invert(floorToWorld)
        let profiles = session.cameras.compactMap { camera -> CameraCalibrationProfile? in
            guard let calibration = camera.calibration, let imageSize = camera.framePixelSize else { return nil }
            return CameraCalibrationProfile(
                cameraID: camera.id,
                label: camera.label,
                referenceFrameSeconds: camera.referenceFrameSeconds,
                imageSize: imageSize,
                calibration: calibration
            )
        }
        guard profiles.count == session.cameras.count else { throw CalibrationError.invalidProfile }
        return CalibrationProfile(
            schemaVersion: CalibrationProfile.currentSchemaVersion,
            worldBoundsM: PixelSize(width: session.venueWidthM, height: session.venueHeightM),
            floorplan: FloorplanProfile(
                sourceName: session.usesScaledCanvas ? "Canvas berskala" : (session.floorPlanName ?? "Floor plan"),
                pixelSize: floorSize,
                usesCanvas: session.usesScaledCanvas,
                // Gambar denahnya ikut disematkan supaya profil ini utuh
                // sendiri. Tanpa ini, mengimpornya mengembalikan titik tapi
                // panel denahnya kosong.
                imageData: session.usesScaledCanvas ? nil
                    : session.floorPlanURL.flatMap { try? Data(contentsOf: $0) },
                imagePath: session.usesScaledCanvas ? nil : session.floorPlanURL?.path
            ),
            homographyFloorToWorld: floorToWorld,
            homographyWorldToFloor: worldToFloor,
            cameras: profiles
        )
    }

    static func apply(_ profile: CalibrationProfile, to session: AnalysisSession) throws {
        guard profile.schemaVersion == CalibrationProfile.currentSchemaVersion else { throw CalibrationError.invalidProfile }
        guard profile.worldBoundsM.width > 0, profile.worldBoundsM.height > 0 else { throw CalibrationError.invalidProfile }
        session.widthM = Self.number(profile.worldBoundsM.width)
        session.heightM = Self.number(profile.worldBoundsM.height)
        session.usesScaledCanvas = profile.floorplan.usesCanvas
        if !profile.floorplan.usesCanvas {
            session.floorPlanName = profile.floorplan.sourceName
            session.floorPlanPixelSize = profile.floorplan.pixelSize
            // Tanpa baris ini panel denah tetap kosong setelah impor: layar
            // Kalibrasi memuat gambarnya dari `floorPlanURL`, dan dulu tidak
            // ada satu pun yang mengisinya kembali.
            session.floorPlanURL = pulihkanDenah(profile.floorplan)
        }

        for index in session.cameras.indices {
            let camera = session.cameras[index]
            guard let saved = profile.cameras.first(where: { $0.cameraID == camera.id || $0.label == camera.label }) else { continue }
            guard saved.imageSize.isValid, saved.calibration.cameraPointsPx.count == saved.calibration.floorPointsPx.count else { continue }
            session.cameras[index].referenceFrameSeconds = saved.referenceFrameSeconds
            session.cameras[index].framePixelSize = saved.imageSize
            session.cameras[index].imagePoints = saved.calibration.cameraPointsPx.map {
                NormPoint(x: Self.clamp($0.x / saved.imageSize.width), y: Self.clamp($0.y / saved.imageSize.height))
            }
            session.cameras[index].planePoints = saved.calibration.floorPointsPx.map {
                NormPoint(x: Self.clamp($0.x / profile.floorplan.pixelSize.width), y: Self.clamp($0.y / profile.floorplan.pixelSize.height))
            }
            session.cameras[index].calibration = saved.calibration
        }
    }

    /// Nama berkas profil di dalam folder lari.
    static let namaBerkasLari = "kalibrasi.json"

    /// Simpan kalibrasi sesi ini KE DALAM folder hasilnya.
    ///
    /// Kalibrasi selama ini cuma hidup di sesi, jadi membuka hasil lama dari
    /// Riwayat selalu kehilangan denah lantainya — padahal hasilnya sendiri
    /// utuh. Satu-satunya jalan melihat denahnya lagi adalah Import + Kalibrasi
    /// + Proses ulang, lima menit untuk sesuatu yang sudah dihitung.
    ///
    /// Disimpan bersama hasilnya, bukan di tempat lain, supaya keduanya tidak
    /// bisa terpisah: hapus larinya, kalibrasinya ikut hilang; salin foldernya,
    /// kalibrasinya ikut.
    static func simpanKeLari(_ session: AnalysisSession, folder: URL?) {
        guard let folder,
              let profile = try? exportProfile(from: session),
              let data = try? encode(profile) else { return }
        try? data.write(to: folder.appendingPathComponent(namaBerkasLari))
    }

    /// Baca profil yang tersimpan bersama sebuah lari.
    static func bacaDariLari(_ folder: URL?) -> CalibrationProfile? {
        guard let folder else { return nil }
        let berkas = folder.appendingPathComponent(namaBerkasLari)
        guard let data = try? Data(contentsOf: berkas) else { return nil }
        return try? decode(data)
    }

    static func encode(_ profile: CalibrationProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profile)
    }

    static func decode(_ data: Data) throws -> CalibrationProfile {
        try JSONDecoder().decode(CalibrationProfile.self, from: data)
    }

    /// Kembalikan lokasi berkas denah yang bisa dibaca.
    ///
    /// Berkas aslinya dipakai lebih dulu kalau masih ada — kalau pengguna
    /// mengganti gambarnya, yang terbaca versi terbarunya. Kalau tidak ada
    /// (profil dari laptop lain), yang tersemat ditulis ke folder aplikasi.
    private static func pulihkanDenah(_ f: FloorplanProfile) -> URL? {
        if let p = f.imagePath, FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        guard let data = f.imageData, !data.isEmpty else { return nil }
        let folder = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CrowdFlow/denah", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Nama berkas dari isinya, bukan dari `sourceName`: nama bisa memuat
        // spasi, garis miring, atau tabrakan antar-profil yang berbeda.
        //
        // AKHIRANNYA dipertahankan. Pemuat gambar memeriksa akhiran untuk
        // memutuskan denah PDF dirender lewat PDFDocument, jadi menulis semua
        // denah dengan akhiran seragam akan membuat denah PDF gagal dimuat —
        // diam-diam, dan hanya untuk sebagian pengguna.
        let akhiran = (f.sourceName as NSString).pathExtension.lowercased()
        let nama = String(format: "%08x", UInt32(truncatingIfNeeded: data.hashValue))
        let tujuan = folder.appendingPathComponent(
            akhiran.isEmpty ? nama : "\(nama).\(akhiran)")
        if !FileManager.default.fileExists(atPath: tujuan.path) {
            do { try data.write(to: tujuan) } catch { return nil }
        }
        return tujuan
    }

    private static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}
