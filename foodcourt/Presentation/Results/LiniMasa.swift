//
//  LiniMasa.swift
//  foodcourt
//
//  Pemutar waktu untuk visualisasi hasil, dan pengekspor gambar/video.
//
//  Yang membuat animasi ini mungkin: `jejakWaktu` dari pipeline, yang menyimpan
//  NOMOR FRAME tiap titik kaki. Urutan di dalam `jejak` biasa tidak bisa
//  dipakai sebagai waktu — titik hanya ditambahkan saat orangnya terlihat,
//  jadi indeks ke-0 milik orang yang datang di menit ke-3 berarti menit ke-3.
//
//  Yang digambar di layar dan yang direkam ke video adalah VIEW YANG SAMA,
//  dirender lewat ImageRenderer. Jadi videonya tidak bisa diam-diam berbeda
//  dari yang dilihat orang waktu memutarnya.
//

import SwiftUI
import AVFoundation
import Observation
import UniformTypeIdentifiers

// MARK: - Lini masa

@Observable
final class LiniMasa {
    /// Posisi sekarang, dalam nomor frame video sumber.
    var frame: Int = 0
    var sedangMain = false
    /// Frame terakhir yang punya data.
    var maks: Int = 0
    /// fps video sumber, untuk mengubah frame jadi detik.
    var fps: Double = 20
    /// Jarak antar cuplikan jejak, dalam frame.
    var langkah: Int = 20

    private var jam: Timer?

    var detik: Double { fps > 0 ? Double(frame) / fps : 0 }
    var detikTotal: Double { fps > 0 ? Double(maks) / fps : 0 }

    func siapkan(maks: Int, fps: Double, langkah: Int) {
        guard maks != self.maks || fps != self.fps else { return }
        self.maks = maks
        self.fps = fps > 0 ? fps : 20
        self.langkah = max(1, langkah)
        frame = maks                 // mulai dari gambar penuh, bukan kosong
        hentikan()
    }

    func togel() { sedangMain ? hentikan() : mulai() }

    func mulai() {
        guard maks > 0 else { return }
        if frame >= maks { frame = 0 }
        sedangMain = true
        // Diputar pada KECEPATAN ASLI: satu detik nyata = satu detik rekaman.
        // Mempercepatnya membuat orang terlihat berlari, dan itu berbohong
        // tentang satu-satunya hal yang diukur gambar ini — gerak.
        let selang = Double(langkah) / fps
        jam?.invalidate()
        jam = Timer.scheduledTimer(withTimeInterval: selang, repeats: true) { [weak self] _ in
            guard let self else { return }
            frame += langkah
            if frame >= maks { frame = maks; hentikan() }
        }
    }

    func hentikan() {
        sedangMain = false
        jam?.invalidate(); jam = nil
    }

    deinit { jam?.invalidate() }
}

// MARK: - Kendali pemutar

/// Baris play/pause + penggeser waktu, dipasang di bawah panel visualisasi.
struct KendaliLiniMasa: View {
    @Bindable var lini: LiniMasa

    var body: some View {
        HStack(spacing: Space.s) {
            Button(action: lini.togel) {
                Image(systemName: lini.sedangMain ? "pause.fill" : "play.fill")
                    .font(.caption).frame(width: 14)
            }
            .buttonStyle(.plain)
            .disabled(lini.maks == 0)

            Slider(
                value: Binding(
                    get: { Double(lini.frame) },
                    set: { lini.frame = Int($0) }
                ),
                in: 0...Double(max(lini.maks, 1))
            ) { sedang in
                if sedang { lini.hentikan() }
            }
            .controlSize(.small)
            .disabled(lini.maks == 0)

            Text("\(jam(lini.detik)) / \(jam(lini.detikTotal))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            // Kembali ke gambar penuh. Tanpa ini, orang yang menggeser
            // penggeser ke tengah kehilangan gambar ringkasannya dan tidak
            // punya cara jelas mengembalikannya.
            Button("Semua") { lini.hentikan(); lini.frame = lini.maks }
                .buttonStyle(.link)
                .font(.caption2)
                .disabled(lini.maks == 0 || lini.frame == lini.maks)
        }
    }

    private func jam(_ d: Double) -> String {
        guard d.isFinite, d >= 0 else { return "0:00" }
        let t = Int(d.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Ekspor

enum Ekspor {
    /// Ukuran keluaran. Lebih besar dari panel di layar supaya hasilnya masih
    /// tajam waktu ditaruh di slide presentasi.
    static let lebar: CGFloat = 1600

    static func ukuran(rasio: Double) -> CGSize {
        let r = rasio.isFinite && rasio > 0.1 ? rasio : 16.0 / 9.0
        // Tinggi digenapkan ke bilangan GENAP: encoder H.264 menolak dimensi
        // ganjil, dan kegagalannya muncul jauh di belakang sebagai video
        // kosong tanpa pesan.
        let t = (lebar / r).rounded()
        return CGSize(width: lebar, height: t.truncatingRemainder(dividingBy: 2) == 0 ? t : t + 1)
    }

    // MARK: gambar

    @MainActor
    static func png(_ view: some View, ukuran: CGSize) -> Data? {
        let r = ImageRenderer(content: view.frame(width: ukuran.width, height: ukuran.height))
        r.scale = 2
        guard let img = r.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    @MainActor
    static func simpanPNG(_ view: some View, ukuran: CGSize, nama: String) {
        guard let data = png(view, ukuran: ukuran) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = nama + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    // MARK: video

    /// Rekam satu visualisasi sepanjang lini masanya jadi mp4.
    ///
    /// Tiap frame dirender dari VIEW YANG SAMA dengan yang tampil di layar,
    /// cuma dengan `hingga` yang berbeda — jadi videonya tidak bisa diam-diam
    /// menyimpang dari yang dilihat orang waktu memutarnya.
    ///
    /// AVAssetWriter, bukan AVKit: berkas ini dipakai proses yang sama dengan
    /// pemutar video hasil, dan AVKit gagal dimuat di macOS ini (lihat catatan
    /// panjang di PipelineVideo.swift).
    @MainActor
    static func simpanVideo(
        ukuran: CGSize,
        maksFrame: Int,
        langkah: Int,
        fpsSumber: Double,
        nama: String,
        gambar: @escaping (Int) -> AnyView,
        selesai: @escaping (String?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = nama + ".mp4"
        guard panel.runModal() == .OK, let url = panel.url else { selesai(nil); return }
        try? FileManager.default.removeItem(at: url)

        // fps keluaran mengikuti kecepatan asli rekaman: satu cuplikan jejak
        // per `langkah` frame sumber, jadi fps videonya fpsSumber/langkah.
        // Dibatasi 6..30 supaya tidak jadi slideshow atau kilatan.
        let fpsKeluar = min(30.0, max(6.0, fpsSumber / Double(max(1, langkah))))

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            selesai("Tidak bisa membuat berkas video."); return
        }
        let setelan: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(ukuran.width),
            AVVideoHeightKey: Int(ukuran.height),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: setelan)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: Int(ukuran.width),
                kCVPixelBufferHeightKey as String: Int(ukuran.height),
            ])
        guard writer.canAdd(input) else { selesai("Encoder menolak ukuran video."); return }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let langkahAman = max(1, langkah)
        let jumlah = max(1, maksFrame / langkahAman)
        var n = 0

        // Render dilakukan di MainActor (ImageRenderer mengharuskannya), tapi
        // TIDAK dalam satu putaran tertutup: satu putaran panjang membekukan
        // antarmuka sampai selesai. Tiap frame dijadwalkan terpisah supaya
        // aplikasinya tetap hidup.
        func berikutnya() {
            guard n <= jumlah else {
                input.markAsFinished()
                writer.finishWriting { selesai(writer.status == .completed ? nil : "Gagal menulis video.") }
                return
            }
            guard input.isReadyForMoreMediaData else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { berikutnya() }
                return
            }
            let hingga = min(maksFrame, n * langkahAman)
            if let buf = buffer(gambar(hingga), ukuran: ukuran, pool: adaptor.pixelBufferPool) {
                adaptor.append(buf, withPresentationTime:
                    CMTime(value: CMTimeValue(n), timescale: CMTimeScale(fpsKeluar)))
            }
            n += 1
            DispatchQueue.main.async { berikutnya() }
        }
        berikutnya()
    }

    @MainActor
    private static func buffer(_ view: AnyView, ukuran: CGSize,
                               pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        let r = ImageRenderer(content: view.frame(width: ukuran.width, height: ukuran.height))
        r.scale = 1
        guard let cg = r.cgImage else { return nil }

        var buf: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buf) }
        if buf == nil {
            CVPixelBufferCreate(nil, Int(ukuran.width), Int(ukuran.height),
                                kCVPixelFormatType_32ARGB, nil, &buf)
        }
        guard let px = buf else { return nil }

        CVPixelBufferLockBaseAddress(px, [])
        defer { CVPixelBufferUnlockBaseAddress(px, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(px),
            width: Int(ukuran.width), height: Int(ukuran.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(px),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(origin: .zero, size: ukuran))
        return px
    }
}
