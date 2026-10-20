import Foundation
import SwiftUI

struct Account: Codable {
    let server: URL
    let loginName: String
    var userId: String
    var displayName: String

    /// "Baki's Notes"
    var notebookTitle: String {
        let first = displayName.split(separator: " ").first.map(String.init) ?? displayName
        return first.isEmpty ? "Notes" : "\(first)'s Notes"
    }
}

/// Account + revocable app password in a private file (no Keychain: the app is ad-hoc signed
/// and every update would make macOS ask for Keychain access again and block the launch).
enum CredentialStore {
    struct Saved: Codable {
        let account: Account
        let appPassword: String
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("work.baki.notes007", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }

    private static var fileURL: URL { directory.appendingPathComponent("account.json") }

    static func load() -> Saved? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    static func save(_ account: Account, password: String) {
        guard let data = try? JSONEncoder().encode(Saved(account: account, appPassword: password)) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func delete() { try? FileManager.default.removeItem(at: fileURL) }
}

/// A note as the Nextcloud Notes API sends it.
struct ServerNote: Codable {
    let id: Int
    let etag: String?
    let readonly: Bool?
    let modified: Int?
    let title: String?
    let category: String?
    let content: String?
    let favorite: Bool?
}

/// A note as kept on this Mac. The Mac copy is the source of truth; the server is updated from it.
struct LocalNote: Codable, Identifiable, Equatable {
    var id: UUID = UUID()           // never changes, so selection survives syncing
    var serverId: Int?
    var etag: String?
    var title: String = ""
    var content: String = ""
    var category: String = ""
    var favorite = false
    var readonly = false
    var modified: Int = Int(Date().timeIntervalSince1970)

    var dirty = false               // has changes the server doesn't have yet
    var deleted = false             // deleted here, waiting to be deleted on the server
    var revision = 0                // bumps on every local change
    var lastSynced: Int?
    var error: String?

    var displayTitle: String { title.isEmpty ? "New note" : title }
    var needsUpload: Bool { dirty || deleted }

    var preview: String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let rest = lines.drop { Self.cleanTitle($0) == title }.first ?? ""
        return Self.stripMarkers(rest)
    }

    init() {}

    init(server s: ServerNote) {
        serverId = s.id
        etag = s.etag
        title = s.title ?? ""
        content = s.content ?? ""
        category = s.category ?? ""
        favorite = s.favorite ?? false
        readonly = s.readonly ?? false
        modified = s.modified ?? modified
        lastSynced = Int(Date().timeIntervalSince1970)
    }

    mutating func apply(server s: ServerNote) {
        serverId = s.id
        etag = s.etag
        title = s.title ?? title
        content = s.content ?? content
        category = s.category ?? ""
        favorite = s.favorite ?? false
        readonly = s.readonly ?? false
        modified = s.modified ?? modified
        lastSynced = Int(Date().timeIntervalSince1970)
        error = nil
    }

    /// Title = first non-empty line without Markdown markers (like the Nextcloud Notes web app).
    static func title(from content: String) -> String {
        let first = content.split(separator: "\n").map(String.init).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return String(cleanTitle(first).prefix(100))
    }

    static func cleanTitle(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix("#") { s.removeFirst() }
        return stripMarkers(s).trimmingCharacters(in: .whitespaces)
    }

    static func stripMarkers(_ s: String) -> String {
        var t = s
        for m in ["~~", "**", "__", "<u>", "</u>", "`"] { t = t.replacingOccurrences(of: m, with: "") }
        if let r = t.range(of: #"^\s*[-*+]\s+\[[ xX]\]\s+"#, options: .regularExpression) { t.removeSubrange(r) }
        if let r = t.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) { t.removeSubrange(r) }
        return t.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespaces)
    }
}

enum SyncMode: String, CaseIterable, Identifiable {
    case automatic, manual
    var id: String { rawValue }
    var label: String { self == .automatic ? "Automatic" : "Manual" }
}

/// What the little ticks show for a note.
enum NoteStatus: Equatable {
    case synced(Int?)     // ✓✓
    case pending          // ✓  saved on this Mac
    case syncing
    case failed(String)   // ⚠︎
}

// MARK: - Look & formatting

enum Theme {
    static let body = Font.system(size: 15)
    static let name = Font.system(size: 14, weight: .semibold)
    static let preview = Font.system(size: 13)
    static let caption = Font.system(size: 12)
    static let small = Font.system(size: 11)
    static let title = Font.system(size: 16, weight: .semibold)
    static let syncedBlue = Color(red: 0.33, green: 0.68, blue: 1.0)
}

enum Fmt {
    private static let timeF: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()
    private static let shortDateF: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none; return f
    }()
    private static let fullF: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    static func date(_ ts: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(ts)) }

    static func relative(_ ts: Int) -> String {
        let d = date(ts)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return timeF.string(from: d) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return shortDateF.string(from: d)
    }

    static func time(_ ts: Int) -> String {
        let d = date(ts)
        return Calendar.current.isDateInToday(d) ? timeF.string(from: d) : fullF.string(from: d)
    }
}
