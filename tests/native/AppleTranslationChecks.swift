import Foundation

@MainActor
func runAppleTranslationChecks() throws -> Int {
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw AppError.message("Apple 翻译验证：" + message) }
        count += 1
    }
    for (input, code) in [("Simplified Chinese", "zh-Hans"), (" zh-CN ", "zh-Hans"), ("简体中文", "zh-Hans"),
                          ("English", "en"), ("en", "en"), ("日本語", "ja"), ("Japanese", "ja")] {
        try check(try AppleTranslationLanguages.targetCode(input) == code, "目标语言映射 \(input)")
    }
    do {
        _ = try AppleTranslationLanguages.targetCode("Klingon")
        throw AppError.message("Apple 翻译验证：未拒绝未配置语言")
    } catch let error as AppError {
        guard error.localizedDescription == "Apple 翻译暂未配置这个目标语言。" else { throw error }
        count += 1
    }
    try check(try AppleTranslationLanguages.sourceCode("A lightweight translator keeps the original meaning intact.") == "en", "英文源语言识别")
    try check(try AppleTranslationLanguages.sourceCode("这是一款轻巧的翻译工具，可以在电脑上选择文字进行翻译。") == "zh-Hans", "中文源语言识别")
    try check(try AppleTranslationLanguages.sourceCode("これは日本語の文章です。自然な翻訳を表示します。") == "ja", "日文源语言识别")
    for text in ["OpenAI", "LLM", "API", "Cancel", "s"] {
        try check(try AppleTranslationLanguages.sourceCode(text) == "en", "短ASCII低置信度按英语：\(text)")
    }
    try check(try AppleTranslationLanguages.sourceCode("Bonjour") == "fr", "高置信度法语短词")
    try check(try AppleTranslationLanguages.sourceCode("Hola") == "es", "高置信度西语短词")
    try check(try AppleTranslationLanguages.sourceCode("你好") == "zh-Hans", "简繁共同字不误分到繁体包")
    try check(try AppleTranslationLanguages.sourceCode("這是一款輕巧的翻譯工具，可以選擇文字進行翻譯。") == "zh-Hant", "繁体字形保留源脚本")
    try check(AppleTranslationLanguages.sameLanguage(Locale.Language(identifier: "en-US"), Locale.Language(identifier: "en")), "同语言地区变体")
    try check(!AppleTranslationLanguages.sameLanguage(Locale.Language(identifier: "ja"), Locale.Language(identifier: "zh-Hans")), "不同语言")
    try check(!AppleTranslationLanguages.sameLanguage(Locale.Language(identifier: "zh-Hant"), Locale.Language(identifier: "zh-Hans")), "繁简转换不可返回未改变原文")

    let simple = AppleTranslationTextPlan("Hello, world!")
    try check(simple.paragraphs == ["Hello, world!"] && (try simple.join(["你好，世界！"])) == "你好，世界！", "单段文本")
    let multi = AppleTranslationTextPlan("First paragraph.\n\nSecond paragraph.\n\nThird paragraph.")
    try check(multi.paragraphs.count == 3 && (try multi.join(["第一段。", "第二段。", "第三段。 "])) == "第一段。\n\n第二段。\n\n第三段。 ", "段落及译文保真")
    let windows = AppleTranslationTextPlan("Line one.\r\nLine two.\r\n \t\r\nNext paragraph.")
    try check(windows.paragraphs == ["Line one.\r\nLine two.", "Next paragraph."], "CRLF 不应分成两个换行")
    try check(try windows.join(["第一段", "第二段"]) == "第一段\r\n \t\r\n第二段", "Windows 空行和空白保留")
    let singleLines = AppleTranslationTextPlan("A\nB\rC")
    try check(singleLines.paragraphs == ["A\nB\rC"], "单换行保留段内上下文")
    let edges = AppleTranslationTextPlan("\n\nHello.\n\n\n")
    try check(try edges.join(["你好。"]) == "\n\n你好。\n\n\n", "边界空行保留")
    let empty = AppleTranslationTextPlan(" \n\t\n")
    try check(empty.paragraphs.isEmpty && (try empty.join([])) == " \n\t\n", "纯空白不创建翻译请求")
    do {
        _ = try multi.join(["一段"])
        throw AppError.message("Apple 翻译验证：未拒绝遗漏段落")
    } catch let error as AppError {
        guard error.localizedDescription == "Apple 翻译返回的段落不完整，请重试。" else { throw error }
        count += 1
    }
    let smartPairs = AppleTranslationLanguages.setupPairs(targetLanguage: .smart)
    let japanesePairs = AppleTranslationLanguages.setupPairs(targetLanguage: .japanese)
    try check(smartPairs.count == 2 && smartPairs.contains(where: { $0 == ("en", "zh-Hans") }) && smartPairs.contains(where: { $0 == ("zh-Hans", "en") }), "中英双向准备")
    try check(japanesePairs.count == 6 && !japanesePairs.contains(where: { $0.0 == $0.1 }), "中英日组合不重复自己")
    let extra = AppleTranslationLanguages.setupPairs(targetLanguage: .smart, additional: ("ja", "zh-Hans"))
    try check(extra.count == 3 && extra.contains(where: { $0 == ("ja", "zh-Hans") }), "实际缺失的源语言可以准备")
    try check(AppleTranslationLanguages.setupPairs(targetLanguage: .smart, additional: ("en", "zh")).count == 2, "源语言别名不得重复准备")
    try check(AppleTranslationLanguages.setupPairs(targetLanguage: .smart, additional: ("fr", "en")).last.map { $0 == ("fr", "en") } == true, "其他系统支持语言按实际请求准备")

    let firstHost = UUID(), secondHost = UUID()
    var claim = AppleTranslationHostClaim()
    guard let firstToken = claim.acquire(host: firstHost) else { throw AppError.message("Apple 翻译验证：首个 host 无法接管") }
    try check(claim.hostID == firstHost && claim.matches(firstToken), "首次领取任务")
    try check(claim.acquire(host: secondHost) == nil, "两个 host 不得重复翻译")
    try check(!claim.release(host: secondHost) && claim.matches(firstToken), "其他 host 消失不得取消执行者")
    try check(claim.release(host: firstHost) && !claim.matches(firstToken), "执行 host 消失使旧结果失效")
    guard let secondToken = claim.acquire(host: secondHost) else { throw AppError.message("Apple 翻译验证：存活 host 无法接管") }
    try check(secondToken != firstToken && claim.hostID == secondHost && claim.matches(secondToken) && !claim.matches(firstToken), "新 host 接管与晚结果隔离")
    return count
}
