import Foundation

enum APIError: LocalizedError {
    case unauthorized
    case notFound
    case conflict
    case locked
    case http(Int)
    case invalidResponse
    case offline

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Session expired. Please sign in again."
        case .notFound: return "Not found on the server."
        case .conflict: return "Changed on another device."
        case .locked: return "Locked on the server (open on another device?)"
        case .http(let code): return "Server error (\(code))."
        case .invalidResponse: return "Unexpected server response."
        case .offline: return "No connection to the server."
        }
    }
}

let userAgent = "007 Notes (macOS)"

/// Nextcloud Notes API v1 (index.php/apps/notes/api/v1) plus the bits of core we need.
final class NotesAPI {
    let account: Account
    private let password: String
    private let session: URLSession

    init(account: Account, password: String) {
        self.account = account
        self.password = password
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    var authorizationHeader: String {
        "Basic " + Data("\(account.loginName):\(password)".utf8).base64EncodedString()
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil,
                         headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var r = URLRequest(url: account.server.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: r)
        } catch let e as URLError where e.code != .cancelled {
            throw APIError.offline
        }
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return (data, http)
        case 401: throw APIError.unauthorized
        case 404: throw APIError.notFound
        case 412: throw APIError.conflict
        case 423: throw APIError.locked
        default: throw APIError.http(http.statusCode)
        }
    }

    private static let notes = "index.php/apps/notes/api/v1/notes"

    private func body(_ n: LocalNote) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "title": n.title.isEmpty ? LocalNote.title(from: n.content) : n.title,
            "content": n.content,
            "category": n.category,
            "favorite": n.favorite,
            "modified": n.modified,
        ] as [String: Any])
    }

    func list() async throws -> [ServerNote] {
        let (data, _) = try await request(Self.notes)
        return try JSONDecoder().decode([ServerNote].self, from: data)
    }

    func get(_ id: Int) async throws -> ServerNote {
        let (data, _) = try await request("\(Self.notes)/\(id)")
        return try JSONDecoder().decode(ServerNote.self, from: data)
    }

    func create(_ n: LocalNote) async throws -> ServerNote {
        let (data, _) = try await request(Self.notes, method: "POST", body: try body(n))
        return try JSONDecoder().decode(ServerNote.self, from: data)
    }

    /// With an etag the server refuses (412) if the note changed elsewhere since we last saw it.
    func update(_ id: Int, _ n: LocalNote, etag: String?) async throws -> ServerNote {
        var headers: [String: String] = [:]
        if let etag { headers["If-Match"] = "\"\(etag)\"" }
        let (data, _) = try await request("\(Self.notes)/\(id)", method: "PUT", body: try body(n), headers: headers)
        return try JSONDecoder().decode(ServerNote.self, from: data)
    }

    func delete(_ id: Int) async throws {
        do {
            _ = try await request("\(Self.notes)/\(id)", method: "DELETE")
        } catch APIError.notFound {
            // already gone
        }
    }

    // MARK: Core

    func currentUser() async throws -> (id: String, displayName: String) {
        struct Wrap: Decodable {
            struct OCS: Decodable { let data: User }
            struct User: Decodable { let id: String; let displayname: String? }
            let ocs: OCS
        }
        let (data, _) = try await request("ocs/v2.php/cloud/user")
        let u = try JSONDecoder().decode(Wrap.self, from: data).ocs.data
        return (u.id, u.displayname ?? u.id)
    }

    func serverName() async -> String {
        guard let response = try? await request("ocs/v2.php/cloud/capabilities"),
              let json = try? JSONSerialization.jsonObject(with: response.0) as? [String: Any],
              let caps = ((json["ocs"] as? [String: Any])?["data"] as? [String: Any])?["capabilities"] as? [String: Any],
              let name = (caps["theming"] as? [String: Any])?["name"] as? String, !name.isEmpty
        else { return "Nextcloud" }
        return name
    }

    func avatarURL(size: Int = 128) -> URL? {
        guard let id = account.userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: account.server.absoluteString + "/index.php/avatar/\(id)/\(size)")
    }

    func fetch(_ url: URL) async throws -> Data {
        var r = URLRequest(url: url)
        r.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.invalidResponse }
        return data
    }

    func revoke() async throws {
        _ = try await request("ocs/v2.php/core/apppassword", method: "DELETE")
    }
}

/// Nextcloud Login Flow v2: approve in the browser, receive an app password.
enum LoginFlow {
    struct Start: Decodable {
        struct Poll: Decodable { let token: String; let endpoint: String }
        let poll: Poll
        let login: String
    }

    struct Result: Decodable {
        let server: String
        let loginName: String
        let appPassword: String
    }

    static func start(server: URL) async throws -> Start {
        var r = URLRequest(url: server.appendingPathComponent("index.php/login/v2"))
        r.httpMethod = "POST"
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(Start.self, from: data)
    }

    static func poll(_ start: Start) async throws -> Result {
        guard let url = URL(string: start.poll.endpoint) else { throw APIError.invalidResponse }
        let deadline = Date().addingTimeInterval(20 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            var r = URLRequest(url: url)
            r.httpMethod = "POST"
            r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data("token=\(start.poll.token)".utf8)
            if let response = try? await URLSession.shared.data(for: r),
               (response.1 as? HTTPURLResponse)?.statusCode == 200,
               let result = try? JSONDecoder().decode(Result.self, from: response.0) {
                return result
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw APIError.http(408)
    }
}
