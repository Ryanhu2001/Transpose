//! Local CLI adapters. Discovery only inspects paths; it never launches a CLI.
//! npm shims are resolved to Node entry points and are never passed to cmd.exe.

use serde_json::{json, Value};
use std::collections::HashSet;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::Command;

const MAX_OUTPUT: usize = 2_000_000;
const MAX_DIAGNOSTIC: usize = 16_384;
const CLI_TIMEOUT: Duration = Duration::from_secs(60);
const PROVIDERS: [&str; 4] = ["codex", "dsh", "claude", "kimi"];

pub fn discover() -> Vec<Value> {
    let roots = search_directories();
    PROVIDERS
        .iter()
        .filter_map(|provider| {
            locate(provider, &roots)
                .map(|path| json!({"provider": provider, "path": path.to_string_lossy()}))
        })
        .collect()
}

fn search_directories() -> Vec<PathBuf> {
    let mut roots: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|path| std::env::split_paths(&path).collect())
        .unwrap_or_default();
    if let Some(home) = std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME")) {
        let home = PathBuf::from(home);
        roots.extend([
            home.join(".local/bin"),
            home.join(".kimi-code/bin"),
            home.join(".cargo/bin"),
            home.join(".bun/bin"),
            home.join(".npm-global/bin"),
            home.join(".volta/bin"),
            home.join("scoop/shims"),
        ]);
    }
    if let Some(appdata) = std::env::var_os("APPDATA") {
        roots.push(PathBuf::from(appdata).join("npm"));
    }
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        roots.extend([
            PathBuf::from(&local).join("Microsoft/WinGet/Links"),
            PathBuf::from(local).join("Programs/nodejs"),
        ]);
    }
    let mut seen = HashSet::new();
    // Relative PATH entries must not select a project-local executable.
    roots.retain(|path| path.is_absolute() && seen.insert(path.to_string_lossy().to_lowercase()));
    roots
}

fn locate(name: &str, roots: &[PathBuf]) -> Option<PathBuf> {
    #[cfg(windows)]
    let extensions = ["exe", "cmd", "bat", ""];
    #[cfg(not(windows))]
    let extensions = [""];
    roots.iter().find_map(|root| {
        extensions.iter().find_map(|extension| {
            let filename = if extension.is_empty() {
                name.to_owned()
            } else {
                format!("{name}.{extension}")
            };
            let path = root.join(filename);
            if !path.is_file() {
                return None;
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                if path.metadata().ok()?.permissions().mode() & 0o111 == 0 {
                    return None;
                }
            }
            Some(path)
        })
    })
}

pub async fn translate(
    provider: &str,
    path: &str,
    model: &str,
    prompt: &str,
    text: &str,
    on_delta: &(dyn Fn(String) + Send + Sync),
) -> Result<String, String> {
    if !PROVIDERS.contains(&provider) {
        return Err("Choose a supported local CLI.".into());
    }
    let executable = if path.trim().is_empty() {
        locate(provider, &search_directories())
    } else {
        Some(PathBuf::from(path.trim()))
    }
    .filter(|candidate| candidate.is_absolute() && candidate.is_file())
    .ok_or_else(|| {
        format!(
            "{} was not found. Scan or enter its executable path.",
            title(provider)
        )
    })?;
    let directory = TemporaryDirectory::new()?;
    let invocation = Invocation::make(provider, model, prompt, text, &directory.0)?;
    let (program, prefix) = resolve_program(&executable)?;
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        let command_size = std::iter::once(program.as_os_str())
            .chain(prefix.iter().map(OsString::as_os_str))
            .chain(invocation.arguments.iter().map(OsString::as_os_str))
            .map(|argument| argument.encode_wide().count().saturating_mul(2) + 3)
            .sum::<usize>();
        if command_size > 30_000 {
            return Err("The source text is too long for this CLI on Windows. Select less text or use an API service.".into());
        }
    }
    let mut command = Command::new(program);
    command
        .args(prefix)
        .args(&invocation.arguments)
        .current_dir(&directory.0)
        .envs(invocation.environment.iter().copied())
        .env("NO_COLOR", "1")
        .env("TERM", "dumb")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    #[cfg(windows)]
    command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    let mut child = command.spawn().map_err(|_| {
        format!(
            "{} could not start. Check its installation and path.",
            title(provider)
        )
    })?;
    #[cfg(windows)]
    let _job = ProcessJob::attach(&child)?;
    let stdin = child.stdin.take().ok_or("CLI input is unavailable.")?;
    let stdout = child.stdout.take().ok_or("CLI output is unavailable.")?;
    let stderr = child
        .stderr
        .take()
        .ok_or("CLI diagnostics are unavailable.")?;
    let operation = async {
        let write = async {
            let mut stdin = stdin;
            stdin.write_all(&invocation.input).await.map_err(|_| {
                format!(
                    "{} stopped before accepting the source text.",
                    title(provider)
                )
            })?;
            stdin
                .shutdown()
                .await
                .map_err(|_| "Could not finish CLI input.".to_owned())
        };
        let wait = async {
            child
                .wait()
                .await
                .map_err(|_| "Could not read the CLI exit status.".to_owned())
        };
        let (output, diagnostic, (), status) = tokio::try_join!(
            read_output(stdout, provider, on_delta),
            read_diagnostic(stderr),
            write,
            wait
        )?;
        if !status.success() {
            return Err(classify_error(&diagnostic, provider));
        }
        let final_output = output.trim().to_owned();
        if final_output.is_empty() {
            return Err(format!(
                "{} returned no translation. Check its model and login.",
                title(provider)
            ));
        }
        if final_output != output {
            on_delta(final_output.clone());
        }
        Ok(final_output)
    };
    match tokio::time::timeout(CLI_TIMEOUT, operation).await {
        Ok(result) => result,
        Err(_) => {
            let _ = child.kill().await;
            Err(format!(
                "{} took too long. Try again or choose a faster model.",
                title(provider)
            ))
        }
    }
}

struct TemporaryDirectory(PathBuf);

impl TemporaryDirectory {
    fn new() -> Result<Self, String> {
        let path = std::env::temp_dir().join(format!("Transpose-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&path).map_err(|_| "Could not create the CLI working directory.")?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))
                .map_err(|_| "Could not secure the CLI working directory.")?;
        }
        Ok(Self(path))
    }
}

impl Drop for TemporaryDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct Invocation {
    arguments: Vec<OsString>,
    input: Vec<u8>,
    environment: Vec<(&'static str, &'static str)>,
}

impl Invocation {
    fn make(
        provider: &str,
        model: &str,
        prompt: &str,
        text: &str,
        directory: &Path,
    ) -> Result<Self, String> {
        let model = model.trim();
        let mut args: Vec<OsString> = Vec::new();
        let mut input = Vec::new();
        let mut environment = Vec::new();
        match provider {
            "codex" => {
                args.extend(
                    [
                        "exec",
                        "--ephemeral",
                        "--skip-git-repo-check",
                        "--ignore-user-config",
                        "--ignore-rules",
                        "--sandbox",
                        "read-only",
                        "--json",
                        "--color",
                        "never",
                        "-C",
                    ]
                    .map(OsString::from),
                );
                args.push(directory.as_os_str().to_owned());
                args.extend(
                    [
                        "-c",
                        "model_reasoning_effort=\"low\"",
                        "-c",
                        "web_search=\"disabled\"",
                        "-c",
                        "project_doc_max_bytes=0",
                    ]
                    .map(OsString::from),
                );
                if !model.is_empty() {
                    args.extend(["-m", model].map(OsString::from));
                }
                for feature in [
                    "apps",
                    "plugins",
                    "memories",
                    "shell_tool",
                    "browser_use",
                    "browser_use_external",
                    "computer_use",
                    "image_generation",
                    "view_image",
                    "multi_agent",
                    "multi_agent_v2",
                    "hooks",
                    "skill_search",
                    "sleep_tool",
                    "tool_suggest",
                    "workspace_dependencies",
                    "in_app_browser",
                ] {
                    args.extend([
                        OsString::from("-c"),
                        OsString::from(format!("features.{feature}=false")),
                    ]);
                }
                args.extend(
                    ["-c", "features.skip_host_skill_discovery=true", "-"].map(OsString::from),
                );
                input = format!("{prompt}\n\nSOURCE TEXT TO TRANSLATE:\n{text}").into_bytes();
            }
            "claude" => {
                let prompt_file = directory.join("translation-prompt.txt");
                write_private(&prompt_file, prompt)?;
                args.extend(
                    [
                        "--print",
                        "--safe-mode",
                        "--tools",
                        "",
                        "--strict-mcp-config",
                        "--disable-slash-commands",
                        "--permission-mode",
                        "dontAsk",
                        "--permission-prompts",
                        "none",
                        "--no-chrome",
                        "--no-session-persistence",
                        "--output-format",
                        "stream-json",
                        "--verbose",
                        "--include-partial-messages",
                        "--system-prompt-file",
                    ]
                    .map(OsString::from),
                );
                args.push(prompt_file.into_os_string());
                args.extend(
                    [
                        "--settings",
                        "{\"disableAllHooks\":true}",
                        "--effort",
                        "low",
                    ]
                    .map(OsString::from),
                );
                if !model.is_empty() {
                    args.extend(["--model", model].map(OsString::from));
                }
                input = text.as_bytes().to_vec();
            }
            "kimi" => {
                let agent = directory.join("transpose-translator.md");
                let skills = directory.join("skills");
                std::fs::create_dir(&skills)
                    .map_err(|_| "Could not create the isolated CLI skills directory.")?;
                write_private(&agent, &format!("---\nname: transpose-translator\ndescription: Translate the supplied source text faithfully.\ntools: []\nsubagents: []\n---\n\n{prompt}"))?;
                args.extend([
                    OsString::from("--agent-file"),
                    agent.into_os_string(),
                    OsString::from("--skills-dir"),
                    skills.into_os_string(),
                ]);
                args.extend(["--output-format", "stream-json"].map(OsString::from));
                if !model.is_empty() {
                    args.extend(["--model", model].map(OsString::from));
                }
                args.extend(["--prompt", text].map(OsString::from));
                environment.push(("KIMI_DISABLE_TELEMETRY", "1"));
            }
            "dsh" => {
                let plugin = directory.join("transpose-translation.mjs");
                let patch = directory.join("transpose-translation.patch.yml");
                let prompt_json = json!(prompt).to_string();
                let model_json = json!(model).to_string();
                let source = format!(
                    r#"export const name = "transpose-translation";
export const inject = ["tools", "systemPrompt"];
export function apply(ctx) {{
  ctx.tools.guard(() => "Tools are disabled for this translation request.");
  ctx.systemPrompt.suppressRuntimeContext();
  ctx.systemPrompt.section({{ name: "transpose:translation", order: -1000, complete: true, text: {prompt_json} }});
  ctx.on("system-prompt/assemble", async (_assembly, _context, next) => {{
    const assembled = await next();
    return {{ ...assembled, tools: [], contexts: [] }};
  }});
  let requests = 0;
  ctx.on("agent/request", async (_event, next) => {{
    if (++requests > 1) throw new Error("Translation allows one model request.");
    const config = await next();
    const model = {model_json};
    return {{ ...config, ...(model ? {{ model }} : {{}}), maxTokens: 16384 }};
  }});
}}
"#
                );
                write_private(&plugin, &source)?;
                let disabled = [
                    "session-title-llm",
                    "session-persistence-jsonl",
                    "session-checkpoint-policy",
                    "session-telemetry-otel",
                    "agent-instructions",
                    "skill-filesystem",
                    "tool-skill",
                    "tool-bash",
                    "tool-pwsh",
                    "tool-fs",
                    "tool-fs-search",
                    "tool-jobs",
                    "tool-subagent",
                    "tool-subagent-fork",
                    "tool-subagent-control",
                    "tool-subagent-list-agents",
                    "tool-subagent-report",
                    "tool-workflow",
                    "tool-goal",
                    "tool-ralph",
                    "tool-str-replace-editor",
                    "tool-todo",
                    "tool-web",
                    "code-runtime",
                ];
                let mut yaml = disabled
                    .iter()
                    .map(|name| format!("- id: {name}\n  disabled: true\n"))
                    .collect::<String>();
                yaml.push_str("- id: system-prompt\n  config:\n    includeHarnessIdentity: false\n    includeRuntimeContext: false\n    persona: ''\n- id: tools\n  config:\n    mode: native\n");
                yaml.push_str(&format!(
                    "- insert:\n    - id: transpose-translation\n      name: {}\n",
                    json!(file_url(&plugin))
                ));
                write_private(&patch, &yaml)?;
                args.extend([
                    OsString::from("--profile"),
                    OsString::from("headless"),
                    OsString::from("--patch"),
                    patch.into_os_string(),
                    OsString::from("--"),
                    OsString::from(text),
                ]);
                environment.extend([
                    ("DSH_TELEMETRY_DISABLED", "1"),
                    ("DSH_PERMISSION_MODE", "read-only"),
                ]);
            }
            _ => return Err("Choose a supported local CLI.".into()),
        }
        Ok(Self {
            arguments: args,
            input,
            environment,
        })
    }
}

fn file_url(path: &Path) -> String {
    let normalized = path.to_string_lossy().replace('\\', "/");
    let mut encoded = String::new();
    for byte in normalized.as_bytes() {
        if byte.is_ascii_alphanumeric() || b"/-._~:".contains(byte) {
            encoded.push(*byte as char);
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    if normalized.starts_with('/') {
        format!("file://{encoded}")
    } else {
        format!("file:///{encoded}")
    }
}

fn write_private(path: &Path, value: &str) -> Result<(), String> {
    std::fs::write(path, value).map_err(|_| "Could not prepare the isolated CLI request.")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .map_err(|_| "Could not secure the isolated CLI request.")?;
    }
    Ok(())
}

fn resolve_program(executable: &Path) -> Result<(PathBuf, Vec<OsString>), String> {
    #[cfg(windows)]
    {
        let extension = executable
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        if extension == "exe" || extension == "com" {
            return Ok((executable.to_owned(), Vec::new()));
        }
        if !["cmd", "bat", "js", "cjs", "mjs", ""].contains(&extension.as_str()) {
            return Err("Choose the CLI executable or its npm .cmd launcher.".into());
        }
        let root = executable.parent().ok_or("The CLI path is invalid.")?;
        let entry = if ["js", "cjs", "mjs"].contains(&extension.as_str()) {
            executable.to_owned()
        } else {
            let content = read_small_file(executable, 65_536)?;
            if extension.is_empty() && content.lines().next().unwrap_or("").contains("node") {
                executable.to_owned()
            } else {
                let relative = node_shim_entry(&content).ok_or(
                    "This CLI launcher is unsupported. Choose its .exe or JavaScript entry point.",
                )?;
                let candidate = root.join(relative.replace('\\', "/"));
                if !candidate.is_file() {
                    return Err("The npm CLI entry point is missing. Reinstall the CLI.".into());
                }
                candidate
            }
        };
        let sibling = root.join("node.exe");
        let node = if sibling.is_file() {
            Some(sibling)
        } else {
            locate("node", &search_directories())
        }
        .filter(|path| {
            path.extension()
                .and_then(|extension| extension.to_str())
                .is_some_and(|extension| extension.eq_ignore_ascii_case("exe"))
        })
        .ok_or("Node.js was not found. Install Node.js or choose a standalone CLI executable.")?;
        return Ok((node, vec![entry.into_os_string()]));
    }
    #[cfg(not(windows))]
    Ok((executable.to_owned(), Vec::new()))
}

#[cfg(windows)]
fn read_small_file(path: &Path, maximum: u64) -> Result<String, String> {
    use std::io::Read;
    let file = std::fs::File::open(path).map_err(|_| "Could not read the CLI launcher.")?;
    let mut bytes = Vec::new();
    file.take(maximum + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "Could not read the CLI launcher.")?;
    if bytes.len() as u64 > maximum {
        return Err("The CLI launcher is unexpectedly large. Choose its executable.".into());
    }
    String::from_utf8(bytes).map_err(|_| "Choose the CLI .exe or npm .cmd launcher.".into())
}

/// Extract only a quoted, directory-relative Node entry point. No shell syntax is run.
#[cfg(any(windows, test))]
fn node_shim_entry(source: &str) -> Option<String> {
    source.split('"').skip(1).step_by(2).find_map(|quoted| {
        let lower = quoted.to_ascii_lowercase();
        let suffix = if lower.starts_with("%dp0%") {
            &quoted[5..]
        } else if lower.starts_with("%~dp0") {
            &quoted[5..]
        } else {
            return None;
        };
        let suffix = suffix.trim_start_matches(['\\', '/']);
        let normalized = suffix.replace('\\', "/");
        let lower = normalized.to_ascii_lowercase();
        if !(lower.ends_with(".js") || lower.ends_with(".cjs") || lower.ends_with(".mjs"))
            || !lower.starts_with("node_modules/")
            || normalized
                .split('/')
                .any(|part| part.is_empty() || part == ".." || part == ".")
            || normalized.contains(['%', '\r', '\n', ':', '"'])
        {
            return None;
        }
        Some(normalized)
    })
}

#[derive(Debug, PartialEq)]
enum TextUpdate {
    Append(String),
    Replace(String),
}

fn parse_line(provider: &str, line: &str) -> Result<Option<TextUpdate>, String> {
    if provider == "dsh" {
        return Ok(Some(TextUpdate::Append(format!("{line}\n"))));
    }
    let event: Value = match serde_json::from_str(line) {
        Ok(value) => value,
        Err(_) => return Ok(None),
    };
    let kind = event["type"].as_str().unwrap_or("");
    match provider {
        "codex" => {
            if kind == "error" || kind == "turn.failed" {
                return Err(classify_error("", provider));
            }
            if event["phase"] == "commentary" {
                return Ok(None);
            }
            if [
                "agent_message.delta",
                "item.agent_message.delta",
                "response.output_text.delta",
            ]
            .contains(&kind)
            {
                return Ok(event["delta"]
                    .as_str()
                    .map(|text| TextUpdate::Append(text.into())));
            }
            if ["item.started", "item.updated", "item.completed"].contains(&kind) {
                let item = &event["item"];
                if item["type"] == "agent_message" && item["phase"] != "commentary" {
                    return Ok(item["text"]
                        .as_str()
                        .filter(|text| !text.is_empty())
                        .map(|text| TextUpdate::Replace(text.into())));
                }
            }
            if kind == "agent_message" {
                return Ok(event["text"]
                    .as_str()
                    .map(|text| TextUpdate::Replace(text.into())));
            }
        }
        "claude" => {
            if !event["parent_tool_use_id"].is_null() {
                return Ok(None);
            }
            if kind == "result" {
                if event["is_error"].as_bool() == Some(true)
                    || event["subtype"]
                        .as_str()
                        .is_some_and(|value| value != "success")
                {
                    return Err(classify_error(
                        event["result"].as_str().unwrap_or(""),
                        provider,
                    ));
                }
                return Ok(event["result"]
                    .as_str()
                    .map(|text| TextUpdate::Replace(text.into())));
            }
            if kind == "stream_event"
                && event["event"]["type"] == "content_block_delta"
                && event["event"]["delta"]["type"] == "text_delta"
            {
                return Ok(event["event"]["delta"]["text"]
                    .as_str()
                    .map(|text| TextUpdate::Append(text.into())));
            }
        }
        "kimi" => {
            if !event["error"].is_null() {
                return Err(classify_error("", provider));
            }
            let message = event.get("message").unwrap_or(&event);
            if message["role"] != "assistant" {
                return Ok(None);
            }
            if message["tool_calls"]
                .as_array()
                .is_some_and(|calls| !calls.is_empty())
            {
                return Err(
                    "Kimi requested a tool operation outside translation. The request was stopped."
                        .into(),
                );
            }
            if let Some(text) = message["content"].as_str() {
                return Ok(Some(TextUpdate::Replace(text.into())));
            }
            if let Some(blocks) = message["content"].as_array() {
                let text = blocks
                    .iter()
                    .filter(|block| block["type"] == "text")
                    .filter_map(|block| block["text"].as_str())
                    .collect::<String>();
                if !text.is_empty() {
                    return Ok(Some(TextUpdate::Replace(text)));
                }
            }
        }
        _ => {}
    }
    Ok(None)
}

async fn read_output(
    mut reader: impl AsyncRead + Unpin,
    provider: &str,
    on_delta: &(dyn Fn(String) + Send + Sync),
) -> Result<String, String> {
    let mut buffer = [0; 8192];
    let mut pending = Vec::new();
    let mut count = 0usize;
    let mut result = String::new();
    loop {
        let size = reader
            .read(&mut buffer)
            .await
            .map_err(|_| "Could not read CLI output.")?;
        if size == 0 {
            break;
        }
        count += size;
        if count > MAX_OUTPUT {
            return Err("CLI output exceeded the translation limit.".into());
        }
        pending.extend_from_slice(&buffer[..size]);
        while let Some(end) = pending.iter().position(|byte| *byte == b'\n') {
            let line = String::from_utf8_lossy(&pending[..end])
                .trim_end_matches('\r')
                .to_owned();
            apply_line(provider, &line, &mut result, on_delta)?;
            pending.drain(..=end);
        }
    }
    if !pending.is_empty() {
        apply_line(
            provider,
            &String::from_utf8_lossy(&pending),
            &mut result,
            on_delta,
        )?;
    }
    Ok(result)
}

fn apply_line(
    provider: &str,
    line: &str,
    result: &mut String,
    on_delta: &(dyn Fn(String) + Send + Sync),
) -> Result<(), String> {
    match parse_line(provider, line)? {
        Some(TextUpdate::Append(delta)) => result.push_str(&delta),
        Some(TextUpdate::Replace(value)) => *result = value,
        None => return Ok(()),
    }
    if result.len() > MAX_OUTPUT {
        return Err("CLI output exceeded the translation limit.".into());
    }
    if !result.is_empty() {
        on_delta(result.clone());
    }
    Ok(())
}

async fn read_diagnostic(mut reader: impl AsyncRead + Unpin) -> Result<String, String> {
    let mut buffer = [0; 4096];
    let mut bytes = Vec::new();
    loop {
        let size = reader
            .read(&mut buffer)
            .await
            .map_err(|_| "Could not read CLI status.")?;
        if size == 0 {
            break;
        }
        let remaining = MAX_DIAGNOSTIC.saturating_sub(bytes.len());
        bytes.extend_from_slice(&buffer[..size.min(remaining)]);
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn title(provider: &str) -> &str {
    match provider {
        "codex" => "Codex CLI",
        "dsh" => "DeepSeek CLI",
        "claude" => "Claude Code",
        "kimi" => "Kimi Code",
        _ => "CLI",
    }
}

/// Untrusted third-party diagnostics are classified, never shown verbatim.
fn classify_error(diagnostic: &str, provider: &str) -> String {
    let text = diagnostic.to_lowercase();
    let title = title(provider);
    let groups = [
        (
            &[
                "unknown option",
                "unrecognized option",
                "unexpected argument",
                "unknown argument",
                "unsupported option",
            ][..],
            "version does not support the required options. Update the CLI and try again.",
        ),
        (
            &[
                "rate limit",
                "usage limit",
                "quota",
                "credit balance",
                "insufficient balance",
                "billing",
                "exceeded your",
                "hit your limit",
                "limit reached",
            ][..],
            "has reached its usage limit. Check the account and try again.",
        ),
        (
            &[
                "not logged in",
                "log in",
                "login",
                "authenticate",
                "authentication",
                "invalid api key",
                "api key is required",
                "no api key",
                "no credential configured",
                "credentials missing",
                "token expired",
                "unauthorized",
                "401",
            ][..],
            "is not logged in or its session has expired. Sign in from a terminal.",
        ),
        (
            &[
                "no model",
                "unknown model",
                "model not found",
                "model is not",
                "invalid model",
                "model does not",
                "model_not_found",
            ][..],
            "model is unavailable. Check its default model or the model in Settings.",
        ),
        (
            &[
                "network",
                "connect",
                "fetch failed",
                "timed out",
                "dns",
                "enotfound",
                "econnrefused",
            ][..],
            "could not reach the model service. Check the network and CLI service address.",
        ),
        (
            &[
                "plugin tree failed",
                "failed to load",
                "config",
                "pending (waiting",
                "enoent",
                "cannot find module",
                "typeerror",
                "syntaxerror",
            ][..],
            "configuration or plugins could not start. Check the CLI from a terminal.",
        ),
        (
            &["permission denied", "operation not permitted", "eacces"][..],
            "could not access its files. Check its path and permissions.",
        ),
    ];
    for (patterns, message) in groups {
        if patterns.iter().any(|pattern| text.contains(pattern)) {
            return format!("{title} {message}");
        }
    }
    format!("{title} translation failed. Check its login, model, and version.")
}

/// Closing this Job Object terminates CLI helpers as well as the direct process.
#[cfg(windows)]
struct ProcessJob {
    _handle: std::os::windows::io::OwnedHandle,
}

#[cfg(windows)]
impl ProcessJob {
    fn attach(child: &tokio::process::Child) -> Result<Self, String> {
        use std::ffi::c_void;
        use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
        #[repr(C)]
        #[derive(Default)]
        struct BasicLimits {
            per_process_user_time: i64,
            per_job_user_time: i64,
            flags: u32,
            minimum_working_set: usize,
            maximum_working_set: usize,
            active_process_limit: u32,
            affinity: usize,
            priority_class: u32,
            scheduling_class: u32,
        }
        #[repr(C)]
        #[derive(Default)]
        struct ExtendedLimits {
            basic: BasicLimits,
            io: [u64; 6],
            process_memory_limit: usize,
            job_memory_limit: usize,
            peak_process_memory_used: usize,
            peak_job_memory_used: usize,
        }
        #[link(name = "kernel32")]
        extern "system" {
            fn CreateJobObjectW(attributes: *const c_void, name: *const u16) -> *mut c_void;
            fn SetInformationJobObject(
                job: *mut c_void,
                class: i32,
                info: *const c_void,
                size: u32,
            ) -> i32;
            fn AssignProcessToJobObject(job: *mut c_void, process: *mut c_void) -> i32;
        }
        let raw = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
        if raw.is_null() {
            return Err("Could not isolate the CLI process.".into());
        }
        let handle = unsafe { OwnedHandle::from_raw_handle(raw) };
        let mut limits = ExtendedLimits::default();
        limits.basic.flags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        let configured = unsafe {
            SetInformationJobObject(
                handle.as_raw_handle(),
                9,
                &limits as *const _ as *const c_void,
                std::mem::size_of_val(&limits) as u32,
            )
        };
        let process = child
            .raw_handle()
            .ok_or("The CLI exited before it could be isolated.")?;
        if configured == 0
            || unsafe { AssignProcessToJobObject(handle.as_raw_handle(), process) } == 0
        {
            return Err("Could not isolate the CLI process. Try a standalone executable.".into());
        }
        Ok(Self { _handle: handle })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn npm_shims_resolve_without_running_shell() {
        let shim = r#"@ECHO off
"%_prog%" "%dp0%\node_modules\@openai\codex\bin\codex.js" %*
"#;
        assert_eq!(
            node_shim_entry(shim).as_deref(),
            Some("node_modules/@openai/codex/bin/codex.js")
        );
        assert!(node_shim_entry(r#"node "%dp0%\..\outside.js" %*"#).is_none());
        assert!(node_shim_entry(r#"node "%dp0%\node_modules\%EVIL%\entry.js" %*"#).is_none());
        assert!(node_shim_entry(r#"cmd /c echo untrusted && node arbitrary.js"#).is_none());
    }

    #[test]
    fn codex_outputs_only_assistant_text() {
        for line in [
            r#"{"type":"item.completed","item":{"type":"reasoning","text":"secret"}}"#,
            r#"{"type":"item.completed","item":{"type":"command_execution","aggregated_output":"secret"}}"#,
            r#"{"type":"item.completed","item":{"type":"agent_message","phase":"commentary","text":"secret"}}"#,
        ] {
            assert_eq!(parse_line("codex", line).unwrap(), None);
        }
        assert_eq!(
            parse_line(
                "codex",
                r#"{"type":"response.output_text.delta","delta":"好"}"#
            )
            .unwrap(),
            Some(TextUpdate::Append("好".into()))
        );
        assert_eq!(
            parse_line(
                "codex",
                r#"{"type":"item.completed","item":{"type":"agent_message","text":"你好"}}"#
            )
            .unwrap(),
            Some(TextUpdate::Replace("你好".into()))
        );
        assert!(!parse_line(
            "codex",
            r#"{"type":"turn.failed","error":{"message":"secret-fixture"}}"#
        )
        .unwrap_err()
        .contains("secret-fixture"));
    }

    #[test]
    fn claude_outputs_stream_and_authoritative_final() {
        assert_eq!(parse_line("claude", r#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"secret"}}}"#).unwrap(), None);
        assert_eq!(parse_line("claude", r#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"你"}}}"#).unwrap(), Some(TextUpdate::Append("你".into())));
        assert_eq!(
            parse_line(
                "claude",
                r#"{"type":"assistant","message":{"content":[{"type":"text","text":"你好"}]}}"#
            )
            .unwrap(),
            None
        );
        assert_eq!(
            parse_line(
                "claude",
                r#"{"type":"result","subtype":"success","result":"你好"}"#
            )
            .unwrap(),
            Some(TextUpdate::Replace("你好".into()))
        );
        assert!(!parse_line(
            "claude",
            r#"{"type":"result","is_error":true,"result":"unknown option --secret-fixture"}"#
        )
        .unwrap_err()
        .contains("secret-fixture"));
    }

    #[test]
    fn kimi_rejects_tools_and_omits_thinking() {
        assert_eq!(
            parse_line("kimi", r#"{"role":"tool","content":"secret"}"#).unwrap(),
            None
        );
        assert_eq!(parse_line("kimi", r#"{"role":"assistant","content":[{"type":"thinking","text":"secret"},{"type":"text","text":"你好"}]}"#).unwrap(), Some(TextUpdate::Replace("你好".into())));
        assert!(parse_line(
            "kimi",
            r#"{"role":"assistant","tool_calls":[{"function":{"name":"Bash"}}]}"#
        )
        .is_err());
    }

    #[test]
    fn adapters_keep_text_literal_and_disable_tools() {
        let directory = TemporaryDirectory::new().unwrap();
        let text = "Hello %PATH% & echo unsafe \"quoted\"\n--not-an-option";
        for provider in PROVIDERS {
            let invocation =
                Invocation::make(provider, "fixture", "Translate only.", text, &directory.0)
                    .unwrap();
            assert!(!invocation
                .arguments
                .iter()
                .any(|arg| arg == "--dangerously-skip-permissions"));
            if provider == "codex" || provider == "claude" {
                assert!(String::from_utf8_lossy(&invocation.input).contains(text));
                assert!(!invocation.arguments.iter().any(|arg| arg == text));
            } else {
                assert_eq!(invocation.arguments.last(), Some(&OsString::from(text)));
            }
        }
        let dsh = std::fs::read_to_string(directory.0.join("transpose-translation.mjs")).unwrap();
        assert!(
            dsh.contains("ctx.tools.guard")
                && dsh.contains("tools: []")
                && dsh.contains("++requests > 1")
        );
        let agent = std::fs::read_to_string(directory.0.join("transpose-translator.md")).unwrap();
        assert!(agent.contains("tools: []") && agent.contains("subagents: []"));
    }

    #[test]
    fn errors_never_include_raw_diagnostics() {
        for diagnostic in [
            "secret-fixture",
            "unknown option --secret-fixture",
            "invalid api key sk-secret-fixture",
            "config secret-fixture",
        ] {
            assert!(!classify_error(diagnostic, "codex").contains("secret-fixture"));
        }
    }

    #[test]
    fn plugin_file_url_encodes_unicode_and_reserved_characters() {
        assert_eq!(
            file_url(Path::new("C:\\Users\\test name\\插件.mjs")),
            "file:///C:/Users/test%20name/%E6%8F%92%E4%BB%B6.mjs"
        );
    }

    #[tokio::test]
    async fn streaming_preserves_split_utf8_and_bounds_memory() {
        let (mut writer, reader) = tokio::io::duplex(16);
        let send = async {
            writer.write_all("你好\n世界".as_bytes()).await.unwrap();
            writer.shutdown().await.unwrap();
        };
        let read = read_output(reader, "dsh", &|_| {});
        let ((), output) = tokio::join!(send, read);
        assert_eq!(output.unwrap(), "你好\n世界\n");
        let bytes = vec![b'x'; MAX_OUTPUT + 1];
        assert!(read_output(bytes.as_slice(), "dsh", &|_| {}).await.is_err());
        let bytes = vec![b'x'; MAX_DIAGNOSTIC + 100];
        assert_eq!(
            read_diagnostic(bytes.as_slice()).await.unwrap().len(),
            MAX_DIAGNOSTIC
        );
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn windows_node_fixtures_receive_literal_source_and_no_shell() {
        let directory = TemporaryDirectory::new().unwrap();
        let fixture = directory.0.join("fixture.js");
        write_private(
            &fixture,
            r#"
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", value => input += value);
process.stdin.on("end", () => {
  const args = process.argv.slice(2);
  let text = input;
  let output;
  if (args[0] === "exec") {
    text = input.split("SOURCE TEXT TO TRANSLATE:\n")[1];
    output = { type: "item.completed", item: { type: "agent_message", text } };
  } else if (args.includes("--print")) {
    output = { type: "result", subtype: "success", result: text };
  } else if (args.includes("--agent-file")) {
    text = args[args.indexOf("--prompt") + 1];
    output = { role: "assistant", content: text };
  } else {
    text = args[args.indexOf("--") + 1];
    process.stdout.write(text);
    return;
  }
  process.stdout.write(JSON.stringify(output) + "\n");
});
"#,
        )
        .unwrap();
        let source = "你好 %PATH% & echo PWNED \"quoted\" 'single' `code`\nsecond line";
        for provider in PROVIDERS {
            let output = translate(
                provider,
                fixture.to_str().unwrap(),
                "fixture",
                "Translate only.",
                source,
                &|_| {},
            )
            .await
            .unwrap();
            assert_eq!(output, source, "{provider} altered the source argument");
        }
        let npm_directory = directory.0.join("node_modules/fixture");
        std::fs::create_dir_all(&npm_directory).unwrap();
        std::fs::copy(&fixture, npm_directory.join("entry.js")).unwrap();
        let npm_shim = directory.0.join("codex.cmd");
        write_private(
            &npm_shim,
            "@ECHO off\n\"%_prog%\" \"%dp0%\\node_modules\\fixture\\entry.js\" %*\n",
        )
        .unwrap();
        let output = translate(
            "codex",
            npm_shim.to_str().unwrap(),
            "fixture",
            "Translate only.",
            source,
            &|_| {},
        )
        .await
        .unwrap();
        assert_eq!(output, source);

        write_private(
            &fixture,
            "process.stderr.write('unknown option --secret-fixture'); process.exit(1);",
        )
        .unwrap();
        let error = translate(
            "codex",
            fixture.to_str().unwrap(),
            "fixture",
            "Translate only.",
            source,
            &|_| {},
        )
        .await
        .unwrap_err();
        assert!(!error.contains("secret-fixture"));
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn cancelling_windows_cli_also_terminates_helpers() {
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;
        let directory = TemporaryDirectory::new().unwrap();
        let fixture = directory.0.join("cancel-fixture.js");
        let marker = directory.0.join("orphan-marker");
        let helper = format!(
            "setTimeout(() => require('fs').writeFileSync({}, 'orphan'), 1500);",
            json!(marker.to_string_lossy())
        );
        write_private(
            &fixture,
            &format!(
                "require('child_process').spawn(process.execPath, ['-e', {}], {{ stdio: 'ignore' }});\nprocess.stdout.write(JSON.stringify({{type:'item.updated',item:{{type:'agent_message',text:'ready'}}}})+'\\n');\nsetInterval(() => {{}}, 1000);",
                json!(helper)
            ),
        )
        .unwrap();
        let ready = Arc::new(AtomicBool::new(false));
        let callback_ready = ready.clone();
        let path = fixture.to_string_lossy().into_owned();
        let task = tokio::spawn(async move {
            translate(
                "codex",
                &path,
                "fixture",
                "Translate only.",
                "Hello",
                &move |_| {
                    callback_ready.store(true, Ordering::SeqCst);
                },
            )
            .await
        });
        for _ in 0..200 {
            if ready.load(Ordering::SeqCst) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(
            ready.load(Ordering::SeqCst),
            "Local CLI fixture did not start"
        );
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
        tokio::time::sleep(Duration::from_millis(1800)).await;
        assert!(!marker.exists(), "The cancelled CLI left a running helper");
    }
}
