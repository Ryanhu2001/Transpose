import Foundation
import CoreFoundation

/// The bridge accepts only the small, explicit JSON shape shared with TypeScript.
/// API credentials deliberately have no place in an outbound state model.
struct NativeBridgeRequest {
    static let actions: Set<String> = ["snapshot", "update_settings", "provider_select", "set_language", "key_save", "key_remove",
                                       "connection_test", "cli_scan", "glossary_upsert", "glossary_delete", "glossary_import", "glossary_export",
                                       "permission", "login_set", "login_settings", "apple_prepare", "translate", "capture", "result_close",
                                       "result_pin", "result_retry", "result_copy", "open_settings", "open_external", "app_quit", "app_restart"]
    static let resultActions: Set<String> = ["snapshot", "result_close", "result_pin", "result_retry", "result_copy", "open_settings"]

    static func allows(_ action: String, fromResult: Bool) -> Bool {
        (fromResult ? resultActions : actions).contains(action)
    }
    let id: String
    let action: String
    let payload: [String: Any]

    init(_ value: [String: Any]) throws {
        guard let id = value["id"] as? String, !id.isEmpty, id.utf8.count <= 160,
              let action = value["action"] as? String, !action.isEmpty, action.utf8.count <= 80,
              let payload = value["payload"] as? [String: Any] else {
            throw AppError.message("请求格式有误。")
        }
        self.id = id
        self.action = action
        self.payload = payload
    }

    static func decode(_ text: String) throws -> NativeBridgeRequest {
        guard text.utf8.count <= 1_000_000,
              let data = text.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.message("请求格式有误。")
        }
        return try NativeBridgeRequest(value)
    }

    func string(_ key: String, maximum: Int = 16_000, required: Bool = true) throws -> String? {
        guard let value = payload[key] else {
            if required { throw AppError.message("请求缺少必要字段。") }
            return nil
        }
        guard let text = value as? String, text.count <= maximum, !text.contains("\0") else {
            throw AppError.message("输入内容格式有误或过长。")
        }
        return text
    }

    func boolean(_ key: String, required: Bool = true) throws -> Bool? {
        guard let value = payload[key] else {
            if required { throw AppError.message("请求缺少必要字段。") }
            return nil
        }
        // NSNumber's conditional Bool cast also accepts 0/1; reject numbers so
        // a malformed request cannot silently change a system preference.
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw AppError.message("请求中的开关状态有误。")
        }
        return number.boolValue
    }

    func validateConnectionPatch(currentProvider: String) throws {
        guard ["baseURL", "model", "cliPath"].contains(where: { payload[$0] != nil }) else { return }
        guard try string("expectedProvider", maximum: 40) == currentProvider else {
            throw AppError.message("连接已切换，请重试。")
        }
    }

    func validateCredentialContext(currentProvider: String, currentBaseURL: String) throws {
        guard try string("provider", maximum: 40) == currentProvider,
              try string("baseURL", maximum: 2_048) == currentBaseURL else {
            throw AppError.message("连接已切换，请重试。")
        }
    }
}

struct NativeBridgePublicSettings {
    let provider: String
    let target: String
    let automaticSelection: Bool
    let preferences: String
    let baseURL: String
    let model: String
    let cliPath: String
    let keyIsSaved: Bool

    var dictionary: [String: Any] {
        ["provider": provider, "target": target, "automaticSelection": automaticSelection,
         "preferences": preferences, "baseURL": baseURL, "model": model, "cliPath": cliPath, "keyIsSaved": keyIsSaved]
    }
}

struct NativeResultState {
    var id = UUID()
    var source = ""
    var sourceApp = ""
    var sourceLanguage = "自动检测"
    var targetLanguage = "译文"
    var output = ""
    var isLoading = false
    var loadingMessage = "正在翻译…"
    var error: String?
    var status = ""
    var provider = ""
    var isPinned = false
    var canRetry = false

    var dictionary: [String: Any] {
        ["id": id.uuidString,
         "source": source,
         "sourceApp": L10n.text(sourceApp),
         "sourceLanguage": L10n.languageName(code: sourceLanguage),
         "targetLanguage": L10n.languageName(code: targetLanguage),
         "output": output,
         "isLoading": isLoading,
         "loadingMessage": L10n.text(loadingMessage),
         "error": error.map(L10n.text) as Any? ?? NSNull(),
         "status": L10n.text(status),
         "provider": L10n.text(provider),
         "isPinned": isPinned,
         "canRetry": canRetry]
    }
}
