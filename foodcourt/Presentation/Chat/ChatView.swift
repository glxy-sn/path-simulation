import SwiftUI

// MARK: - API models

struct ExplanatoryStatusDTO: Decodable {
    let state: String
    let progress: Double
    let error: String?
    let contextRevision: Int
    let packageSchemaVersion: String?
    let chatModel: String
    let embeddingModel: String
    let ollamaReady: Bool
    let modelReady: Bool
    let missingModels: [String]
}

struct ChatSessionSummaryDTO: Decodable, Identifiable, Hashable {
    var id: String { sessionId }
    let sessionId: String
    let jobId: String
    let title: String
    let createdAt: String
    let updatedAt: String
    let contextRevision: Int
    let messageCount: Int
}

struct ChatMediaDTO: Decodable, Identifiable, Hashable {
    var id: String { mediaId }
    let mediaId: String
    let kind: String
    let mimeType: String
    let artifactURL: String
    let thumbnailURL: String
    let caption: String
    let width: Int
    let height: Int
    let selectedAreaId: String?
    let areaKind: String?
    let supportLevel: String?
    let confidence: Double?
    let metricSummary: [String: String]?
    let limitations: [String]?
}

struct ChatExchangeDTO: Decodable, Identifiable {
    var id: String { messageId }
    let messageId: String
    let runId: String
    let question: String
    let text: String
    let supportLevel: String?
    let selectedAreaId: String?
    let selectedAreaKind: String?
    let selectedAreaLabel: String?
    let selectedAreaConfidence: Double?
    let metricSummary: [String: String]?
    let limitations: [String]
    let contextRevision: Int
    let media: [ChatMediaDTO]
    let createdAt: String
}

struct ChatSessionDTO: Decodable, Identifiable {
    var id: String { sessionId }
    let sessionId: String
    let jobId: String
    let title: String
    let createdAt: String
    let updatedAt: String
    let contextRevision: Int
    let messages: [ChatExchangeDTO]
}

struct TanyaDataAPI {
    let http: HTTPClient

    private struct SessionList: Decodable { let sessions: [ChatSessionSummaryDTO] }
    private struct NewSession: Encodable { let title: String? }
    private struct RenameSession: Encodable { let title: String }
    private struct NewMessage: Encodable { let text: String }
    private struct ZoneBody: Encodable {
        struct Zone: Encodable {
            struct Rect: Encodable { let x: Double; let y: Double; let width: Double; let height: Double }
            let id: String; let label: String; let rectNormalized: Rect
        }
        let customZones: [Zone]
    }
    private struct EmptyBody: Encodable {}

    func status(jobId: String) async throws -> ExplanatoryStatusDTO {
        try await http.get("/jobs/\(jobId)/explanatory/status")
    }

    func build(jobId: String) async throws -> ExplanatoryStatusDTO {
        try await http.post("/jobs/\(jobId)/explanatory/build", body: EmptyBody(), timeout: 30)
    }

    func sessions(jobId: String) async throws -> [ChatSessionSummaryDTO] {
        let response: SessionList = try await http.get("/jobs/\(jobId)/chat-sessions")
        return response.sessions
    }

    func create(jobId: String) async throws -> ChatSessionDTO {
        try await http.post("/jobs/\(jobId)/chat-sessions", body: NewSession(title: nil))
    }

    func get(jobId: String, sessionId: String) async throws -> ChatSessionDTO {
        try await http.get("/jobs/\(jobId)/chat-sessions/\(sessionId)")
    }

    func rename(jobId: String, sessionId: String, title: String) async throws -> ChatSessionDTO {
        try await http.patch("/jobs/\(jobId)/chat-sessions/\(sessionId)", body: RenameSession(title: title))
    }

    func delete(jobId: String, sessionId: String) async throws {
        try await http.delete("/jobs/\(jobId)/chat-sessions/\(sessionId)")
    }

    func send(jobId: String, sessionId: String, text: String) async throws -> ChatExchangeDTO {
        try await http.post("/jobs/\(jobId)/chat-sessions/\(sessionId)/messages", body: NewMessage(text: text), timeout: 900)
    }

    func updateContext(jobId: String, zones: [CustomZone]) async throws -> ExplanatoryStatusDTO {
        let body = ZoneBody(customZones: zones.map {
            .init(id: $0.id.uuidString, label: $0.name,
                  rectNormalized: .init(x: $0.rect.minX, y: $0.rect.minY,
                                        width: $0.rect.width, height: $0.rect.height))
        })
        return try await http.put("/jobs/\(jobId)/analysis-context", body: body, timeout: 30)
    }
}

// MARK: - State

@MainActor
@Observable
final class HistoryChatViewModel {
    let jobId: String
    let baseURL: URL
    private let api: TanyaDataAPI

    var status: ExplanatoryStatusDTO?
    var sessions: [ChatSessionSummaryDTO] = []
    var active: ChatSessionDTO?
    var draft = ""
    var isLoading = false
    var isAnswering = false
    var errorMessage: String?

    init(jobId: String, http: HTTPClient) {
        self.jobId = jobId
        self.baseURL = http.baseURL
        self.api = TanyaDataAPI(http: http)
    }

    var isReady: Bool { status?.state == "ready" && status?.modelReady == true }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            status = try await api.status(jobId: jobId)
            if status?.state == "not_started" { status = try await api.build(jobId: jobId) }
            sessions = try await api.sessions(jobId: jobId)
            let key = "Foodcourt.lastChat.\(jobId)"
            if active == nil,
               let remembered = UserDefaults.standard.string(forKey: key),
               sessions.contains(where: { $0.sessionId == remembered }) {
                active = try await api.get(jobId: jobId, sessionId: remembered)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pollStatus() async {
        guard status?.state != "ready" else { return }
        do { status = try await api.status(jobId: jobId) }
        catch { errorMessage = error.localizedDescription }
    }

    func newChat() async {
        do {
            let created = try await api.create(jobId: jobId)
            active = created
            remember(created.sessionId)
            sessions = try await api.sessions(jobId: jobId)
        } catch { errorMessage = error.localizedDescription }
    }

    func open(_ summary: ChatSessionSummaryDTO) async {
        do {
            active = try await api.get(jobId: jobId, sessionId: summary.sessionId)
            remember(summary.sessionId)
        } catch { errorMessage = error.localizedDescription }
    }

    func backToList() { active = nil }

    func send() async {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, isReady, !isAnswering else { return }
        if active == nil { await newChat() }
        guard let sessionID = active?.sessionId else { return }
        draft = ""
        isAnswering = true
        defer { isAnswering = false }
        do {
            _ = try await api.send(jobId: jobId, sessionId: sessionID, text: question)
            active = try await api.get(jobId: jobId, sessionId: sessionID)
            sessions = try await api.sessions(jobId: jobId)
            errorMessage = nil
        } catch {
            draft = question
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ summary: ChatSessionSummaryDTO, to title: String) async {
        do {
            let updated = try await api.rename(jobId: jobId, sessionId: summary.sessionId, title: title)
            if active?.sessionId == updated.sessionId { active = updated }
            sessions = try await api.sessions(jobId: jobId)
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ summary: ChatSessionSummaryDTO) async {
        do {
            try await api.delete(jobId: jobId, sessionId: summary.sessionId)
            if active?.sessionId == summary.sessionId { active = nil }
            sessions = try await api.sessions(jobId: jobId)
        } catch { errorMessage = error.localizedDescription }
    }

    func synchronize(zones: [CustomZone]) async {
        do { status = try await api.updateContext(jobId: jobId, zones: zones) }
        catch { errorMessage = error.localizedDescription }
    }

    private func remember(_ id: String) {
        UserDefaults.standard.set(id, forKey: "Foodcourt.lastChat.\(jobId)")
    }
}

// MARK: - Inspector

struct HistoryChatInspector: View {
    @State private var viewModel: HistoryChatViewModel
    let onOpenMedia: (ChatMediaDTO) -> Void
    let zones: [CustomZone]

    @State private var renameCandidate: ChatSessionSummaryDTO?
    @State private var renameText = ""
    @State private var deleteCandidate: ChatSessionSummaryDTO?
    @State private var contextSyncTask: Task<Void, Never>?

    init(jobId: String, http: HTTPClient, zones: [CustomZone], onOpenMedia: @escaping (ChatMediaDTO) -> Void) {
        _viewModel = State(initialValue: HistoryChatViewModel(jobId: jobId, http: http))
        self.zones = zones
        self.onOpenMedia = onOpenMedia
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let active = viewModel.active {
                conversation(active)
            } else {
                sessionList
            }
        }
        .frame(minWidth: 360, idealWidth: 420, maxWidth: 520)
        .task {
            await viewModel.load()
            while !Task.isCancelled && !viewModel.isReady {
                try? await Task.sleep(for: .seconds(1))
                await viewModel.pollStatus()
            }
        }
        .onChange(of: zones) {
            contextSyncTask?.cancel()
            contextSyncTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await viewModel.synchronize(zones: zones)
            }
        }
        .alert("Ubah Nama Chat", isPresented: Binding(
            get: { renameCandidate != nil },
            set: { if !$0 { renameCandidate = nil } }
        )) {
            TextField("Judul", text: $renameText)
            Button("Simpan") {
                if let candidate = renameCandidate { Task { await viewModel.rename(candidate, to: renameText) } }
                renameCandidate = nil
            }
            Button("Batal", role: .cancel) { renameCandidate = nil }
        }
        .confirmationDialog("Hapus sesi chat ini?", isPresented: Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        )) {
            Button("Hapus", role: .destructive) {
                if let candidate = deleteCandidate { Task { await viewModel.delete(candidate) } }
                deleteCandidate = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            if viewModel.active != nil {
                Button { viewModel.backToList() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).help("Daftar chat")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.active?.title ?? "Tanya Data").font(.headline).lineLimit(1)
                Text(statusText).font(.caption).foregroundStyle(statusColor)
            }
            Spacer()
            Button("New Chat", systemImage: "square.and.pencil") { Task { await viewModel.newChat() } }
                .labelStyle(.iconOnly).help("New Chat")
        }
        .padding(Space.m)
    }

    private var statusText: String {
        guard let status = viewModel.status else { return "Memeriksa pipeline…" }
        switch status.state {
        case "ready" where !status.modelReady:
            return "Model belum siap: \(status.missingModels.joined(separator: ", "))"
        case "ready": return "Qwen3 14B · data siap"
        case "building": return "Membangun analisis \(Int(status.progress * 100))%"
        case "stale": return "Memperbarui konteks…"
        case "error": return status.error ?? "Pipeline gagal"
        default: return "Menunggu analisis mendalam…"
        }
    }

    private var statusColor: Color { viewModel.isReady ? .green : (viewModel.status?.state == "error" ? .red : .secondary) }

    private var sessionList: some View {
        Group {
            if viewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.sessions.isEmpty {
                ContentUnavailableView("Belum ada chat", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Buat New Chat untuk bertanya tentang riwayat ini."))
            } else {
                List(viewModel.sessions) { session in
                    Button { Task { await viewModel.open(session) } } label: {
                        HStack(spacing: Space.s) {
                            Image(systemName: "bubble.left")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title).lineLimit(1)
                                Text("\(session.messageCount) pesan · revisi \(session.contextRevision)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Ubah Nama") { renameCandidate = session; renameText = session.title }
                        Button("Hapus", role: .destructive) { deleteCandidate = session }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .overlay(alignment: .top) { errorNote }
    }

    private func conversation(_ session: ChatSessionDTO) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.m) {
                        if session.messages.isEmpty {
                            suggestions
                        }
                        ForEach(session.messages) { exchange in
                            UserBubble(text: exchange.question)
                            AssistantBubble(exchange: exchange)
                            ForEach(exchange.media) { media in
                                ImageBubble(media: media, url: mediaURL(media.thumbnailURL)) {
                                    onOpenMedia(media)
                                }
                            }
                            if !exchange.limitations.isEmpty {
                                LimitationBubble(items: exchange.limitations)
                            }
                        }
                        if viewModel.isAnswering {
                            HStack { ProgressView().controlSize(.small); Text("Qwen3 14B menyusun jawaban…") }
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(Space.m)
                }
                .onChange(of: session.messages.count) {
                    if let last = session.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            errorNote
            Divider()
            composer
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Coba tanyakan:").font(.caption).foregroundStyle(.secondary)
            ForEach(["Area mana yang paling ramai?", "Meja mana yang paling efektif?", "Area mana yang jarang dilewati?"], id: \.self) { value in
                Button(value) { viewModel.draft = value; Task { await viewModel.send() } }.buttonStyle(.link)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: Space.s) {
            TextField("Tanya data riwayat ini…", text: $viewModel.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...5)
                .onSubmit { Task { await viewModel.send() } }
            Button { Task { await viewModel.send() } } label: { Image(systemName: "paperplane.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.isReady || viewModel.isAnswering || viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(Space.m)
    }

    @ViewBuilder private var errorNote: some View {
        if let error = viewModel.errorMessage {
            Text(error).font(.caption).foregroundStyle(.red).padding(Space.s).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func mediaURL(_ path: String) -> URL? {
        URL(string: path, relativeTo: viewModel.baseURL)?.absoluteURL
    }
}

private struct UserBubble: View {
    let text: String
    var body: some View {
        HStack { Spacer(minLength: 60); Text(text).textSelection(.enabled).padding(10).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10)) }
    }
}

private struct AssistantBubble: View {
    let exchange: ChatExchangeDTO
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(exchange.text).textSelection(.enabled)
            HStack(spacing: 6) {
                if let area = exchange.selectedAreaId { Text(area).font(.caption.monospaced()).foregroundStyle(.secondary) }
                if let support = exchange.supportLevel {
                    Text(support).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
        }
        .padding(10).background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ImageBubble: View {
    let media: ChatMediaDTO
    let url: URL?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.s) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit()
                    case .failure: ContentUnavailableView("Gambar gagal dimuat", systemImage: "photo.badge.exclamationmark")
                    default: ProgressView().frame(maxWidth: .infinity, minHeight: 140)
                    }
                }
                .frame(maxHeight: 240).clipShape(RoundedRectangle(cornerRadius: Radius.s))
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(media.caption).font(.callout.weight(.semibold))
                        if let area = media.selectedAreaId { Text(area).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        if let metric = media.metricSummary?.sorted(by: { $0.key < $1.key }).first {
                            Text("\(metric.key): \(metric.value)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let support = media.supportLevel {
                        Text(support).font(.caption2).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
            }
            .padding(8).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.m))
        }
        .buttonStyle(.plain)
    }
}

private struct LimitationBubble: View {
    let items: [String]
    @State private var expanded = false
    var body: some View {
        DisclosureGroup("Keterbatasan data", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(.secondary) }
            }.padding(.top, 4)
        }
        .font(.caption.weight(.medium)).padding(8)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: Radius.s))
    }
}
