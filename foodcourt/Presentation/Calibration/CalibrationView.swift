//
//  CalibrationView.swift
//  foodcourt
//

import SwiftUI
import AppKit
import AVFoundation
import PDFKit
import UniformTypeIdentifiers

struct CalibrationView: View {
    @Environment(\.uiScale) private var scale
    @Environment(AppRouter.self) private var router
    @Environment(AnalysisSession.self) private var session

    @State private var selectedCameraIndex = 0
    @State private var floorPlanImage: NSImage?
    @State private var cameraFrameImage: NSImage?
    @State private var isLoadingFrame = false
    @State private var message: String?
    @State private var reloadToken = UUID()

    private var selectedIndex: Int {
        min(max(0, selectedCameraIndex), max(0, session.cameras.count - 1))
    }

    private var selectedCamera: SessionCamera? {
        guard session.cameras.indices.contains(selectedIndex) else { return nil }
        return session.cameras[selectedIndex]
    }

    var body: some View {
        Group {
            if session.cameras.isEmpty { emptyState }
            else { calibrationContent }
        }
        .task(id: reloadToken) {
            await refreshImages()
            // Homografi DITURUNKAN dari titik + ukuran ruangan, jadi ia
            // dihitung ulang tiap layar ini muncul, bukan disimpan lalu
            // dipercaya. Ukuran ruangan diketik di layar Import — satu layar
            // sebelum ini — dan sebelumnya mengubahnya di sana tidak
            // menyentuh homografi sama sekali: titiknya tetap, centangnya
            // tetap hijau, tapi angka meternya sudah tidak berlaku lagi.
            // Persis kesalahan yang sama dengan penggantian denah.
            recalculateAllCameras(diam: true)
        }
        .onChange(of: selectedCameraIndex) { _, _ in reloadToken = UUID() }
    }

    private var emptyState: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "camera.metering.none")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Belum ada kamera").font(.headline)
            Text("Import video dulu di langkah sebelumnya.")
                .font(.callout)
                .foregroundStyle(.secondary)
            GhostButton(title: "Ke Import", systemImage: "chevron.left") { router.back() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var calibrationContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l * scale) {
                    header

                    barisPesan

                    canvases
                        .frame(height: 360 * scale)

                    inspector
                }
                .spad(Space.xl, [.horizontal, .top])
                .padding(.bottom, Space.xl)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            WizardFooter(onBack: { router.back() }) {
                PrimaryButton(
                    title: session.allCalibrated ? "Kalibrasi Selesai" : "Kalibrasi Semua Kamera",
                    systemImage: "checkmark.seal",
                    enabled: session.allCalibrated
                ) {
                    router.next()
                }
            }
        }
    }

    /// Satu baris pesan di bawah kepala layar.
    ///
    /// Ada 18 tempat di berkas ini yang mengisi `message` — hasil kalibrasi,
    /// titik ditambah, denah diganti, profil diimpor, semua kegagalan — dan
    /// TIDAK ADA SATU PUN yang menampilkannya. Jadi selama ini layar Kalibrasi
    /// bekerja tanpa suara: pengguna mengklik, sesuatu terjadi atau gagal, dan
    /// tidak ada kabar apa pun. Peringatan ukuran ruangan tertukar pun ikut
    /// tenggelam, padahal justru itu yang paling perlu terbaca.
    ///
    /// Bukan tampilan baru — cuma menyambungkan yang sudah ditulis.
    @ViewBuilder
    private var barisPesan: some View {
        let peringatan = peringatanRasio
        if peringatan != nil || message != nil {
            let teks = peringatan ?? message ?? ""
            // Peringatan menang atas pesan biasa: pesan biasa cuma memberi
            // tahu apa yang barusan terjadi, peringatan memberi tahu hasilnya
            // akan salah.
            let buruk = peringatan != nil || teks.hasPrefix("Gagal")
            HStack(spacing: Space.s) {
                Image(systemName: buruk ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(buruk ? .orange : .secondary)
                Text(teks)
                    .font(.callout)
                    .foregroundStyle(buruk ? .primary : .secondary)
                Spacer()
            }
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
            .background((buruk ? Color.orange : Color.primary).opacity(0.08),
                        in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.m * scale) {
            SectionHeader(
                title: "Kalibrasi",
                subtitle: "Pilih titik lantai yang sama pada CCTV dan denah. Gunakan 4–8 pasangan titik bebas."
            )
            HStack(spacing: Space.s) {
                ForEach(Array(session.cameras.enumerated()), id: \.element.id) { index, camera in
                    Button {
                        selectedCameraIndex = index
                    } label: {
                        HStack(spacing: Space.s) {
                            Image(systemName: camera.isCalibrated ? "checkmark.circle.fill" : "camera")
                                .foregroundStyle(camera.isCalibrated ? .green : (index == selectedIndex ? .white : .secondary))
                            Text(camera.label)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, Space.m)
                        .padding(.vertical, Space.s)
                        .foregroundStyle(index == selectedIndex ? Color.white : Color.primary)
                        .background(index == selectedIndex ? Theme.accent : Color.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Pilih \(camera.label)")
                }
                Spacer()
                Button("Impor Profil", systemImage: "square.and.arrow.down") { importProfile() }
                    .buttonStyle(.bordered)
                Button("Ekspor Profil", systemImage: "square.and.arrow.up") { exportProfile() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.allCalibrated)
            }
        }
    }

    private var canvases: some View {
        let camera = selectedCamera
        let calibration = camera?.calibration
        return HStack(spacing: Space.m * scale) {
            CalibrationCanvas(
                title: "Frame CCTV — \(camera?.label ?? "")",
                subtitle: isLoadingFrame ? "Memuat frame…" : "Klik titik lantai, lalu klik pasangan yang sama di denah.",
                image: cameraFrameImage,
                sourceSize: camera?.framePixelSize?.cgSize,
                points: camera?.imagePoints ?? [],
                projectedPoints: [],
                accent: Theme.accent,
                canInteract: cameraFrameImage != nil,
                canvasAccessory: nil,
                footerAccessory: nil,
                emptyState: AnyView(
                    ContentUnavailableView(
                        "Frame belum tersedia",
                        systemImage: "video.slash",
                        description: Text("Pilih video pada langkah Import atau tunggu frame dimuat.")
                    )
                ),
                onAdd: { addCameraPoint($0) },
                onDeletePair: { deletePair(at: $0) },
                onMove: { geserTitikKamera($0, ke: $1) }
            )
            CalibrationCanvas(
                title: session.usesScaledCanvas ? "Canvas Berskala" : (session.floorPlanName ?? "Floor Plan"),
                subtitle: "Seluruh gambar dipetakan ke \(session.widthM) × \(session.heightM) m.",
                image: session.usesScaledCanvas ? nil : floorPlanImage,
                sourceSize: session.usesScaledCanvas ? nil : session.floorPlanPixelSize?.cgSize,
                points: camera?.planePoints ?? [],
                projectedPoints: validationPoints(calibration),
                jangkauan: jangkauanLantai(camera),
                accent: .orange,
                canInteract: session.usesScaledCanvas || floorPlanImage != nil,
                canvasAccessory: floorPlanCanvasAction,
                footerAccessory: AnyView(floorSourcePicker),
                emptyState: nil,
                onAdd: { addPlanePoint($0) },
                onDeletePair: { deletePair(at: $0) },
                onMove: { geserTitikDenah($0, ke: $1) }
            )
        }
    }

    /// Bidang lantai yang terlihat kamera ini, dalam koordinat denah 0–1.
    ///
    /// Inilah yang membuat kalibrasi bisa DIPERIKSA, bukan cuma dinilai dari
    /// angka. Galat reproyeksi tetap kecil walaupun seluruh korespondensinya
    /// tercermin — titiknya konsisten satu sama lain, cuma ruangannya terbalik.
    /// Bidang ini memperlihatkannya sekejap: kamera yang menghadap konter tapi
    /// bidangnya menempel di sisi seberang berarti titiknya tertukar.
    ///
    /// Dibangun dengan menyapu tepi bawah frame — pasti lantai, pasti paling
    /// dekat kamera — lalu naik baris demi baris sampai proyeksinya keluar
    /// ruangan. Batas itu horizon lantainya.
    private func jangkauanLantai(_ camera: SessionCamera?) -> [CGPoint] {
        guard let camera, let kal = camera.calibration, kal.isValid,
              let px = camera.framePixelSize, px.isValid,
              session.venueWidthM > 0, session.venueHeightM > 0 else { return [] }
        let H = kal.homographyCameraToWorld
        let batas = AnalysisResult.marginDenahMeter

        func keDenah(_ x: Double, _ y: Double) -> CGPoint? {
            guard let m = HomographySolver.transform(
                CalibrationPoint(x: x * px.width, y: y * px.height), with: H) else { return nil }
            guard m.x >= -batas, m.x <= session.venueWidthM + batas,
                  m.y >= -batas, m.y <= session.venueHeightM + batas else { return nil }
            return CGPoint(x: m.x / session.venueWidthM, y: m.y / session.venueHeightM)
        }

        var bawah: [CGPoint] = [], atas: [CGPoint] = []
        let kolom = 14
        for i in 0...kolom {
            let x = Double(i) / Double(kolom)
            var b: CGPoint?, a: CGPoint?
            for j in stride(from: 1.0, through: 0.25, by: -0.02) {
                if let p = keDenah(x, j) {
                    if b == nil { b = p }
                    a = p
                } else if b != nil { break }
            }
            if let b, let a { bawah.append(b); atas.append(a) }
        }
        guard bawah.count >= 3 else { return [] }
        return bawah + atas.reversed()
    }

    private func geserTitikKamera(_ i: Int, ke titik: CGPoint) {
        guard session.cameras.indices.contains(selectedIndex),
              session.cameras[selectedIndex].imagePoints.indices.contains(i) else { return }
        session.cameras[selectedIndex].imagePoints[i] = NormPoint(x: titik.x, y: titik.y)
        recalculateSelectedCamera()
    }

    private func geserTitikDenah(_ i: Int, ke titik: CGPoint) {
        guard session.cameras.indices.contains(selectedIndex),
              session.cameras[selectedIndex].planePoints.indices.contains(i) else { return }
        session.cameras[selectedIndex].planePoints[i] = NormPoint(x: titik.x, y: titik.y)
        recalculateSelectedCamera()
    }

    private var inspector: some View {
        let camera = selectedCamera
        let calibration = camera?.calibration
        return ViewThatFits(in: .horizontal) {
            regularInspector(camera: camera, calibration: calibration)
                .frame(minWidth: 920)
            compactInspector(camera: camera, calibration: calibration)
        }
    }

    private func regularInspector(camera: SessionCamera?, calibration: CameraCalibration?) -> some View {
        HStack(alignment: .top, spacing: Space.m * scale) {
            referenceFramePanel(camera, height: panelHeight(172))
            pointPairsPanel(camera, height: panelHeight(172))
            validationPanel(calibration, height: panelHeight(172))
            cameraStatusPanel(height: panelHeight(172))
        }
    }

    private func compactInspector(camera: SessionCamera?, calibration: CameraCalibration?) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: Space.m * scale), GridItem(.flexible())],
            alignment: .leading,
            spacing: Space.m * scale
        ) {
            referenceFramePanel(camera, height: panelHeight(164))
            pointPairsPanel(camera, height: panelHeight(164))
            validationPanel(calibration, height: panelHeight(164))
            cameraStatusPanel(height: panelHeight(164))
        }
    }

    private func referenceFramePanel(_ camera: SessionCamera?, height: CGFloat) -> some View {
        inspectorPanel(height: height) {
            VStack(alignment: .leading, spacing: Space.s) {
                FieldLabel(text: "Frame Referensi")
                if let camera {
                    let range = referenceRange(for: camera)
                    Slider(
                        value: Binding(
                            get: { clamp(session.cameras[selectedIndex].referenceFrameSeconds, to: range) },
                            set: { value in
                                session.cameras[selectedIndex].referenceFrameSeconds = clamp(value, to: range)
                                invalidateCalibration(for: selectedIndex)
                                reloadToken = UUID()
                            }
                    ),
                    in: range
                )
                    HStack {
                        Text(timecode(clamp(session.cameras[selectedIndex].referenceFrameSeconds, to: range)))
                        Spacer()
                        Text("\(timecode(range.lowerBound)) – \(timecode(range.upperBound))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pointPairsPanel(_ camera: SessionCamera?, height: CGFloat) -> some View {
        inspectorPanel(height: height) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    FieldLabel(text: "Pasangan Titik")
                    Spacer()
                    Text("\(camera?.imagePoints.count ?? 0)/8")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                pointActionButton("Reset Kamera", systemImage: "arrow.counterclockwise", enabled: canUndoCameraPoint) {
                    resetSelectedCamera()
                }
                pointActionButton("Undo CCTV", systemImage: "arrow.uturn.backward", enabled: canUndoCameraPoint) {
                    undoCameraPoint()
                }
                pointActionButton("Undo Floor plan", systemImage: "arrow.uturn.backward", enabled: canUndoFloorPlanPoint) {
                    undoFloorPlanPoint()
                }
            }
        }
    }

    private func pointActionButton(
        _ title: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.s)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.42)
    }

    private func validationPanel(_ calibration: CameraCalibration?, height: CGFloat) -> some View {
        inspectorPanel(height: height) { metricContent(calibration) }
    }

    private func cameraStatusPanel(height: CGFloat) -> some View {
        inspectorPanel(height: height) {
            VStack(alignment: .leading, spacing: Space.s) {
                FieldLabel(text: "Status Kamera")
                ForEach(session.cameras) { item in
                    HStack(spacing: Space.s) {
                        Image(systemName: item.isCalibrated ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isCalibrated ? .green : .secondary)
                        Text(item.label).font(.callout).lineLimit(1)
                        Spacer()
                    }
                }
            }
        }
    }

    private func panelHeight(_ base: CGFloat) -> CGFloat {
        min(base * scale, base + 16)
    }

    private func inspectorPanel<Content: View>(height: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .card(padding: Space.m)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }

    @ViewBuilder
    private func metricContent(_ calibration: CameraCalibration?) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            FieldLabel(text: "Validasi")
            if let calibration {
                metric("Median", String(format: "%.3f m", calibration.metrics.medianErrorM))
                metric("P95", String(format: "%.3f m", calibration.metrics.p95ErrorM))
                metric("Inlier", "\(calibration.metrics.inliers)/\(calibration.metrics.points)")
            } else {
                Text("Tambahkan minimal empat pasangan titik untuk menghitung homografi.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospacedDigit().weight(.medium))
        }
    }

    private func addCameraPoint(_ point: CGPoint) {
        guard session.cameras.indices.contains(selectedIndex) else { return }
        let camera = session.cameras[selectedIndex]
        guard camera.imagePoints.count < HomographySolver.maximumPoints else {
            message = "Gagal: maksimum 8 pasangan titik per kamera."; return
        }
        guard camera.imagePoints.count == camera.planePoints.count else {
            message = "Klik pasangan titik di denah terlebih dahulu."; return
        }
        session.cameras[selectedIndex].imagePoints.append(NormPoint(x: point.x, y: point.y))
        invalidateCalibration(for: selectedIndex)
        message = "Titik CCTV \(camera.imagePoints.count + 1) ditambahkan. Klik pasangan yang sama di denah."
    }

    private func addPlanePoint(_ point: CGPoint) {
        guard session.cameras.indices.contains(selectedIndex) else { return }
        let camera = session.cameras[selectedIndex]
        guard camera.planePoints.count < camera.imagePoints.count else {
            message = "Mulai pasangan baru dengan klik titik pada CCTV."; return
        }
        session.cameras[selectedIndex].planePoints.append(NormPoint(x: point.x, y: point.y))
        recalculateSelectedCamera()
    }

    private func deletePair(at index: Int) {
        guard session.cameras.indices.contains(selectedIndex) else { return }
        guard session.cameras[selectedIndex].imagePoints.indices.contains(index),
              session.cameras[selectedIndex].planePoints.indices.contains(index) else { return }
        session.cameras[selectedIndex].imagePoints.remove(at: index)
        session.cameras[selectedIndex].planePoints.remove(at: index)
        invalidateCalibration(for: selectedIndex)
        recalculateSelectedCamera()
    }

    private func resetSelectedCamera() {
        guard session.cameras.indices.contains(selectedIndex) else { return }
        session.cameras[selectedIndex].imagePoints = []
        session.cameras[selectedIndex].planePoints = []
        invalidateCalibration(for: selectedIndex)
        message = "Titik \(session.cameras[selectedIndex].label) direset."
    }

    private var canUndoCameraPoint: Bool {
        guard session.cameras.indices.contains(selectedIndex) else { return false }
        return !session.cameras[selectedIndex].imagePoints.isEmpty
    }

    private var canUndoFloorPlanPoint: Bool {
        guard session.cameras.indices.contains(selectedIndex) else { return false }
        let camera = session.cameras[selectedIndex]
        return !camera.planePoints.isEmpty && camera.imagePoints.count == camera.planePoints.count
    }

    private func undoCameraPoint() {
        guard session.cameras.indices.contains(selectedIndex) else { return }
        let imageCount = session.cameras[selectedIndex].imagePoints.count
        let floorCount = session.cameras[selectedIndex].planePoints.count
        guard imageCount > 0 else { return }

        session.cameras[selectedIndex].imagePoints.removeLast()
        if imageCount == floorCount {
            session.cameras[selectedIndex].planePoints.removeLast()
        }
        invalidateCalibration(for: selectedIndex)
        recalculateSelectedCamera()
        message = "Titik CCTV terakhir dihapus."
    }

    private func undoFloorPlanPoint() {
        guard canUndoFloorPlanPoint else { return }
        session.cameras[selectedIndex].planePoints.removeLast()
        invalidateCalibration(for: selectedIndex)
        message = "Titik floor plan terakhir dihapus. Pilih titik penggantinya di denah."
    }

    private func invalidateCalibration(for index: Int) {
        guard session.cameras.indices.contains(index) else { return }
        session.cameras[index].calibration = nil
    }

    private func referenceRange(for camera: SessionCamera) -> ClosedRange<Double> {
        let upperLimit = max(0, camera.durationSec)
        let lower = min(max(0, session.trimStartSec), upperLimit)
        let requestedUpper = session.trimEndSec > lower ? session.trimEndSec : upperLimit
        let upper = min(max(lower, requestedUpper), upperLimit)
        return lower...upper
    }

    private func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    private func constrainReferenceFramesToTrim() {
        for index in session.cameras.indices {
            session.cameras[index].referenceFrameSeconds = clamp(
                session.cameras[index].referenceFrameSeconds,
                to: referenceRange(for: session.cameras[index])
            )
        }
    }

    /// Peringatan kalau ukuran ruangan yang diketik tidak sebangun dengan
    /// gambar denahnya — hampir selalu berarti lebar dan tinggi tertukar.
    ///
    /// Seluruh gambar denah dipetakan ke persegi venue, jadi kalau angkanya
    /// tertukar, gambarnya dipipihkan DAN homografinya memetakan ke ruangan
    /// yang bentuknya salah. Yang terlihat pengguna cuma "hasilnya jelek" —
    /// tidak ada satu pun angka yang menyebut sebabnya, karena kalibrasinya
    /// sendiri tetap sahih: galat median tetap kecil, inlier tetap lolos.
    /// Titik-titiknya memang konsisten satu sama lain, cuma ruangannya yang
    /// salah bentuk.
    ///
    /// Ambangnya longgar (30%) karena gambar denah biasanya punya marjin dan
    /// garis ukuran, jadi rasio pikselnya tidak sama persis dengan rasio
    /// ruangannya. Yang mau ditangkap cuma yang tertukar — dan itu selalu
    /// melenceng jauh.
    private var peringatanRasio: String? {
        // Rasio tertukar diperiksa lebih dulu: ia membuat SEMUA angka lain
        // menyesatkan, jadi memperbaikinya harus jadi langkah pertama.
        if let p = peringatanRasioSaja { return p }
        return peringatanCakupan
    }

    private var peringatanRasioSaja: String? {
        switch cekRasio() {
        case .tertukar:
            return "Ukuran ruangan sepertinya TERTUKAR — coba \(session.heightM) × \(session.widthM) m."
        case .tidakSebangun:
            return "Bentuk gambar tidak sebangun dengan ukuran ruangan; denahnya akan tergambar pipih."
        case .cocok:
            return nil
        }
    }

    /// Berapa bagian lantai yang terlihat kamera mendarat DI DALAM ruangan.
    ///
    /// Ini menangkap kegagalan yang tidak bisa dilihat dari galat reproyeksi:
    /// kalau titik kalibrasi hampir SEGARIS di gambar kamera, homografinya
    /// tetap melewati titik-titik itu dengan sempurna — galat median bisa 5 cm
    /// — tapi memetakan sisanya ke tempat yang ngawur.
    ///
    /// Terukur pada kalibrasi pantry yang galatnya "bagus" (median 0,049 m,
    /// inlier 6/8): seluruh jejak orangnya mendarat di pita setebal 0,6 m di
    /// LUAR ruangan, dan 0% petak ruangan tersentuh. Galatnya tidak bisa
    /// memberi tahu, karena galat hanya mengukur titik yang kita berikan
    /// sendiri.
    ///
    /// Yang diperiksa: titik-titik contoh di separuh bawah frame — bagian yang
    /// hampir pasti lantai — diproyeksikan, lalu dihitung berapa yang jatuh di
    /// dalam ruangan.
    private func cakupanLantai(_ camera: SessionCamera?) -> Double? {
        guard let camera, let kal = camera.calibration, kal.isValid,
              let px = camera.framePixelSize, px.isValid,
              session.venueWidthM > 0, session.venueHeightM > 0 else { return nil }
        let H = kal.homographyCameraToWorld
        var di = 0, semua = 0
        for i in 0..<12 {
            for j in 0..<8 {
                let x = (Double(i) + 0.5) / 12 * px.width
                // separuh bawah frame saja: di atasnya dinding dan langit-langit
                let y = (0.5 + (Double(j) + 0.5) / 16) * px.height
                semua += 1
                guard let m = HomographySolver.transform(CalibrationPoint(x: x, y: y), with: H)
                else { continue }
                if m.x >= 0, m.x <= session.venueWidthM,
                   m.y >= 0, m.y <= session.venueHeightM { di += 1 }
            }
        }
        return semua > 0 ? Double(di) / Double(semua) : nil
    }

    /// Peringatan kalau kalibrasi tampak sahih tapi memetakan ke luar ruangan.
    private var peringatanCakupan: String? {
        guard let c = cakupanLantai(selectedCamera), c < 0.15 else { return nil }
        return "Kalibrasi ini lolos angka galat, tapi hanya \(Int((c * 100).rounded()))% "
            + "lantai yang terlihat kamera mendarat DI DALAM ruangan — titiknya terlalu "
            + "segaris. Sebar titiknya ke DEPAN-BELAKANG juga: beberapa dekat kamera "
            + "(bawah frame), beberapa jauh (batas lantai paling atas yang terlihat)."
    }

    private enum HasilCekRasio { case cocok, tertukar, tidakSebangun }

    private func cekRasio() -> HasilCekRasio {
        guard !session.usesScaledCanvas,
              let px = session.floorPlanPixelSize, px.isValid,
              session.venueWidthM > 0, session.venueHeightM > 0 else { return .cocok }
        let rasioGambar = px.width / px.height
        let rasioVenue = session.venueWidthM / session.venueHeightM
        let selisih = max(rasioGambar / rasioVenue, rasioVenue / rasioGambar)
        guard selisih > 1.3 else { return .cocok }

        let rasioTukar = session.venueHeightM / session.venueWidthM
        let selisihTukar = max(rasioGambar / rasioTukar, rasioTukar / rasioGambar)
        return selisihTukar < selisih ? .tertukar : .tidakSebangun
    }

    /// Betulkan ukuran ruangan yang tertukar, dan laporkan kalau membetulkannya.
    ///
    /// Dipanggil setelah Impor Profil. Profil menyimpan ukuran venue, jadi
    /// mengimpornya MENIMPA angka yang barusan dibetulkan pengguna di layar
    /// Import — dan angka penggantinya adalah angka salah yang sama yang
    /// tersimpan waktu profil itu dibuat. Hasilnya lingkaran tanpa ujung:
    /// betulkan di Import, impor profil, salah lagi, tanpa satu pun petunjuk
    /// bahwa profilnya yang menimpa.
    ///
    /// Kalau profilnya bertentangan dengan gambar denahnya sendiri, yang
    /// dipercaya GAMBARNYA: bentuk gambar itu fakta, angka venue itu ketikan.
    @discardableResult
    private func perbaikiRasioTertukar() -> Bool {
        guard cekRasio() == .tertukar else { return false }
        let w = session.widthM
        session.widthM = session.heightM
        session.heightM = w
        recalculateAllCameras(diam: true)
        return true
    }

    private func recalculateSelectedCamera() { recalculate(at: selectedIndex) }

    private func recalculate(at selectedIndex: Int, diam: Bool = false) {
        guard session.cameras.indices.contains(selectedIndex) else { return }
        let camera = session.cameras[selectedIndex]
        guard camera.imagePoints.count == camera.planePoints.count else { return }
        guard camera.imagePoints.count >= HomographySolver.minimumPoints else { return }
        guard let frameSize = camera.framePixelSize, frameSize.isValid else {
            message = "Gagal: frame CCTV belum dapat dibaca."; return
        }
        let cameraPoints = camera.imagePoints.map {
            CalibrationPoint(x: $0.x * frameSize.width, y: $0.y * frameSize.height)
        }
        let floorSize = session.calibrationFloorSize
        let floorPoints = camera.planePoints.map {
            CalibrationPoint(x: $0.x * floorSize.width, y: $0.y * floorSize.height)
        }
        do {
            session.cameras[selectedIndex].calibration = try HomographySolver.calibrate(
                cameraPointsPx: cameraPoints,
                floorPointsPx: floorPoints,
                floorSize: floorSize,
                venueWidthM: session.venueWidthM,
                venueHeightM: session.venueHeightM
            )
            let metrics = session.cameras[selectedIndex].calibration?.metrics
            if !diam {
                message = "Kalibrasi valid: \(metrics?.inliers ?? 0)/\(metrics?.points ?? 0) inlier."
            }
        } catch {
            session.cameras[selectedIndex].calibration = nil
            if !diam { message = "Gagal: \(error.localizedDescription)" }
        }
    }

    /// Hitung ulang SEMUA kamera dari titik yang sudah ada.
    ///
    /// Dipakai setelah denah diganti. Titik denah disimpan ternormalkan 0–1,
    /// jadi ia ikut menyesuaikan sendiri ke ukuran gambar yang baru dan tidak
    /// perlu diklik ulang satu pun. Yang sebelumnya terjadi: kalibrasinya
    /// dibatalkan tapi tidak ada yang menghitungnya kembali, jadi centang
    /// hijaunya hilang dan pengguna harus mengutak-atik titik satu per satu
    /// hanya untuk memicu perhitungan yang sebenarnya sudah bisa dilakukan.
    ///
    /// Angka galatnya tetap dilaporkan apa adanya — kalau denah barunya
    /// ternyata ruangan lain, itu akan terlihat sebagai galat yang melonjak,
    /// bukan tersembunyi di balik centang hijau.
    private func recalculateAllCameras(diam: Bool = false) {
        for index in session.cameras.indices { recalculate(at: index, diam: diam) }
    }

    private func validationPoints(_ calibration: CameraCalibration?) -> [ValidationPoint] {
        guard let calibration else { return [] }
        let floorSize = session.calibrationFloorSize
        return calibration.projectedFloorPointsPx.enumerated().map { index, point in
            ValidationPoint(
                point: CGPoint(x: point.x / floorSize.width, y: point.y / floorSize.height),
                isInlier: calibration.inlierMask.indices.contains(index) ? calibration.inlierMask[index] : false
            )
        }
    }

    private func chooseFloorPlan() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .pdf, .image]
        guard panel.runModal() == .OK, let url = panel.url, let image = loadFloorPlanImage(url) else { return }
        floorPlanImage = image
        session.floorPlanURL = url
        session.floorPlanName = url.lastPathComponent
        session.floorPlanPixelSize = pixelSize(of: image)
        session.usesScaledCanvas = false
        invalidateAllCalibrations()
        // Titiknya tidak hilang, jadi tidak ada alasan menyuruh pengguna
        // mengulang: hitung ulang saja dari titik yang sudah ada.
        recalculateAllCameras()
        let siap = session.cameras.filter(\.isCalibrated).count
        message = siap > 0
            ? "Denah diperbarui. \(siap) dari \(session.cameras.count) kamera terhitung ulang otomatis dari titik yang sudah ada."
            : "Denah diperbarui. Titik kalibrasi belum cukup — butuh minimal 4 pasangan per kamera."
    }

    private var floorSourcePicker: some View {
        HStack(spacing: Space.s) {
            floorSourceRadio(title: "Canvas", selected: session.usesScaledCanvas) {
                selectScaledCanvas()
            }
            floorSourceRadio(title: "Floor plan", selected: !session.usesScaledCanvas) {
                selectFloorPlan()
            }
        }
        .font(.caption.weight(.medium))
    }

    private func floorSourceRadio(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                Text(title).foregroundStyle(selected ? Color.primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Gunakan \(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func selectScaledCanvas() {
        guard !session.usesScaledCanvas else { return }
        session.usesScaledCanvas = true
        invalidateAllCalibrations()
        message = "Menggunakan Canvas Berskala. Kalibrasi tiap kamera perlu dihitung ulang."
    }

    private func selectFloorPlan() {
        guard session.usesScaledCanvas else { return }
        session.usesScaledCanvas = false
        invalidateAllCalibrations()
        if session.floorPlanURL == nil {
            message = "Unggah floor plan untuk mulai memberi titik pada denah."
        } else {
            message = "Menggunakan floor plan tersimpan. Kalibrasi tiap kamera perlu dihitung ulang."
        }
    }

    private var floorPlanCanvasAction: AnyView? {
        guard !session.usesScaledCanvas else { return nil }
        let hasFloorPlan = floorPlanImage != nil
        return AnyView(
            Button(hasFloorPlan ? "Update" : "Upload", systemImage: hasFloorPlan ? "arrow.triangle.2.circlepath" : "photo") {
                chooseFloorPlan()
            }
            .buttonStyle(.bordered)
        )
    }

    private func exportProfile() {
        do {
            let profile = try CalibrationProfileStore.exportProfile(from: session)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "camera_floorplan_calibration.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try CalibrationProfileStore.encode(profile).write(to: url, options: .atomic)
            message = "Profil kalibrasi diekspor ke \(url.lastPathComponent)."
        } catch {
            message = "Gagal: \(error.localizedDescription)"
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let profile = try CalibrationProfileStore.decode(Data(contentsOf: url))
            try CalibrationProfileStore.apply(profile, to: session)
            let dibetulkan = perbaikiRasioTertukar()
            reloadToken = UUID()
            message = dibetulkan
                ? "Profil diimpor. Ukuran ruangannya tertukar dan sudah dibetulkan jadi "
                    + "\(session.widthM) × \(session.heightM) m — ekspor ulang profilnya "
                    + "supaya tidak terulang."
                : "Profil kalibrasi diimpor. Cocokkan kembali frame referensi bila video berubah."
        } catch {
            message = "Gagal: \(error.localizedDescription)"
        }
    }

    private func invalidateAllCalibrations() {
        for index in session.cameras.indices { session.cameras[index].calibration = nil }
    }

    @MainActor
    private func refreshImages() async {
        constrainReferenceFramesToTrim()
        if let url = session.floorPlanURL { floorPlanImage = loadFloorPlanImage(url) }
        else { floorPlanImage = nil }
        guard let camera = selectedCamera, let url = camera.url else {
            cameraFrameImage = nil; return
        }
        isLoadingFrame = true
        let expectedID = camera.id
        let image = await VideoFrameLoader.image(url: url, at: camera.referenceFrameSeconds)
        guard selectedCamera?.id == expectedID else { return }
        cameraFrameImage = image
        if let image {
            let size = pixelSize(of: image)
            if size.isValid { session.cameras[selectedIndex].framePixelSize = size }
        }
        isLoadingFrame = false
    }

    private func loadFloorPlanImage(_ url: URL) -> NSImage? {
        if url.pathExtension.lowercased() == "pdf", let page = PDFDocument(url: url)?.page(at: 0) {
            return page.thumbnail(of: NSSize(width: 2400, height: 2400), for: .mediaBox)
        }
        return NSImage(contentsOf: url)
    }

    private func pixelSize(of image: NSImage) -> PixelSize {
        if let rep = image.representations.first(where: { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }) {
            return PixelSize(width: Double(rep.pixelsWide), height: Double(rep.pixelsHigh))
        }
        return PixelSize(image.size)
    }
}

private enum VideoFrameLoader {
    static func image(url: URL, at seconds: Double) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
            guard let frame = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
            return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
        }.value
    }
}

private struct ValidationPoint: Identifiable {
    let id = UUID()
    let point: CGPoint
    let isInlier: Bool
}

private struct CalibrationCanvas: View {
    let title: String
    let subtitle: String
    let image: NSImage?
    let sourceSize: CGSize?
    let points: [NormPoint]
    let projectedPoints: [ValidationPoint]
    /// Bidang lantai yang terlihat kamera, dalam koordinat denah 0–1.
    /// Kosong untuk panel CCTV.
    var jangkauan: [CGPoint] = []
    let accent: Color
    let canInteract: Bool
    let canvasAccessory: AnyView?
    let footerAccessory: AnyView?
    let emptyState: AnyView?
    let onAdd: (CGPoint) -> Void
    let onDeletePair: (Int) -> Void
    /// Geser titik yang sudah ada. Tanpa ini satu titik yang meleset sedikit
    /// harus dihapus lalu dipasang ulang — dan menghapus pasangan berarti
    /// menghapus DUA titik, di dua panel.
    var onMove: ((Int, CGPoint) -> Void)?

    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var basePan: CGSize = .zero
    @State private var hoveredIndex: Int?
    @State private var seretIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            GeometryReader { geo in
                let rect = fittedRect(in: geo.size)
                ZStack {
                    scene(size: rect.size)
                        .frame(width: rect.width, height: rect.height)
                        .scaleEffect(zoom)
                        .offset(pan)
                        .position(x: rect.midX, y: rect.midY)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(interactionGesture(rect: rect))
                .simultaneousGesture(magnifyGesture(rect: rect))
                .overlay(alignment: .bottomTrailing) {
                    controls(rect: rect).padding(Space.s)
                }
                .overlay(alignment: .topTrailing) {
                    canvasAccessory?.padding(Space.s)
                }
                .overlay(alignment: .bottomLeading) {
                    footerAccessory?.padding(Space.s)
                }
                .overlay {
                    if !canInteract, let emptyState { emptyState }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    @ViewBuilder
    private func scene(size: CGSize) -> some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                ZStack {
                    Color.primary.opacity(0.035)
                    GridBackground()
                }
            }
            // Bidang lantai yang terlihat kamera. Digambar SEBELUM titiknya,
            // jadi tidak menutupi apa pun yang perlu diklik.
            if jangkauan.count >= 3 {
                Path { path in
                    path.addLines(jangkauan.map {
                        CGPoint(x: $0.x * size.width, y: $0.y * size.height)
                    })
                    path.closeSubpath()
                }
                .fill(Color.cyan.opacity(0.10))
                Path { path in
                    path.addLines(jangkauan.map {
                        CGPoint(x: $0.x * size.width, y: $0.y * size.height)
                    })
                    path.closeSubpath()
                }
                .stroke(Color.cyan.opacity(0.65),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
            if points.count >= 2 {
                Path { path in
                    let values = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                    path.addLines(values)
                }
                .stroke(accent.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                PointMarker(number: index + 1, color: accent, deleteMode: hoveredIndex == index)
                    .position(x: point.x * size.width, y: point.y * size.height)
                    .onHover { hoveredIndex = $0 ? index : nil }
            }
            ForEach(Array(projectedPoints.enumerated()), id: \.element.id) { index, point in
                ProjectedMarker(number: index + 1, isInlier: point.isInlier)
                    .position(x: point.point.x * size.width, y: point.point.y * size.height)
            }
        }
        .clipShape(Rectangle())
    }

    private func interactionGesture(rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard canInteract else { return }
                let distance = hypot(value.translation.width, value.translation.height)
                // Seret yang DIMULAI di atas titik memindahkan titik itu.
                // Diputuskan sekali di awal, lalu dipegang sampai lepas —
                // kalau diperiksa terus, titik yang diseret melewati titik
                // lain bisa berpindah tangan di tengah jalan.
                if seretIndex == nil, distance > 3, onMove != nil,
                   let awal = normalizedPoint(value.startLocation, in: rect),
                   let i = nearestPoint(to: awal, in: rect) {
                    seretIndex = i
                }
                if let i = seretIndex, let n = normalizedPoint(value.location, in: rect) {
                    onMove?(i, n)
                    return
                }
                if distance > 6, zoom > 1 {
                    pan = clampedPan(CGSize(width: basePan.width + value.translation.width, height: basePan.height + value.translation.height), rect: rect)
                }
            }
            .onEnded { value in
                guard canInteract else { return }
                if seretIndex != nil { seretIndex = nil; return }
                let distance = hypot(value.translation.width, value.translation.height)
                if distance > 6, zoom > 1 { basePan = pan; return }
                guard let normalized = normalizedPoint(value.location, in: rect) else { return }
                if let index = nearestPoint(to: normalized, in: rect) { onDeletePair(index) }
                else { onAdd(normalized) }
            }
    }

    private func magnifyGesture(rect: CGRect) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = min(5, max(1, baseZoom * value.magnification))
                pan = clampedPan(pan, rect: rect)
            }
            .onEnded { _ in
                baseZoom = zoom
                if zoom == 1 { pan = .zero; basePan = .zero } else { basePan = pan }
            }
    }

    private func controls(rect: CGRect) -> some View {
        HStack(spacing: Space.s) {
            Button { setZoom(zoom - 0.5, rect: rect) } label: { Image(systemName: "minus") }
            Text("\(Int((zoom * 100).rounded()))%")
                .font(.caption.monospacedDigit()).frame(width: 38)
            Button { setZoom(zoom + 0.5, rect: rect) } label: { Image(systemName: "plus") }
            Button {
                zoom = 1; baseZoom = 1; pan = .zero; basePan = .zero
            } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Space.s)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }

    private func fittedRect(in container: CGSize) -> CGRect {
        let source = sourceSize ?? CGSize(width: 4, height: 3)
        guard source.width > 0, source.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let factor = min(container.width / source.width, container.height / source.height)
        let size = CGSize(width: source.width * factor, height: source.height * factor)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func normalizedPoint(_ point: CGPoint, in rect: CGRect) -> CGPoint? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = ((point.x - rect.midX - pan.width) / zoom) + rect.midX
        let y = ((point.y - rect.midY - pan.height) / zoom) + rect.midY
        guard rect.contains(CGPoint(x: x, y: y)) else { return nil }
        return CGPoint(x: (x - rect.minX) / rect.width, y: (y - rect.minY) / rect.height)
    }

    private func nearestPoint(to point: CGPoint, in rect: CGRect) -> Int? {
        let hitRadius = 15 / max(zoom, 1)
        return points.indices.min { first, second in
            let firstDistance = hypot((points[first].x - point.x) * rect.width, (points[first].y - point.y) * rect.height)
            let secondDistance = hypot((points[second].x - point.x) * rect.width, (points[second].y - point.y) * rect.height)
            return firstDistance < secondDistance
        }.flatMap { index in
            let distance = hypot((points[index].x - point.x) * rect.width, (points[index].y - point.y) * rect.height)
            return distance <= hitRadius ? index : nil
        }
    }

    private func clampedPan(_ value: CGSize, rect: CGRect) -> CGSize {
        let maxX = rect.width * (zoom - 1) / 2
        let maxY = rect.height * (zoom - 1) / 2
        return CGSize(width: min(max(value.width, -maxX), maxX), height: min(max(value.height, -maxY), maxY))
    }

    private func setZoom(_ value: CGFloat, rect: CGRect) {
        zoom = min(5, max(1, value)); baseZoom = zoom
        pan = clampedPan(pan, rect: rect); basePan = pan
    }
}

private struct PointMarker: View {
    let number: Int
    let color: Color
    let deleteMode: Bool

    var body: some View {
        ZStack {
            Circle().fill(deleteMode ? Color.red : color).frame(width: deleteMode ? 26 : 22, height: deleteMode ? 26 : 22)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
            if deleteMode { Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.white) }
            else { Text("\(number)").font(.caption2.bold()).foregroundStyle(.white) }
        }
        .shadow(radius: 1)
        .help("Klik untuk menghapus pasangan titik \(number)")
    }
}

private struct ProjectedMarker: View {
    let number: Int
    let isInlier: Bool

    var body: some View {
        ZStack {
            Circle().strokeBorder(isInlier ? .green : .red, lineWidth: 2).frame(width: 18, height: 18)
            Path { path in
                path.move(to: CGPoint(x: -7, y: 0)); path.addLine(to: CGPoint(x: 7, y: 0))
                path.move(to: CGPoint(x: 0, y: -7)); path.addLine(to: CGPoint(x: 0, y: 7))
            }
            .stroke(isInlier ? .green : .red, lineWidth: 1.5)
            Text("\(number)").font(.system(size: 8, weight: .bold)).foregroundStyle(isInlier ? .green : .red).offset(y: -14)
        }
        .allowsHitTesting(false)
        .help(isInlier ? "Proyeksi inlier" : "Proyeksi outlier")
    }
}

private struct GridBackground: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for index in 0...10 {
                let x = size.width * CGFloat(index) / 10
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for index in 0...8 {
                let y = size.height * CGFloat(index) / 8
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.secondary.opacity(0.16)), lineWidth: 1)
        }
    }
}
