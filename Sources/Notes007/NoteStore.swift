import AppKit
import Foundation
import Network

/// Offline-first: every change is saved on this Mac immediately, then pushed to the server.
/// Server data never overwrites a note that still has local changes.
@MainActor
final class NoteStore: ObservableObject {
    static let shared = NoteStore()

    enum LoginState { case loggedOut, waitingForBrowser, loggedIn }

    @Published private(set) var account: Account?
    @Published private(set) var loginState: LoginState = .loggedOut
    @Published var loginError: String?
    @Published private(set) var notes: [LocalNote] = []
    @Published var selectedId: UUID? {
        didSet { if oldValue != selectedId { discardIfEmpty(oldValue) } }
    }
    @Published var search = ""
    @Published var categoryFilter: String?      // nil = all notes
    @Published private(set) var syncing = false
    @Published private(set) var pushingId: UUID?
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncMessage: String?   // e.g. "Offline — changes are saved on this Mac"
    @Published private(set) var serverName = "Nextcloud"
    @Published private(set) var isOnline = true
    @Published var pendingDelete: LocalNote?
    @Published var focusToken = 0                     // bump to focus the editor

    @Published var syncMode: SyncMode = SyncMode(rawValue: UserDefaults.standard.string(forKey: "syncMode") ?? "") ?? .automatic {
        didSet {
            UserDefaults.standard.set(syncMode.rawValue, forKey: "syncMode")
            if syncMode == .automatic { requestSync() }
        }
    }

    private(set) var api: NotesAPI?
    private var loginTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var syncDebounce: Task<Void, Never>?
    private var syncAgain = false
    private let monitor = NWPathMonitor()
    let images = ImageCache()

    private static var notesFile: URL { CredentialStore.directory.appendingPathComponent("notes.json") }

    init() {
        if let data = try? Data(contentsOf: Self.notesFile),
           let saved = try? JSONDecoder().decode([LocalNote].self, from: data) {
            notes = saved
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let wasOffline = !self.isOnline
                self.isOnline = online
                if online && wasOffline { self.requestSync() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "net"))
        if let saved = CredentialStore.load() { activate(saved.account, password: saved.appPassword) }
    }

    // MARK: Derived

    var visibleNotes: [LocalNote] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return notes
            .filter { !$0.deleted }
            .filter { categoryFilter == nil || $0.category == categoryFilter }
            .filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || $0.content.localizedCaseInsensitiveContains(q) }
            .sorted { a, b in
                if a.favorite != b.favorite { return a.favorite }
                return a.modified > b.modified
            }
    }

    var categories: [String] {
        Array(Set(notes.filter { !$0.deleted }.map(\.category).filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var pendingCount: Int { notes.filter(\.needsUpload).filter { !($0.serverId == nil && $0.content.isEmpty) }.count }
    var selected: LocalNote? { notes.first { $0.id == selectedId } }

    func status(of n: LocalNote) -> NoteStatus {
        if let e = n.error { return .failed(e) }
        if n.needsUpload { return (syncing && pushingId == n.id) ? .syncing : .pending }
        return .synced(n.lastSynced)
    }

    // MARK: Editing (always local first)

    func newNote() {
        if let current = selected, current.serverId == nil, current.content.isEmpty {
            focusToken += 1                 // already on an empty new note
            return
        }
        var n = LocalNote()
        n.category = categoryFilter ?? ""
        n.dirty = true
        notes.append(n)
        search = ""
        selectedId = n.id
        focusToken += 1
        scheduleSave()
    }

    func updateContent(_ id: UUID, _ text: String) {
        guard let i = index(id), notes[i].content != text, !notes[i].readonly else { return }
        notes[i].content = text
        notes[i].title = LocalNote.title(from: text)
        touch(i)
    }

    func toggleFavorite(_ id: UUID) {
        guard let i = index(id) else { return }
        notes[i].favorite.toggle()
        touch(i)
    }

    func setCategory(_ id: UUID, _ category: String) {
        guard let i = index(id) else { return }
        notes[i].category = category.trimmingCharacters(in: .whitespaces)
        touch(i)
    }

    func delete(_ id: UUID) {
        guard let i = index(id) else { return }
        if notes[i].serverId == nil {
            notes.remove(at: i)
        } else {
            notes[i].deleted = true
            notes[i].revision += 1
        }
        if selectedId == id { selectedId = visibleNotes.first?.id }
        scheduleSave()
        scheduleAutoSync()
    }

    private func touch(_ i: Int) {
        notes[i].modified = Int(Date().timeIntervalSince1970)
        notes[i].dirty = true
        notes[i].error = nil
        notes[i].revision += 1
        scheduleSave()
        scheduleAutoSync()
    }

    /// A new note that was never typed into is dropped instead of being uploaded empty.
    private func discardIfEmpty(_ id: UUID?) {
        guard let id, let i = index(id), notes[i].serverId == nil,
              notes[i].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        notes.remove(at: i)
        scheduleSave()
    }

    private func index(_ id: UUID) -> Int? { notes.firstIndex { $0.id == id } }

    // MARK: Local storage

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: Self.notesFile, options: [.atomic])
    }

    // MARK: Sync

    private func scheduleAutoSync() {
        guard syncMode == .automatic else { return }
        syncDebounce?.cancel()
        syncDebounce = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    /// Automatic mode only (timer, coming back online, app activation).
    func requestSync() {
        guard syncMode == .automatic || (lastSync == nil && notes.isEmpty) else { return }
        Task { await sync() }
    }

    /// "Sync now": works in both modes.
    func sync() async {
        guard let api else { return }
        if syncing { syncAgain = true; return }
        syncing = true
        defer { syncing = false; pushingId = nil }
        repeat {
            syncAgain = false
            let pushedAll = await push(api)
            if pushedAll || isOnline { await pull(api) }
        } while syncAgain && self.api === api
        saveNow()
    }

    /// Sends local changes. Returns false if it had to stop (offline, signed out).
    private func push(_ api: NotesAPI) async -> Bool {
        let ids = notes.filter(\.needsUpload).map(\.id)
        for id in ids {
            guard self.api === api, let n = notes.first(where: { $0.id == id }) else { continue }
            if n.serverId == nil && n.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !n.deleted { continue }
            let rev = n.revision
            pushingId = id
            do {
                if n.deleted {
                    if let sid = n.serverId { try await api.delete(sid) }
                    notes.removeAll { $0.id == id && $0.revision == rev }
                } else if let sid = n.serverId {
                    let result: ServerNote
                    do {
                        result = try await api.update(sid, n, etag: n.etag)
                    } catch APIError.conflict {
                        // Changed on another device too: keep both, nothing is lost.
                        let other = try await api.get(sid)
                        if (other.content ?? "") != n.content { keepOtherVersion(other) }
                        result = try await api.update(sid, n, etag: nil)
                    } catch APIError.notFound {
                        result = try await api.create(n)   // deleted elsewhere: put it back
                    }
                    finishPush(id, rev, result)
                } else {
                    finishPush(id, rev, try await api.create(n))
                }
            } catch APIError.locked {
                // Temporary: the file is being edited elsewhere. Stay pending (✓) and try again later.
                if let i = index(id) { notes[i].error = nil }
                lockedIds.insert(id)
                scheduleLockedRetry()
            } catch APIError.offline {
                syncMessage = "Offline — changes are saved on this Mac."
                return false
            } catch APIError.unauthorized {
                signedOutByServer()
                return false
            } catch {
                if Task.isCancelled { return false }
                if let i = index(id) { notes[i].error = error.localizedDescription }
            }
        }
        pushingId = nil
        return true
    }

    /// Notes the server refused because the file is locked; retried every 30 s, even in manual mode.
    @Published private(set) var lockedIds = Set<UUID>()
    private var lockedRetry: Task<Void, Never>?

    private func scheduleLockedRetry() {
        guard lockedRetry == nil else { return }
        lockedRetry = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            lockedRetry = nil
            if !lockedIds.isEmpty { await sync() }
        }
    }

    private func finishPush(_ id: UUID, _ rev: Int, _ s: ServerNote) {
        lockedIds.remove(id)
        guard let i = index(id) else { return }
        notes[i].serverId = s.id
        notes[i].etag = s.etag
        notes[i].lastSynced = Int(Date().timeIntervalSince1970)
        notes[i].error = nil
        if notes[i].revision == rev { notes[i].dirty = false }   // typed more meanwhile? stays pending
    }

    private func keepOtherVersion(_ other: ServerNote) {
        var copy = LocalNote()
        copy.content = other.content ?? ""
        copy.title = (other.title ?? LocalNote.title(from: copy.content)) + " (other version)"
        copy.category = other.category ?? ""
        copy.dirty = true
        notes.append(copy)
        syncMessage = "A note was changed on two devices — the other version was kept as a separate note."
    }

    /// Takes the server's notes, without touching notes that still have local changes.
    private func pull(_ api: NotesAPI) async {
        do {
            let server = try await api.list()
            guard self.api === api else { return }
            let serverIds = Set(server.map(\.id))
            for s in server {
                if let i = notes.firstIndex(where: { $0.serverId == s.id }) {
                    if notes[i].needsUpload { continue }
                    if notes[i].etag != s.etag { notes[i].apply(server: s) }
                    notes[i].lastSynced = Int(Date().timeIntervalSince1970)
                } else {
                    notes.append(LocalNote(server: s))
                }
            }
            // Deleted on the server (and unchanged here) → remove here too.
            notes.removeAll { n in
                guard let sid = n.serverId else { return false }
                return !serverIds.contains(sid) && !n.needsUpload
            }
            if let sel = selectedId, index(sel) == nil { selectedId = nil }
            lastSync = Date()
            if syncMessage?.hasPrefix("Offline") == true { syncMessage = nil }
        } catch APIError.offline {
            syncMessage = "Offline — changes are saved on this Mac."
        } catch APIError.unauthorized {
            signedOutByServer()
        } catch {
            syncMessage = "Sync failed: \(error.localizedDescription)"
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                self?.requestSync()
            }
        }
    }

    // MARK: Login

    func startLogin(serverInput: String) {
        loginError = nil
        guard let server = Self.normalize(serverInput) else {
            loginError = "Please enter a valid server address."
            return
        }
        loginState = .waitingForBrowser
        loginTask?.cancel()
        loginTask = Task {
            do {
                let start = try await LoginFlow.start(server: server)
                if let url = URL(string: start.login) { NSWorkspace.shared.open(url) }
                let result = try await LoginFlow.poll(start)
                var acc = Account(server: Self.normalize(result.server) ?? server, loginName: result.loginName,
                                  userId: result.loginName, displayName: result.loginName)
                if let me = try? await NotesAPI(account: acc, password: result.appPassword).currentUser() {
                    acc.userId = me.id
                    acc.displayName = me.displayName
                }
                CredentialStore.save(acc, password: result.appPassword)
                activate(acc, password: result.appPassword)
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                guard !Task.isCancelled else { return }
                loginState = .loggedOut
                loginError = "Sign in failed: \(error.localizedDescription)"
            }
        }
    }

    func cancelLogin() {
        loginTask?.cancel()
        loginState = .loggedOut
    }

    private func activate(_ acc: Account, password: String) {
        let api = NotesAPI(account: acc, password: password)
        self.api = api
        account = acc
        loginState = .loggedIn
        startTimer()
        Task {
            // Refresh name and server title in the background.
            if let me = try? await api.currentUser(), self.api === api {
                account?.displayName = me.displayName
                if let a = account { CredentialStore.save(a, password: password) }
            }
            let name = await api.serverName()
            if self.api === api { serverName = name }
        }
        if syncMode == .automatic || notes.isEmpty { Task { await sync() } }
    }

    func logout() {
        let old = api
        Task { try? await old?.revoke() }
        CredentialStore.delete()
        timerTask?.cancel()
        api = nil
        account = nil
        notes = []
        selectedId = nil
        saveNow()
        images.clear()
        loginState = .loggedOut
    }

    private func signedOutByServer() {
        logout()
        loginError = APIError.unauthorized.errorDescription
    }

    private static func normalize(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }
}

/// Tiny authorized image cache (profile photo).
@MainActor
final class ImageCache {
    private var images: [URL: NSImage] = [:]

    func image(_ url: URL, api: NotesAPI) async -> NSImage? {
        if let img = images[url] { return img }
        guard let data = try? await api.fetch(url), let img = NSImage(data: data) else { return nil }
        images[url] = img
        return img
    }

    func clear() { images.removeAll() }
}
