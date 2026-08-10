//
//  KurvaHalus.swift
//  foodcourt
//

import SwiftUI

/// Menyambung titik jejak dengan kurva, bukan garis patah.
///
/// Jejak dicuplik beberapa kali per detik, lalu selama ini disambung
/// `addLines` — garis lurus yang bertemu di sudut tajam. Orang berjalan
/// melengkung, jadi lintasannya terbaca menyiku dan patah-patah, seolah
/// trackernya melompat padahal titiknya berurutan rapi.
///
/// Dipakai varian CENTRIPETAL (alpha = 0,5), bukan Catmull-Rom biasa. Yang
/// biasa (uniform) melengkung terlalu jauh ketika jarak antar titik timpang —
/// persis yang terjadi waktu orang berhenti lalu jalan lagi — dan kurvanya
/// bisa membentuk simpul atau menjorok keluar melewati titik aslinya. Di denah
/// ruangan, menjorok berarti menggambar orang menembus meja atau dinding di
/// tempat yang datanya tidak pernah menyebut. Varian centripetal dijamin tidak
/// membentuk simpul dan tidak menjorok sejauh itu.
///
/// Kurvanya TETAP melewati semua titik aslinya; yang berubah hanya jalan di
/// antaranya. Jadi ini memperhalus bentuk, bukan mengarang posisi.
extension Path {
    /// Alpha untuk parameterisasi: 0 uniform, 0,5 centripetal, 1 chordal.
    private static let alpha: CGFloat = 0.5

    /// Sambung `pts` sebagai satu kurva menerus, dimulai dari titik pertama.
    mutating func tambahKurvaHalus(_ pts: [CGPoint]) {
        guard pts.count >= 2 else { return }
        guard pts.count >= 3 else {          // dua titik: tetap garis lurus
            move(to: pts[0])
            addLine(to: pts[1])
            return
        }

        move(to: pts[0])
        for i in 0..<(pts.count - 1) {
            // Titik bayangan di kedua ujung, supaya ruas pertama dan terakhir
            // ikut melengkung dan tidak patah sendirian.
            let p0 = i == 0 ? pts[0] : pts[i - 1]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : pts[pts.count - 1]

            let (c1, c2) = kendali(p0, p1, p2, p3)
            addCurve(to: p2, control1: c1, control2: c2)
        }
    }

    /// Dua titik kendali Bezier untuk ruas p1→p2, mengikuti Catmull-Rom
    /// centripetal.
    private func kendali(_ p0: CGPoint, _ p1: CGPoint,
                         _ p2: CGPoint, _ p3: CGPoint) -> (CGPoint, CGPoint) {
        func jarak(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            pow(hypot(b.x - a.x, b.y - a.y), Path.alpha)
        }
        // Titik berhimpit membuat pembagi nol. Kembali ke garis lurus di situ:
        // ruasnya memang tidak punya arah untuk dilengkungkan.
        let d1 = max(jarak(p0, p1), 1e-6)
        let d2 = max(jarak(p1, p2), 1e-6)
        let d3 = max(jarak(p2, p3), 1e-6)

        var c1 = CGPoint(
            x: (d1 * d1 * p2.x - d2 * d2 * p0.x + (2 * d1 * d1 + 3 * d1 * d2 + d2 * d2) * p1.x) / (3 * d1 * (d1 + d2)),
            y: (d1 * d1 * p2.y - d2 * d2 * p0.y + (2 * d1 * d1 + 3 * d1 * d2 + d2 * d2) * p1.y) / (3 * d1 * (d1 + d2)))
        var c2 = CGPoint(
            x: (d3 * d3 * p1.x - d2 * d2 * p3.x + (2 * d3 * d3 + 3 * d3 * d2 + d2 * d2) * p2.x) / (3 * d3 * (d3 + d2)),
            y: (d3 * d3 * p1.y - d2 * d2 * p3.y + (2 * d3 * d3 + 3 * d3 * d2 + d2 * d2) * p2.y) / (3 * d3 * (d3 + d2)))

        if !c1.x.isFinite || !c1.y.isFinite { c1 = p1 }
        if !c2.x.isFinite || !c2.y.isFinite { c2 = p2 }
        return (c1, c2)
    }

    /// Satu kurva utuh dari deret titik.
    static func kurvaHalus(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.tambahKurvaHalus(pts)
        return p
    }
}
