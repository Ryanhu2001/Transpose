import Foundation
import Darwin

@MainActor
enum CLIRunner {
    static func translate(
        _ text: String,
        options: TranslationOptions,
        systemPrompt: String,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        try Task.checkCancellation()
        let rawPath = options.cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = rawPath.isEmpty
            ? CLIProbe.discover().first(where: { $0.provider == options.provider })?.path ?? ""
            : (rawPath as NSString).expandingTildeInPath
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw AppError.message("找不到 \(options.provider.title)，请在设置中扫描或填写可执行文件路径。")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Transpose-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let invocation = try CLIInvocation.make(provider: options.provider, text: text, model: options.model, systemPrompt: systemPrompt, directory: directory)
        let process = try CLIProcessBridge(executable: executable, arguments: invocation.arguments, input: invocation.input, directory: directory, extraEnvironment: invocation.environment)
        defer { process.cancel() }
        var decoder = CLIStreamParser(provider: options.provider)
        var result = ""
        return try await withTaskCancellationHandler {
            for try await line in process.lines {
                try Task.checkCancellation()
                if let update = try decoder.consume(line) {
                    switch update {
                    case .append(let delta): result += delta
                    case .replace(let value): result = value
                    }
                    if !result.isEmpty { onDelta(result) }
                }
            }
            try Task.checkCancellation()
            let status = await process.exitStatus()
            try Task.checkCancellation()
            guard status == 0 else {
                throw AppError.message(process.failureMessage(provider: options.provider))
            }
            let final = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !final.isEmpty else { throw AppError.message("\(options.provider.title) 没有返回译文，请检查模型和登录状态。") }
            if final != result { onDelta(final) }
            return final
        } onCancel: { process.cancel() }
    }
}

struct CLIInvocation {
    let arguments: [String]
    let input: Data
    var environment: [String: String] = [:]

    static func make(provider: TranslationProvider, text: String, model: String, systemPrompt: String, directory: URL) throws -> CLIInvocation {
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .codex:
            var arguments = [
                "exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                "--sandbox", "read-only", "--json", "--color", "never", "-C", directory.path,
                "-c", "model_reasoning_effort=\"low\"", "-c", "web_search=\"disabled\"", "-c", "project_doc_max_bytes=0"
            ]
            if !selectedModel.isEmpty { arguments += ["-m", selectedModel] }
            for feature in ["apps", "plugins", "memories", "shell_tool", "browser_use", "browser_use_external", "computer_use", "image_generation", "view_image", "multi_agent", "multi_agent_v2", "hooks", "skill_search", "sleep_tool", "tool_suggest", "workspace_dependencies", "in_app_browser"] {
                arguments += ["-c", "features.\(feature)=false"]
            }
            arguments += ["-c", "features.skip_host_skill_discovery=true", "-"]
            return CLIInvocation(arguments: arguments, input: Data((systemPrompt + "\n\nSOURCE TEXT TO TRANSLATE:\n" + text).utf8))
        case .claude:
            let prompt = directory.appendingPathComponent("translation-prompt.txt")
            try writePrivate(systemPrompt, to: prompt)
            var arguments = [
                "--print", "--safe-mode", "--tools", "", "--strict-mcp-config", "--disable-slash-commands",
                "--permission-mode", "dontAsk", "--permission-prompts", "none", "--no-chrome",
                "--no-session-persistence", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                "--system-prompt-file", prompt.path, "--settings", "{\"disableAllHooks\":true}", "--effort", "low"
            ]
            if !selectedModel.isEmpty { arguments += ["--model", selectedModel] }
            return CLIInvocation(arguments: arguments, input: Data(text.utf8))
        case .kimi:
            let agent = directory.appendingPathComponent("vela-translator.md")
            let emptySkills = directory.appendingPathComponent("skills", isDirectory: true)
            try FileManager.default.createDirectory(at: emptySkills, withIntermediateDirectories: false)
            try writePrivate("---\nname: vela-translator\ndescription: Translate the supplied source text faithfully.\ntools: []\nsubagents: []\n---\n\n" + systemPrompt, to: agent)
            var arguments = ["--agent-file", agent.path, "--skills-dir", emptySkills.path, "--output-format", "stream-json"]
            if !selectedModel.isEmpty { arguments += ["--model", selectedModel] }
            arguments += ["--prompt", text]
            return CLIInvocation(arguments: arguments, input: Data(), environment: ["KIMI_DISABLE_TELEMETRY": "1"])
        case .dsh:
            let plugin = directory.appendingPathComponent("vela-translation.mjs")
            let patch = directory.appendingPathComponent("vela-translation.patch.yml")
            let promptJSON = try jsonString(systemPrompt)
            let modelJSON = try jsonString(selectedModel)
            // A request-local Cordis plugin uses the shipped public hooks. User authentication
            // stays inside dsh. No user configuration or credential file is read by Transpose.
            let source = """
            export const name = "vela-translation";
            export const inject = ["tools", "systemPrompt"];
            export function apply(ctx) {
              ctx.tools.guard(() => "Tools are disabled for this translation request.");
              ctx.systemPrompt.suppressRuntimeContext();
              ctx.systemPrompt.section({ name: "vela:translation", order: -1000, complete: true, text: \(promptJSON) });
              ctx.on("system-prompt/assemble", async (_assembly, _context, next) => {
                const assembled = await next();
                return { ...assembled, tools: [], contexts: [] };
              });
              let requests = 0;
              ctx.on("agent/request", async (_event, next) => {
                if (++requests > 1) throw new Error("Translation allows one model request.");
                const config = await next();
                const model = \(modelJSON);
                return { ...config, ...(model ? { model } : {}), maxTokens: 16384 };
              });
            }
            """
            try writePrivate(source, to: plugin)
            let disabled = ["session-title-llm", "session-persistence-jsonl", "session-checkpoint-policy", "session-telemetry-otel", "agent-instructions", "skill-filesystem", "tool-skill", "tool-bash", "tool-pwsh", "tool-fs", "tool-fs-search", "tool-jobs", "tool-subagent", "tool-subagent-fork", "tool-subagent-control", "tool-subagent-list-agents", "tool-subagent-report", "tool-workflow", "tool-goal", "tool-ralph", "tool-str-replace-editor", "tool-todo", "tool-web", "code-runtime"]
            var yaml = disabled.map { "- id: \($0)\n  disabled: true\n" }.joined()
            yaml += "- id: system-prompt\n  config:\n    includeHarnessIdentity: false\n    includeRuntimeContext: false\n    persona: ''\n"
            yaml += "- id: tools\n  config:\n    mode: native\n"
            yaml += "- insert:\n    - id: vela-translation\n      name: " + (try jsonString(plugin.absoluteString)) + "\n"
            try writePrivate(yaml, to: patch)
            return CLIInvocation(arguments: ["--profile", "headless", "--patch", patch.path, "--", text], input: Data(), environment: ["DSH_TELEMETRY_DISABLED": "1", "DSH_PERMISSION_MODE": "read-only"])
        default:
            throw AppError.message("请选择一个本地 CLI。")
        }
    }

    private static func writePrivate(_ value: String, to url: URL) throws {
        try Data(value.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func jsonString(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}

/// Each adapter accepts only assistant text; thinking, tool results and startup metadata stay hidden.
struct CLIStreamParser {
    enum TextUpdate: Equatable { case append(String), replace(String) }
    let provider: TranslationProvider

    init(provider: TranslationProvider) { self.provider = provider }

    mutating func consume(_ line: String) throws -> TextUpdate? {
        if provider == .dsh { return .append(line + "\n") }
        guard let data = line.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if provider == .codex { return try Self.codexEvent(event) }
        if provider == .claude {
            guard event["parent_tool_use_id"] == nil || event["parent_tool_use_id"] is NSNull else { return nil }
            let type = event["type"] as? String
            if type == "result" {
                if event["is_error"] as? Bool == true || (event["subtype"] as? String).map({ $0 != "success" }) == true {
                    let diagnostic = (event["result"] as? String) ?? (event["errors"] as? [String])?.joined(separator: " ") ?? ""
                    throw AppError.message(CLIErrorClassifier.message(diagnostic, provider: .claude))
                }
                if let result = event["result"] as? String { return .replace(result) }
            }
            if type == "stream_event", let stream = event["event"] as? [String: Any],
               stream["type"] as? String == "content_block_delta", let delta = stream["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta", let text = delta["text"] as? String { return .append(text) }
            // Final assistant messages repeat the streamed content. The result event is authoritative.
            return nil
        }
        if provider == .kimi {
            if let error = event["error"] { throw AppError.message(CLIErrorClassifier.message(String(describing: error), provider: .kimi)) }
            let message = (event["message"] as? [String: Any]) ?? event
            guard message["role"] as? String == "assistant" else { return nil }
            if let tools = message["tool_calls"] as? [Any], !tools.isEmpty { throw AppError.message("Kimi 请求了翻译以外的操作，已停止。") }
            if let content = message["content"] as? String { return .replace(content) }
            if let blocks = message["content"] as? [[String: Any]] {
                let content = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
                return content.isEmpty ? nil : .replace(content)
            }
        }
        return nil
    }

    static func codex(_ line: String) throws -> TextUpdate? {
        guard let data = line.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return try codexEvent(event)
    }

    private static func codexEvent(_ event: [String: Any]) throws -> TextUpdate? {
        let type = event["type"] as? String
        if type == "error" || type == "turn.failed" { throw AppError.message("Codex 翻译失败，请检查 CLI 登录状态和模型。") }
        guard event["phase"] as? String != "commentary" else { return nil }
        if ["agent_message.delta", "item.agent_message.delta", "response.output_text.delta"].contains(type ?? ""), let delta = event["delta"] as? String { return .append(delta) }
        if ["item.started", "item.updated", "item.completed"].contains(type ?? ""),
           let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message",
           item["phase"] as? String != "commentary", let text = item["text"] as? String, !text.isEmpty { return .replace(text) }
        if type == "agent_message", let text = event["text"] as? String { return .replace(text) }
        return nil
    }
}

/// Converts untrusted third-party diagnostics to fixed messages. No raw diagnostic is surfaced.
enum CLIErrorClassifier {
    static func message(_ diagnostic: String, provider: TranslationProvider) -> String {
        let text = diagnostic.lowercased()
        let title = provider.title
        if ["unknown option", "unrecognized option", "unexpected argument", "unknown argument", "unsupported option"].contains(where: text.contains) {
            return "\(title) 版本暂不支持所需参数，请更新 CLI 后重试。"
        }
        if ["rate limit", "usage limit", "quota", "credit balance", "insufficient balance", "billing", "exceeded your", "hit your limit", "limit reached"].contains(where: text.contains) {
            return "\(title) 当前额度不足或触发限流，请检查账户后重试。"
        }
        if ["not logged in", "log in", "login", "authenticate", "authentication", "invalid api key", "api key is required", "no api key", "no credential configured", "credentials missing", "token expired", "unauthorized", "401"].contains(where: text.contains) {
            return "\(title) 尚未登录或认证已失效，请在终端中登录后重试。"
        }
        if ["no model", "unknown model", "model not found", "model is not", "invalid model", "model does not", "model_not_found"].contains(where: text.contains) {
            return "\(title) 的模型不可用，请检查 CLI 默认模型或设置中的模型名称。"
        }
        if ["network", "connect", "fetch failed", "timed out", "dns", "enotfound", "econnrefused"].contains(where: text.contains) {
            return "\(title) 无法连接模型服务，请检查网络与 CLI 的服务地址。"
        }
        if ["plugin tree failed", "failed to load", "config", "pending (waiting", "enoent", "cannot find module", "typeerror", "syntaxerror"].contains(where: text.contains) {
            return "\(title) 配置或插件无法启动，请在终端检查该 CLI。"
        }
        if ["permission denied", "operation not permitted", "eacces"].contains(where: text.contains) {
            return "\(title) 无法访问所需文件，请检查 CLI 路径和文件权限。"
        }
        return "\(title) 翻译失败，请检查 CLI 登录状态、模型与版本。"
    }
}

/// Owns a POSIX process group so cancellation also reaches the CLI's child processes.
/// stderr remains in a bounded memory buffer and is mapped to fixed error messages.
final class CLIProcessBridge: @unchecked Sendable {
    let lines: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let output = Pipe()
    private let input = Pipe()
    private let diagnostics = Pipe()
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var pending = Data()
    private var outputBytes = 0
    private var streamFinished = false
    private var diagnosticsFinished = false
    private var cancelled = false
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private var timeout: DispatchWorkItem?
    private var diagnosticBytes = Data()
    private let maximumOutputBytes: Int

    init(executable: String, arguments: [String], input: Data, directory: URL, extraEnvironment: [String: String] = [:], timeoutSeconds: TimeInterval = 60, maximumOutputBytes: Int = 2_000_000) throws {
        var captured: AsyncThrowingStream<String, Error>.Continuation!
        lines = AsyncThrowingStream { captured = $0 }
        continuation = captured
        self.maximumOutputBytes = maximumOutputBytes
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, self.input.fileHandleForReading.fileDescriptor, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, diagnostics.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, self.input.fileHandleForWriting.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, output.fileHandleForReading.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, diagnostics.fileHandleForReading.fileDescriptor)
        if #available(macOS 26.0, *) { posix_spawn_file_actions_addchdir(&actions, directory.path) }
        else { posix_spawn_file_actions_addchdir_np(&actions, directory.path) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = CLIProbe.searchDirectories.joined(separator: ":")
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        environment.merge(extraEnvironment) { _, value in value }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        let result = argv.withUnsafeBufferPointer { argvPointer in
            envp.withUnsafeBufferPointer { envPointer in
                posix_spawn(&pid, executable, &actions, &attributes, argvPointer.baseAddress!, envPointer.baseAddress!)
            }
        }
        guard result == 0 else { throw AppError.message("无法启动 CLI，请检查可执行文件路径与版本。") }
        try? self.input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? diagnostics.fileHandleForWriting.close()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.receive(handle.availableData) }
        diagnostics.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.receiveDiagnostic(handle.availableData) }
        let deadline = DispatchWorkItem { [weak self] in self?.cancel(error: AppError.message("CLI 翻译超过 60 秒，请重试。")) }
        timeout = deadline
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: deadline)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            try? self.input.fileHandleForWriting.write(contentsOf: input)
            try? self.input.fileHandleForWriting.close()
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            // waitpid's status uses the low 7 bits for a signal and the high byte for an exit code.
            didExit((status & 0x7f) == 0 ? ((status >> 8) & 0xff) : 128 + (status & 0x7f))
        }
    }

    func exitStatus() async -> Int32 {
        await withCheckedContinuation { waiter in
            lock.lock()
            if let status, diagnosticsFinished || cancelled { lock.unlock(); waiter.resume(returning: status) }
            else { waiters.append(waiter); lock.unlock() }
        }
    }

    func failureMessage(provider: TranslationProvider) -> String {
        lock.lock()
        let value = String(decoding: diagnosticBytes, as: UTF8.self)
        lock.unlock()
        return CLIErrorClassifier.message(value, provider: provider)
    }

    func cancel(error: Error = CancellationError()) {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let shouldFinish = !streamFinished
        streamFinished = true
        let processID = pid
        let exitedStatus = status
        let finishedWaiters = exitedStatus == nil ? [] : waiters
        if exitedStatus != nil { waiters.removeAll() }
        lock.unlock()
        timeout?.cancel()
        if shouldFinish { continuation.finish(throwing: error) }
        output.fileHandleForReading.readabilityHandler = nil
        diagnostics.fileHandleForReading.readabilityHandler = nil
        if let exitedStatus { for waiter in finishedWaiters { waiter.resume(returning: exitedStatus) } }
        guard processID > 0 else { return }
        let children = Self.descendants(of: processID)
        for child in children.reversed() { Darwin.kill(child, SIGTERM) }
        Darwin.kill(-processID, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4) {
            for child in children.reversed() { Darwin.kill(child, SIGKILL) }
            Darwin.kill(-processID, SIGKILL)
        }
    }

    private func receive(_ data: Data) {
        var ready: [String] = []
        lock.lock()
        guard !streamFinished else { lock.unlock(); return }
        outputBytes += data.count
        if outputBytes > maximumOutputBytes {
            lock.unlock()
            cancel(error: AppError.message("CLI 返回内容过多，已停止这次翻译。"))
            return
        }
        if data.isEmpty {
            if !pending.isEmpty { ready.append(String(decoding: pending, as: UTF8.self)); pending.removeAll() }
            streamFinished = true
            let exited = status != nil && diagnosticsFinished
            lock.unlock()
            output.fileHandleForReading.readabilityHandler = nil
            for line in ready { continuation.yield(line) }
            continuation.finish()
            if exited { timeout?.cancel() }
            return
        }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            ready.append(String(decoding: pending[..<newline], as: UTF8.self))
            pending.removeSubrange(...newline)
        }
        lock.unlock()
        for line in ready { continuation.yield(line) }
    }

    private func receiveDiagnostic(_ data: Data) {
        lock.lock()
        if data.isEmpty {
            diagnosticsFinished = true
            let exitedStatus = status
            let finishedWaiters = exitedStatus == nil ? [] : waiters
            let fullyFinished = exitedStatus != nil && streamFinished
            if exitedStatus != nil { waiters.removeAll() }
            lock.unlock()
            diagnostics.fileHandleForReading.readabilityHandler = nil
            if fullyFinished { timeout?.cancel() }
            if let exitedStatus { for waiter in finishedWaiters { waiter.resume(returning: exitedStatus) } }
            return
        }
        // Always drain stderr to prevent backpressure, retaining only a bounded in-memory sample.
        if diagnosticBytes.count < 16_384 { diagnosticBytes.append(data.prefix(16_384 - diagnosticBytes.count)) }
        lock.unlock()
    }

    private func didExit(_ code: Int32) {
        lock.lock()
        status = code
        let ready = diagnosticsFinished || cancelled ? waiters : []
        if diagnosticsFinished || cancelled { waiters.removeAll() }
        let finished = streamFinished && diagnosticsFinished
        lock.unlock()
        if finished { timeout?.cancel() }
        for waiter in ready { waiter.resume(returning: code) }
    }

    private static func descendants(of root: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue = [root]
        while let parent = queue.popLast(), result.count < 256 {
            var children = [pid_t](repeating: 0, count: 256)
            let bytes = children.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, Int32($0.count)) }
            guard bytes > 0 else { continue }
            for child in children.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where child > 0 && !result.contains(child) {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }
}
