import Foundation
import Security
import CryptoKit
import LocalAuthentication

/// Credentials belong to this app and the specific endpoint selected by its user.
/// No credential is imported automatically from a shell, another app, or a file.
enum KeychainStore {
    static let service = "dev.ryan.TranslateAnywhere.api"
    private static let accessLock = NSLock()
    private static var refreshedAccounts = Set<String>()

    static func get(provider: TranslationProvider, baseURL: String) -> String? {
        accessLock.lock()
        defer { accessLock.unlock() }
        _ = withoutInteraction { refreshLegacyLabel(provider: provider, baseURL: baseURL) }
        var query = itemQuery(provider: provider, baseURL: baseURL)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        // A normal, user-authorized read may make a previously denied metadata
        // update possible. Its failure never prevents use of the credential.
        _ = withoutInteraction { refreshLegacyLabel(provider: provider, baseURL: baseURL) }
        return key
    }

    static func contains(provider: TranslationProvider, baseURL: String) -> Bool {
        accessLock.lock()
        defer { accessLock.unlock() }
        return withoutInteraction {
            refreshLegacyLabel(provider: provider, baseURL: baseURL)
            var query = nonInteractiveItemQuery(provider: provider, baseURL: baseURL)
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var attributes: CFTypeRef?
            return SecItemCopyMatching(query as CFDictionary, &attributes) == errSecSuccess
        } ?? false
    }

    /// Called only by the explicit Save action in settings.
    static func set(_ key: String, provider: TranslationProvider, baseURL: String) throws {
        accessLock.lock()
        defer { accessLock.unlock() }
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 16_384,
              !clean.contains("\n"), !clean.contains("\r") else {
            throw KeychainError.message("请输入有效的 API Key。")
        }
        let query = itemQuery(provider: provider, baseURL: baseURL)
        let attributes = credentialAttributes(clean, provider: provider)
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess {
            refreshedAccounts.insert(account(provider: provider, baseURL: baseURL))
            return
        }
        guard update == errSecItemNotFound else { throw KeychainError.status(update) }
        var newItem = query
        newItem.merge(attributes) { _, value in value }
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(newItem as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainError.status(add) }
        refreshedAccounts.insert(account(provider: provider, baseURL: baseURL))
    }

    static func delete(provider: TranslationProvider, baseURL: String) throws {
        accessLock.lock()
        defer { accessLock.unlock() }
        let result = SecItemDelete(itemQuery(provider: provider, baseURL: baseURL) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw KeychainError.status(result)
        }
        refreshedAccounts.remove(account(provider: provider, baseURL: baseURL))
    }

    // Pure attribute builders are shared by add/update and offline verification.
    static func labelAttributes(provider: TranslationProvider) -> [String: Any] {
        [kSecAttrLabel as String: "Transpose · \(provider.title)"]
    }

    static func credentialAttributes(_ key: String, provider: TranslationProvider) -> [String: Any] {
        var attributes = labelAttributes(provider: provider)
        attributes[kSecValueData as String] = Data(key.utf8)
        return attributes
    }

    static func isLegacyLabel(_ label: String) -> Bool {
        ["Vela", "Translate Anywhere", "TranslateAnywhere"].contains {
            label == $0 || label.hasPrefix($0 + " · ")
        }
    }

    static func nonInteractiveItemQuery(provider: TranslationProvider, baseURL: String) -> [String: Any] {
        var query = itemQuery(provider: provider, baseURL: baseURL)
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    /// Caller holds accessLock and has disabled interaction. Only metadata is
    /// requested, and only a known old brand label on this connection is changed.
    private static func refreshLegacyLabel(provider: TranslationProvider, baseURL: String) {
        let identifier = account(provider: provider, baseURL: baseURL)
        guard !refreshedAccounts.contains(identifier) else { return }
        var query = nonInteractiveItemQuery(provider: provider, baseURL: baseURL)
        var inspection = query
        inspection[kSecReturnAttributes as String] = true
        inspection[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(inspection as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any],
              let oldLabel = attributes[kSecAttrLabel as String] as? String else { return }
        let changes = labelAttributes(provider: provider)
        if oldLabel == changes[kSecAttrLabel as String] as? String {
            refreshedAccounts.insert(identifier)
            return
        }
        guard isLegacyLabel(oldLabel) else { return }
        query[kSecAttrLabel as String] = oldLabel
        if SecItemUpdate(query as CFDictionary, changes as CFDictionary) == errSecSuccess {
            refreshedAccounts.insert(identifier)
        }
    }

    /// LAContext covers Data Protection items. The legacy switch also suppresses
    /// login-keychain UI; it is process-local and restored before normal reads.
    /// All app Keychain operations use accessLock, and this scope never suspends.
    private static func withoutInteraction<T>(_ action: () -> T) -> T? {
        var allowed: DarwinBoolean = false
        guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess else { return nil }
        defer { _ = SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return nil }
        return action()
    }

    // Internal so the isolated verification harness can check routing without
    // accessing the user's Keychain.
    static func account(provider: TranslationProvider, baseURL: String) -> String {
        let enteredURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = normalizedEndpoint(enteredURL.isEmpty ? provider.defaultBaseURL : enteredURL)
        let digest = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
        return provider.rawValue + ":" + digest
    }

    static func normalizedEndpoint(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), let host = components.host else { return trimmed }
        components.scheme = components.scheme?.lowercased()
        components.host = host.lowercased()
        components.user = nil
        components.password = nil
        components.fragment = nil
        if (components.scheme == "https" && components.port == 443) ||
            (components.scheme == "http" && components.port == 80) { components.port = nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        if let items = components.queryItems {
            components.queryItems = items.sorted {
                $0.name == $1.name ? ($0.value ?? "") < ($1.value ?? "") : $0.name < $1.name
            }
        }
        return components.string ?? trimmed
    }

    private static func itemQuery(provider: TranslationProvider, baseURL: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account(provider: provider, baseURL: baseURL),
         kSecAttrSynchronizable as String: false]
    }

    private enum KeychainError: LocalizedError {
        case status(OSStatus), message(String)
        var errorDescription: String? {
            switch self {
            case .message(let message): return message
            case .status(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "状态 \(status)"
                return "钥匙串操作失败：\(detail)"
            }
        }
    }
}
