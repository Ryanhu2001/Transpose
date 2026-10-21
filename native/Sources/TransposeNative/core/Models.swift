import Foundation
import AppKit

enum TranslationProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case apple, deepseek, openrouter, customAPI, codex, dsh, claude, kimi
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apple: return L10n.text("Apple 翻译")
        case .deepseek: return "DeepSeek"
        case .openrouter: return "OpenRouter"
        case .customAPI: return L10n.text("自定义 API")
        case .codex: return "Codex CLI"
        case .dsh: return "DeepSeek CLI"
        case .claude: return "Claude Code"
        case .kimi: return "Kimi Code"
        }
    }
    var isAPI: Bool { [.deepseek, .openrouter, .customAPI].contains(self) }
    var isCLI: Bool { cliName != nil }
    var defaultBaseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .customAPI: return "http://localhost:11434/v1"
        default: return ""
        }
    }
    var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-flash"
        case .openrouter: return "openrouter/free"
        case .codex: return "gpt-6-luna"
        default: return ""
        }
    }
    var cliName: String? {
        switch self {
        case .codex: return "codex"
        case .dsh: return "dsh"
        case .claude: return "claude"
        case .kimi: return "kimi"
        default: return nil
        }
    }
}

enum TargetLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case smart, simplifiedChinese, english, japanese
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smart: return L10n.text("智能中英互译")
        case .simplifiedChinese: return L10n.text("简体中文")
        case .english: return "English"
        case .japanese: return L10n.text("日本語")
        }
    }
    func resolved(for text: String) -> String {
        guard self == .smart else {
            switch self {
            case .simplifiedChinese: return "Simplified Chinese"
            case .english: return "English"
            case .japanese: return "Japanese"
            default: return "Simplified Chinese"
            }
        }
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let han = letters.filter { (0x3400...0x9FFF).contains(Int($0.value)) }.count
        return !letters.isEmpty && Double(han) / Double(letters.count) > 0.45 ? "English" : "Simplified Chinese"
    }
}

struct TranslationOptions: Sendable {
    let provider: TranslationProvider
    let targetLanguage: String
    let baseURL: String
    let model: String
    let apiKey: String
    let cliPath: String
    let preferences: String
    let glossary: [GlossaryEntry]

    init(provider: TranslationProvider, targetLanguage: String, baseURL: String = "", model: String = "", apiKey: String = "", cliPath: String = "", preferences: String = "", glossary: [GlossaryEntry] = []) {
        self.provider = provider
        self.targetLanguage = targetLanguage
        self.baseURL = baseURL.isEmpty ? provider.defaultBaseURL : baseURL
        self.model = model.isEmpty ? provider.defaultModel : model
        self.apiKey = apiKey
        self.cliPath = cliPath
        self.preferences = preferences
        self.glossary = glossary
    }
}

struct GlossaryEntry: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var source: String
    var translation: String
    var note: String
    var enabled: Bool
    init(id: UUID = UUID(), source: String, translation: String, note: String = "", enabled: Bool = true) {
        self.id = id
        self.source = source
        self.translation = translation
        self.note = note
        self.enabled = enabled
    }
}

struct DetectedCLI: Identifiable, Sendable {
    let provider: TranslationProvider
    let path: String
    var id: String { provider.rawValue }
}

struct SelectedContent {
    let text: String
    let anchor: NSPoint
    let sourceApp: String
}

struct TranslationStats: Sendable {
    let elapsed: TimeInterval
    let firstToken: TimeInterval?
    let cached: Bool
    let provider: String
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return L10n.text(value) }
    }
}
