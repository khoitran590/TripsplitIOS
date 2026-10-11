import Foundation
import Security

/// Invitation links grant access, so interrupted joins keep the link in the
/// device-only Keychain rather than preferences. Never stores profile links.
struct PendingInvitationStore {
    var service = "com.tripsplit.pending-invitation"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "link"]
    }

    static func accepts(_ url: URL) -> Bool {
        let custom = url.scheme?.lowercased() == "tripsplit" && url.host?.lowercased() == "invite"
        let universal = url.scheme?.lowercased() == "https" && url.path == "/invite"
        guard custom || universal,
              let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "token" })?.value
        else { return false }
        return token.range(of: "^[a-f0-9]{36,64}$", options: .regularExpression) != nil
    }

    func load() -> URL? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8),
              let url = URL(string: value), Self.accepts(url) else { return nil }
        return url
    }

    @discardableResult func save(_ url: URL) -> Bool {
        guard Self.accepts(url) else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(url.absoluteString.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return result == errSecSuccess
    }

    @discardableResult func delete() -> Bool {
        let result = SecItemDelete(query as CFDictionary)
        return result == errSecSuccess || result == errSecItemNotFound
    }
}
