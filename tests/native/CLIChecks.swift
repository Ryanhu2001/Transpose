import Foundation
import Darwin

private enum CLIChecks {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }
    static func require(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws -> Int {
        guard try condition() else { throw Failure(reason: reason) }
        return 1
    }

    @MainActor
    static func run() async throws -> Int {
        var checks = 0
        checks += try require(try CLIStreamParser.codex(#"{"type":"item.completed","item":{"type":"reasoning","text":"private"}}"#) == nil, "CLI leaked reasoning")
        checks += try require(try CLIStreamParser.codex(#"{"type":"item.completed","item":{"type":"command_execution","aggregated_output":"private"}}"#) == nil, "CLI leaked tool output")
        checks += try require(try CLIStreamParser.codex(#"{"type":"item.completed","item":{"type":"agent_message","phase":"commentary","text":"working"}}"#) == nil, "CLI leaked commentary")
        checks += try require(try CLIStreamParser.codex(#"{"type":"item.completed","item":{"type":"agent_message","text":"你好"}}"#) == .replace("你好"), "Codex final missing")
        checks += try require(try CLIStreamParser.codex(#"{"type":"response.output_text.delta","delta":"好"}"#) == .append("好"), "Codex delta missing")
        do {
            _ = try CLIStreamParser.codex(#"{"type":"turn.failed","error":{"message":"sk-sensitive-fixture"}}"#)
            throw Failure(reason: "CLI error accepted")
        } catch let error as AppError {
            checks += try require(!error.localizedDescription.contains("sk-sensitive"), "CLI diagnostic leaked")
        }
        checks += try require(CLIErrorClassifier.message("Provider managed:fixture has no credential configured", provider: .kimi).contains("尚未登录"), "Kimi missing authentication not explained")
        checks += try require(!CLIErrorClassifier.message("unknown option --secret-fixture", provider: .claude).contains("secret-fixture"), "CLI diagnostic text exposed")
        var claude = CLIStreamParser(provider: .claude)
        checks += try require(try claude.consume(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"private"}}}"#) == nil, "Claude reasoning visible")
        checks += try require(try claude.consume(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"你好"}}}"#) == .append("你好"), "Claude stream text")
        checks += try require(try claude.consume(#"{"type":"assistant","message":{"content":[{"type":"text","text":"你好"}]}}"#) == nil, "Claude duplicated streamed assistant")
        checks += try require(try claude.consume(#"{"type":"result","subtype":"success","is_error":false,"result":"你好"}"#) == .replace("你好"), "Claude final missing")
        var kimi = CLIStreamParser(provider: .kimi)
        checks += try require(try kimi.consume(#"{"role":"tool","content":"private"}"#) == nil, "Kimi tool result visible")
        checks += try require(try kimi.consume(#"{"role":"assistant","content":[{"type":"thinking","text":"private"},{"type":"text","text":"译文"}]}"#) == .replace("译文"), "Kimi final missing")
        do {
            _ = try kimi.consume(#"{"role":"assistant","tool_calls":[{"function":{"name":"Bash"}}]}"#)
            throw Failure(reason: "Kimi tool call accepted")
        } catch is AppError { checks += 1 }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Transpose-CLI-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "Hello '$HOME' `not a shell`\n--do-not-run"
        for provider in [TranslationProvider.codex, .claude, .dsh, .kimi] {
            let invocation = try CLIInvocation.make(provider: provider, text: source, model: "fixture", systemPrompt: "Translate only.", directory: directory)
            checks += try require(!invocation.arguments.contains("--dangerously-skip-permissions"), "Unsafe permission flag")
            if provider == .codex || provider == .claude {
                checks += try require(!invocation.arguments.contains(source) && String(decoding: invocation.input, as: UTF8.self).contains(source), "CLI source not on stdin")
            } else {
                checks += try require(invocation.arguments.last == source, "CLI source not a literal argument")
            }
        }
        let dshPlugin = try String(contentsOf: directory.appendingPathComponent("vela-translation.mjs"), encoding: .utf8)
        let dshPatch = try String(contentsOf: directory.appendingPathComponent("vela-translation.patch.yml"), encoding: .utf8)
        checks += try require(dshPlugin.contains("ctx.tools.guard") && dshPlugin.contains("tools: []") && dshPlugin.contains("++requests > 1"), "DSH request not restricted")
        checks += try require(dshPatch.contains("session-title-llm") && dshPatch.contains("session-persistence-jsonl"), "DSH extra work not disabled")
        let agent = try String(contentsOf: directory.appendingPathComponent("vela-translator.md"), encoding: .utf8)
        checks += try require(agent.contains("tools: []") && agent.contains("subagents: []"), "Kimi agent has tools")

        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
        let probeMarker = directory.appendingPathComponent("probe-launched")
        for name in ["codex", "dsh", "claude", "kimi"] {
            let executable = bin.appendingPathComponent(name)
            try Data(("#!/bin/sh\ntouch '" + probeMarker.path + "'\n").utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let detected = CLIProbe.discover(environment: ["PATH": bin.path], home: directory.path)
        checks += try require(detected.count == 4 && detected.allSatisfy({ $0.path.hasPrefix(bin.path + "/") }), "CLI path detection failed")
        checks += try require(!FileManager.default.fileExists(atPath: probeMarker.path), "CLI discovery launched executable")

        let executable = directory.appendingPathComponent("fixture")
        func install(_ body: String) throws {
            try Data(("#!/bin/sh\n" + body).utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        func options(_ provider: TranslationProvider) -> TranslationOptions {
            TranslationOptions(provider: provider, targetLanguage: "Chinese", model: "fixture", cliPath: executable.path)
        }
        try install("/bin/cat >/dev/null\nprintf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"你好\"}}'\n")
        var updates = [String]()
        let final = try await CLIRunner.translate("Hello", options: options(.codex), systemPrompt: "Translate") { updates.append($0) }
        checks += try require(final == "你好" && updates == ["你好"], "CLI invocation did not deliver final text")
        try install("/bin/cat >/dev/null\nprintf '%s\\n' '{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"你\"}}}' '{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"你好\"}'\n")
        updates.removeAll()
        let claudeFinal = try await CLIRunner.translate("Hello", options: options(.claude), systemPrompt: "Translate") { updates.append($0) }
        checks += try require(claudeFinal == "你好" && updates == ["你", "你好"], "Claude cumulative output wrong")
        try install("printf '%s\\n' '{\"role\":\"assistant\",\"content\":\"你好\"}'\n")
        let kimiFinal = try await CLIRunner.translate("Hello", options: options(.kimi), systemPrompt: "Translate") { _ in }
        checks += try require(kimiFinal == "你好", "Kimi process output")
        try install("printf '%s\\n' '你好' '世界'\n")
        let dshFinal = try await CLIRunner.translate("Hello", options: options(.dsh), systemPrompt: "Translate") { _ in }
        checks += try require(dshFinal == "你好\n世界", "DSH final output")
        try install("/bin/cat >/dev/null\nprintf '%s\\n' 'unknown option --sk-sensitive-fixture' >&2\nexit 1\n")
        do {
            _ = try await CLIRunner.translate("Hello", options: options(.claude), systemPrompt: "Translate") { _ in }
            throw Failure(reason: "Failed CLI accepted")
        } catch let error as AppError {
            checks += try require(error.localizedDescription.contains("版本") && !error.localizedDescription.contains("sk-sensitive"), "CLI stderr classification incorrect")
        }

        let pids = directory.appendingPathComponent("pids")
        try install("/bin/cat >/dev/null\ntrap '' TERM\n/bin/sleep 20 &\necho \"$$ $!\" > '\(pids.path)'\nprintf '%s\\n' '{\"type\":\"item.updated\",\"item\":{\"type\":\"agent_message\",\"text\":\"开始\"}}'\nwait\n")
        var started = false
        let task = Task { try await CLIRunner.translate("Cancel", options: options(.codex), systemPrompt: "Translate") { _ in started = true } }
        for _ in 0..<200 where !started { try await Task.sleep(nanoseconds: 10_000_000) }
        checks += try require(started, "CLI cancel fixture did not start")
        let processIDs = try String(contentsOf: pids, encoding: .utf8).split(separator: " ").compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        checks += try require(processIDs.count == 2, "CLI child fixture missing")
        let start = Date()
        task.cancel()
        do { _ = try await task.value; throw Failure(reason: "Cancelled CLI succeeded") }
        catch is CancellationError { checks += 1 }
        checks += try require(Date().timeIntervalSince(start) < 1, "CLI cancellation blocked UI")
        for _ in 0..<200 where processIDs.contains(where: { kill($0, 0) == 0 }) { try await Task.sleep(nanoseconds: 10_000_000) }
        checks += try require(processIDs.allSatisfy({ kill($0, 0) != 0 }), "Cancelled CLI process tree survived")

        try install("while :; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n'; done\n")
        let oversized = try CLIProcessBridge(executable: executable.path, arguments: [], input: Data(), directory: directory, maximumOutputBytes: 512)
        do {
            for try await _ in oversized.lines {}
            throw Failure(reason: "Oversized CLI output accepted")
        } catch is AppError { checks += 1 }
        _ = await oversized.exitStatus()
        try install("exec /bin/sleep 20\n")
        let timed = try CLIProcessBridge(executable: executable.path, arguments: [], input: Data(), directory: directory, timeoutSeconds: 0.1)
        do {
            for try await _ in timed.lines {}
            throw Failure(reason: "CLI timeout did not fail")
        } catch is AppError { checks += 1 }
        _ = await timed.exitStatus()
        return checks
    }
}

@MainActor
func runCLIChecks() async throws -> Int { try await CLIChecks.run() }
