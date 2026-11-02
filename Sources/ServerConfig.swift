import Foundation
import Security

/// Small, dependency-free persistence layer.
/// The server URL lives in UserDefaults, the password and the optional Zen key live in Keychain.
final class ServerConfig {
    static let shared = ServerConfig()

    private let defaults = UserDefaults.standard
    private let urlKey = "ocm.server.url"
    private let userKey = "ocm.server.user"

    private init() {}

    var serverURL: String {
        get { defaults.string(forKey: urlKey) ?? "" }
        set { defaults.set(newValue, forKey: urlKey) }
    }

    var username: String {
        get {
            let v = defaults.string(forKey: userKey) ?? ""
            return v.isEmpty ? "opencode" : v
        }
        set { defaults.set(newValue, forKey: userKey) }
    }

    var password: String {
        get { Keychain.get("ocm.server.password") ?? "" }
        set { Keychain.set("ocm.server.password", newValue) }
    }

    var zenKey: String {
        get { Keychain.get("ocm.zen.key") ?? "" }
        set { Keychain.set("ocm.zen.key", newValue) }
    }

    var zenAccess: String {
        get { Keychain.get("ocm.zen.access") ?? "" }
        set { Keychain.set("ocm.zen.access", newValue) }
    }

    var zenRefresh: String {
        get { Keychain.get("ocm.zen.refresh") ?? "" }
        set { Keychain.set("ocm.zen.refresh", newValue) }
    }

    var zenExpiry: Double {
        get { defaults.double(forKey: "ocm.zen.expiry") }
        set { defaults.set(newValue, forKey: "ocm.zen.expiry") }
    }

    var zenEmail: String {
        get { defaults.string(forKey: "ocm.zen.email") ?? "" }
        set { defaults.set(newValue, forKey: "ocm.zen.email") }
    }

    var zenOrgID: String {
        get { defaults.string(forKey: "ocm.zen.org") ?? "" }
        set { defaults.set(newValue, forKey: "ocm.zen.org") }
    }

    var zenModel: String {
        get { defaults.string(forKey: "ocm.zen.model") ?? "" }
        set { defaults.set(newValue, forKey: "ocm.zen.model") }
    }

    /// Last Console gateway that accepted the current credential. Empty means auto.
    var zenBase: String {
        get { defaults.string(forKey: "ocm.zen.base") ?? "" }
        set { defaults.set(newValue, forKey: "ocm.zen.base") }
    }

    var hasServer: Bool { !serverURL.isEmpty }

    /// Accepts `host`, `host:4096`, `http://host:4096`, `https://host/prefix`.
    /// Returns a URL string without a trailing slash, or nil.
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            s = "http://" + s
        }
        guard var c = URLComponents(string: s), let host = c.host, !host.isEmpty else { return nil }
        if c.scheme == "http" && c.port == nil {
            c.port = 4096
        }
        c.fragment = nil
        guard var out = c.url?.absoluteString else { return nil }
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// URL for an opencode API path such as `/global/health`.
    func apiURL(_ path: String) -> URL? {
        guard !serverURL.isEmpty else { return nil }
        let p = path.hasPrefix("/") ? path : "/" + path
        return URL(string: serverURL + p)
    }

    var basicAuth: String? {
        let p = password
        guard !p.isEmpty else { return nil }
        let pair = "\(username):\(p)"
        return "Basic " + Data(pair.utf8).base64EncodedString()
    }
}

enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.opencodemob.ios",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
    }

    static func get(_ key: String) -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query(key) as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.opencodemob.ios",
            kSecAttrAccount as String: key
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}