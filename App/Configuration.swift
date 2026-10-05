import Foundation
import Security

struct DeliveryConfiguration: Codable {
    let endpoint: URL
    let token: String

    init(endpoint: String, token: String) throws {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw ConfigurationError.invalidEndpoint
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConfigurationError.invalidToken("The token field is empty.") }
        guard trimmed.count <= 512 else { throw ConfigurationError.invalidToken("The token is longer than 512 characters.") }
        if let bad = trimmed.unicodeScalars.first(where: { $0.value < 33 || $0.value > 126 }) {
            throw ConfigurationError.invalidToken(
                "It contains an unsupported character at position \(trimmed.unicodeScalars.distance(from: trimmed.unicodeScalars.startIndex, to: trimmed.unicodeScalars.firstIndex(of: bad)!) + 1): U+\(String(bad.value, radix: 16, uppercase: true)).")
        }
        self.endpoint = url
        self.token = trimmed
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(endpoint: values.decode(URL.self, forKey: .endpoint).absoluteString,
                      token: values.decode(String.self, forKey: .token))
    }
}

extension DeliveryConfiguration {
    static let enrollScheme = "cochlea"

    /// `offlineshazam://enroll?url=<capture URL>&token=<token>`, opened from Music
    /// Sync's enrollment page. nil for any other link; throws on unusable values.
    static func fromEnrollLink(_ link: URL) throws -> DeliveryConfiguration? {
        guard [enrollScheme, "offlineshazam"].contains(link.scheme?.lowercased() ?? ""), link.host?.lowercased() == "enroll" else { return nil }
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value ?? "" }
        return try DeliveryConfiguration(endpoint: value("url"), token: value("token"))
    }
}

enum ConfigurationError: LocalizedError {
    case invalidEndpoint, invalidToken(String), keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Enter the HTTPS capture URL from Music Sync, without login details or query parameters."
        case .invalidToken(let reason): return "Enter a valid capture access token from Music Sync. " + reason
        case .keychain: return "Could not access the saved connection. Unlock the phone and try again."
        }
    }
}

struct CapturePayload {
    let id: UUID
    let metadata: MatchMetadata
    func data() throws -> Data {
        var fields = [
            "capture_id": id.uuidString.lowercased(),
            "title": metadata.title,
            "artist": metadata.artist,
            "apple_music_id": metadata.appleMusicID ?? "",
            "shazam_url": metadata.shazamURL ?? ""
        ]
        if let isrc = metadata.isrc { fields["isrc"] = isrc }
        return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }
}

struct ConnectionStore {
    var service = (Bundle.main.bundleIdentifier ?? "cochlea") + ".connection"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "capture"]
    }

    func load() throws -> DeliveryConfiguration? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else {
            throw ConfigurationError.keychain(status)
        }
        return try JSONDecoder().decode(DeliveryConfiguration.self, from: data)
    }

    func save(_ configuration: DeliveryConfiguration) throws {
        var values: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(configuration)]
        #if os(iOS)
        values[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ConfigurationError.keychain(status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ConfigurationError.keychain(status) }
    }
}

// The capture endpoint authenticates before validating payloads. An empty object
// exercises that boundary without resolving or adding a Spotify track.
final class ConnectionVerifier: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let acceptedMessage = "capture requires capture_id, title, artist, apple_music_id and shazam_url; isrc is optional"

    func verify(_ connection: DeliveryConfiguration,
                sessionConfiguration: URLSessionConfiguration = .ephemeral) async throws {
        let session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: connection.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError {
            if [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(error.code) {
                throw ConnectionCheckError.offline
            }
            throw ConnectionCheckError.unavailable
        }
        guard let response = response as? HTTPURLResponse else { throw ConnectionCheckError.wrongEndpoint }
        if response.statusCode == 401 || response.statusCode == 403 { throw ConnectionCheckError.rejected }
        if response.statusCode >= 500 || response.statusCode == 429 { throw ConnectionCheckError.unavailable }
        struct Rejection: Decodable { let ok: Bool; let message: String }
        guard response.statusCode == 422,
              let result = try? JSONDecoder().decode(Rejection.self, from: data),
              !result.ok, result.message == Self.acceptedMessage else { throw ConnectionCheckError.wrongEndpoint }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum ConnectionCheckError: LocalizedError {
    case rejected, offline, unavailable, wrongEndpoint
    var errorDescription: String? {
        switch self {
        case .rejected: return "Music Sync rejected this access token. Check the Capture URL and token in Settings."
        case .offline: return "Waiting for internet. Your saved songs will retry automatically."
        case .unavailable: return "Music Sync is temporarily unavailable. Your saved songs will retry automatically."
        case .wrongEndpoint: return "This URL did not respond as a Music Sync capture endpoint. Check the Capture URL in Settings."
        }
    }
}
