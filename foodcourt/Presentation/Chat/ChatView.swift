//
//  ChatView.swift
//  foodcourt
//

import SwiftUI

struct PesanChat: Identifiable, Codable {
    var id = UUID()
    let dariOrang: Bool
    let teks: String
    /// Penanda ganti lari — bukan ucapan siapa pun, ditampilkan sebagai garis
    /// pemisah.
    var pemisah = false
}

@Observable
@MainActor
final class ChatViewModel {
    var runs: [RunDTO] = []
    var runTerpilih: String?
    var pesan: [PesanChat] = []
    var draf = ""
    var sedangJawab = false
    var errorMessage: String?

    /// Lari yang sedang dibicarakan percakapan ini. Dipisah dari `runTerpilih`
    /// supaya pergantian di pemilih bisa dikenali.
    private var runPercakapan: String?

    // MARK: simpanan
    //
    // Ditulis ke Documents/crowdflow — satu-satunya folder di luar kotak pasir
    // yang boleh ditulis aplikasi ini, dan tempat hasil analisis sudah berada.

    private struct Simpanan: Codable {
        var pesan: [PesanChat]
        var riwayat: [Giliran]
        var run: String?
        struct Giliran: Codable { let peran: String; let teks: String }
    }

    private static let berkas = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/crowdflow/chat-riwayat.json")

    init() { pulihkan() }

    private func pulihkan() {
        guard let data = try? Data(contentsOf: Self.berkas),
              let s = try? JSONDecoder().decode(Simpanan.self, from: data)
        else { return }
        pesan = s.pesan
        riwayatBersih = s.riwayat.map { .init(peran: $0.peran, teks: $0.teks) }
        runPercakapan = s.run
        runTerpilih = s.run
    }

    /// Dipanggil tiap giliran, bukan saat aplikasi ditutup: aplikasi bisa mati
    /// paksa, dan percakapan yang hilang karena itu terasa seperti kesalahan
    /// pemakai padahal bukan.
    private func simpan() {
        let s = Simpanan(pesan: pesan,
                         riwayat: riwayatBersih.map { .init(peran: $0.peran, teks: $0.teks) },
                         run: runPercakapan)
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? FileManager.default.createDirectory(
            at: Self.berkas.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.berkas, options: .atomic)
    }

    func hapusPercakapan() {
        pesan = []
        riwayatBersih = []
        runPercakapan = nil
        try? FileManager.default.removeItem(at: Self.berkas)
    }

    func muat(_ api: EngineAPI) async {
        runs = (try? await api.runs()) ?? []
        if runTerpilih == nil { runTerpilih = runs.first?.id }
    }

    func kirim(_ api: EngineAPI) async {
        let t = draf.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let run = runTerpilih, !sedangJawab else { return }

        // Ganti lari di tengah percakapan pernah membuat satu layar berisi
        // angka dari dua rekaman berbeda tanpa satu pun tanda di layar: jawaban
        // "588 detik" milik lari lama, lalu jawaban berikutnya menyangkalnya
        // karena lari yang baru tidak punya angka itu. Riwayat dipotong di
        // sini, dan pemotongannya terlihat.
        if let lama = runPercakapan, lama != run {
            pesan.append(PesanChat(dariOrang: false,
                                   teks: "Ganti ke \(run) — jawaban di atas "
                                       + "memakai angka dari \(lama).",
                                   pemisah: true))
            riwayatBersih = []
        }
        runPercakapan = run

        draf = ""
        pesan.append(PesanChat(dariOrang: true, teks: t))
        riwayatBersih.append(.init(peran: "orang", teks: t))
        sedangJawab = true
        errorMessage = nil
        defer { sedangJawab = false }
        do {
            // Riwayat dikirim tanpa giliran terakhir: itu pertanyaannya sendiri.
            let sebelum = Array(riwayatBersih.dropLast())
            let j = try await api.chat(runId: run, pertanyaan: t, riwayat: sebelum)
            pesan.append(PesanChat(dariOrang: false, teks: j))
            riwayatBersih.append(.init(peran: "bot", teks: j))
        } catch {
            errorMessage = pesanRamah(error)
            riwayatBersih.removeLast()      // pertanyaan yang tak terjawab
        }
        simpan()
    }

    /// Percakapan yang dikirim ke model — tanpa penanda pemisah.
    private var riwayatBersih: [EngineAPI.GiliranChat] = []

    /// Engine mengirim `{"error": "..."}`; ditampilkan mentah, isinya jadi
    /// `HTTP 503: {"error": "Ollama belum jalan…}` — pesan yang berguna
    /// terkubur di dalam tanda kurung.
    private func pesanRamah(_ e: Error) -> String {
        if case EngineError.http(_, let body) = e,
           let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let m = obj["error"] as? String {
            return m
        }
        return e.localizedDescription
    }
}

/// Tanya-jawab atas satu hasil analisis, dijawab model bahasa lokal.
///
/// Yang dikirim ke model bukan pertanyaannya saja, tapi ringkasan lari yang
/// dipilih — jadi jawabannya terikat pada rekaman ini, bukan pengetahuan umum.
struct ChatView: View {
    @Environment(\.uiScale) private var scale
    @Environment(Sidecar.self) private var sidecar
    // Dimiliki RootView, bukan layar ini — lihat catatan di sana.
    @Environment(ChatViewModel.self) private var vm

    private var api: EngineAPI { EngineAPI(http: sidecar.http) }

    private let contoh = [
        "Tempat mana yang cocok buat main board game?",
        "Di mana orang paling lama berhenti?",
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
                Picker("", selection: $vm.runTerpilih) {
                    ForEach(vm.runs, id: \.id) { r in
                        Text(r.id).tag(String?.some(r.id))
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
                                Text("Menyusun jawaban… (bisa sampai satu menit)")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            .id("tunggu")
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
                    .onSubmit { Task { await vm.kirim(api) } }
                PrimaryButton(title: "Kirim", systemImage: "paperplane.fill") {
                    Task { await vm.kirim(api) }
                }
                .disabled(vm.sedangJawab || vm.runTerpilih == nil)
            }
            .spad(Space.xl, [.horizontal])
            .padding(.bottom, Space.l)
        }
        .task { await vm.muat(api) }
    }

    private var pembuka: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Coba tanya:").font(.callout).foregroundStyle(.secondary)
            ForEach(contoh, id: \.self) { c in
                Button(c) { vm.draf = c; Task { await vm.kirim(api) } }
                    .buttonStyle(.link)
            }
            InfoNote(text: "Jawaban hanya memakai angka dari analisis. Jumlah "
                         + "pengunjung dan puncak okupansi masih perkiraan — "
                         + "chatbot akan menyebutkan itu sendiri.",
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
    ChatView()
        .environment(Sidecar())
        .environment(ChatViewModel())
        .frame(width: 1100, height: 780)
}
