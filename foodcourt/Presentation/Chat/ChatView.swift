//
//  ChatView.swift
//  foodcourt
//
//  Tanya-jawab hasil analisis dengan model bahasa lokal.
//
//  Bicara ke layanan chat di :8766, BUKAN ke engine analisis di :8765. Dua
//  alasan: engine itu tidak perlu diubah demi fitur ini, dan chatbot yang mati
//  tidak boleh ikut mematikan analisis. Karena itu layar ini memakai klien
//  kecilnya sendiri dan tidak menyentuh EngineAPI.
//

import SwiftUI

// MARK: - Klien layanan chat

struct ChatAPI {
    var baseURL = URL(string: "http://127.0.0.1:8766")!

    struct Giliran: Codable { let peran: String; let teks: String }

    func riwayatTersedia() async throws -> [String] {
        struct Res: Decodable { let riwayat: [String] }
        let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("riwayat"))
        return try JSONDecoder().decode(Res.self, from: data).riwayat
    }

    func tanya(nama: String, pertanyaan: String,
               riwayat: [Giliran]) async throws -> String {
        struct Req: Encodable {
            let nama: String; let pertanyaan: String; let riwayat: [Giliran]
        }
        struct Res: Decodable { let jawaban: String }
        struct Galat: Decodable { let error: String }

        var req = URLRequest(url: baseURL.appendingPathComponent("chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Model lokal butuh 15-60 detik. Dengan batas 30 detik bawaan
        // URLSession, jawaban yang sedang disusun tampil sebagai kegagalan.
        req.timeoutInterval = 300
        req.httpBody = try JSONEncoder().encode(
            Req(nama: nama, pertanyaan: pertanyaan, riwayat: riwayat))

        let (data, resp) = try await URLSession.shared.data(for: req)
        let kode = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(kode) else {
            // Layanan mengirim pesan yang sudah menyebut cara membetulkannya
            // ("Ollama belum jalan. Jalankan: ollama serve"). Menampilkan kode
            // HTTP saja membuang satu-satunya petunjuk yang berguna.
            if let g = try? JSONDecoder().decode(Galat.self, from: data) {
                throw ChatError.pesan(g.error)
            }
            throw ChatError.pesan("Layanan chat menjawab HTTP \(kode).")
        }
        return try JSONDecoder().decode(Res.self, from: data).jawaban
    }
}

enum ChatError: LocalizedError {
    case pesan(String)
    var errorDescription: String? {
        switch self { case .pesan(let m): return m }
    }
}

// MARK: - Model tampilan

struct PesanChat: Identifiable, Codable {
    var id = UUID()
    let dariOrang: Bool
    let teks: String
    /// Penanda ganti riwayat — bukan ucapan siapa pun.
    var pemisah = false
}

@Observable
@MainActor
final class ChatViewModel {
    var tersedia: [String] = []
    var terpilih: String?
    var pesan: [PesanChat] = []
    var draf = ""
    var sedangJawab = false
    var errorMessage: String?

    private let api = ChatAPI()
    private var riwayatKirim: [ChatAPI.Giliran] = []
    private var riwayatDibahas: String?

    func muat() async {
        do {
            tersedia = try await api.riwayatTersedia()
            errorMessage = tersedia.isEmpty
                ? "Belum ada analisis tersimpan. Jalankan satu analisis dulu."
                : nil
        } catch {
            tersedia = []
            errorMessage = "Layanan chat belum jalan. Di Terminal: ./llm/jalankan.sh"
        }
        if terpilih == nil { terpilih = tersedia.first }
    }

    func kirim() async {
        let t = draf.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let nama = terpilih, !sedangJawab else { return }

        // Ganti riwayat di tengah percakapan pernah membuat satu layar berisi
        // angka dari dua rekaman berbeda tanpa satu pun tanda. Percakapan
        // dipotong di sini, dan pemotongannya terlihat.
        if let lama = riwayatDibahas, lama != nama {
            pesan.append(PesanChat(dariOrang: false,
                                   teks: "Ganti ke \(nama) — jawaban di atas memakai angka dari \(lama).",
                                   pemisah: true))
            riwayatKirim = []
        }
        riwayatDibahas = nama

        draf = ""
        pesan.append(PesanChat(dariOrang: true, teks: t))
        riwayatKirim.append(.init(peran: "orang", teks: t))
        sedangJawab = true
        errorMessage = nil
        defer { sedangJawab = false }
        do {
            let sebelum = Array(riwayatKirim.dropLast())   // tanpa pertanyaan ini
            let j = try await api.tanya(nama: nama, pertanyaan: t, riwayat: sebelum)
            pesan.append(PesanChat(dariOrang: false, teks: j))
            riwayatKirim.append(.init(peran: "bot", teks: j))
        } catch {
            errorMessage = error.localizedDescription
            riwayatKirim.removeLast()                     // pertanyaan tak terjawab
        }
    }

    func hapusPercakapan() {
        pesan = []
        riwayatKirim = []
        riwayatDibahas = nil
    }
}

// MARK: - Tampilan

struct ChatView: View {
    @Environment(\.uiScale) private var scale
    @State private var vm = ChatViewModel()

    private let contoh = [
        "Tempat mana yang cocok buat main board game?",
        "Di mana orang paling sering berada?",
        "Berapa pengunjungnya?",
    ]

    var body: some View {
        @Bindable var vm = vm
        return VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .top) {
                SectionHeader(title: "Tanya Data",
                              subtitle: "Dijawab dari hasil analisis yang dipilih, bukan dari tebakan.")
                Spacer()
                if !vm.pesan.isEmpty {
                    GhostButton(title: "Hapus", systemImage: "trash") {
                        vm.hapusPercakapan()
                    }
                }
                Picker("", selection: $vm.terpilih) {
                    ForEach(vm.tersedia, id: \.self) { r in
                        Text(r).tag(String?.some(r))
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }
            .spad(Space.xl, [.horizontal, .top])

            if let e = vm.errorMessage {
                InfoNote(text: e, systemImage: "exclamationmark.triangle")
                    .spad(Space.xl, [.horizontal])
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.m) {
                        if vm.pesan.isEmpty { pembuka }
                        ForEach(vm.pesan) { p in
                            GelembungPesan(pesan: p).id(p.id)
                        }
                        if vm.sedangJawab {
                            HStack(spacing: Space.s) {
                                ProgressView().controlSize(.small)
                                Text("Menyusun jawaban…")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .spad(Space.xl, [.horizontal])
                    .padding(.vertical, Space.m)
                }
                .onChange(of: vm.pesan.count) {
                    withAnimation { proxy.scrollTo(vm.pesan.last?.id, anchor: .bottom) }
                }
            }

            HStack(spacing: Space.s) {
                TextField("Tanya apa saja tentang hasil ini…", text: $vm.draf)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await vm.kirim() } }
                PrimaryButton(title: "Kirim", systemImage: "paperplane.fill") {
                    Task { await vm.kirim() }
                }
                .disabled(vm.sedangJawab || vm.terpilih == nil)
            }
            .spad(Space.xl, [.horizontal])
            .padding(.bottom, Space.l)
        }
        .task { await vm.muat() }
    }

    private var pembuka: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Coba tanya:").font(.callout).foregroundStyle(.secondary)
            ForEach(contoh, id: \.self) { c in
                Button(c) { vm.draf = c; Task { await vm.kirim() } }
                    .buttonStyle(.link)
            }
            InfoNote(text: "Jawaban hanya memakai angka dari analisis. Nama tempat "
                         + "diambil dari zona yang kamu gambar sendiri di layar "
                         + "Kalibrasi — kalau belum ada, chatbot akan bilang begitu.",
                     systemImage: "info.circle")
                .padding(.top, Space.s)
        }
        .frame(maxWidth: 620, alignment: .leading)
    }
}

private struct GelembungPesan: View {
    let pesan: PesanChat

    var body: some View {
        if pesan.pemisah {
            HStack(spacing: Space.s) {
                VStack { Divider() }
                Text(pesan.teks).font(.caption).foregroundStyle(.secondary)
                VStack { Divider() }
            }
            .padding(.vertical, Space.xs)
        } else {
            gelembung
        }
    }

    private var gelembung: some View {
        HStack {
            if pesan.dariOrang { Spacer(minLength: 80) }
            Text(pesan.teks)
                .textSelection(.enabled)
                .padding(.vertical, Space.s)
                .padding(.horizontal, Space.m)
                .background(
                    RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                        .fill(pesan.dariOrang ? Theme.accentSoft : Color.secondary.opacity(0.10))
                )
                .frame(maxWidth: 620, alignment: pesan.dariOrang ? .trailing : .leading)
            if !pesan.dariOrang { Spacer(minLength: 80) }
        }
    }
}

#Preview {
    ChatView().frame(width: 1100, height: 780)
}
