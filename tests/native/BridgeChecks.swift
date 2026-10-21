import Foundation

private enum BridgeChecks {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { "桥接验证：" + reason }
    }

    static func require(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws -> Int {
        guard try condition() else { throw Failure(reason: reason) }
        return 1
    }

    static func rejects(_ action: () throws -> Void, _ reason: String) throws -> Int {
        do { try action() } catch { return 1 }
        throw Failure(reason: reason)
    }

    static func run() throws -> Int {
        var count = 0
        let valid = try NativeBridgeRequest.decode(#"{"id":"request-1","action":"update_settings","payload":{"automaticSelection":true,"preferences":"保留原文段落"}}"#)
        count += try require(valid.id == "request-1" && valid.action == "update_settings", "请求相关 ID 与动作")
        count += try require(try valid.boolean("automaticSelection") == true, "仅接受 JSON true")
        count += try require(try valid.string("preferences") == "保留原文段落", "Unicode 偏好保持原样")
        count += try require(try valid.string("missing", required: false) == nil, "未提交字段维持可选")
        count += try require(try valid.boolean("missing", required: false) == nil, "未提交开关维持可选")
        for value in ["0", "1", "1.0", "\"true\"", "null", "[]"] {
            count += try rejects({
                let request = try NativeBridgeRequest.decode("{\"id\":\"t\",\"action\":\"login_set\",\"payload\":{\"enabled\":\(value)}}")
                _ = try request.boolean("enabled")
            }, "拒绝伪布尔值 \(value)")
        }
        let disabled = try NativeBridgeRequest.decode(#"{"id":"t","action":"login_set","payload":{"enabled":false}}"#)
        count += try require(try disabled.boolean("enabled") == false, "关闭操作识别 JSON false")
        count += try rejects({ _ = try NativeBridgeRequest.decode(#"{"id":"","action":"snapshot","payload":{}}"#) }, "空 ID 不可用")
        count += try rejects({ _ = try NativeBridgeRequest(["id": String(repeating: "x", count: 161), "action": "snapshot", "payload": [:]]) }, "ID 长度上限")
        count += try rejects({ _ = try NativeBridgeRequest.decode(#"{"id":"t","action":"snapshot","payload":null}"#) }, "payload 必须为对象")
        count += try rejects({ _ = try NativeBridgeRequest.decode(String(repeating: " ", count: 1_000_001)) }, "整体桥接 body 长度上限")
        let oversized = try NativeBridgeRequest(["id": "t", "action": "translate", "payload": ["text": String(repeating: "字", count: 16_001)]])
        count += try rejects({ _ = try oversized.string("text") }, "文字使用字符数上限")
        let embeddedNull = try NativeBridgeRequest(["id": "t", "action": "key_save", "payload": ["key": "test\0suffix"]])
        count += try rejects({ _ = try embeddedNull.string("key") }, "拒绝嵌入 NUL 的字段")
        count += try rejects({ _ = try valid.string("missing") }, "必要字段缺失被拒绝")
        count += try require(NativeBridgeRequest.allows("key_save", fromResult: false), "设置桥支持密钥保存")
        count += try require(!NativeBridgeRequest.allows("key_save", fromResult: true), "译文桥禁止修改密钥")
        count += try require(!NativeBridgeRequest.allows("login_set", fromResult: true), "译文桥禁止改登录项")
        count += try require(!NativeBridgeRequest.allows("open_external", fromResult: true), "译文桥禁止打开任意外链")
        count += try require(NativeBridgeRequest.allows("result_pin", fromResult: true), "译文桥允许固定")
        count += try require(!NativeBridgeRequest.allows("execute_shell", fromResult: false), "未知设置动作被拒绝")
        let connectionPatch = try NativeBridgeRequest(["id": "t", "action": "update_settings", "payload": ["expectedProvider": "deepseek", "baseURL": "https://api.deepseek.com"]])
        try connectionPatch.validateConnectionPatch(currentProvider: "deepseek")
        count += 1
        count += try rejects({ try connectionPatch.validateConnectionPatch(currentProvider: "openrouter") }, "延迟连接表单不能写入其他服务")
        let missingConnectionContext = try NativeBridgeRequest(["id": "t", "action": "update_settings", "payload": ["model": "example"]])
        count += try rejects({ try missingConnectionContext.validateConnectionPatch(currentProvider: "deepseek") }, "连接字段必须绑定服务")
        try valid.validateConnectionPatch(currentProvider: "apple")
        count += 1
        let credentials = try NativeBridgeRequest(["id": "t", "action": "key_save", "payload": ["provider": "deepseek", "baseURL": "https://api.deepseek.com", "key": "fixture-only"]])
        try credentials.validateCredentialContext(currentProvider: "deepseek", currentBaseURL: "https://api.deepseek.com")
        count += 1
        count += try rejects({ try credentials.validateCredentialContext(currentProvider: "openrouter", currentBaseURL: "https://api.deepseek.com") }, "密钥不能保存到已切换服务")
        count += try rejects({ try credentials.validateCredentialContext(currentProvider: "deepseek", currentBaseURL: "https://other.example") }, "密钥不能保存到已切换地址")

        let settings = NativeBridgePublicSettings(provider: "deepseek", target: "smart", automaticSelection: true,
                                                  preferences: "清晰自然", baseURL: "https://api.deepseek.com", model: "deepseek-flash",
                                                  cliPath: "", keyIsSaved: true)
        let expected: Set<String> = ["provider", "target", "automaticSelection", "preferences", "baseURL", "model", "cliPath", "keyIsSaved"]
        count += try require(Set(settings.dictionary.keys) == expected, "对外设置字段使用固定白名单")
        count += try require(settings.dictionary["apiKey"] == nil && settings.dictionary["keyDraft"] == nil && settings.dictionary["key"] == nil, "对外设置不含凭据字段")
        let encodedSettings = try JSONSerialization.data(withJSONObject: settings.dictionary)
        count += try require(try JSONSerialization.jsonObject(with: encodedSettings) as? [String: Any] != nil, "公开设置始终可 JSON 编码")
        var result = NativeResultState()
        result.source = "Hello"
        result.output = "你好"
        result.sourceLanguage = "en"
        result.targetLanguage = "zh-Hans"
        result.isPinned = true
        let object = result.dictionary
        count += try require(object["error"] is NSNull, "无错误时传 JSON null")
        count += try require(object["isPinned"] as? Bool == true && object["sourceLanguage"] as? String == L10n.languageName(code: "en"), "结果保留固定与语言信息")
        count += try require(JSONSerialization.isValidJSONObject(object), "结果可 JSON 编码")
        result.error = "翻译未完成"
        count += try require(result.dictionary["error"] as? String == L10n.text("翻译未完成"), "错误按界面语言显示")
        return count
    }
}

func runBridgeChecks() throws -> Int { try BridgeChecks.run() }
