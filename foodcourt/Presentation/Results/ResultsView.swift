//
//  ResultsView.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI
import Charts

enum ResultVisual: String, CaseIterable, Identifiable {
    case boundingBox = "Bounding Box"
    case path = "Path Simulation"
    case heatmap = "Heatmap"
    case zona = "Zona"
    var id: String { rawValue }
    var isVideo: Bool { self == .boundingBox || self == .path }
}

/// Sumber angka di layar ini.
///
/// Semua yang di bawah dulunya `SampleResult` — angka karangan yang tampil
/// sama persis berapa pun video yang diproses (143 pengunjung, 5 zona, 34%).
/// Sekarang isinya hasil engine, dan `SampleResult` hanya dipakai kalau belum
/// ada analisis sama sekali — dengan pemberitahuan, supaya tidak ada yang
/// mengira angka contoh itu hasil pengukuran.
@Observable
final class ResultsViewModel {
    var visual: ResultVisual = .boundingBox
    /// Hasil apa adanya dari engine — memuat semua sudut kamera.
    var semua: AnalysisResult?
    /// Sudut yang sedang dilihat. 0 kalau cuma satu kamera.
    var kameraTerpilih = 0

    /// Hasil sudut yang sedang dipilih. Seluruh layar membaca ini, jadi zona,
    /// heatmap, jalur, dan lama tinggal otomatis ikut kamera yang dipilih.
    var hasil: AnalysisResult? {
        guard let s = semua else { return nil }
        guard s.perKamera.count > 1 else { return s }
        return s.perKamera[min(kameraTerpilih, s.perKamera.count - 1)]
    }

    var kamera: [AnalysisResult] { semua?.perKamera ?? [] }
    var banyakKamera: Bool { kamera.count > 1 }

    /// Boleh digambar jadi SATU denah?
    ///
    /// Syaratnya semua kamera terkalibrasi ke venue yang berukuran sama —
    /// hanya dengan begitu titiknya berada di satu sistem koordinat meter dan
    /// boleh ditumpuk. Kalau salah satu belum dikalibrasi, panelnya tetap
    /// terpisah: menumpuk koordinat gambar dua kamera yang berbeda sudut
    /// menghasilkan gambar yang tidak berarti apa-apa.
    var bisaDisatukan: Bool {
        guard kamera.count > 1, let acuan = kamera.first?.venueMeter else { return false }
        return kamera.allSatisfy { k in
            k.adaDenah && k.venueMeter.map {
                abs($0.width - acuan.width) < 0.01 && abs($0.height - acuan.height) < 0.01
            } == true
        }
    }

    var adaHasil: Bool { semua != nil }

    var summary: VenueSummary { hasil?.summary ?? SampleResult.summary }
    var zones: [ZoneRank] { hasil?.zones ?? SampleResult.zones }
    /// Dihitung di aplikasi dari jejak + zona, bukan dikirim engine — supaya
    /// angkanya ikut berubah begitu kotak zona digeser manual.
    var stops: [StopPoint] {
        guard let h = hasil else { return SampleResult.stops }
        // Dari zona yang BERLAKU sekarang — termasuk suntingan manual, karena
        // "berapa lama orang berhenti di sini" hanya berarti kalau "sini"-nya
        // memang kotak yang kamu tetapkan.
        let dihitung = zona(h)
            .map { z -> (StopPoint, Double) in
                let l = h.lamaTinggal(di: z.rect)
                return (StopPoint(name: "\(z.nama) · \(l.orang) orang",
                                  dwellSeconds: Int(l.rataDetik.rounded())), l.rataDetik)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        return dihitung.isEmpty ? h.stops : dihitung
    }
    var occupancy: [OccupancyPoint] {
        let o = hasil?.occupancy ?? []
        return o.isEmpty ? (adaHasil ? [] : SampleResult.occupancy) : o
    }
    var blobs: [HeatBlob] {
        let b = hasil?.blobs ?? []
        return b.isEmpty ? (adaHasil ? [] : SampleResult.blobs) : b
    }
    var paths: [PathTrace] {
        let p = hasil?.paths ?? []
        return p.isEmpty ? (adaHasil ? [] : SampleResult.paths) : p
    }

    var videoURL: URL? { hasil?.pathVideoURL }

    // MARK: zona suntingan

    /// Mode sunting menyala/mati. Di luar mode ini kotak tidak bisa tergeser
    /// tanpa sengaja saat orang cuma ingin melihat.
    var menyunting = false
    /// Zona hasil suntingan per kamera, dikunci pada foldernya masing-masing.
    var zonaSunting: [String: [ZonaSunting]] = [:]

    private static let palet: [UInt] = [0x5457D6, 0xF59E0B, 0x22C55E, 0xEC4899, 0x14B8A6, 0x3B82F6]

    func kunciZona(_ h: AnalysisResult?) -> String? { h?.folder?.path }

    /// Zona untuk sebuah sudut: hasil suntingan kalau ada, kalau belum
    /// disunting maka hasil otomatis dipakai sebagai titik awal.
    func zona(_ h: AnalysisResult?) -> [ZonaSunting] {
        guard let h, let k = kunciZona(h) else { return [] }
        if let z = zonaSunting[k] { return z }
        if let tersimpan = ZonaStore.muat(k) { return tersimpan }
        return otomatis(h)
    }

    func otomatis(_ h: AnalysisResult) -> [ZonaSunting] {
        h.zones.enumerated().map { i, z in
            ZonaSunting(code: z.code, nama: z.name,
                        x: z.rect.minX, y: z.rect.minY,
                        w: z.rect.width, h: z.rect.height,
                        colorHex: z.colorHex)
        }
    }

    func setZona(_ h: AnalysisResult?, _ baru: [ZonaSunting]) {
        guard let k = kunciZona(h) else { return }
        zonaSunting[k] = baru
        ZonaStore.simpan(k, baru)
    }

    func tambahZona(_ h: AnalysisResult?) {
        guard let h else { return }
        var z = zona(h)
        let kode = String(UnicodeScalar(UInt8(65 + min(z.count, 25))))
        z.append(ZonaSunting(code: kode, nama: "Zona \(kode)",
                             x: 0.4, y: 0.4, w: 0.15, h: 0.15,
                             colorHex: Self.palet[z.count % Self.palet.count]))
        setZona(h, z)
    }

    func kembalikanOtomatis(_ h: AnalysisResult?) {
        guard let h, let k = kunciZona(h) else { return }
        ZonaStore.hapus(k)
        zonaSunting[k] = otomatis(h)
    }

    /// Ranking zona mengikuti kotak yang BERLAKU sekarang — kalau sudah
    /// disunting, angkanya ikut kotak suntingan, bukan kotak otomatis.
    func peringkat(_ h: AnalysisResult?) -> [(ZonaSunting, AnalysisResult.LamaTinggal, Double)] {
        guard let h else { return [] }
        return zona(h)
            .map { z in (z, h.lamaTinggal(di: z.rect), h.kepadatan(di: z.rect).porsi) }
            .sorted { $0.2 > $1.2 }
    }
    /// "detik" untuk potongan pendek — grafik 16 detik yang dilabeli "menit
    /// ke-" salah baca dua kali lipat besarnya.
    var satuanWaktu: String { hasil?.occupancySatuan ?? "menit" }
}

struct ResultsView: View {
    /// Posisi waktu bersama untuk Path, Heatmap, dan Zona. Satu lini masa
    /// untuk ketiganya: kalau tiap tab punya sendiri, berpindah tab akan
    /// melompat waktu tanpa alasan yang bisa dijelaskan.
    @State private var lini = LiniMasa()
    @State private var sedangMerekam = false
    @State private var pesanEkspor: String?

    @Environment(\.uiScale) private var scale
    @Environment(AnalysisSession.self) private var session
    @State private var vm = ResultsViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l * scale) {
                header
                if !vm.adaHasil {
                    InfoNote(text: "Belum ada analisis — semua angka di bawah ini DATA CONTOH, "
                             + "bukan hasil pengukuran. Jalankan analisis dari langkah Import.",
                             systemImage: "exclamationmark.triangle")
                }
                ForEach(vm.hasil?.catatan ?? [], id: \.self) { c in
                    InfoNote(text: c)
                }
                metrics
                mediaCard
                HStack(alignment: .top, spacing: Space.l * scale) {
                    rankingCard.relativeWidth(0.40)
                    occupancyCard.frame(maxWidth: .infinity)
                }
            }
            .spad(Space.xl, [.horizontal, .top])
            .padding(.bottom, Space.xl)
        }
        // Hasil dibaca dari sesi tiap layar ini muncul, bukan sekali saat
        // dibuat — kalau tidak, analisis kedua menampilkan angka yang pertama.
        .onAppear {
            vm.semua = berkalibrasi(session.result)
            siapkanLini()
        }
        .onChange(of: vm.visual) { _, _ in lini.hentikan() }
        .onChange(of: session.result?.jobIdentitas) {
            vm.semua = berkalibrasi(session.result)
            vm.kameraTerpilih = 0
            siapkanLini()
        }
    }

    /// Sisipkan homografi dari layar Kalibrasi ke hasil, per kamera.
    ///
    /// Kalibrasi hidup di sesi (layar Kalibrasi), hasil datang dari engine —
    /// keduanya baru bertemu di sini. Kalau kameranya belum dikalibrasi,
    /// hasilnya lewat tanpa diubah dan tampilannya tetap seperti biasa.
    private func berkalibrasi(_ h: AnalysisResult?) -> AnalysisResult? {
        guard var hasil = h else { return nil }
        let venue = CGSize(width: session.venueWidthM, height: session.venueHeightM)
        guard venue.width > 0, venue.height > 0 else { return hasil }

        // Hanya dipakai kalau denahnya gambar sungguhan. Dalam mode "Canvas
        // berskala" tidak ada gambar apa pun untuk dipasang, dan kisi meter
        // memang sudah jadi satu-satunya acuan yang tersedia.
        let denah = session.usesScaledCanvas ? nil : session.floorPlanURL

        func pasang(_ r: inout AnalysisResult, _ cam: SessionCamera?) {
            guard let cam, let kal = cam.calibration, kal.isValid,
                  let px = cam.framePixelSize else { return }
            r.homografi = kal.homographyCameraToWorld
            r.ukuranFramePx = px
            r.venueMeter = venue
            r.denahURL = denah
        }

        if hasil.perKamera.count > 1 {
            for i in hasil.perKamera.indices where i < session.cameras.count {
                pasang(&hasil.perKamera[i], session.cameras[i])
            }
        }
        pasang(&hasil, session.cameras.first)
        return hasil
    }

    // MARK: Header + tombol atas

    private var header: some View {
        HStack(alignment: .center) {
            SectionHeader(
                title: "Hasil Analisis",
                subtitle: subjudul
            )
            // Export → PDF generation (diimplementasi setelah slicing selesai)
            PrimaryButton(title: "Export Laporan", systemImage: "square.and.arrow.up") {}
        }
    }

    /// Menyebut video, durasi, dan fps yang BENAR-BENAR diproses. Sebelumnya
    /// tertulis mati "Pujasera Kampus · 3 kamera · durasi ~12 menit", apa pun
    /// yang diproses.
    private var subjudul: String {
        guard let h = vm.hasil else { return "Belum ada analisis." }
        let detik = h.fpsSumber > 0 ? Double(h.frameDiproses) / h.fpsSumber : 0
        let durasi = detik >= 60
            ? "\(Int(detik) / 60)m \(Int(detik) % 60)s"
            : "\(Int(detik.rounded()))s"
        let n = max(1, vm.kamera.count)
        var teks = "\(h.namaVideo) · \(n) kamera · \(durasi) diproses "
            + "(\(h.frameDiproses) frame @ \(String(format: "%.1f", h.fpsSumber)) fps)"
        // Angka seluruh ruangan diselipkan di baris yang memang sudah ada,
        // bukan dibuatkan kartu sendiri — tata letak aslinya tetap utuh.
        if vm.banyakKamera, let puncak = vm.semua?.puncakGabungan {
            teks += " · puncak okupansi seluruh sudut: \(puncak) orang "
                + "(pengunjung tidak dijumlahkan — orang yang pindah sudut akan terhitung dua kali)"
        }
        return teks
    }

    // MARK: Metrik

    private var metrics: some View {
        HStack(spacing: Space.m * scale) {
            // Tiap kartu menyebut dari mana angkanya dan seberapa meleset.
            // Angka tanpa keterangan terbaca seolah-olah pasti, padahal tiga
            // dari empat ini punya galat yang sudah terukur.
            MetricTile(title: "Total Pengunjung",
                       value: "\(vm.summary.totalVisitors)",
                       caption: vm.hasil?.visitorsKeterangan,
                       systemImage: "person.2.fill")
            MetricTile(title: "Rata-rata Dwell",
                       value: vm.summary.avgDwellText,
                       caption: vm.hasil?.dwellKeterangan,
                       systemImage: "clock.fill", tint: .orange)
            MetricTile(title: "Puncak Okupansi",
                       value: "\(vm.summary.peakOccupancy)",
                       caption: vm.adaHasil
                           ? "Jumlah orang terbanyak yang terlihat bersamaan dalam satu frame."
                           : nil,
                       systemImage: "chart.line.uptrend.xyaxis", tint: .pink)
            MetricTile(title: "Capture Rate",
                       value: vm.summary.captureRateText,
                       caption: vm.hasil?.captureKeterangan,
                       systemImage: "arrow.down.right.circle.fill", tint: .green)
        }
    }

    // MARK: Panel media (4 tab)

    private var mediaCard: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                Text("Visualisasi").font(.headline)
                Spacer()
                // Alat sunting hanya muncul di tab Zona, di baris yang memang
                // sudah ada — tidak ada kartu atau layar baru.
                if vm.visual == .zona && vm.adaHasil {
                    if vm.menyunting {
                        GhostButton(title: "Tambah zona", systemImage: "plus") {
                            vm.tambahZona(vm.hasil)
                        }
                        GhostButton(title: "Kembalikan otomatis", systemImage: "arrow.uturn.backward") {
                            vm.kembalikanOtomatis(vm.hasil)
                        }
                    }
                    GhostButton(title: vm.menyunting ? "Selesai" : "Sunting zona",
                                systemImage: vm.menyunting ? "checkmark" : "square.and.pencil") {
                        vm.menyunting.toggle()
                    }
                }

                Picker("", selection: Binding(get: { vm.visual }, set: { vm.visual = $0 })) {
                    ForEach(ResultVisual.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            // Semua sudut ditampilkan BERSAMAAN, bukan bergantian. Dua kamera
            // di satu ruangan menceritakan satu kejadian yang sama dari dua
            // sisi; melihatnya bergantian memaksa orang mengingat sisi yang
            // satunya, dan perbandingan yang jadi intinya justru hilang.
            // Bounding Box SELALU per kamera. Tab itu menampilkan video
            // beranotasi tiap kamera apa adanya — bukan koordinat lantai —
            // jadi tidak ada yang bisa digabungkan: menyatukannya cuma akan
            // membuang salah satu videonya.
            HStack(spacing: Space.m) {
                if vm.banyakKamera && vm.bisaDisatukan && vm.visual != .boundingBox {
                    // Semua kamera dikalibrasi ke RUANGAN YANG SAMA, jadi
                    // titiknya sudah berada di satu sistem koordinat meter.
                    // Menggambarnya di dua panel terpisah menyembunyikan
                    // justru yang paling berguna: bagian ruangan mana yang
                    // hanya terlihat satu kamera, dan bagian mana yang
                    // dilewati orang menurut dua-duanya.
                    panelVisual(vm.kamera, judul: judulGabungan)
                } else if vm.banyakKamera {
                    ForEach(Array(vm.kamera.enumerated()), id: \.offset) { i, k in
                        panelVisual([k], judul: k.label.isEmpty ? "Kamera \(i + 1)" : k.label)
                    }
                } else if let h = vm.hasil {
                    panelVisual([h], judul: nil)
                } else {
                    panelVisual([], judul: nil)
                }
            }
            // Panel gabungan dibiarkan lebih tinggi: sebelumnya dua panel
            // berbagi lebar, sekarang satu panel memakainya sendiri, dan
            // dengan tinggi lama denahnya jadi kecil di tengah lautan kosong.
            .frame(height: satuPanel ? min(560, max(380, 480 * scale))
                                     : min(400, max(300, 360 * scale)))

            if vm.visual != .boundingBox {
                HStack(spacing: Space.m) {
                    if bisaDianimasi {
                        KendaliLiniMasa(lini: lini)
                    } else {
                        Text("Animasi butuh hasil analisis baru — hasil lama tidak menyimpan waktu tiap titik.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                    }
                    barisUnduh
                }
            }

            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    /// Batas waktu yang sedang dipakai menggambar.
    ///
    /// nil kalau penggeser berada di ujung kanan — dan itu disengaja: di ujung
    /// kanan yang tampil GAMBAR RINGKASAN dari pipeline (petak penuh, jalur
    /// tersorot), bukan hasil kumpulan animasi yang kebetulan sampai di frame
    /// terakhir. Keduanya nyaris sama, tapi yang dari pipeline itu yang
    /// angkanya dilaporkan di kartu-kartu di atas.
    private var batasWaktu: Int? {
        guard bisaDianimasi, lini.maks > 0, lini.frame < lini.maks else { return nil }
        return lini.frame
    }

    private func siapkanLini() {
        let k = kameraTergambar
        let maks = k.map(\.frameTerakhir).max() ?? 0
        let fps = k.first(where: { $0.fpsSumber > 0 })?.fpsSumber ?? 20
        let langkah = k.first?.jejakLangkah ?? 20
        lini.siapkan(maks: maks, fps: fps, langkah: langkah)
    }

    /// Satu panel penuh lebar (gabungan atau kamera tunggal)?
    private var satuPanel: Bool {
        !(vm.banyakKamera && (!vm.bisaDisatukan || vm.visual == .boundingBox))
    }

    private var kameraTergambar: [AnalysisResult] {
        if vm.banyakKamera && vm.bisaDisatukan { return vm.kamera }
        if let h = vm.hasil { return [h] }
        return []
    }

    private var bisaDianimasi: Bool { kameraTergambar.contains(where: \.bisaDianimasi) }

    /// Tombol unduh gambar dan video untuk tab yang sedang dibuka.
    @ViewBuilder
    private var barisUnduh: some View {
        HStack(spacing: Space.s) {
            if let pesanEkspor {
                Text(pesanEkspor).font(.caption2).foregroundStyle(.secondary)
            }
            Button {
                unduhGambar()
            } label: {
                Label("Gambar", systemImage: "photo").font(.caption)
            }
            .buttonStyle(.bordered)
            .disabled(sedangMerekam)

            Button {
                unduhVideo()
            } label: {
                Label(sedangMerekam ? "Merekam…" : "Video", systemImage: "film").font(.caption)
            }
            .buttonStyle(.bordered)
            .disabled(!bisaDianimasi || sedangMerekam)
        }
    }

    // MARK: unduh

    /// View yang diekspor — SAMA dengan yang tampil di panel, cuma dengan
    /// batas waktu yang ditentukan pemanggil.
    ///
    /// Satu sumber gambar untuk layar dan untuk berkas: kalau keduanya
    /// digambar oleh kode yang berbeda, cepat atau lambat berkasnya akan
    /// menyimpang dari yang dilihat orang waktu menekan tombolnya.
    private func viewEkspor(_ hingga: Int?) -> AnyView {
        let kamera = kameraTergambar
        let hasil = kamera.first
        let rasio = ekspRasio
        let latar = kamera.count > 1 ? nil : hasil?.latarURL
        switch vm.visual {
        case .path:
            return AnyView(PathContent(paths: hasil?.paths ?? [], rasio: rasio, latar: latar,
                                       jejak: hasil?.jejak ?? [:],
                                       hasil: hasil, hingga: hingga, kamera: kamera))
        case .heatmap:
            return AnyView(ZStack {
                HeatmapView(blobs: hasil?.blobs ?? [], grid: hasil?.grid,
                            rasio: rasio, latar: latar, hingga: hingga,
                            hasil: hasil, kamera: kamera)
                HeatmapLegend(maks: hasil?.grid?.sel.max())
            })
        case .zona:
            guard let h = hasil else { return AnyView(Color.clear) }
            return AnyView(ZonaEditorView(
                zona: .constant(vm.zona(h)), menyunting: false,
                rasio: rasio, latar: latar, hasil: h, hingga: hingga,
                kameraLain: Array(kamera.dropFirst()),
                zonaLain: { vm.zona($0) },
                angka: { r in
                    let l = h.lamaTinggal(di: r)
                    return (l.orang, l.rataDetik, h.kepadatan(di: r).porsi)
                }))
        case .boundingBox:
            return AnyView(Color.clear)
        }
    }

    /// Rasio gambar keluaran. Di mode denah yang menentukan bentuk RUANGAN,
    /// bukan bentuk frame kamera — kalau tidak, denah 10x7,5 m diekspor ke
    /// kanvas 16:9 dan separuhnya kosong.
    private var ekspRasio: Double {
        // Di mode denah bentuk gambarnya ditentukan RUANGAN, bukan frame
        // kamera: mengekspor denah 10x7,5 m ke kanvas 16:9 menyisakan
        // seperempat gambar kosong di kiri dan kanan.
        if let v = kameraTergambar.first?.venueMeter,
           kameraTergambar.first?.adaDenah == true, v.height > 0 {
            return v.width / v.height
        }
        return kameraTergambar.first?.rasioVideo ?? 16.0 / 9.0
    }

    private var namaBerkas: String {
        let tab = vm.visual.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
        let video = (kameraTergambar.first?.namaVideo ?? "hasil")
            .replacingOccurrences(of: ".mp4", with: "")
        return "crowdflow-\(video)-\(tab)"
    }

    private func unduhGambar() {
        pesanEkspor = nil
        Ekspor.simpanPNG(viewEkspor(batasWaktu),
                         ukuran: Ekspor.ukuran(rasio: ekspRasio),
                         nama: namaBerkas)
    }

    private func unduhVideo() {
        lini.hentikan()
        sedangMerekam = true
        pesanEkspor = nil
        let k = kameraTergambar
        Ekspor.simpanVideo(
            ukuran: Ekspor.ukuran(rasio: ekspRasio),
            maksFrame: k.map(\.frameTerakhir).max() ?? 0,
            langkah: k.first?.jejakLangkah ?? 20,
            fpsSumber: k.first(where: { $0.fpsSumber > 0 })?.fpsSumber ?? 20,
            nama: namaBerkas,
            gambar: { viewEkspor($0) },
            selesai: { galat in
                sedangMerekam = false
                pesanEkspor = galat ?? "Video tersimpan."
            })
    }

    private var judulGabungan: String {
        let nama = vm.kamera.enumerated().map { i, k in
            k.label.isEmpty ? "Kamera \(i + 1)" : k.label
        }
        return nama.joined(separator: " + ")
    }

    private func orangPerZona(_ hasil: AnalysisResult?) -> [String: Int] {
        guard let h = hasil else { return [:] }
        return Dictionary(uniqueKeysWithValues:
            h.zones.map { ($0.code, h.lamaTinggal(di: $0.rect).orang) })
    }

    /// Satu panel visualisasi untuk satu sudut kamera.
    ///
    /// `hasil` nil berarti belum ada analisis sama sekali — yang tampil data
    /// contoh, dan itu sudah diberi peringatan di atas layar.
    @ViewBuilder
    private func panelVisual(_ kamera: [AnalysisResult], judul: String?) -> some View {
        // Kamera pertama menentukan latar dan rasio panel. Di mode gabungan
        // keduanya tidak dipakai sama sekali — bidang gambarnya venue, bukan
        // frame kamera mana pun.
        let hasil: AnalysisResult? = kamera.first
        let rasio = hasil?.rasioVideo ?? 16.0 / 9.0
        let latar = kamera.count > 1 ? nil : hasil?.latarURL
        ZStack(alignment: .topLeading) {
            ZStack {
                switch vm.visual {
                case .boundingBox:
                    // Video beranotasi yang benar-benar dirender pipeline.
                    // VideoChrome (tombol play yang tidak bisa diklik) hanya
                    // dipakai kalau videonya tidak ada.
                    if let u = hasil?.pathVideoURL {
                        PipelineVideo(url: u)
                    } else if let latar {
                        // Frame CCTV sungguhan, bukan mockup dengan ID
                        // karangan (7, 12, 23, 31) yang dulu tampil di sini —
                        // mockup itu terbaca seperti hasil deteksi padahal
                        // bukan, dan angkanya sama untuk video apa pun.
                        FrameDiam(latar: latar, rasio: rasio,
                                  pesan: "Video beranotasi tidak dirender untuk analisis ini.")
                    } else {
                        BoundingBoxContent(); VideoChrome()
                    }
                case .path:
                    PathContent(paths: hasil?.paths ?? SampleResult.paths,
                                rasio: rasio, latar: latar,
                                jejak: hasil?.jejak ?? [:],
                                hasil: hasil, hingga: batasWaktu, kamera: kamera)
                case .heatmap:
                    HeatmapView(blobs: hasil?.blobs ?? SampleResult.blobs,
                                grid: hasil?.grid, rasio: rasio, latar: latar,
                                hingga: batasWaktu,
                                hasil: hasil, kamera: kamera)
                    HeatmapLegend(maks: hasil?.grid?.sel.max())
                case .zona:
                    if let h = hasil {
                        ZonaEditorView(
                            zona: Binding(get: { vm.zona(h) },
                                          set: { vm.setZona(h, $0) }),
                            menyunting: vm.menyunting,
                            rasio: rasio, latar: latar, hasil: h,
                            hingga: batasWaktu,
                            kameraLain: Array(kamera.dropFirst()),
                            zonaLain: { vm.zona($0) },
                            angka: { r in
                                let l = h.lamaTinggal(di: r)
                                return (l.orang, l.rataDetik, h.kepadatan(di: r).porsi)
                            })
                    } else {
                        ZoneMapView(zones: SampleResult.zones, rasio: rasio, latar: latar)
                    }
                }
            }

            if let judul {
                Text(judul)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Space.s).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(Space.s)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
    }

    private var caption: String {
        switch vm.visual {
        case .boundingBox:
            return vm.videoURL == nil
                ? "Ilustrasi — video beranotasi belum ada untuk analisis ini."
                // Menyebutkan apa arti tiap tanda. Titik oranye itu yang jadi
                // sumber SELURUH tab lain, jadi pantas disebut namanya.
                : "Kotak = orang terdeteksi · angka = ID hasil pelacakan · "
                + "titik oranye = titik kaki, dan titik inilah yang dipakai "
                + "menghitung heatmap, zona, dan jalur · angka di pojok = jumlah "
                + "orang pada frame itu. ID bisa berganti kalau orangnya "
                + "tertutup terlalu lama."
        case .path:
            // Keterangan lama berbunyi "diproyeksikan ke bidang lantai".
            // Itu tidak benar: yang digambar koordinat gambar kamera apa
            // adanya, tanpa homografi. Perbedaannya penting — di ruang gambar,
            // orang yang jauh dari kamera tampak berpindah lebih sedikit
            // daripada orang dekat walau jaraknya sama.
            //
            // Yang dipilih juga jejak yang paling jauh BERPINDAH, bukan yang
            // paling lama terlacak: orang yang duduk diam terlacak paling lama
            // dan akan memenuhi gambar dengan titik yang tidak ke mana-mana.
            let semua = vm.hasil?.jejak.count ?? 0
            return "Garis biru samar = jejak semua \(semua) orang; yang menumpuk "
                + "berarti lintasan itu sering dilewati. Garis diputus tiap kali "
                + "orangnya sempat hilang, supaya lompatan ID tidak tergambar "
                + "sebagai perjalanan. Garis berwarna = "
                + "\(vm.paths.count) orang dengan perpindahan terjauh, lingkaran = "
                + "tempat mulai, panah = arah dan tempat berakhir (warna hanya "
                + "membedakan orang). " + akhiranRuang
        // Heatmap dan zona dihitung dari titik kaki yang SAMA dengan tab
        // Path, jadi ruangnya juga sama — kalau yang satu denah lantai, yang
        // dua lagi denah lantai, dan sebaliknya. Karena itu ketiganya memakai
        // kalimat penutup yang sama, `akhiranRuang`, bukan kalimat masing-
        // masing yang bisa saling bertentangan setelah diedit terpisah.
        case .heatmap:
            // Skala log disebutkan karena mengubah cara membaca gambarnya:
            // warna merah BUKAN berarti 10x lebih ramai dari biru.
            let n = vm.hasil?.grid.map { "\($0.total) titik kaki" } ?? "titik kaki"
            return "Kepadatan \(n): berapa sering ada orang berdiri di tiap petak. "
                + "Makin terang makin sering. Skalanya logaritmik, jadi warna "
                + "menunjukkan URUTAN keramaian, bukan kelipatannya — petak "
                + "paling terang bukan berarti dua kali lebih ramai dari yang di tengah. "
                + akhiranRuang
        case .zona:
            return "\(vm.zones.count) area terpadat, ditemukan otomatis dari kepadatan titik kaki. "
                + "Angka di label = berapa ORANG berbeda yang pernah berada di kotak itu. "
                + "Warna sama dengan daftar ranking di bawah. " + akhiranRuang
        }
    }

    /// Kalimat penutup yang menyebutkan gambarnya berada di ruang yang mana.
    ///
    /// Sebelum kalibrasi ada, ketiga tab menutup dengan "belum diproyeksikan ke
    /// denah lantai". Kalimat itu jadi keliru begitu kalibrasinya dipakai, dan
    /// keliru dengan cara yang paling merugikan: menyuruh orang meragukan
    /// gambar yang justru sudah benar.
    private var akhiranRuang: String {
        guard let h = vm.hasil, h.adaDenah, let v = h.venueMeter else {
            return "Belum dikalibrasi, jadi gambarnya masih dari sudut kamera — "
                + "jarak di gambar belum sebanding dengan jarak sebenarnya. "
                + "Pakai Mode Lengkap kalau ingin denah tampak atas."
        }
        var s = "Sudah diproyeksikan ke denah lantai lewat kalibrasi: "
            + "tampak atas, ruangan \(bulat(v.width)) × \(bulat(v.height)) m, "
            + "jarak di gambar = jarak sebenarnya."
        // Titik yang jatuh di luar denah dibuang. Jumlahnya disebutkan, karena
        // yang menentukan bukan pipeline melainkan letak empat titik kalibrasi
        // — dan itu bisa diperbaiki pengguna, kalau tahu.
        // Penggabungan dua kamera harus disebut, karena mengubah cara membaca
        // gambarnya: tidak ada pencocokan identitas lintas kamera, jadi orang
        // yang terlihat dua kamera menyumbang dua jejak dan dua kali kepadatan.
        if vm.bisaDisatukan {
            s += " Kedua kamera ditumpuk di denah yang sama karena keduanya"
                + " dikalibrasi ke ruangan ini. Identitas TIDAK dicocokkan"
                + " antar-kamera, jadi bagian yang terlihat dua kamera tampak"
                + " lebih pekat — baca itu sebagai lebih sering TERLIHAT, bukan"
                + " lebih ramai. Jumlah orang tidak diambil dari gambar ini."
        }
        if let luar = h.porsiDiLuarDenah, luar >= 0.02 {
            s += " \(Int((luar * 100).rounded()))% titik kaki jatuh di luar denah "
                + "dan tidak digambar — titik kalibrasinya belum mencakup seluruh "
                + "lantai yang terlihat kamera, atau ukuran ruangannya kekecilan."
        }
        return s
    }

    // MARK: Ranking + stop points

    private var rankingCard: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zona Paling Ramai").font(.headline)
                    Text("Batang = porsi kepadatan titik kaki di zona itu.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if vm.adaHasil {
                    // Mengikuti kotak yang BERLAKU sekarang — begitu zonanya
                    // digeser manual, urutan dan angkanya ikut berubah.
                    ForEach(Array(vm.peringkat(vm.hasil).enumerated()), id: \.element.0.id) { i, baris in
                        let (z, lama, porsi) = baris
                        ZoneRow(nama: z.nama, warna: z.colorHex, urutan: i + 1,
                                porsi: porsi, lama: lama)
                    }
                } else {
                    ForEach(Array(SampleResult.zones.enumerated()), id: \.element.id) { i, z in
                        ZoneRow(nama: z.name, warna: z.colorHex, urutan: i + 1,
                                porsi: z.share, lama: nil, cadangan: z.visits)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stop Point Terlama").font(.headline)
                    // Rata-rata per orang, bukan total: area yang dilewati
                    // banyak orang sebentar-sebentar akan menang kalau
                    // totalnya yang dipakai, padahal tak ada yang berhenti.
                    Text("Rata-rata lama satu orang berada di area itu.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if vm.adaHasil && vm.stops.isEmpty {
                    Text("Tidak ada orang yang terlacak di dalam zona mana pun.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(vm.stops) { stop in
                    HStack {
                        Image(systemName: "mappin.circle.fill").foregroundStyle(.orange)
                        Text(stop.name).font(.callout)
                        Spacer()
                        Text(stop.dwellText).font(.callout.monospacedDigit().weight(.semibold))
                    }
                }
            }
        }
        .card()
    }

    // MARK: Grafik okupansi

    private var satuan: String { vm.satuanWaktu }

    private var occupancyCard: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Okupansi dari Waktu ke Waktu").font(.headline)
            Chart(vm.occupancy) { point in
                AreaMark(x: .value(satuan, point.minute), y: .value("Orang", point.count))
                    .foregroundStyle(LinearGradient(
                        colors: [Theme.accent.opacity(0.35), Theme.accent.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                LineMark(x: .value(satuan, point.minute), y: .value("Orang", point.count))
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.catmullRom)
            }
            // Potongan pendek dihitung per detik. Sumbu yang selalu berbunyi
            // "menit ke-" membuat rekaman 16 detik terbaca 16 menit.
            .chartXAxisLabel("\(satuan) ke-")
            .chartYAxisLabel("orang")
            .frame(minHeight: 220)
        }
        .card()
    }
}

// MARK: - Baris zona (dengan warna)

private struct ZoneRow: View {
    let nama: String
    let warna: UInt
    let urutan: Int
    let porsi: Double
    /// nil untuk data contoh — jejak tidak tersedia, jadi jumlah orang tidak
    /// bisa dihitung dan angka pengamatan dipakai apa adanya.
    var lama: AnalysisResult.LamaTinggal?
    var cadangan: Int = 0

    private var color: Color { Color(hex: warna) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Space.s) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color)
                    .frame(width: 14, height: 14)
                Text("\(urutan).").font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
                Text(nama).font(.callout).lineLimit(1)
                Spacer()
                if let lama {
                    Text("\(lama.orang) orang")
                        .font(.callout.monospacedDigit().weight(.medium))
                    Text("· rata \(detik(lama.rataDetik))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Text("\(cadangan)").font(.callout.monospacedDigit().weight(.medium))
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color)
                        .frame(width: geo.size.width * min(1, max(0, porsi)))
                }
            }
            .frame(height: 6)
        }
    }

    private func detik(_ d: Double) -> String {
        d >= 60 ? "\(Int(d) / 60)m \(Int(d) % 60)s" : "\(Int(d.rounded()))s"
    }
}

// MARK: - Peta zona

/// Zona terpadat, di atas frame CCTV.
///
/// Zona ditemukan otomatis dari kepadatan titik kaki, jadi kotaknya berada di
/// ruang gambar kamera — bukan di denah. Menggambarnya di atas frame membuat
/// kotaknya bisa dinilai: apakah "Zona A" itu benar-benar konter, atau cuma
/// tempat orang lewat.
private struct ZoneMapView: View {
    let zones: [ZoneRank]
    var rasio: Double = 16.0 / 9.0
    var latar: URL?
    /// Jumlah orang per kode zona. nil untuk data contoh.
    var orangPerZona: [String: Int] = [:]

    var body: some View {
        GeometryReader { geo in
            let peta = PetaKamera(rasio: rasio, ukuran: geo.size, perbesar: nil)
            ZStack {
                (latar == nil ? Color(hex: 0xF7F8FA) : Color.black)

                Canvas { ctx, size in
                    gambarLatar(&ctx, latar, peta, redup: 0.5)
                    guard latar == nil else { return }
                    var grid = Path()
                    let cols = 10, rows = 6
                    for c in 0...cols { let x = size.width * CGFloat(c)/CGFloat(cols)
                        grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
                    for r in 0...rows { let y = size.height * CGFloat(r)/CGFloat(rows)
                        grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
                    ctx.stroke(grid, with: .color(Color(hex: 0x1E293B, alpha: 0.07)), lineWidth: 1)
                }

                ForEach(zones) { zone in
                    let color = Color(hex: zone.colorHex)
                    let r = peta.kotak(zone.rect)
                    let orang = orangPerZona[zone.code]
                    ZStack {
                        RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                            .fill(color.opacity(latar == nil ? 0.20 : 0.28))
                        RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                            .strokeBorder(color, lineWidth: 2)
                    }
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)

                    // Label DI LUAR kotak. Zona terkecil yang terukur cuma
                    // 3,8% × 3,7% bidang gambar — huruf dan angka di dalamnya
                    // akan tumpang tindih dan tidak terbaca sama sekali.
                    HStack(spacing: 4) {
                        Text(zone.code)
                            .font(.system(.caption, design: .rounded, weight: .bold))
                        // Jumlah orang, bukan jumlah pengamatan titik kaki —
                        // angka pengamatan terbaca seperti jumlah pengunjung
                        // padahal ratusan kali lipatnya.
                        Text(orang.map { "\($0) orang" } ?? "\(zone.visits)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(color, in: Capsule())
                    .position(x: r.midX, y: max(9, r.minY - 10))
                }
            }
        }
    }
}

/// Frame CCTV diam, dipakai saat video beranotasi tidak dirender.
private struct FrameDiam: View {
    let latar: URL
    var rasio: Double = 16.0 / 9.0
    let pesan: String

    var body: some View {
        ZStack {
            Color.black
            Canvas { ctx, size in
                let peta = PetaKamera(rasio: rasio, ukuran: size, perbesar: nil)
                gambarLatar(&ctx, latar, peta, redup: 1.0)
            }
            VStack {
                Spacer()
                Text(pesan)
                    .font(.caption).foregroundStyle(.white)
                    .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(Space.m)
            }
        }
    }
}

// MARK: - Konten video: bounding box

private struct BoundingBoxContent: View {
    @State private var phase = false
    private let boxes: [(id: Int, rect: CGRect)] = [
        (7,  CGRect(x: 0.18, y: 0.30, width: 0.10, height: 0.34)),
        (12, CGRect(x: 0.42, y: 0.26, width: 0.11, height: 0.40)),
        (23, CGRect(x: 0.64, y: 0.34, width: 0.09, height: 0.30)),
        (31, CGRect(x: 0.80, y: 0.42, width: 0.08, height: 0.26))
    ]
    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color(hex: 0x232733), Color(hex: 0x12151D)],
                               startPoint: .top, endPoint: .bottom)
                ForEach(boxes, id: \.id) { box in
                    let r = CGRect(x: box.rect.minX * geo.size.width, y: box.rect.minY * geo.size.height,
                                   width: box.rect.width * geo.size.width, height: box.rect.height * geo.size.height)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.accent, lineWidth: 2)
                            .frame(width: r.width, height: r.height)
                        Text("ID \(box.id)").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Theme.accent).foregroundStyle(.white).offset(y: -14)
                        Circle().fill(.orange).frame(width: 5, height: 5)
                            .offset(x: r.width / 2 - 2.5, y: r.height - 2.5)
                    }
                    .position(x: r.midX, y: r.midY)
                    .opacity(phase ? 1 : 0.6)
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { phase = true }
        }
    }
}

// MARK: - Konten video: path simulation

// MARK: - Pemetaan ke ruang gambar kamera
//
// Jalur, heatmap, dan zona SEMUANYA dihitung dari titik kaki yang sama, yang
// dinormalkan terhadap lebar dan tinggi frame secara terpisah. Karena itu
// ketiganya punya kebutuhan yang sama persis, dan dulu punya cacat yang sama:
//
//   - koordinatnya dipetakan langsung ke kotak gambar, sehingga bentuknya
//     memipih atau melebar mengikuti bentuk kotak, bukan mengikuti videonya;
//   - digambar di atas bidang kosong, sehingga tidak ada yang bisa tahu mana
//     meja dan mana konter.
//
// Satu pemetaan dipakai bertiga supaya ketiganya menunjuk tempat yang sama.

struct PetaKamera {
    let rasio: Double
    let ukuran: CGSize
    /// nil kalau seluruh frame ditampilkan; berisi kotak data kalau tidak ada
    /// frame CCTV dan gambar perlu diperbesar supaya tidak melompong.
    var perbesar: CGRect?

    /// Kalau hasilnya punya kalibrasi, titik diproyeksikan ke DENAH LANTAI
    /// lebih dulu: perspektif hilang dan satuannya meter.
    ///
    /// Tidak ada tombol untuk menyalakannya, dan memang tidak perlu — kalau
    /// denahnya sudah bisa dihitung, tidak ada alasan memilih tampilan
    /// berperspektif yang jaraknya tidak sebanding.
    var hasil: AnalysisResult?

    var denah: Bool { hasil?.adaDenah == true }

    private var bidang: CGRect {
        if denah, let v = hasil?.venueMeter {
            // Sedikit lebih besar dari ruangannya: batas dinding tidak menempel
            // di tepi kanvas, dan keterangan skala di bawahnya punya tempat.
            let napas = max(v.width, v.height) * 0.07
            return CGRect(x: -napas, y: -napas,
                          width: v.width + napas * 2, height: v.height + napas * 2)
        }
        return perbesar ?? CGRect(x: 0, y: 0, width: rasio, height: 1)
    }
    /// Satu skala untuk kedua sumbu. Skala berbeda memenuhi kanvas lebih
    /// rapat tapi memelintir bentuk — gambar jadi berbohong demi enak dilihat.
    var skala: CGFloat {
        min(ukuran.width / bidang.width, ukuran.height / bidang.height)
    }
    var geserX: CGFloat { (ukuran.width - bidang.width * skala) / 2 - bidang.minX * skala }
    var geserY: CGFloat { (ukuran.height - bidang.height * skala) / 2 - bidang.minY * skala }

    /// Titik hasil (0–1 terhadap lebar & tinggi frame) -> titik di kanvas,
    /// nil kalau di mode denah proyeksinya tidak bisa dipercaya.
    ///
    /// Yang menggambar titik per titik WAJIB memakai versi ini, bukan `titik`:
    /// titik di balik horizon tergambar di tempat yang masuk akal tapi salah,
    /// dan tidak ada cara melihatnya dari gambar jadinya.
    func titikSah(_ p: CGPoint) -> CGPoint? {
        guard denah else { return titik(p) }
        guard let m = hasil?.keLantai(p) else { return nil }
        return CGPoint(x: m.x * skala + geserX, y: m.y * skala + geserY)
    }

    /// Seperti `titikSah`, tapi titik yang gagal dijatuhkan jauh di luar kanvas
    /// supaya terpotong sendiri. Hanya untuk pemanggil yang tidak bisa
    /// menangani nil (misalnya perhitungan kotak pembungkus).
    func titik(_ p: CGPoint) -> CGPoint {
        if denah {
            guard let m = hasil?.keLantai(p) else { return CGPoint(x: -1e5, y: -1e5) }
            return CGPoint(x: m.x * skala + geserX, y: m.y * skala + geserY)
        }
        return CGPoint(x: p.x * rasio * skala + geserX, y: p.y * skala + geserY)
    }

    /// Titik denah (meter) -> titik kanvas. Untuk garis bantu, bukan data.
    func dariMeter(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * skala + geserX, y: y * skala + geserY)
    }

    /// Titik kanvas -> titik hasil (0–1 di frame kamera). Kebalikan `titik`.
    ///
    /// Dipakai penyuntingan zona: yang digeser jari itu piksel kanvas, yang
    /// disimpan koordinat gambar kamera, dan di mode denah keduanya dipisahkan
    /// oleh homografi — bukan cuma oleh skala.
    func balik(_ p: CGPoint) -> CGPoint? {
        guard skala > 0 else { return nil }
        let x = (p.x - geserX) / skala
        let y = (p.y - geserY) / skala
        if denah { return hasil?.dariLantai(CGPoint(x: x, y: y)) }
        return CGPoint(x: x / rasio, y: y)
    }
    /// Kotak hasil -> kotak di kanvas.
    ///
    /// Di mode denah, keempat sudutnya diproyeksikan satu per satu lalu diambil
    /// kotak pembungkusnya: persegi di gambar kamera menjadi trapesium di
    /// lantai, jadi memproyeksikan satu sudut lalu memakai lebar aslinya akan
    /// menaruh kotaknya di tempat yang salah.
    func kotak(_ r: CGRect) -> CGRect {
        if denah {
            // Keempat sudut harus sahih. Kalau satu saja gagal — misalnya sel
            // heatmap yang menyentuh dinding di atas horizon — kotak
            // pembungkusnya ditarik oleh sudut yang tersisa dan jadi jauh lebih
            // besar dari sel aslinya. Lebih baik tidak digambar.
            let sudut = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
                .compactMap(titikSah)
            guard sudut.count == 4 else { return .zero }
            let xs = sudut.map(\.x), ys = sudut.map(\.y)
            guard let x0 = xs.min(), let x1 = xs.max(),
                  let y0 = ys.min(), let y1 = ys.max() else { return .zero }
            return CGRect(x: x0, y: y0, width: max(x1 - x0, 1), height: max(y1 - y0, 1))
        }
        let a = titik(CGPoint(x: r.minX, y: r.minY))
        return CGRect(x: a.x, y: a.y,
                      width: r.width * rasio * skala, height: r.height * skala)
    }
    /// Seluruh bidang frame di kanvas — tempat menggambar foto CCTV.
    var bidangFrame: CGRect {
        CGRect(x: geserX, y: geserY, width: rasio * skala, height: skala)
    }

    /// Kotak yang benar-benar berisi data, dengan sedikit ruang napas.
    /// Dipakai hanya saat tidak ada frame CCTV.
    static func batasData(_ titik: [CGPoint], rasio: Double) -> CGRect? {
        let p = titik.map { CGPoint(x: $0.x * rasio, y: $0.y) }
        guard let x0 = p.map(\.x).min(), let x1 = p.map(\.x).max(),
              let y0 = p.map(\.y).min(), let y1 = p.map(\.y).max()
        else { return nil }
        return CGRect(x: x0, y: y0, width: max(x1 - x0, 0.01), height: max(y1 - y0, 0.01))
            .insetBy(dx: -0.04, dy: -0.04)
    }
}

/// Foto CCTV sebagai latar, diredupkan supaya tanda di atasnya tetap terbaca.
func gambarLatar(_ ctx: inout GraphicsContext, _ url: URL?, _ peta: PetaKamera,
                 redup: Double = 0.55, gelap: Bool = true) {
    // Di mode denah, frame CCTV tidak digambar: fotonya berperspektif,
    // sedangkan titik-titiknya sudah diratakan ke lantai. Menumpuk keduanya
    // akan menaruh orang di tempat yang tidak sesuai dengan gambar di
    // belakangnya — lebih menyesatkan daripada tidak ada latar sama sekali.
    // Yang dipasang justru denah lantai yang diunggah pengguna.
    if peta.denah { gambarDenah(&ctx, peta, redup: redup, gelap: gelap); return }
    guard let url, let img = NSImage(contentsOf: url) else { return }
    ctx.opacity = redup
    ctx.draw(Image(nsImage: img), in: peta.bidangFrame)
    ctx.opacity = 1
}

/// Latar mode denah: gambar denah lantai yang diunggah, kisi meter, batas
/// ruangan, dan penanda skala.
///
/// Kisi meter memberi JARAK, denah memberi ARTI. Dua-duanya perlu: tanpa kisi,
/// gambar ini tidak bisa dipakai mengukur; tanpa denah, jalur yang tergambar
/// tidak bisa ditafsirkan karena tidak ada yang tahu mana meja, mana konter,
/// mana pintu. Persis alasan tampilan kamera memakai frame CCTV sebagai latar.
///
/// Seluruh gambar denah dipetakan ke persegi venue — sama persis dengan
/// `floorToWorld` di layar Kalibrasi, jadi tidak ada penyelarasan kedua di sini
/// yang bisa meleset sendiri terhadap titik-titiknya.
///
/// `gelap` menyatakan warna permukaan panel, dan menentukan warna tinta. Tab
/// Heatmap memakai permukaan gelap karena skala warnanya (ungu -> kuning
/// terang) memang disetel untuk latar gelap; Jalur dan Zona memakai permukaan
/// terang supaya denahnya terbaca seperti denah di atas kertas.
private func gambarDenah(_ ctx: inout GraphicsContext, _ peta: PetaKamera,
                         redup: Double, gelap: Bool) {
    guard let v = peta.hasil?.venueMeter else { return }

    let lantai = CGRect(origin: peta.dariMeter(0, 0),
                        size: CGSize(width: v.width * peta.skala, height: v.height * peta.skala))

    let tinta = gelap ? Color.white : Color.black

    if let url = peta.hasil?.denahURL, let img = NSImage(contentsOf: url) {
        // Denah aslinya putih. Di panel gelap ia diredupkan supaya tanda di
        // atasnya tetap menang; di panel terang dibiarkan hampir penuh.
        ctx.opacity = gelap ? redup : 0.9
        ctx.draw(Image(nsImage: img), in: lantai)
        ctx.opacity = 1
    } else {
        // Tidak ada denah (mode "Canvas berskala"): lantai dibedakan tipis dari
        // luar ruangan supaya batas ruangan terbaca sebagai bidang.
        ctx.fill(Path(lantai), with: .color(tinta.opacity(0.05)))
    }

    // Kisi meter. Di ruangan yang sangat besar satu meter jadi terlalu rapat
    // untuk dibaca, jadi langkahnya naik ke 2 atau 5 m.
    let langkah: CGFloat = max(v.width, v.height) > 40 ? 5 : (max(v.width, v.height) > 18 ? 2 : 1)
    var kisi = Path()
    var x: CGFloat = 0
    while x <= v.width + 1e-6 {
        kisi.move(to: peta.dariMeter(x, 0)); kisi.addLine(to: peta.dariMeter(x, v.height))
        x += langkah
    }
    var y: CGFloat = 0
    while y <= v.height + 1e-6 {
        kisi.move(to: peta.dariMeter(0, y)); kisi.addLine(to: peta.dariMeter(v.width, y))
        y += langkah
    }
    ctx.stroke(kisi, with: .color(tinta.opacity(0.14)), lineWidth: 1)
    ctx.stroke(Path(lantai), with: .color(tinta.opacity(0.35)), lineWidth: 1.5)

    // Skala disebut angkanya, bukan cuma digambar kisinya: tanpa angka, kisi
    // rapat dan kisi renggang terlihat sama saja.
    //
    // Ditaruh DI DALAM lantai, bukan di bawahnya: di luar, tulisannya terpotong
    // tepi panel — terukur pada tangkapan layar dua kamera, terpotong separuh.
    let teks = Text("kisi \(bulat(langkah)) m · ruangan \(bulat(v.width)) × \(bulat(v.height)) m")
        .font(.caption2.monospacedDigit())
        .foregroundStyle(tinta.opacity(0.75))
    ctx.draw(teks, at: CGPoint(x: lantai.minX + 6, y: lantai.maxY - 6), anchor: .bottomLeading)
}

private func bulat(_ v: CGFloat) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
}

/// Jalur pergerakan di RUANG GAMBAR KAMERA.
///
/// Dua hal yang membuat versi sebelumnya terlihat kosong dan patah-patah, dan
/// keduanya bukan soal selera:
///
/// 1. Titik kaki hanya menempati bagian bawah frame — di kamera pantry, lantai
///    memang cuma terlihat di separuh bawah (terukur: y 0,52–1,00). Kanvas
///    yang dipetakan 0–1 penuh karena itu SELALU kosong separuh atasnya, video
///    apa pun. Sekarang gambarnya dipangkas ke kotak yang benar-benar berisi
///    data, dengan skala yang SAMA untuk x dan y supaya bentuk jalurnya tidak
///    ikut terpelintir — yang berubah cuma perbesarannya.
///
/// 2. Perspektif belum dihilangkan. Orang yang jauh dari kamera tampak
///    berpindah sedikit walau jaraknya sama dengan yang dekat. Memperbaiki itu
///    butuh homografi dari layar Kalibrasi, dan itu belum ada — jadi jangan
///    membaca panjang jalur di sini sebagai jarak sebenarnya. Keterangan di
///    bawah gambar menyebutkan hal ini.
private struct PathContent: View {
    let paths: [PathTrace]
    /// Lebar : tinggi video asli. Koordinat x dan y sudah dibagi lebar dan
    /// tinggi TERPISAH, jadi tanpa dikalikan rasio ini lagi, jalur di video
    /// 16:9 tergambar seolah videonya bujur sangkar.
    var rasio: Double = 16.0 / 9.0
    /// Frame CCTV di belakang jalur. Tanpa ini gambarnya benar secara angka
    /// tapi tidak berarti apa-apa — orang tidak bisa tahu mana meja, mana
    /// konter, mana pintu, jadi jalur yang tergambar tidak bisa ditafsirkan.
    var latar: URL?
    /// Jejak SEMUA orang, bukan cuma 12 yang disorot.
    ///
    /// Pola lalu-lalang tidak muncul dari satu jalur yang panjang, melainkan
    /// dari banyak jalur yang bertumpuk: lintasan yang dilewati berkali-kali
    /// menumpuk jadi garis terang, yang cuma dilewati sekali tetap samar.
    /// Pipeline membatasi `paths` di 12 supaya gambarnya tidak penuh — tapi
    /// `jejak` memuat semua orang, dan selama ini menganggur di berkas hasil.
    var jejak: [String: [CGPoint]] = [:]
    /// Dipakai untuk proyeksi ke denah lantai kalau kameranya sudah dikalibrasi.
    var hasil: AnalysisResult?
    /// Gambar hanya sampai frame ini. nil = seluruh rekaman (gambar ringkasan).
    var hingga: Int?
    /// Semua sudut kamera yang digambar di panel ini.
    ///
    /// Lebih dari satu hanya terjadi di mode denah, dan di situ memang sahih:
    /// tiap kamera punya homografinya sendiri ke RUANGAN YANG SAMA, jadi
    /// titiknya sudah berada di satu sistem koordinat meter sebelum digambar.
    /// Tidak ada penyelarasan tambahan, dan tidak ada pencocokan identitas
    /// lintas kamera — yang ditumpuk lintasannya, bukan orangnya.
    var kamera: [AnalysisResult] = []

    private var daftar: [AnalysisResult] {
        kamera.count > 1 ? kamera : (hasil.map { [$0] } ?? [])
    }

    var body: some View {
        Canvas { ctx, size in
            // Ada frame CCTV -> tampilkan seluruh frame; latarnya yang memberi
            // arti pada ruang kosong. Tidak ada frame -> perbesar ke data,
            // karena bidang kosong yang separuhnya melompong tidak berguna.
            let peta = PetaKamera(
                rasio: rasio, ukuran: size,
                perbesar: latar == nil
                    ? PetaKamera.batasData(paths.flatMap(\.points), rasio: rasio)
                    : nil,
                hasil: hasil)

            gambarLatar(&ctx, latar, peta, gelap: !peta.denah)

            // Grid hanya saat tidak ada foto — di atas foto, garis bantu
            // menambah kekacauan tanpa menambah keterangan apa pun. Di mode
            // denah, kisi meternya sudah digambar `gambarDenah` dan kisi 0,1
            // bidang gambar ini tidak berarti apa-apa lagi.
            if latar == nil && !peta.denah {
                var grid = Path()
                let langkah: CGFloat = 0.1
                for i in 0...Int(rasio / langkah) {
                    let x = peta.titik(CGPoint(x: Double(i) * langkah / rasio, y: 0)).x
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                for i in 0...Int(1 / langkah) {
                    let y = peta.titik(CGPoint(x: 0, y: Double(i) * langkah)).y
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                ctx.stroke(grid, with: .color(Color(hex: 0x1E293B, alpha: 0.07)), lineWidth: 1)
            }

            // LAPIS BAWAH: jejak semua orang, tipis dan samar.
            //
            // Digambar dengan warna sama dan tembus pandang, jadi yang
            // menumpuk otomatis jadi lebih terang — itulah lintasan yang
            // benar-benar sering dilewati. Satu orang lewat hampir tak
            // terlihat; sepuluh orang lewat di garis yang sama jadi jelas.
            // Garis DIPUTUS di tiap lompatan.
            //
            // Jejak dicuplik sedetik sekali. Kalau dua titik berurutan
            // berjauhan, itu bukan orang berjalan cepat — itu orang yang
            // sempat tertutup lalu muncul lagi di tempat lain, atau dua
            // potongan track yang disambungkan. Menyambungnya jadi garis lurus
            // menggambar perjalanan yang tidak pernah terjadi.
            //
            // Terukur pada rekaman 3 menit: ruas terpanjang 1,12 lebar frame
            // dalam SATU detik — menyeberangi seluruh ruangan lebih dari
            // sekali. Batas di bawah kira-kira secepat orang berjalan
            // (~1,5 m/s di ruangan 7 meter); 7% ruas melewatinya dan dibuang.
            // Satu putaran per sudut kamera. Tiap kamera punya PETA-nya
            // sendiri — homografinya berbeda, venue-nya sama — jadi lintasan
            // keduanya jatuh di kotak kanvas yang sama tanpa penyelarasan
            // tambahan apa pun.
            //
            // Yang ditumpuk LINTASANNYA, bukan orangnya: tidak ada pencocokan
            // identitas lintas kamera di sini, jadi satu orang yang terlihat
            // dua kamera menyumbang dua jejak. Untuk membaca lintasan mana yang
            // sering dilewati itu tidak apa-apa; untuk MENGHITUNG orang, tidak
            // boleh — dan angka orang memang tidak diambil dari gambar ini.
            for k in (daftar.isEmpty ? [nil] : daftar.map { Optional($0) }) {
            let peta = k.map {
                PetaKamera(rasio: rasio, ukuran: size, perbesar: peta.perbesar, hasil: $0)
            } ?? peta
            let paths = k?.paths ?? self.paths

            let batasLangkah = 0.15
            for (_, titik) in jejakTerpotong(k) where titik.count >= 2 {
                var g = Path()
                var mulaiBaru = true
                for (a, b) in zip(titik, titik.dropFirst()) {
                    let jauh = hypot((b.x - a.x) * rasio, b.y - a.y)
                    if jauh > batasLangkah { mulaiBaru = true; continue }
                    // Di mode denah, ruas yang salah satu ujungnya tidak bisa
                    // diproyeksikan diputus, bukan dilewati diam-diam:
                    // menyambungkan dua titik yang mengapitnya menggambar
                    // perjalanan lurus yang tidak pernah terjadi.
                    guard let pa = peta.titikSah(a), let pb = peta.titikSah(b) else {
                        mulaiBaru = true; continue
                    }
                    if mulaiBaru { g.move(to: pa); mulaiBaru = false }
                    g.addLine(to: pb)
                }
                // Di atas denah putih, cyan nyaris tidak terlihat; di atas
                // foto CCTV yang gelap, biru tua yang hilang. Warnanya
                // mengikuti permukaan, kepekatannya tidak — yang menumpuk
                // tetap harus jadi lebih terang.
                ctx.stroke(g, with: .color(terang
                                           ? Color(hex: 0x1D4ED8, alpha: 0.20)
                                           : .cyan.opacity(0.18)),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }

            for trace in (k == nil ? jalurTersorot : (hingga == nil ? paths : [])) {
                // Potongan menerus terpanjang yang bisa diproyeksikan. Lingkaran
                // "mulai" dan panah "berakhir" hanya boleh menandai satu
                // perjalanan yang benar-benar utuh — kalau jejaknya terbelah
                // karena sebagian keluar denah, menggambar keduanya di ujung
                // yang tersisa akan menyebut tempat mulai yang keliru.
                let pts = potonganTerpanjang(trace.points, peta)
                guard pts.count >= 2 else { continue }
                let warna = Color(hue: trace.hue, saturation: 0.72, brightness: 0.82)

                var garis = Path()
                garis.addLines(pts)
                // Garis putih di bawahnya memisahkan jalur yang bersilangan —
                // tanpa itu, jalur yang menumpuk terbaca sebagai satu.
                // Garis kontras di bawahnya memisahkan jalur yang bersilangan,
                // dan menahan warna jalur supaya tetap terbaca di atas foto.
                ctx.stroke(garis, with: .color(terang
                                               ? Color(hex: 0xF7F8FA, alpha: 0.9)
                                               : .black.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))
                ctx.stroke(garis, with: .color(warna),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                // Titik awal berongga, ujung berupa panah: arah gerak terbaca
                // tanpa perlu legenda hijau/merah.
                let awal = pts[0]
                ctx.fill(Path(ellipseIn: CGRect(x: awal.x - 4, y: awal.y - 4, width: 8, height: 8)),
                         with: .color(terang ? Color(hex: 0xF7F8FA) : .black))
                ctx.stroke(Path(ellipseIn: CGRect(x: awal.x - 4, y: awal.y - 4, width: 8, height: 8)),
                           with: .color(warna), lineWidth: 2)

                let akhir = pts[pts.count - 1]
                let sebelum = pts[max(0, pts.count - 3)]
                let sudut = atan2(akhir.y - sebelum.y, akhir.x - sebelum.x)
                var panah = Path()
                let panjang: CGFloat = 9, lebar: CGFloat = 0.42
                panah.move(to: akhir)
                panah.addLine(to: CGPoint(x: akhir.x - panjang * cos(sudut - lebar),
                                          y: akhir.y - panjang * sin(sudut - lebar)))
                panah.addLine(to: CGPoint(x: akhir.x - panjang * cos(sudut + lebar),
                                          y: akhir.y - panjang * sin(sudut + lebar)))
                panah.closeSubpath()
                ctx.fill(panah, with: .color(warna))
            }
            }
        }
        .background(terang ? Color(hex: 0xF7F8FA) : .black)
    }

    /// Permukaan panel terang atau gelap.
    ///
    /// Ada TIGA keadaan, bukan dua, dan itu yang membuat `latar == nil` tidak
    /// lagi cukup: ada frame CCTV (gelap, supaya foto menang), tidak ada frame
    /// (terang), dan mode denah (terang — denah lantai terbaca seperti denah
    /// di atas kertas, dan gambarnya memang putih).
    private var terang: Bool { (hasil?.adaDenah ?? false) || latar == nil }

    /// Jejak yang ditampilkan pada posisi lini masa sekarang.
    ///
    /// Tanpa `hingga` (gambar ringkasan) yang dipakai `jejak` biasa, supaya
    /// hasil lama — yang tidak punya `jejakWaktu` — tetap tergambar utuh.
    private func jejakTerpotong(_ k: AnalysisResult?) -> [String: [CGPoint]] {
        let sumber = k ?? hasil
        guard let hingga else { return k?.jejak ?? self.jejak }
        guard let w = sumber?.jejakWaktu, !w.isEmpty else { return k?.jejak ?? self.jejak }
        return w.compactMapValues { deret -> [CGPoint]? in
            let potong = deret.prefix { $0.frame <= hingga }.map(\.titik)
            return potong.count >= 2 ? potong : nil
        }
    }

    /// Jalur tersorot yang sudah SELESAI pada posisi lini masa sekarang.
    ///
    /// Jalur tersorot tidak punya waktu sendiri — `paths` cuma daftar titik.
    /// Jadi saat animasi berjalan, yang digambar hanya jejak; jalur berwarna
    /// muncul kembali di gambar penuh. Menggambarnya utuh sejak detik nol akan
    /// memperlihatkan perjalanan yang belum terjadi.
    private var jalurTersorot: [PathTrace] { hingga == nil ? paths : [] }

    /// Deret titik kanvas menerus terpanjang; di luar mode denah selalu utuh.
    private func potonganTerpanjang(_ titik: [CGPoint], _ peta: PetaKamera) -> [CGPoint] {
        var terbaik: [CGPoint] = [], kini: [CGPoint] = []
        for p in titik {
            if let q = peta.titikSah(p) { kini.append(q) }
            else { if kini.count > terbaik.count { terbaik = kini }; kini = [] }
        }
        return kini.count > terbaik.count ? kini : terbaik
    }
}

// MARK: - Heatmap + legend

private struct HeatmapLegend: View {
    /// Nilai sel tertinggi, supaya legendanya menyebut angka sungguhan dan
    /// bukan cuma "rendah/tinggi" yang tidak bisa dipakai membandingkan
    /// apa pun antar analisis.
    var maks: Int?

    private let warna: [Color] = [
        Color(hex: 0x3B0F70), Color(hex: 0xB6377A), Color(hex: 0xF1605D),
        Color(hex: 0xFEAF77), Color(hex: 0xFCFDBF),
    ]

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: Space.s) {
                    Text("jarang").font(.caption2).foregroundStyle(.white.opacity(0.85))
                    LinearGradient(colors: warna, startPoint: .leading, endPoint: .trailing)
                        .frame(width: 90, height: 8).clipShape(Capsule())
                    if let maks {
                        Text("sering (maks \(maks)x)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                    } else {
                        Text("sering").font(.caption2).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                .background(.black.opacity(0.45), in: Capsule())
            }
        }
        .padding(Space.m)
    }
}

/// Kepadatan titik kaki, di atas frame CCTV.
///
/// Sumbernya `grid` — petak 120×68 yang dihitung pipeline dari SETIAP titik
/// kaki (18.000-an titik pada rekaman satu menit). Sebelumnya yang dipakai
/// `blobs`: 28 lingkaran beradius seragam, ringkasan kasar dari petak yang
/// sama. Petaknya sudah dikirim sejak awal dan tinggal dipakai.
///
/// `blobs` tetap dipakai kalau petaknya tidak ada, supaya hasil lama tetap
/// tergambar.
private struct HeatmapView: View {
    let blobs: [HeatBlob]
    var grid: (w: Int, h: Int, total: Int, sel: [Int])?
    var rasio: Double = 16.0 / 9.0
    var latar: URL?
    /// Kumpulkan hanya sampai frame ini. nil = petak penuh dari pipeline.
    var hingga: Int?
    /// Dipakai untuk proyeksi ke denah lantai kalau kameranya sudah dikalibrasi.
    var hasil: AnalysisResult?
    /// Semua sudut kamera yang digambar di panel ini.
    ///
    /// Lebih dari satu hanya terjadi di mode denah, dan di situ memang sahih:
    /// tiap kamera punya homografinya sendiri ke RUANGAN YANG SAMA, jadi
    /// titiknya sudah berada di satu sistem koordinat meter sebelum digambar.
    /// Tidak ada penyelarasan tambahan, dan tidak ada pencocokan identitas
    /// lintas kamera — yang ditumpuk lintasannya, bukan orangnya.
    var kamera: [AnalysisResult] = []

    private var daftar: [AnalysisResult] {
        kamera.count > 1 ? kamera : (hasil.map { [$0] } ?? [])
    }

    var body: some View {
        Canvas { ctx, size in
            let peta = PetaKamera(rasio: rasio, ukuran: size, perbesar: nil, hasil: hasil)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x0F1524)))
            // Latar lebih gelap di sini: warna panas harus menang atas foto.
            gambarLatar(&ctx, latar, peta, redup: 0.42)

            // Tiap kamera digambar dengan PETA-nya sendiri — homografinya
            // berbeda, venue-nya sama — jadi keduanya jatuh di kotak kanvas
            // yang sama tanpa perlu menggabungkan petaknya lebih dulu.
            //
            // Warnanya bertumpuk, jadi bagian yang terlihat DUA kamera tampak
            // lebih panas. Itu bukan galat penggambaran, tapi harus dibaca
            // sebagai "lebih sering TERLIHAT", bukan "lebih ramai" — dan itu
            // disebutkan di keterangan bawah gambar.
            if daftar.count > 1 {
                for k in daftar {
                    let pk = PetaKamera(rasio: rasio, ukuran: size, perbesar: nil, hasil: k)
                    if let g = petakSampai(k) ?? k.grid, !g.sel.isEmpty, g.w > 0, g.h > 0 {
                        gambarPetak(&ctx, g, pk)
                    } else {
                        gambarBlobs(&ctx, k.blobs, pk)
                    }
                }
            } else if let g = petakSampai(hasil) ?? grid, !g.sel.isEmpty, g.w > 0, g.h > 0 {
                gambarPetak(&ctx, g, peta)
            } else {
                gambarBlobs(&ctx, blobs, peta)
            }
        }
    }

    /// Petak kepadatan yang dikumpulkan sendiri dari titik kaki sampai `hingga`.
    ///
    /// Petak dari pipeline sudah menjumlahkan SELURUH rekaman dan tidak bisa
    /// dipotong per waktu — jadi untuk animasi, petaknya dihitung ulang di sini
    /// dari `jejakWaktu`. Ukuran petaknya sengaja disamakan dengan milik
    /// pipeline supaya bentuk gumpalannya tidak berubah waktu animasi berhenti
    /// dan gambar penuh mengambil alih.
    ///
    /// nil = tidak ada batas waktu, atau hasil lama yang tidak punya waktu.
    private func petakSampai(_ k: AnalysisResult?) -> (w: Int, h: Int, total: Int, sel: [Int])? {
        guard let hingga, let k, !k.jejakWaktu.isEmpty else { return nil }
        let w = k.grid?.w ?? 120, h = k.grid?.h ?? 68
        guard w > 0, h > 0 else { return nil }
        var sel = [Int](repeating: 0, count: w * h)
        var total = 0
        for (_, deret) in k.jejakWaktu {
            for t in deret where t.frame <= hingga {
                let cx = min(w - 1, max(0, Int(t.titik.x * Double(w))))
                let cy = min(h - 1, max(0, Int(t.titik.y * Double(h))))
                sel[cy * w + cx] += 1
                total += 1
            }
        }
        return total > 0 ? (w: w, h: h, total: total, sel: sel) : nil
    }

    private func gambarPetak(_ ctx: inout GraphicsContext,
                             _ g: (w: Int, h: Int, total: Int, sel: [Int]),
                             _ peta: PetaKamera) {
        let maks = g.sel.max() ?? 1
        guard maks > 0 else { return }
        // Skala LOGARITMIK, bukan linear. Terukur pada rekaman satu menit:
        // nilai sel berkisar 1–1055, dan dengan skala linear 93% sel terisi
        // jatuh di bawah 5% intensitas — nyaris tak terlihat, sehingga peta
        // hanya memperlihatkan satu-dua titik terpanas dan menyembunyikan
        // seluruh pola lalu-lalangnya. Dengan log, tidak ada sel yang hilang.
        let pembagi = log1p(Double(maks))
        let lebarSel = 1.0 / Double(g.w), tinggiSel = 1.0 / Double(g.h)

        ctx.addFilter(.blur(radius: 9))
        ctx.drawLayer { lapis in
            for (i, v) in g.sel.enumerated() where v > 0 {
                let t = log1p(Double(v)) / pembagi
                let r = peta.kotak(CGRect(x: Double(i % g.w) * lebarSel,
                                          y: Double(i / g.w) * tinggiSel,
                                          width: lebarSel, height: tinggiSel))
                // Sedikit dilebihkan supaya antar-sel tidak menyisakan celah
                // yang membuat peta tampak berlubang-lubang.
                lapis.fill(Path(CGRect(x: r.minX, y: r.minY,
                                       width: r.width * 1.6, height: r.height * 1.6)),
                           with: .color(warnaPanas(t).opacity(0.28 + 0.62 * t)))
            }
        }
    }

    private func gambarBlobs(_ ctx: inout GraphicsContext, _ blobs: [HeatBlob], _ peta: PetaKamera) {
        ctx.addFilter(.blur(radius: 18))
        ctx.drawLayer { lapis in
            for blob in blobs {
                guard let pusat = peta.titikSah(CGPoint(x: blob.x, y: blob.y)) else { continue }
                let r = blob.radius * peta.skala * rasio
                let kotak = CGRect(x: pusat.x - r, y: pusat.y - r, width: r * 2, height: r * 2)
                lapis.fill(Path(ellipseIn: kotak), with: .radialGradient(
                    Gradient(stops: [
                        .init(color: warnaPanas(blob.intensity).opacity(0.9), location: 0),
                        .init(color: warnaPanas(blob.intensity).opacity(0.0), location: 1)
                    ]),
                    center: pusat, startRadius: 0, endRadius: r))
            }
        }
    }

    /// Skala warna dengan KECERAHAN yang naik terus.
    ///
    /// Sebelumnya biru → hijau → kuning → merah. Pelangi seperti itu tidak
    /// bisa diurutkan oleh mata: hijau tidak terlihat "lebih besar" dari biru,
    /// dan lompatan hijau→kuning terbaca seperti ganti kategori, bukan naik
    /// jumlah. Merah di ujung juga lebih gelap daripada kuning di tengahnya,
    /// jadi urutannya malah terbalik di bagian paling ramai.
    ///
    /// Ramp di bawah ini ungu tua → merah → oranye → kuning terang: kecerahan
    /// naik satu arah dari awal sampai akhir, jadi urutannya terbaca tanpa
    /// menghafal legenda, dan tetap terbaca oleh mata yang buta warna merah-
    /// hijau karena yang membedakan terang-gelapnya, bukan corak warnanya.
    private func warnaPanas(_ i: Double) -> Color {
        let henti: [(Double, UInt)] = [
            (0.00, 0x3B0F70),   // ungu tua
            (0.35, 0xB6377A),   // magenta
            (0.65, 0xF1605D),   // merah oranye
            (0.85, 0xFEAF77),   // oranye muda
            (1.00, 0xFCFDBF),   // kuning terang
        ]
        let t = min(max(i, 0), 1)
        for k in 1..<henti.count where t <= henti[k].0 {
            let (t0, c0) = henti[k - 1], (t1, c1) = henti[k]
            let f = t1 > t0 ? (t - t0) / (t1 - t0) : 0
            return campur(c0, c1, f)
        }
        return Color(hex: henti[henti.count - 1].1)
    }

    private func campur(_ a: UInt, _ b: UInt, _ f: Double) -> Color {
        func pecah(_ c: UInt) -> (Double, Double, Double) {
            (Double((c >> 16) & 0xFF), Double((c >> 8) & 0xFF), Double(c & 0xFF))
        }
        let (r1, g1, b1) = pecah(a), (r2, g2, b2) = pecah(b)
        return Color(red: (r1 + (r2 - r1) * f) / 255,
                     green: (g1 + (g2 - g1) * f) / 255,
                     blue: (b1 + (b2 - b1) * f) / 255)
    }
}

// MARK: - Chrome video (play + scrubber)

private struct VideoChrome: View {
    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.35)).frame(width: 62, height: 62)
                .overlay(Image(systemName: "play.fill").font(.title2).foregroundStyle(.white))
            VStack {
                Spacer()
                HStack(spacing: Space.s) {
                    Image(systemName: "play.fill").font(.caption).foregroundStyle(.white)
                    Capsule().fill(.white.opacity(0.3)).frame(height: 4)
                        .overlay(alignment: .leading) {
                            GeometryReader { g in Capsule().fill(.white).frame(width: g.size.width * 0.32) }
                        }
                    Text("0:04 / 0:12").font(.caption2.monospacedDigit()).foregroundStyle(.white)
                }
                .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                .background(.black.opacity(0.28))
            }
        }
    }
}

#Preview {
    ResultsView()
        .environment(AppRouter())
        .environment(AnalysisSession())
        .frame(width: 1200, height: 900)
}
