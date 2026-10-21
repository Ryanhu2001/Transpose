import Foundation
import Combine

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, simplifiedChinese, english

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L10n.text("跟随系统")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}

/// UI language is independent of the language selected for translation.
/// Synchronous lookups also work from nonisolated error and model types.
@MainActor
final class L10n: ObservableObject {
    static let shared = L10n()
    nonisolated static let didChangeNotification = Notification.Name("Transpose.AppLanguageDidChange")

    @Published var selection: AppLanguage {
        didSet {
            guard selection != oldValue else { return }
            if Self.previewLanguage == nil {
                UserDefaults.standard.set(selection.rawValue, forKey: "appLanguage")
            }
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    private init() {
        selection = Self.previewLanguage ?? AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .system
    }

    nonisolated static var isEnglish: Bool {
        switch previewLanguage ?? AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .system {
        case .simplifiedChinese: return false
        case .english: return true
        case .system: return !(Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("zh")
        }
    }

    nonisolated static var locale: Locale { Locale(identifier: isEnglish ? "en" : "zh-Hans") }

    // Offscreen previews must never alter the user's UI-language preference.
    // Ignore this option during a normal app launch.
    nonisolated private static let previewLanguage: AppLanguage? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--render-previews"),
              let index = arguments.firstIndex(of: "--preview-language"),
              arguments.indices.contains(index + 1) else { return nil }
        switch arguments[index + 1] {
        case "en": return .english
        case "zh": return .simplifiedChinese
        default: return nil
        }
    }()

    nonisolated static func text(_ key: String) -> String {
        guard isEnglish else { return key }
        if let translated = english[key] { return translated }
        // Runtime error/status strings may already contain an interpolated value.
        // Only known, fully anchored message templates are matched.
        let range = NSRange(key.startIndex..<key.endIndex, in: key)
        for rule in dynamicRules {
            guard let match = rule.pattern.firstMatch(in: key, range: range) else { continue }
            var template = rule.translation
            if match.numberOfRanges > 1, let firstRange = Range(match.range(at: 1), in: key) {
                let first = String(key[firstRange])
                // Provider labels can outlive a language switch in an existing
                // result window. Translation output and error details stay intact.
                if ["Apple 翻译", "兼容 API", "自定义 API"].contains(first), let name = english[first] {
                    template = template.replacingOccurrences(of: "$1", with: NSRegularExpression.escapedTemplate(for: name))
                }
            }
            return rule.pattern.replacementString(for: match, in: key, offset: 0, template: template)
        }
        return key
    }

    nonisolated static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }

    nonisolated static func languageName(code: String) -> String {
        if ["自动检测", "识别中", "译文"].contains(code) { return text(code) }
        let normalized: String
        switch code.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "simplified chinese", "简体中文", "zh", "zh-cn", "zh-hans": normalized = "zh-Hans"
        case "traditional chinese", "繁体中文", "zh-tw", "zh-hk", "zh-hant": normalized = "zh-Hant"
        case "english", "英语", "en": normalized = "en"
        case "japanese", "日本語", "日语", "ja": normalized = "ja"
        default: normalized = code
        }
        switch normalized {
        case "zh-Hans": return text("简体中文")
        case "zh-Hant": return text("繁体中文")
        case "en": return text("英语")
        case "ja": return text("日语")
        default: return locale.localizedString(forIdentifier: normalized) ?? normalized
        }
    }

    nonisolated private static let english: [String: String] = [
        "屏幕录制权限尚未生效。请重新启动 Transpose 后继续圈选。": "Screen recording access is not available to this running app yet. Restart Transpose to continue selecting screen areas.",
        "圈选需要屏幕录制权限。请在系统设置中允许 Transpose，再重新启动应用。": "Screen translation needs screen recording access. Allow Transpose in System Settings, then restart the app.",
        "请求格式有误。": "The request format is invalid.",
        "请求缺少必要字段。": "The request is missing a required field.",
        "输入内容格式有误或过长。": "The input is invalid or too long.",
        "请求中的开关状态有误。": "The requested switch state is invalid.",
        "此操作不可用。": "This action is unavailable.",
        "目标语言无效。": "The target language is invalid.",
        "翻译服务无效。": "The translation service is invalid.",
        "界面语言无效。": "The app language is invalid.",
        "此服务无需 API Key。": "This service does not use an API key.",
        "术语标识无效。": "The glossary entry ID is invalid.",
        "词条格式有误。": "The glossary entry format is invalid.",
        "权限类型无效。": "The permission type is invalid.",
        "没有可重试的翻译。": "There is no translation to retry.",
        "暂无可复制的译文。": "There is no translation to copy yet.",
        "链接无效。": "The link is invalid.",
        "连接已切换，请重试。": "The connection changed. Please try again.",
        "开机启动尚未开启，请在系统设置中确认。": "Launch at login is not enabled. Check System Settings.",
        "开机启动尚未关闭，请在系统设置中确认。": "Launch at login is still enabled. Check System Settings.",
        "跟随系统": "Follow System",
        "界面语言": "App Language",
        "语言": "Language",
        "外观": "Appearance",
        "通用": "General",
        "模型连接": "Translation Services",
        "翻译服务": "Translation Services",
        "词库与偏好": "Glossary & Preferences",
        "选择翻译方式、语言与快捷键。": "Choose translation options, languages, and shortcuts.",
        "选中文字即可翻译，按 ⌥S 圈选屏幕。": "Select text to translate. Press ⌥S to select a screen area.",
        "选择本机翻译，或连接常用的翻译服务。": "Translate on your Mac or connect a translation service.",
        "让译文熟悉你的领域与表达。": "Tailor translations to your field and writing style.",
        "翻译方式": "Translation",
        "划词翻译": "Selection Translation",
        "选中文字后，显示小翻译按钮。": "Select text to show the translation button.",
        "划词后显示翻译按钮": "Show translation button after selecting text",
        "选中文字即可翻译，无需快捷键。": "Select text to translate. No shortcut needed.",
        "自动显示翻译按钮，无需快捷键。": "Show the translation button automatically.",
        "圈选翻译": "Screen Translation",
        "松手后自动翻译；按住 Shift 画矩形。": "Release to translate. Hold Shift for a rectangle.",
        "自由圈选不规则区域，松手后翻译；Shift 画矩形。": "Draw a freeform area and release to translate. Hold Shift for a rectangle.",
        "开始圈选": "Select Area",
        "目标语言": "Translate To",
        "快捷键": "Keyboard Shortcut",
        "试译": "Try Translation",
        "输入要翻译的内容": "Enter text to translate",
        "选择翻译服务": "Choose translation service",
        "翻译": "Translate",
        "译": "T",
        "使用本机 Apple 语言包。": "Uses Apple language packs on your Mac.",
        "点击翻译后，文字会发送给所选服务。": "Your text is sent to the selected service when you translate.",
        "系统权限": "Permissions",
        "辅助功能": "Accessibility",
        "用于跨 App 划词": "Read selected text across apps",
        "屏幕录制": "Screen Recording",
        "用于圈选与本机文字识别": "Capture selected areas and recognize text on your Mac",
        "已允许": "Allowed",
        "未允许": "Not Allowed",
        "授权": "Allow",
        "打开设置": "Open Settings",
        "拖动以调整窗口大小": "Drag to resize the window",
        "调整窗口大小": "Resize window",
        "本机": "On Device",
        "本机运行，无需 API Key": "Runs on your Mac. No API key required",
        "使用自己的 DeepSeek API Key": "Use your own DeepSeek API key",
        "免费模型路由，有额度和速率限制": "Free model router with usage and rate limits",
        "连接兼容 API 或本机模型": "Connect a compatible API or local model",
        "高级选项": "Advanced",
        "使用已安装并配置好的本地命令行工具。": "Use an installed and configured local command-line tool.",
        "Apple 翻译": "Apple Translate",
        "兼容 API": "Custom API",
        "自定义 API": "Custom API",
        "系统译文不应用个人词库或表达偏好。": "Apple Translate does not use your glossary or writing preferences.",
        "API 地址": "API URL",
        "模型": "Model",
        "已保存，输入可更新": "Saved. Enter a new key to update",
        "粘贴 API Key": "Paste API Key",
        "保存": "Save",
        "密钥仅保存在本机钥匙串。": "Your key is stored only in your Mac's Keychain.",
        "移除": "Remove",
        "试译一句": "Try a Sentence",
        "验证连接": "Check Connection",
        "使用本机语言包试译。": "Translate a sentence using local language packs.",
        "发送一小段测试文字，可能使用少量额度。": "Sends a short test sentence. A small charge may apply.",
        "测试中…": "Testing…",
        "测试连接": "Test Connection",
        "使用已安装并配置好的 CLI。": "Use an installed and configured CLI.",
        "重新检测": "Scan Again",
        "CLI 路径": "CLI Path",
        "模型（可选）": "Model (Optional)",
        "尚未检测到 CLI，可填写可执行文件的完整路径。": "No CLI found. Enter the full path to its executable.",
        "检测到文件不代表已登录。登录与服务额度由对应 CLI 管理。": "Each CLI manages its own sign-in and usage limits. Detection does not confirm sign-in.",
        "默认使用免费路由。免费模型有额度和速率限制，可用性会变化。": "Uses the free router by default. Free models have usage limits and may change.",
        "免费路由不代表无限使用；额度、速率及模型可用性会变化。": "Free models have usage limits. Quotas, rate limits, and availability may change.",
        "已检测到 %d 个 CLI": "%d CLIs Detected",
        "注册 OpenRouter ↗": "Sign Up for OpenRouter ↗",
        "创建 API Key ↗": "Create an API Key ↗",
        "翻译偏好": "Translation Preferences",
        "填写研究领域、常用译名或表达语气。": "Enter your field, preferred terms, or writing style.",
        "例如：关注 AI Agent 与强化学习；保留 Agent、RL 等缩写。": "For example: AI agents and reinforcement learning; keep Agent and RL unchanged.",
        "偏好与术语会用于 AI 翻译；Apple 翻译使用系统译文。": "AI services use your preferences and terms. Apple Translate uses system translations.",
        "研究领域、常用译名、表达语气、需要保留的缩写……\n例如：关注 AI Agent 与强化学习；保留 Agent、RL 等缩写。": "Your field, preferred terms, tone, and abbreviations to keep…\nFor example: AI agents and reinforcement learning; keep Agent and RL unchanged.",
        "AI 渠道翻译时随原文发送给模型。Apple 翻译使用系统译文。": "Sent with your text to AI services. Apple Translate uses system translations.",
        "个人词库": "Personal Glossary",
        "导入": "Import",
        "导出": "Export",
        "为专业词指定译法。关闭勾选可暂时停用。": "Set preferred translations for terms. Uncheck a term to pause it.",
        "为专业词指定译法。相同原词会更新已有术语。": "Set preferred translations for terms. Adding the same source term updates its existing entry.",
        "从一个常用术语开始": "Start with a Term",
        "例如：environment scaling → 环境扩展": "For example: environment scaling → 环境扩展",
        "添加术语": "Add Term",
        "添加": "Add",
        "启用术语": "Enable Term",
        "启用术语：%@": "Enable Term: %@",
        "编辑术语": "Edit Term",
        "已添加术语": "Term added",
        "已更新同名术语": "Existing term updated",
        "术语已保存": "Term saved",
        "术语已删除": "Term deleted",
        "该术语已被删除，请重新添加。": "This term was deleted. Add it again.",
        "原词": "Source Term",
        "源词": "Source Term",
        "固定译法": "Preferred Translation",
        "固定译名": "Preferred Translation",
        "备注（可选）": "Note (Optional)",
        "备注或适用语境（可选）": "Note or Context (Optional)",
        "备注": "Note",
        "删除术语": "Delete Term",
        "删除": "Delete",
        "完成": "Done",
        "取消": "Cancel",
        "搜索术语": "Search Terms",
        "搜索词库": "Search Glossary",
        "搜索原词、译法或备注": "Search terms, translations, or notes",
        "清除搜索": "Clear Search",
        "未找到匹配术语": "No Matching Terms",
        "没有匹配的术语": "No Matching Terms",
        "没有匹配的术语。": "No matching terms.",
        "已自动保存": "Saved Automatically",
        "自动保存": "Saved Automatically",
        "偏好会自动保存。": "Preferences are saved automatically.",
        "所有修改自动保存。": "Changes are saved automatically.",
        "英语": "English",
        "智能中英互译": "Auto: Chinese ↔ English",
        "简体中文": "Simplified Chinese",
        "繁体中文": "Traditional Chinese",
        "日语": "Japanese",
        "日本語": "Japanese",
        "自动检测": "Auto Detect",
        "译文": "Translation",
        "正在翻译…": "Translating…",
        "正在翻译": "Translating",
        "翻译选中文字": "Translate Selected Text",
        "翻译 · ⌃⌥D": "Translate · ⌃⌥D",
        "取消固定": "Unpin",
        "固定译文": "Pin Translation",
        "关闭 · Esc": "Close · Esc",
        "暂时无法翻译": "Unable to Translate",
        "重试": "Try Again",
        "翻译设置": "Translation Settings",
        "选中文字，点击「译」即可翻译。": "Select text and click the translation button.",
        "重新翻译": "Translate Again",
        "已复制": "Copied",
        "复制": "Copy",
        "复制译文": "Copy Translation",
        "翻译选区": "Translate Selection",
        "Transpose · 译文": "Transpose · Translation",
        "屏幕圈选": "Screen Selection",
        "交互预览": "Interaction Preview",
        "界面预览 · 未发送请求": "Interface Preview · No Request Sent",
        "关于 Transpose": "About Transpose",
        "隐藏 Transpose": "Hide Transpose",
        "退出 Transpose": "Quit Transpose",
        "编辑": "Edit",
        "撤销": "Undo",
        "剪切": "Cut",
        "粘贴": "Paste",
        "全选": "Select All",
        "窗口": "Window",
        "关闭窗口": "Close Window",
        "设置…": "Settings…",
        "退出": "Quit",
        "识别中": "Detecting",
        "正在识别文字…": "Recognizing Text…",
        "本机文字识别": "On-device Text Recognition",
        "已缓存": "Cached",
        "翻译未完成": "Translation Incomplete",
        "没有识别到可翻译的文字。": "No translatable text was found.",
        "选中文字较多，请分成较小的区域翻译。": "Too much text selected. Translate a smaller area.",
        "翻译服务没有返回文字，请重试。": "The translation service returned no text. Try again.",
        "翻译服务响应无效。": "The translation service returned an invalid response.",
        "服务地址发生重定向，请填写最终服务地址。": "The API URL redirects. Enter the final service URL.",
        "API Key 无效或没有访问权限，请检查设置。": "Your API key is invalid or lacks access. Check your settings.",
        "API 账户额度不足，或所选模型需要付费。": "Your API balance is insufficient, or this model requires payment.",
        "当前模型达到请求限额，请稍后重试或自行更换模型。": "This model's request limit has been reached. Try later or choose another model.",
        "当前模型达到请求限额，请稍后重试或在设置中选择其他服务。": "This model's request limit has been reached. Try later or choose another service.",
        "翻译响应过大，请缩小选区。": "The response is too large. Select a smaller area.",
        "翻译连接提前结束，译文尚未完成，请重试。": "The connection ended before translation finished. Try again.",
        "模型没有返回译文，请检查模型名称。": "The model returned no translation. Check the model name.",
        "翻译请求超时，请重试。": "The translation request timed out. Try again.",
        "无法连接翻译服务，请检查网络和服务地址。": "Cannot connect to the translation service. Check your network and API URL.",
        "翻译连接中断，请重试。": "The translation connection was interrupted. Try again.",
        "翻译服务暂时不可用，请重试。": "The translation service is temporarily unavailable. Try again.",
        "请填写有效的 HTTP 或 HTTPS API 地址，地址中不要包含账号或密码。": "Enter a valid HTTP or HTTPS API URL without a username or password.",
        "远程 API 必须使用 HTTPS；HTTP 仅用于本机服务。": "Remote APIs require HTTPS. HTTP is available for local services only.",
        "API 地址的端口无效。": "The API URL contains an invalid port.",
        "API 地址无效。": "The API URL is invalid.",
        "API Key 格式无效。": "The API key format is invalid.",
        "请在设置中填写 API Key。": "Enter an API key in Settings.",
        "请在设置中填写模型名称。": "Enter a model name in Settings.",
        "翻译流数据不完整，请重试。": "The translation stream was incomplete. Try again.",
        "API 返回错误，请检查模型、额度和服务配置。": "The API returned an error. Check the model, balance, and service settings.",
        "模型未能翻译这段内容。": "The model could not translate this content.",
        "API 没有返回完整译文，请检查服务兼容性。": "The API returned an incomplete translation. Check service compatibility.",
        "译文超过单次长度限制，请缩小选区后重试。": "The translation exceeds the length limit. Select less text and try again.",
        "翻译服务未能处理这段内容。": "The translation service could not process this content.",
        "翻译服务提前停止，译文尚未完成，请重试。": "The translation service stopped before completion. Try again.",
        "请选择一个本地 CLI。": "Choose a local CLI.",
        "Kimi 请求了翻译以外的操作，已停止。": "Kimi requested an operation outside translation. The request was stopped.",
        "Codex 翻译失败，请检查 CLI 登录状态和模型。": "Codex translation failed. Check CLI sign-in and model settings.",
        "无法启动 CLI，请检查可执行文件路径与版本。": "Cannot launch the CLI. Check its path and version.",
        "CLI 翻译超过 60 秒，请重试。": "CLI translation exceeded 60 seconds. Try again.",
        "CLI 返回内容过多，已停止这次翻译。": "The CLI returned too much content. Translation was stopped.",
        "Apple 翻译需要 macOS 15 或更新版本。": "Apple Translate requires macOS 15 or later.",
        "没有可翻译的文字。": "There is no text to translate.",
        "请在设置的 Apple 翻译中点击“准备语言包”，同意系统下载后重试。": "Open Apple Translate in Settings, choose Prepare Languages, and approve the download.",
        "Apple 翻译暂不支持这组语言，请在设置中选择其他渠道。": "Apple Translate does not support this language pair. Choose another service.",
        "暂时无法确认 Apple 翻译的语言支持。": "Apple Translate language support could not be checked.",
        "Apple 翻译返回的段落不完整，请重试。": "Apple Translate returned incomplete paragraphs. Try again.",
        "Apple 翻译没有返回完整译文，请重试。": "Apple Translate returned an incomplete translation. Try again.",
        "Apple 语言包尚未就绪，请在设置中准备语言包后重试。": "Apple language packs are not ready. Prepare them in Settings and try again.",
        "Apple 翻译暂时不可用，请重试或在设置中检查语言包。": "Apple Translate is unavailable. Try again or check language packs in Settings.",
        "Apple 翻译暂未配置这个目标语言。": "This target language has not been configured for Apple Translate.",
        "Apple 翻译无法识别原文语言，请多选择一些文字。": "Apple Translate could not detect the source language. Select more text.",
        "macOS 15–25 的 Apple 翻译需要打开应用译文窗口或设置页面。": "On macOS 15–25, open the translation window or Settings to use Apple Translate.",
        "Apple 翻译等待超时，请重试。": "Apple Translate timed out. Try again.",
        "正在检查本机语言包…": "Checking Local Language Packs…",
        "翻译在本机完成，无需 API Key。首次使用需同意下载 Apple 语言包。": "Translation runs on your Mac without an API key. Approve the language download before first use.",
        "将准备中文、英语与日语之间的翻译。": "Prepares translation between Chinese, English, and Japanese.",
        "将准备中文与英语之间的翻译。": "Prepares translation between Chinese and English.",
        "最近请求的语言：%@ → %@": "Last requested languages: %@ → %@",
        "正在准备…": "Preparing…",
        "准备语言包": "Prepare Languages",
        "重新检查": "Check Again",
        "语言包准备未完成。可重新点击并按系统提示操作。": "Language preparation is incomplete. Try again and follow the system prompt.",
        "所选语言暂不受 Apple 翻译支持。": "Apple Translate does not support the selected languages.",
        "语言包已安装，可直接翻译。": "Language packs are installed and ready.",
        "语言包尚未安装完成，点击由 macOS 确认或继续准备。": "Language packs are not installed yet. Choose Prepare Languages to continue.",
        "正在检查语言包…": "Checking Language Packs…",
        "请按 macOS 提示准备语言包…": "Follow the macOS prompt to prepare languages…",
        "语言包正在下载或等待系统准备…": "Language packs are downloading or waiting for macOS…",
        "语言包尚未安装完成，可稍后重新检查。": "Language packs are not installed yet. Check again later.",
        "划词翻译需要辅助功能权限。请在设置中允许 Transpose。": "Selection translation requires Accessibility permission. Allow Transpose in Settings.",
        "没有读到选中文字。可以按 ⌃⌥S 圈选屏幕中的内容。": "No selected text was found. Use the screen selection shortcut to translate an area.",
        "没有读到选中文字。可以按 ⌥S 圈选屏幕中的内容。": "No selected text was found. Press ⌥S to select a screen area.",
        "圈选翻译需要屏幕录制权限。请在设置中允许 Transpose，然后重新圈选。": "Screen translation requires Screen Recording permission. Allow Transpose in Settings, then select again.",
        "这段内容较长，请选取 16,000 字符以内的部分。": "Select a passage of 16,000 characters or less.",
        "请输入有效的 API Key。": "Enter a valid API key.",
        "请输入 API Key 后保存。": "Enter an API key before saving.",
        "请填写有效的 API 地址。": "Enter a valid API URL.",
        "已保存到 macOS 钥匙串": "Saved to macOS Keychain",
        "已移除此连接的 API Key": "API key removed for this connection",
        "API Key 已保存在 macOS 钥匙串": "API key saved in macOS Keychain",
        "正在试译一句…": "Translating a Test Sentence…",
        "导入术语表": "Import Glossary",
        "导出术语表": "Export Glossary",
        "术语文件超过 2 MB，请缩小后重试。": "The glossary exceeds 2 MB. Use a smaller file.",
        "术语表已导出": "Glossary exported",
        "词库文件不能超过 2 MB。": "The glossary file must not exceed 2 MB.",
        "无法读取文件，请使用 UTF-8 编码。": "Cannot read this file. Use UTF-8 encoding.",
        "JSON 词库格式有误。请使用包含 source、translation 的数组。": "Invalid glossary JSON. Use an array with source and translation fields.",
        "单条源词最多 160 字，译名最多 360 字，备注最多 600 字。": "Each term allows 160 source characters, 360 translation characters, and 600 note characters.",
        "词条包含无法显示的控制字符。": "A glossary entry contains unsupported control characters.",
        "分隔文件的引号后包含多余内容。": "The delimited file contains unexpected text after a closing quote.",
        "分隔文件中的双引号需要成对包围字段。": "Double quotes must enclose a complete field in the delimited file.",
        "分隔文件中有未闭合的双引号。": "The delimited file contains an unclosed double quote.",
        "圈选区域太小，请重新圈选。": "The selected area is too small. Select again.",
        "请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 Transpose，然后重新打开应用。": "Allow Transpose in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen the app.",
        "没有找到可圈选的屏幕。": "No screen is available for selection.",
        "圈选区域里没有识别到文字，请重新圈选。": "No text was found in this area. Select again.",
        "圈选翻译   ·   ⇧ 矩形   ·   Esc 取消": "Select Area   ·   ⇧ Rectangle   ·   Esc Cancel",
        "快捷键监听失败": "Shortcut monitoring failed",
        "快捷键注册失败，可能已被其他应用占用": "The shortcut could not be registered. Another app may be using it",
        "无法缓存界面预览。": "Cannot render the interface preview.",
        "无法保存界面预览。": "Cannot save the interface preview."
    ]

    private struct DynamicRule: @unchecked Sendable {
        let pattern: NSRegularExpression
        let translation: String
    }

    nonisolated private static let dynamicRules: [DynamicRule] = [
        (#"^翻译服务暂时不可用（HTTP ([0-9]+)）。$"#, "The translation service is unavailable (HTTP $1)."),
        (#"^找不到 (.+)，请在设置中扫描或填写可执行文件路径。$"#, "Cannot find $1. Scan for CLIs or enter its executable path in Settings."),
        (#"^(.+) 没有返回译文，请检查模型和登录状态。$"#, "$1 returned no translation. Check its model and sign-in status."),
        (#"^(.+) 版本暂不支持所需参数，请更新 CLI 后重试。$"#, "$1 does not support the required options. Update the CLI and try again."),
        (#"^(.+) 当前额度不足或触发限流，请检查账户后重试。$"#, "$1 has insufficient quota or is rate limited. Check your account and try again."),
        (#"^(.+) 尚未登录或认证已失效，请在终端中登录后重试。$"#, "$1 is not signed in or authentication expired. Sign in through Terminal and try again."),
        (#"^(.+) 的模型不可用，请检查 CLI 默认模型或设置中的模型名称。$"#, "$1's model is unavailable. Check the CLI default model or model name in Settings."),
        (#"^(.+) 无法连接模型服务，请检查网络与 CLI 的服务地址。$"#, "$1 cannot connect to the model service. Check your network and CLI service URL."),
        (#"^(.+) 配置或插件无法启动，请在终端检查该 CLI。$"#, "$1 could not start its configuration or plugins. Check the CLI in Terminal."),
        (#"^(.+) 无法访问所需文件，请检查 CLI 路径和文件权限。$"#, "$1 cannot access a required file. Check the CLI path and file permissions."),
        (#"^(.+) 翻译失败，请检查 CLI 登录状态、模型与版本。$"#, "$1 translation failed. Check CLI sign-in, model, and version."),
        (#"^第 ([0-9]+) 行缺少源词或译名，请用 Tab 分隔两列。$"#, "Row $1 needs a source term and translation, separated by a tab."),
        (#"^第 ([0-9]+) 行的 enabled 应为 true 或 false。$"#, "Row $1: enabled must be true or false."),
        (#"^第 ([0-9]+) 行的 id 格式有误。$"#, "Row $1 contains an invalid ID."),
        (#"^第 ([0-9]+) 条需要填写源词和固定译名。$"#, "Entry $1 needs a source term and preferred translation."),
        (#"^词库最多支持 ([0-9]+) 条。$"#, "The glossary supports up to $1 entries."),
        (#"^词库内容总计不能超过 ([0-9]+) 字。$"#, "The glossary must not exceed $1 characters in total."),
        (#"^已导入 ([0-9]+) 条术语$"#, "Imported $1 terms"),
        (#"^已检测到 ([0-9]+) 个 CLI$"#, "$1 CLIs Detected"),
        (#"^连接成功 · ([0-9.]+) 秒\n([\s\S]*)$"#, "Connected · $1 s\n$2"),
        (#"^最近请求的语言：(.+)$"#, "Last requested languages: $1"),
        (#"^(.+) · 正在翻译$"#, "$1 · Translating"),
        (#"^(.+) · 已缓存$"#, "$1 · Cached"),
        (#"^(.+) · ([0-9.]+) 秒$"#, "$1 · $2 s"),
        (#"^快捷键注册未成功：(.+)。可以从菜单栏或设置启动圈选。$"#, "Could not register shortcut: $1. Start screen selection from the menu bar or Settings."),
        (#"^事件监听（(.+)）$"#, "Event monitoring ($1)"),
        (#"^钥匙串操作失败：(.+)$"#, "Keychain operation failed: $1"),
        (#"^状态 (.+)$"#, "Status $1")
    ].compactMap { pattern, translation in
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return DynamicRule(pattern: expression, translation: translation)
    }
}
