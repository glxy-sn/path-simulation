//
//  JejakTipis.swift
//  foodcourt
//
//  Lapisan jejak samar yang dipakai tab Zona.
//
//  Tab Path menggambar lapisan yang sama di dalam Canvas-nya sendiri karena di
//  sana ia bercampur dengan jalur tersorot, penanda mulai, dan panah arah. Di
//  sini yang dibutuhkan cuma lapisan bawahnya, jadi dipisah supaya kotak zona
//  bisa digambar sebagai View biasa di atasnya — bukan diulang di dalam Canvas.
//

import SwiftUI

struct JejakTipis: View {
    var rasio: Double
    var hingga: Int?
    var terang: Bool
    var kamera: [AnalysisResult]

    var body: some View {
        Canvas { ctx, size in
            for k in kamera {
                let peta = PetaKamera(rasio: rasio, ukuran: size, perbesar: nil, hasil: k)
                for (_, titik) in deret(k) where titik.count >= 2 {
                    var g = Path()
                    var mulaiBaru = true
                    for (a, b) in zip(titik, titik.dropFirst()) {
                        // Ambang yang sama dengan tab Path: ruas yang terlalu
                        // panjang itu lompatan ID, bukan orang berjalan cepat.
                        if hypot((b.x - a.x) * rasio, b.y - a.y) > 0.15 {
                            mulaiBaru = true; continue
                        }
                        guard let pa = peta.titikSah(a), let pb = peta.titikSah(b) else {
                            mulaiBaru = true; continue
                        }
                        if mulaiBaru { g.move(to: pa); mulaiBaru = false }
                        g.addLine(to: pb)
                    }
                    ctx.stroke(g, with: .color(terang
                                               ? Color(hex: 0x1D4ED8, alpha: 0.16)
                                               : .cyan.opacity(0.14)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func deret(_ k: AnalysisResult) -> [String: [CGPoint]] {
        guard let hingga, !k.jejakWaktu.isEmpty else { return k.jejak }
        return k.jejakWaktu.compactMapValues { d -> [CGPoint]? in
            let p = d.prefix { $0.frame <= hingga }.map(\.titik)
            return p.count >= 2 ? p : nil
        }
    }
}
