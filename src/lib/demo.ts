import type { NativeTransport } from "./bridge";
import type {
  AppSnapshot,
  BridgeState,
  GlossaryEntry,
  NativeAction,
  NativeEvent,
  Payload,
  ProviderID,
  ResultState,
} from "./types";

// This in-memory adapter is enabled only by the explicit ?preview=1 flag.
// It does not access the network, credentials, disk, or system permissions.
export function createDemoTransport(): NativeTransport {
  const params = new URLSearchParams(location.search);
  const english = params.get("lang") !== "zh";
  const windows = params.get("platform") === "windows";
  const previewPermissions = params.get("permissions");
  const state: BridgeState = {
    app: {
      version: "0.7.0-dev",
      platform: windows ? "windows" : "macos",
      ...(windows
        ? {
            capabilities: {
              selection: true,
              screenCapture: true,
              ocr: params.get("ocr") !== "missing",
            },
          }
        : {}),
      language: english ? "english" : "simplifiedChinese",
      locale: english ? "en" : "zh-Hans",
      settings: {
        provider: windows ? "deepseek" : "apple",
        target: "smart",
        automaticSelection: true,
        preferences: "",
        baseURL: windows ? "https://api.deepseek.com" : "",
        model: windows ? "deepseek-flash" : "",
        cliPath: "",
        keyIsSaved: false,
      },
      providers: [
        {
          id: "apple",
          title: "Apple Translate",
          isAPI: false,
          isCLI: false,
          defaultBaseURL: "",
          defaultModel: "",
        },
        {
          id: "deepseek",
          title: "DeepSeek",
          isAPI: true,
          isCLI: false,
          defaultBaseURL: "https://api.deepseek.com",
          defaultModel: "deepseek-flash",
        },
        {
          id: "openrouter",
          title: "OpenRouter",
          isAPI: true,
          isCLI: false,
          defaultBaseURL: "https://openrouter.ai/api/v1",
          defaultModel: "openrouter/free",
        },
        {
          id: "customAPI",
          title: "Custom API",
          isAPI: true,
          isCLI: false,
          defaultBaseURL: "http://localhost:11434/v1",
          defaultModel: "",
        },
        ...(["codex", "dsh", "claude", "kimi"] as ProviderID[]).map((id) => ({
          id,
          title: {
            codex: "Codex CLI",
            dsh: "DeepSeek CLI",
            claude: "Claude Code",
            kimi: "Kimi Code",
          }[id as "codex"],
          isAPI: false,
          isCLI: true,
          defaultBaseURL: "",
          defaultModel: id === "codex" ? "gpt-6-luna" : "",
        })),
      ],
      glossary: [
        {
          id: "demo-1",
          source: "transpose",
          translation: "移调",
          note: "Music theory",
          enabled: true,
        },
        {
          id: "demo-2",
          source: "context window",
          translation: "上下文窗口",
          note: "",
          enabled: true,
        },
      ],
      detectedCLIs: [],
      permissions: {
        accessibility:
          previewPermissions === "partial" ||
          previewPermissions === "ready" ||
          previewPermissions === "restart",
        screenRecording: previewPermissions === "ready",
        screenRecordingNeedsRestart: previewPermissions === "restart",
      },
      loginItem: { status: "notRegistered" },
      apple: {
        supported: !windows,
        status: english
          ? "Language packs are managed by macOS."
          : "语言包由 macOS 管理。",
      },
      status: {
        credential: "",
        connection: "",
        testingConnection: false,
        glossary: "",
      },
    },
    result: null,
  };
  const listeners = new Set<(event: NativeEvent) => void>();
  const snapshot = () => structuredClone(state);
  const broadcast = () => {
    listeners.forEach((listener) =>
      listener({ type: "snapshot", data: structuredClone(state.app) }),
    );
    listeners.forEach((listener) =>
      listener({ type: "result", data: structuredClone(state.result) }),
    );
  };
  const sampleResult = (): ResultState => ({
    id: crypto.randomUUID(),
    source: "Good translation carries the thought, not just the words.",
    sourceApp: "Demo",
    sourceLanguage: "English",
    targetLanguage: "Simplified Chinese",
    output: "好的翻译，传达的不只是文字，更是文字背后的思想。",
    isLoading: false,
    loadingMessage: "",
    error: null,
    status: "Demo · no translation service was called",
    provider: windows ? "DeepSeek" : "Apple Translate",
    isPinned: false,
    canRetry: true,
  });
  if (location.hash === "#result") state.result = sampleResult();
  return {
    mode: "demo",
    subscribe: async (listener) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    request: async (action: NativeAction, payload: Payload = {}) => {
      switch (action) {
        case "app_restart":
          if (location.hash === "#result")
            throw new Error("Open Settings to reopen the app.");
          state.app.status.connection =
            state.app.locale === "zh-Hans"
              ? "演示模式：不会重新打开应用。"
              : "Demo: the app was not reopened.";
          break;
        case "set_language":
          state.app.language = payload.language as AppSnapshot["language"];
          state.app.locale =
            payload.language === "simplifiedChinese" ? "zh-Hans" : "en";
          break;
        case "update_settings":
          Object.assign(state.app.settings, payload);
          break;
        case "provider_select": {
          state.app.settings.provider = payload.provider as ProviderID;
          const provider = state.app.providers.find(
            (p) => p.id === payload.provider,
          )!;
          Object.assign(state.app.settings, {
            baseURL: provider.defaultBaseURL,
            model: provider.defaultModel,
            cliPath: "",
            keyIsSaved: false,
          });
          state.app.status.connection = "";
          break;
        }
        case "key_save":
          state.app.settings.keyIsSaved = true;
          state.app.status.credential = "Demo: key was not stored.";
          break;
        case "key_remove":
          state.app.settings.keyIsSaved = false;
          state.app.status.credential = "";
          break;
        case "connection_test":
          state.app.status.connection = "Demo: no connection was made.";
          break;
        case "apple_prepare":
          state.app.apple.status = "Demo: language packs are not downloaded.";
          break;
        case "permission":
          state.app.status.connection =
            "Demo: system permissions cannot be changed here.";
          break;
        case "login_set":
          state.app.loginItem.status = payload.enabled
            ? "enabled"
            : "notRegistered";
          break;
        case "glossary_upsert": {
          const entry = payload.entry as GlossaryEntry;
          const index = state.app.glossary.findIndex(
            (item) => item.id === entry.id,
          );
          if (index >= 0) state.app.glossary[index] = { ...entry };
          else state.app.glossary.push({ ...entry, id: crypto.randomUUID() });
          break;
        }
        case "glossary_delete":
          state.app.glossary = state.app.glossary.filter(
            (item) => item.id !== payload.id,
          );
          break;
        case "glossary_import":
          state.app.status.glossary = "Demo: no file was imported.";
          break;
        case "glossary_export":
          state.app.status.glossary = "Demo: no file was exported.";
          break;
        case "translate":
          state.result = sampleResult();
          break;
        case "result_pin":
          if (state.result) state.result.isPinned = Boolean(payload.pinned);
          break;
        case "result_close":
          state.result = null;
          break;
        case "result_retry":
          state.result = sampleResult();
          break;
        case "result_copy":
          if (state.result)
            await navigator.clipboard?.writeText(state.result.output);
          break;
        case "capture":
          state.app.status.connection =
            "Demo: screen capture is only available in the desktop app.";
          break;
        default:
          break;
      }
      if (action !== "snapshot") broadcast();
      return snapshot();
    },
  };
}
