export type AppLanguage = "system" | "simplifiedChinese" | "english";
export type ProviderID =
  | "apple"
  | "deepseek"
  | "openrouter"
  | "customAPI"
  | "codex"
  | "dsh"
  | "claude"
  | "kimi";
export type TargetLanguage =
  "smart" | "simplifiedChinese" | "english" | "japanese";
export type LoginStatus =
  "notRegistered" | "enabled" | "requiresApproval" | "notFound";
export interface GlossaryEntry {
  id: string;
  source: string;
  translation: string;
  note: string;
  enabled: boolean;
}
export interface Provider {
  id: ProviderID;
  title: string;
  isAPI: boolean;
  isCLI: boolean;
  defaultBaseURL: string;
  defaultModel: string;
}
export interface AppSnapshot {
  version: string;
  // Older macOS bridges omit platform and capabilities.
  platform?: "macos" | "windows";
  capabilities?: {
    selection: boolean;
    screenCapture: boolean;
    ocr: boolean;
    ocrStatus?: string;
  };
  language: AppLanguage;
  locale: "en" | "zh-Hans";
  settings: {
    provider: ProviderID;
    target: TargetLanguage;
    automaticSelection: boolean;
    preferences: string;
    baseURL: string;
    model: string;
    cliPath: string;
    keyIsSaved: boolean;
  };
  providers: Provider[];
  glossary: GlossaryEntry[];
  detectedCLIs: { provider: ProviderID; path: string }[];
  permissions: {
    accessibility: boolean;
    screenRecording: boolean;
    screenRecordingNeedsRestart?: boolean;
  };
  loginItem: { status: LoginStatus; problem?: string };
  apple: { supported: boolean; status: string };
  status: {
    credential: string;
    connection: string;
    testingConnection: boolean;
    glossary: string;
  };
}
export interface ResultState {
  id: string;
  source: string;
  sourceApp: string;
  sourceLanguage: string;
  targetLanguage: string;
  output: string;
  isLoading: boolean;
  loadingMessage: string;
  error: string | null;
  status: string;
  provider: string;
  isPinned: boolean;
  canRetry: boolean;
}
export interface BridgeState {
  app: AppSnapshot;
  result: ResultState | null;
}
export type NativeAction =
  | "snapshot"
  | "update_settings"
  | "provider_select"
  | "set_language"
  | "key_save"
  | "key_remove"
  | "connection_test"
  | "cli_scan"
  | "glossary_upsert"
  | "glossary_delete"
  | "glossary_import"
  | "glossary_export"
  | "permission"
  | "login_set"
  | "login_settings"
  | "apple_prepare"
  | "translate"
  | "capture"
  | "result_close"
  | "result_pin"
  | "result_retry"
  | "result_copy"
  | "open_settings"
  | "open_external"
  | "app_restart"
  | "app_quit";
export type NativeEvent =
  | { type: "snapshot"; data: AppSnapshot }
  | { type: "result"; data: ResultState | null }
  | {
      type: "response";
      id: string;
      ok: boolean;
      data?: BridgeState;
      error?: string;
    }
  | { type: "open_settings" | "hide_settings" | "quit" };
export type Payload = Record<string, unknown>;
export interface NativeRequest {
  id: string;
  action: NativeAction;
  payload: Payload;
}
