import Foundation

/// Argument-domain overrides are process-local. These checks never read or
/// write the user's saved language preference.
func runLocalizationChecks() throws -> Int {
    func select(_ language: String) {
        UserDefaults.standard.setVolatileDomain(["appLanguage": language], forName: UserDefaults.argumentDomain)
    }
    func require(_ condition: @autoclosure () -> Bool, _ reason: String) throws -> Int {
        guard condition() else { throw AppError.message("本地化验证失败：\(reason)") }
        return 1
    }
    defer { select("simplifiedChinese") }
    var checks = 0
    select("simplifiedChinese")
    checks += try require(!L10n.isEnglish && L10n.locale.identifier == "zh-Hans", "中文界面 Locale")
    checks += try require(TranslationProvider.apple.title == "Apple 翻译" && TranslationProvider.customAPI.title == "自定义 API", "中文服务名")
    checks += try require(L10n.languageName(code: "en") == "英语" && L10n.languageName(code: "zh-Hant") == "繁体中文", "中文语言名称")
    checks += try require(L10n.languageName(code: "自动检测") == "自动检测", "中文动态状态")
    select("english")
    checks += try require(L10n.isEnglish && L10n.locale.identifier == "en", "英文界面 Locale")
    checks += try require(TranslationProvider.apple.title == "Apple Translate" && TranslationProvider.customAPI.title == "Custom API", "英文服务名")
    checks += try require(TargetLanguage.smart.title == "Auto: Chinese ↔ English", "英文目标语言菜单")
    checks += try require(L10n.languageName(code: "zh-Hans") == "Simplified Chinese" && L10n.languageName(code: "Japanese") == "Japanese", "英文动态语言名称")
    checks += try require(L10n.languageName(code: "识别中") == "Detecting" && L10n.languageName(code: "译文") == "Translation", "英文动态状态")
    checks += try require(L10n.languageName(code: "fr") == "French", "系统语言名称")
    checks += try require(L10n.format("已检测到 %d 个 CLI", 3) == "3 CLIs Detected", "数字占位符")
    checks += try require(L10n.format("最近请求的语言：%@ → %@", "English", "Japanese") == "Last requested languages: English → Japanese", "多字符串占位符")
    checks += try require(L10n.text("用户输入的内容保持原样") == "用户输入的内容保持原样" && L10n.text("Unrecognized key") == "Unrecognized key", "未知内容保留")
    checks += try require(AppError.message("翻译服务暂时不可用（HTTP 503）。").localizedDescription == "The translation service is unavailable (HTTP 503).", "动态 API 错误")
    checks += try require(L10n.text("Codex CLI 尚未登录或认证已失效，请在终端中登录后重试。") == "Codex CLI is not signed in or authentication expired. Sign in through Terminal and try again.", "动态 CLI 错误")
    checks += try require(L10n.text("Apple 翻译 · 0.1 秒") == "Apple Translate · 0.1 s", "现有译文的服务名与耗时")
    checks += try require(L10n.text("Apple 翻译 · 已缓存") == "Apple Translate · Cached", "现有译文的缓存状态")
    checks += try require(L10n.text("已导入 8 条术语") == "Imported 8 terms", "动态词库状态")
    checks += try require(L10n.text("连接成功 · 0.3 秒\n翻译偏好") == "Connected · 0.3 s\n翻译偏好", "连接状态不得改写实际译文")
    return checks
}
