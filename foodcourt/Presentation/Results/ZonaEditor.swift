//
//  ZonaEditor.swift
//  foodcourt
//
//  Menggambar zona di atas frame CCTV, dan — saat mode sunting menyala —
//  membiarkannya digeser, diubah ukurannya, ditambah, dihapus, dan diganti
//  namanya.
//
//  Sengaja memakai panel visualisasi yang SUDAH ADA, bukan layar atau kartu
//  baru: yang bertambah cuma satu tombol kecil di baris tab yang juga sudah
//  ada.
//

import SwiftUI

struct ZonaEditorView: View {
    @Binding var zona: [ZonaSunting]
    var menyunting: Bool
    var rasio: Double
    var latar: URL?
    /// Dipakai untuk proyeksi ke denah lantai kalau kameranya sudah dikalibrasi.
    var hasil: AnalysisResult?
    /// Sudut kamera LAIN yang zonanya ikut digambar di denah yang sama.
    ///
    /// Hanya terisi di mode denah gabungan. Zonanya digambar apa adanya, tidak
    /// digabungkan jadi satu: zona kamera 1 dan kamera 2 ditemukan terpisah
    /// dari kepadatan masing-masing, dan menyatukan dua kotak yang kebetulan
    /// bertindihan akan mengarang satu zona yang tidak pernah dihitung
    /// siapa pun. Yang bertindihan justru informasinya — di situ dua kamera
    /// sepakat.
    var kameraLain: [AnalysisResult] = []
    /// Zona milik kamera lain, diambil lewat penyimpan yang sama.
    var zonaLain: (AnalysisResult) -> [ZonaSunting] = { _ in [] }
    /// Angka tiap kotak, dihitung ulang oleh pemanggil tiap kotak berubah.
    var angka: (CGRect) -> (orang: Int, rata: Double, porsi: Double)

    @State private var terpilih: UUID?

    var body: some View {
        GeometryReader { geo in
            let peta = PetaKamera(rasio: rasio, ukuran: geo.size, perbesar: nil, hasil: hasil)

            // Mode denah ikut permukaan TERANG, bukan hitam: denah lantainya
            // sendiri putih, dan di atas hitam yang tampak cuma kotak
            // melayang tanpa ruangan di belakangnya.
            let terang = peta.denah || latar == nil

            ZStack(alignment: .topLeading) {
                (terang ? Color(hex: 0xF7F8FA) : Color.black)

                Canvas { ctx, _ in
                    gambarLatar(&ctx, latar, peta, redup: 0.5, gelap: !terang)
                }

                ForEach($zona) { $z in
                    kotak($z, peta: peta, ukuran: geo.size)
                }

                // Zona kamera lain: digambar, tapi TIDAK bisa disunting di
                // sini — yang disunting selalu milik kamera yang sedang aktif,
                // supaya tidak ada kotak yang berubah tanpa bisa dilacak
                // pemiliknya.
                ForEach(Array(kameraLain.enumerated()), id: \.offset) { _, k in
                    let pk = PetaKamera(rasio: rasio, ukuran: geo.size, perbesar: nil, hasil: k)
                    ForEach(zonaLain(k)) { z in
                        kotak(.constant(z), peta: pk, ukuran: geo.size)
                    }
                }

                if menyunting {
                    petunjuk
                }
            }
            // Klik di ruang kosong melepas pilihan, supaya pegangan ukur tidak
            // terus menempel di kotak yang sudah tidak diurus.
            .contentShape(Rectangle())
            .onTapGesture { terpilih = nil }
        }
    }

    // MARK: satu kotak

    @ViewBuilder
    private func kotak(_ z: Binding<ZonaSunting>, peta: PetaKamera, ukuran: CGSize) -> some View {
        let r = peta.kotak(z.wrappedValue.rect)
        let warna = Color(hex: z.wrappedValue.colorHex)
        // Kotak yang tidak bisa diproyeksikan ke denah dikembalikan sebagai
        // .zero. Menggambarnya menaruh kotak sebesar nol di pojok kiri atas
        // beserta labelnya — terbaca sebagai zona sungguhan di tempat yang
        // salah.
        let terproyeksi = r.width > 1 && r.height > 1
        let dipilih = terpilih == z.wrappedValue.id
        let n = angka(z.wrappedValue.rect)

        if terproyeksi {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                // Di atas denah, isian kotak dibuat lebih tipis: yang harus
                // tetap terbaca di baliknya adalah meja dan kursinya — itu
                // seluruh alasan denahnya dipasang.
                .fill(warna.opacity(peta.denah ? 0.16 : (latar == nil ? 0.20 : 0.28)))
            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .strokeBorder(warna, lineWidth: dipilih ? 3 : 2)
        }
        .frame(width: r.width, height: r.height)
        .position(x: r.midX, y: r.midY)
        // Penyuntingan hanya di tampilan kamera. Di denah lantai, satu piksel
        // geseran di layar tidak sama dengan satu satuan di koordinat zona
        // (yang masih ruang gambar kamera) — kotaknya akan lari ke tempat yang
        // salah. Lebih baik tidak bisa digeser daripada digeser keliru.
        .gesture(menyunting && !peta.denah ? geser(z, peta: peta) : nil)
        .onTapGesture { if menyunting && !peta.denah { terpilih = z.wrappedValue.id } }

        // Label di LUAR kotak: zona terkecil yang terukur cuma 3,8% × 3,7%
        // bidang gambar, dan tulisan di dalamnya tidak terbaca sama sekali.
        HStack(spacing: 4) {
            Text(z.wrappedValue.nama)
                .font(.system(.caption, design: .rounded, weight: .bold))
            Text("\(n.orang) orang · \(detik(n.rata))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(warna, in: Capsule())
        .position(x: r.midX, y: max(9, r.minY - 10))

        if menyunting && dipilih {
            // Pegangan ubah-ukuran di pojok kanan bawah.
            Circle()
                .fill(.white)
                .overlay(Circle().strokeBorder(warna, lineWidth: 3))
                .frame(width: 16, height: 16)
                .position(x: r.maxX, y: r.maxY)
                .gesture(ukur(z, peta: peta))
        }
        }
    }

    private func geser(_ z: Binding<ZonaSunting>, peta: PetaKamera) -> some Gesture {
        DragGesture()
            .onChanged { g in
                terpilih = z.wrappedValue.id
                var v = z.wrappedValue
                v.x += g.translation.width / (peta.skala * rasio)
                v.y += g.translation.height / peta.skala
                v.rapikan()
                z.wrappedValue = v
            }
    }

    private func ukur(_ z: Binding<ZonaSunting>, peta: PetaKamera) -> some Gesture {
        DragGesture()
            .onChanged { g in
                var v = z.wrappedValue
                v.w += g.translation.width / (peta.skala * rasio)
                v.h += g.translation.height / peta.skala
                v.rapikan()
                z.wrappedValue = v
            }
    }

    private var petunjuk: some View {
        VStack {
            Spacer()
            Text("Seret kotak untuk memindah · klik kotak lalu seret bulatan di pojok untuk mengubah ukuran")
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(.horizontal, Space.s).padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(Space.s)
    }

    private func detik(_ d: Double) -> String {
        d >= 60 ? "\(Int(d) / 60)m \(Int(d) % 60)s" : "\(Int(d.rounded()))s"
    }
}
