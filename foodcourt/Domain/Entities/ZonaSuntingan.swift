//
//  ZonaSuntingan.swift
//  foodcourt
//
//  Zona yang disunting manual: digeser, diubah ukurannya, diganti namanya.
//
//  Zona otomatis ditemukan dari kepadatan titik kaki, dan itu bagus untuk
//  menebak — tapi mesin tidak tahu bahwa kotak yang satu itu KONTER dan yang
//  lain MEJA MAKAN. Orang yang memakai ruangannya tahu. Karena itu hasil
//  otomatis diperlakukan sebagai titik awal, bukan keputusan akhir.
//
//  Angkanya dihitung ulang di aplikasi tiap kali kotaknya berubah — dari
//  `grid` (kepadatan) dan `jejak` (lama tinggal) yang dikirim engine. Kalau
//  dihitung di pipeline, angkanya langsung basi begitu kotaknya digeser.
//

import Foundation
import CoreGraphics

struct ZonaSunting: Identifiable, Codable, Equatable {
    var id = UUID()
    var code: String
    var nama: String
    /// Ternormalkan 0–1 terhadap lebar & tinggi frame, sama seperti zona
    /// otomatis — jadi bisa langsung dipakai menggambar dan menghitung.
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var colorHex: UInt

    var rect: CGRect {
        get { CGRect(x: x, y: y, width: w, height: h) }
        set { x = newValue.minX; y = newValue.minY; w = newValue.width; h = newValue.height }
    }

    /// Jaga kotak tetap di dalam gambar dan tidak mengecil sampai tak bisa
    /// dipegang lagi.
    mutating func rapikan() {
        w = min(max(w, 0.02), 1)
        h = min(max(h, 0.02), 1)
        x = min(max(x, 0), 1 - w)
        y = min(max(y, 0), 1 - h)
    }
}

/// Simpanan zona per lari, per kamera.
///
/// Disimpan di folder aplikasi, BUKAN di folder hasil — folder hasil bisa
/// dihapus lewat layar Riwayat, dan hilangnya suntingan bersama video itu
/// justru wajar. Yang tidak wajar adalah suntingan hilang karena aplikasi
/// ditutup.
enum ZonaStore {
    private static var berkas: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CrowdFlow")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("zona.json")
    }

    private static func semua() -> [String: [ZonaSunting]] {
        guard let d = try? Data(contentsOf: berkas),
              let z = try? JSONDecoder().decode([String: [ZonaSunting]].self, from: d)
        else { return [:] }
        return z
    }

    static func kunci(lari: String, kamera: Int) -> String { "\(lari)#\(kamera)" }

    static func muat(_ kunci: String) -> [ZonaSunting]? {
        semua()[kunci]
    }

    static func simpan(_ kunci: String, _ zona: [ZonaSunting]) {
        var s = semua()
        s[kunci] = zona
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: berkas) }
    }

    static func hapus(_ kunci: String) {
        var s = semua()
        s[kunci] = nil
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: berkas) }
    }
}
