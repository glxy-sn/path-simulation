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
    var pendingQuestion: String?
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
        pendingQuestion = question
        isAnswering = true
        defer { isAnswering = false }
        do {
            _ = try await api.send(jobId: jobId, sessionId: sessionID, text: question)
            let refreshed = try await api.get(jobId: jobId, sessionId: sessionID)
            pendingQuestion = nil
            active = refreshed
            sessions = try await api.sessions(jobId: jobId)
            errorMessage = nil
        } catch {
            pendingQuestion = nil
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
    let onClose: () -> Void
    let zones: [CustomZone]

    @State private var renameCandidate: ChatSessionSummaryDTO?
    @State private var renameText = ""
    @State private var deleteCandidate: ChatSessionSummaryDTO?
    @State private var contextSyncTask: Task<Void, Never>?

    init(
        jobId: String,
        http: HTTPClient,
        zones: [CustomZone],
        onOpenMedia: @escaping (ChatMediaDTO) -> Void,
        onClose: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: HistoryChatViewModel(jobId: jobId, http: http))
        self.zones = zones
        self.onOpenMedia = onOpenMedia
        self.onClose = onClose
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
        .background(.regularMaterial)
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
                headerIconButton(systemImage: "chevron.left", help: "Kembali ke daftar chat") {
                    viewModel.backToList()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.active?.title ?? "Tanya Data")
                    .font(.headline)
                    .lineLimit(1)
            }
            Spacer()

            if viewModel.active != nil {
                headerIconButton(systemImage: "square.and.pencil", help: "Buat chat baru") {
                    Task { await viewModel.newChat() }
                }
            }
            headerIconButton(systemImage: "sidebar.right", help: "Tutup Tanya Data", action: onClose)
        }
        .padding(Space.m)
    }

    private func headerIconButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout.weight(.medium))
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: Radius.s))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.sessions.isEmpty {
                emptySessionState
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Percakapan")
                            .font(.callout.weight(.semibold))
                        Text("Pilih chat untuk melanjutkan konteks sebelumnya.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Chat Baru", systemImage: "plus") {
                        Task { await viewModel.newChat() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Theme.accent)
                }
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.s)

                ScrollView {
                    LazyVStack(spacing: Space.s) {
                        ForEach(viewModel.sessions) { session in
                            sessionRow(session)
                        }
                    }
                    .padding(.horizontal, Space.m)
                    .padding(.bottom, Space.m)
                }
            }
        }
        .overlay(alignment: .top) { errorNote }
    }

    private var emptySessionState: some View {
        VStack(spacing: Space.m) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.m))
            VStack(spacing: 6) {
                Text("Belum ada chat")
                    .font(.title3.weight(.semibold))
                Text("Mulai percakapan baru untuk bertanya tentang hasil analisis pada riwayat ini.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Buat Chat Baru", systemImage: "square.and.pencil") {
                Task { await viewModel.newChat() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.accent)
            Spacer()
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sessionRow(_ session: ChatSessionSummaryDTO) -> some View {
        Button {
            Task { await viewModel.open(session) }
        } label: {
            HStack {
                Text(session.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Space.m)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: Radius.m))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.m)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .contextMenu {
            Button("Ubah Nama", systemImage: "pencil") {
                renameCandidate = session
                renameText = session.title
            }
            Button("Hapus", systemImage: "trash", role: .destructive) {
                deleteCandidate = session
            }
        }
    }

    private func conversation(_ session: ChatSessionDTO) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.m) {
                        if session.messages.isEmpty && viewModel.pendingQuestion == nil {
                            conversationEmptyState
                        }
                        ForEach(session.messages) { exchange in
                            UserBubble(text: exchange.question)
                            AssistantBubble(exchange: exchange)
                            ForEach(exchange.media) { media in
                                ImageBubble(media: media, url: mediaURL(media.thumbnailURL)) {
                                    onOpenMedia(media)
                                }
                                .padding(.leading, 28 + Space.s)
                            }
                        }
                        if let pendingQuestion = viewModel.pendingQuestion {
                            UserBubble(text: pendingQuestion)
                            HStack(spacing: Space.s) {
                                ProgressView().controlSize(.small)
                                Text("Qwen3 14B sedang menganalisis…")
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        }
                    }
                    .padding(Space.m)
                }
                .background(Color.primary.opacity(0.018))
                .onChange(of: session.messages.count) {
                    if let last = session.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            errorNote
            Divider()
            composer
        }
    }

    private var conversationEmptyState: some View {
        VStack(spacing: Space.s) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(Theme.accent)
            Text("Tanyakan tentang riwayat ini")
                .font(.callout.weight(.semibold))
            Text("Jawaban memakai data analisis dan konteks sesi chat ini saja.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xl)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: Space.s) {
            TextField("Tanya data riwayat ini…", text: $viewModel.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, Space.s)
                .padding(.vertical, 9)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: Radius.m))
                .onSubmit { Task { await viewModel.send() } }
            Button { Task { await viewModel.send() } } label: {
                Image(systemName: "paperplane.fill")
                    .frame(width: 22, height: 22)
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Theme.accent)
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
        HStack {
            Spacer(minLength: 72)
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

private struct AssistantBubble: View {
    let exchange: ChatExchangeDTO
    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Theme.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 7) {
                Text(displayText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayText: String {
        guard let areaId = exchange.selectedAreaId,
              let label = exchange.selectedAreaLabel,
              !label.isEmpty else { return exchange.text }
        return exchange.text
            .replacingOccurrences(of: "Meja dengan ID \(areaId)", with: label, options: .caseInsensitive)
            .replacingOccurrences(of: "Area dengan ID \(areaId)", with: label, options: .caseInsensitive)
            .replacingOccurrences(of: "ID \(areaId)", with: label, options: .caseInsensitive)
            .replacingOccurrences(of: areaId, with: label, options: .caseInsensitive)
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
                        if let metric = media.metricSummary?.sorted(by: { $0.key < $1.key }).first {
                            Text("\(metric.key): \(metric.value)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
            }
            .padding(8).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.m))
        }
        .buttonStyle(.plain)
    }
}
