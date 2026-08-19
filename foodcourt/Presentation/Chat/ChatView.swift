import SwiftUI

// MARK: - API models

struct ExplanatoryStatusDTO: Decodable {
    let state: String
    let progress: Double
    let error: String?
    let contextRevision: Int
    let packageSchemaVersion: String?
    let runtime: String
    let chatModel: String
    let modelReady: Bool
    let modelState: String
    let modelError: String?
}

/// The backend stores "Chat Baru" as the default session title *and* keys its
/// auto-rename on that exact string, so it must stay as-is on the wire. Translate
/// only where it is shown; this also covers sessions saved before the rename.
func chatDisplayTitle(_ raw: String) -> String {
    raw == "Chat Baru" ? "New Chat" : raw
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

// MARK: - Shared Results + Tanya Data layout

struct ResultsChatContainer: View {
    let jobId: String?
    let http: HTTPClient
    let isHistory: Bool
    let onClose: (() -> Void)?
    @Binding var showsChat: Bool

    @Environment(AnalysisSession.self) private var session
    @State private var selectedMedia: ChatMediaDTO?
    @State private var restoreChatAfterArtifact = false

    var body: some View {
        Group {
            if let selectedMedia {
                ArtifactDetailView(
                    media: selectedMedia,
                    baseURL: http.baseURL,
                    onBack: closeArtifact
                )
            } else {
                detailLayout
            }
        }
    }

    private var validJobId: String? {
        guard let jobId, !jobId.isEmpty else { return nil }
        return jobId
    }

    private var detailLayout: some View {
        HStack(spacing: 0) {
            ResultsView(
                isHistory: isHistory,
                onClose: onClose,
                onOpenChat: openChatAction,
                isChatVisible: showsChat
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsChat {
                Divider()
                chatPanel
            }
        }
    }

    private var openChatAction: (() -> Void)? {
        guard validJobId != nil else { return nil }
        return { openChat() }
    }

    @ViewBuilder
    private var chatPanel: some View {
        if let jobId = validJobId {
            HistoryChatInspector(
                jobId: jobId,
                http: http,
                zones: session.customZones,
                onOpenMedia: openMedia,
                onClose: closeChat
            )
            .frame(width: 420)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            LegacyChatUnavailable(onClose: closeChat)
                .frame(width: 420)
        }
    }

    private func openMedia(_ media: ChatMediaDTO) {
        restoreChatAfterArtifact = true
        selectedMedia = media
    }

    private func openChat() {
        withAnimation(.easeInOut(duration: 0.2)) { showsChat = true }
    }

    private func closeChat() {
        withAnimation(.easeInOut(duration: 0.2)) { showsChat = false }
    }

    private func closeArtifact() {
        selectedMedia = nil
        if restoreChatAfterArtifact {
            showsChat = true
            restoreChatAfterArtifact = false
        }
    }
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

    /// Backend sudah lama mengirim alasan kegagalan lewat `error`/`modelError`,
    /// tetapi tidak ada satu pun tempat yang menampilkannya. Akibatnya layar
    /// hanya diam dengan tombol kirim mati, tanpa petunjuk apa pun.
    var blockedReason: String? {
        guard let status else { return nil }
        if status.state == "error" {
            return status.error ?? "Analysis package failed to build."
        }
        if status.modelState == "error" || status.modelError != nil {
            return status.modelError ?? "The language model failed to load."
        }
        return nil
    }

    /// `error` tidak akan berubah sendiri, jadi memungut status tiap detik
    /// selamanya hanya membebani backend tanpa hasil.
    var isBlocked: Bool { blockedReason != nil }

    /// Kenapa tombol kirim mati. Sebelumnya keadaan ini tidak pernah dijelaskan,
    /// jadi tombol abu-abu tampak seperti aplikasi yang rusak.
    var disabledReason: String? {
        if isAnswering { return "Answering your previous question…" }
        guard let status else { return "Connecting to the analysis engine…" }
        if status.state != "ready" {
            let percent = Int((status.progress * 100).rounded())
            return status.state == "building"
                ? "Preparing this analysis for questions… \(percent)%"
                : "This analysis is not ready for questions yet (\(status.state))."
        }
        if !status.modelReady {
            return "Loading the language model… (\(status.modelState))"
        }
        return nil
    }

    func rebuild() async {
        do {
            status = try await api.build(jobId: jobId)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        // Loop pemungutan di view sudah berhenti waktu status jadi error, jadi
        // percobaan ulang harus memungut statusnya sendiri sampai selesai.
        while !Task.isCancelled && !isReady && !isBlocked {
            try? await Task.sleep(for: .seconds(1))
            await pollStatus()
        }
    }

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
        guard status?.state != "ready", !isBlocked else { return }
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
            blockedBanner
            if let active = viewModel.active {
                conversation(active)
            } else {
                sessionList
            }
        }
        .background(.regularMaterial)
        .task {
            await viewModel.load()
            while !Task.isCancelled && !viewModel.isReady && !viewModel.isBlocked {
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
        .alert("Rename Chat", isPresented: Binding(
            get: { renameCandidate != nil },
            set: { if !$0 { renameCandidate = nil } }
        )) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let candidate = renameCandidate { Task { await viewModel.rename(candidate, to: renameText) } }
                renameCandidate = nil
            }
            Button("Cancel", role: .cancel) { renameCandidate = nil }
        }
        .confirmationDialog("Delete this chat session?", isPresented: Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let candidate = deleteCandidate { Task { await viewModel.delete(candidate) } }
                deleteCandidate = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            if viewModel.active != nil {
                headerIconButton(systemImage: "chevron.left", help: "Back to chat list") {
                    viewModel.backToList()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.active.map { chatDisplayTitle($0.title) } ?? "Ask Data")
                    .font(.headline)
                    .lineLimit(1)
            }
            Spacer()

            if viewModel.active != nil {
                headerIconButton(systemImage: "square.and.pencil", help: "New chat") {
                    Task { await viewModel.newChat() }
                }
            }
            headerIconButton(systemImage: "sidebar.right", help: "Close Ask Data", action: onClose)
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
                        Text("Conversations")
                            .font(.callout.weight(.semibold))
                        Text("Pick a chat to continue its previous context.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("New Chat", systemImage: "plus") {
                        Task { await viewModel.newChat() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Theme.accentFill)
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
                Text("No chats yet")
                    .font(.title3.weight(.semibold))
                Text("Start a new conversation to ask about this analysis.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("New Chat", systemImage: "square.and.pencil") {
                Task { await viewModel.newChat() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.accentFill)
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
                Text(chatDisplayTitle(session.title))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.m)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: Radius.m))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.m)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                renameCandidate = session
                renameText = chatDisplayTitle(session.title)
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
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
                                Text("Analyzing…")
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
            composerNote
            Divider()
            composer
        }
    }

    private var conversationEmptyState: some View {
        VStack(spacing: Space.s) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(Theme.accent)
            Text("Ask about this analysis")
                .font(.callout.weight(.semibold))
            Text("Answers use this analysis data and this chat session context only.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xl)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: Space.s) {
            TextField("Ask about this analysis…", text: $viewModel.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, Space.s)
                .padding(.vertical, 9)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: Radius.m))
                .onSubmit { Task { await viewModel.send() } }
                // `axis: .vertical` membuat Return menyisipkan baris baru dan
                // `onSubmit` tidak pernah terpanggil, sehingga tombol Enter
                // terasa mati total. Return dikirim, Shift+Return tetap baris baru.
                .onKeyPress(.return, phases: .down) { press in
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    Task { await viewModel.send() }
                    return .handled
                }
            Button { Task { await viewModel.send() } } label: {
                Image(systemName: "paperplane.fill")
                    .frame(width: 22, height: 22)
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Theme.accentFill)
                .disabled(!viewModel.isReady || viewModel.isAnswering || viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(Space.m)
    }

    /// Ditampilkan ketika paket penjelasan atau model gagal disiapkan. Tanpa ini
    /// pengguna hanya melihat tombol kirim yang mati tanpa sebab.
    @ViewBuilder private var blockedBanner: some View {
        if let reason = viewModel.blockedReason {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Chat is unavailable for this analysis")
                            .font(.callout.weight(.semibold))
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        // Status kegagalan tersimpan di disk dan tidak pernah
                        // dicoba ulang sendiri, jadi pesan lama tetap tampil
                        // walau penyebabnya sudah diperbaiki oleh pembaruan.
                        Text("This message may be left over from an earlier attempt. Press Try Again to rebuild it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Try Again") { Task { await viewModel.rebuild() } }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.m)
            .background(Color.orange.opacity(0.10))
            Divider()
        }
    }

    @ViewBuilder private var composerNote: some View {
        if viewModel.blockedReason == nil, let reason = viewModel.disabledReason {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(reason)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Space.m)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                markdownBody
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
            .replacingOccurrences(of: "Table with ID \(areaId)", with: label, options: .caseInsensitive)
            .replacingOccurrences(of: "Area with ID \(areaId)", with: label, options: .caseInsensitive)
            .replacingOccurrences(of: "ID \(areaId)", with: label, options: .caseInsensitive)
            .replacingOccurrences(of: areaId, with: label, options: .caseInsensitive)
    }

    /// Qwen menjawab dengan paragraf plus daftar berbutir. `interpretedSyntax: .full`
    /// mengurai strukturnya tetapi membuang batas antar-blok begitu semuanya
    /// dijejalkan ke satu `Text`, sehingga paragraf saling menempel. Jadi blok
    /// dipisah sendiri dan tiap blok dirender terpisah.
    private var markdownBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(markdownBlocks.enumerated()), id: \.offset) { _, block in
                if block.isBullet {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\u{2022}")
                        Text(inlineMarkdown(block.text))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text(inlineMarkdown(block.text))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var markdownBlocks: [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(MarkdownBlock(text: joined, isBullet: false)) }
            paragraph.removeAll()
        }

        for rawLine in displayText.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
            } else if let bullet = line.bulletContent {
                flushParagraph()
                blocks.append(MarkdownBlock(text: bullet, isBullet: true))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return blocks
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
    }
}

private struct MarkdownBlock {
    let text: String
    let isBullet: Bool
}

private extension String {
    /// Isi butir untuk baris "- teks", "* teks", atau "1. teks"; nil kalau bukan butir.
    var bulletContent: String? {
        for marker in ["- ", "* ", "\u{2022} "] where hasPrefix(marker) {
            return String(dropFirst(marker.count))
        }
        if let ordered = range(of: "^[0-9]+[.)]\\s+", options: .regularExpression) {
            return String(self[ordered.upperBound...])
        }
        return nil
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
                    case .failure: ContentUnavailableView("Image failed to load", systemImage: "photo.badge.exclamationmark")
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
