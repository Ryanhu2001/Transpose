import {
  ArrowUpRight,
  Check,
  CircleDot,
  Globe2,
  KeyRound,
  Link2,
  LockKeyhole,
  PlugZap,
  RefreshCw,
  Save,
  Terminal,
  Trash2,
} from "lucide-react";
import { useEffect, useState } from "react";
import type { NativeClient } from "../lib/useNative";
import { preferredCLI } from "../lib/providers";
import { platformFeatures, serviceChannels } from "../lib/platform";
import { ProviderLogo } from "./ProviderLogo";
import {
  Busy,
  Field,
  providerName,
  StatusMessage,
  type Translator,
} from "./common";
export function Services({
  client,
  t,
}: {
  client: NativeClient;
  t: Translator;
}) {
  const app = client.state!.app;
  const features = platformFeatures(app);
  const channels = serviceChannels(app);
  const selected = app.settings.provider;
  const provider = app.providers.find((item) => item.id === selected)!;
  const [apiKey, setApiKey] = useState("");
  const [transaction, setTransaction] = useState(false);
  const [baseURL, setBaseURL] = useState(app.settings.baseURL);
  const [model, setModel] = useState(app.settings.model);
  const [cliPath, setCliPath] = useState(app.settings.cliPath);
  useEffect(() => {
    setApiKey("");
  }, [selected]);
  useEffect(() => {
    setBaseURL(app.settings.baseURL);
    setModel(app.settings.model);
    setCliPath(app.settings.cliPath);
  }, [
    selected,
    app.settings.baseURL,
    app.settings.model,
    app.settings.cliPath,
  ]);
  const dirty =
    baseURL !== app.settings.baseURL ||
    model !== app.settings.model ||
    cliPath !== app.settings.cliPath;
  const persist = async () => {
    await client.request("update_settings", {
      baseURL: baseURL.trim(),
      model: model.trim(),
      cliPath: cliPath.trim(),
      expectedProvider: selected,
    });
  };
  const save = async () => {
    setTransaction(true);
    try {
      await persist();
    } finally {
      setTransaction(false);
    }
  };
  const saveKey = async () => {
    setTransaction(true);
    try {
      if (dirty) await persist();
      await client.request("key_save", {
        key: apiKey,
        provider: selected,
        baseURL: baseURL.trim(),
      });
      setApiKey("");
    } catch {
      /* error is shown by the client */
    } finally {
      setTransaction(false);
    }
  };
  const test = async () => {
    setTransaction(true);
    try {
      if (dirty) await persist();
      await client.request("connection_test", { expectedProvider: selected });
    } catch {
      /* error is shown by the client */
    } finally {
      setTransaction(false);
    }
  };
  return (
    <>
      <header className="page-header">
        <span className="eyebrow">
          {t("MADE TO FIT YOUR WORKFLOW", "选择适合你的翻译方式")}
        </span>
        <h1>{t("Translation Services", "翻译服务")}</h1>
        <p>
          {features.isWindows
            ? t(
                "Connect your preferred API or an installed command-line tool.",
                "连接你喜欢的 API 服务，或使用已安装的本地命令行工具。",
              )
            : t(
                "Start on your Mac. Connect more when you need them.",
                "从本机翻译开始，也可以连接你喜欢的服务。",
              )}
        </p>
      </header>
      <div
        className="provider-grid"
        data-channels={channels.length}
        role="group"
        aria-label={t("Choose translation service", "选择翻译服务")}
      >
        {channels.map((channel) => {
          const active =
            channel === "localCLI" ? provider.isCLI : selected === channel;
          return (
            <button
              className={`provider-choice ${active ? "selected" : ""}`}
              key={channel}
              onClick={() =>
                client.act("provider_select", {
                  provider:
                    channel === "localCLI"
                      ? provider.isCLI
                        ? selected
                        : preferredCLI(app.detectedCLIs)
                      : channel,
                })
              }
              disabled={
                transaction ||
                client.pending.has("provider_select") ||
                client.pending.has("key_remove")
              }
              aria-pressed={active}
            >
              <span className="provider-symbol">
                <ProviderLogo channel={channel} />
              </span>
              <span>
                {channel === "localCLI"
                  ? t("Local CLI", "本地 CLI")
                  : providerName(channel, t)}
              </span>
              {active && <Check className="provider-check" size={13} />}
            </button>
          );
        })}
      </div>
      <section className="card service-card">
        <div className="service-heading">
          <div>
            <h2>
              {provider.isCLI
                ? t("Local CLI", "本地 CLI")
                : providerName(selected, t)}
            </h2>
            <p>
              {selected === "apple"
                ? t(
                    "Private, on-device translation. No API key needed.",
                    "本机翻译，无需 API Key。",
                  )
                : selected === "deepseek"
                  ? t(
                      "Fast, thoughtful translation with your DeepSeek account.",
                      "连接你的 DeepSeek 账号，兼顾速度与表达。",
                    )
                  : selected === "openrouter"
                    ? t(
                        "One connection to a wide choice of language models.",
                        "通过一个连接，使用多种语言模型。",
                      )
                    : selected === "customAPI"
                      ? t(
                          "Bring any OpenAI-compatible translation endpoint.",
                          "连接兼容 OpenAI 的 API 服务。",
                        )
                      : t(
                          "Use a CLI already installed on your computer.",
                          "使用电脑上已安装的命令行工具。",
                        )}
            </p>
          </div>
          <span
            className={`service-label ${selected === "apple" ? "local-label" : ""}`}
          >
            {selected === "apple" ? (
              <>
                <LockKeyhole size={12} />
                {t("On-device", "本机")}
              </>
            ) : provider?.isCLI ? (
              <>
                <Terminal size={12} />
                CLI
              </>
            ) : (
              <>
                <Globe2 size={12} />
                API
              </>
            )}
          </span>
        </div>
        {selected === "apple" ? (
          <div className="apple-body">
            <div className="apple-orb">
              <ProviderLogo channel="apple" />
            </div>
            <h3>{t("A good place to begin.", "轻快的开始。")}</h3>
            <p>
              {t(
                "macOS translates on your device after you download the language packs. Your text stays with you.",
                "下载语言包后，即可在 Mac 上完成翻译，文字无需离开本机。",
              )}
            </p>
            <button
              className="button primary"
              disabled={
                !app.apple.supported || client.pending.has("apple_prepare")
              }
              onClick={() => client.act("apple_prepare")}
            >
              {client.pending.has("apple_prepare") ? (
                <Busy />
              ) : (
                <ArrowUpRight size={14} />
              )}
              {t("Prepare Language Packs", "准备语言包")}
            </button>
            <StatusMessage>
              {app.apple.supported
                ? app.apple.status
                : t(
                    "Apple Translate requires macOS 15 or later.",
                    "Apple 翻译需要 macOS 15 或更新版本。",
                  )}
            </StatusMessage>
          </div>
        ) : (
          <div className="connection-form">
            {provider.isCLI && (
              <div className="cli-selector">
                <div className="section-heading">
                  <h2>{t("Choose a Tool", "选择本地工具")}</h2>
                  <button
                    className="button tiny"
                    onClick={() => client.act("cli_scan")}
                    disabled={client.pending.has("cli_scan")}
                  >
                    <RefreshCw
                      size={13}
                      className={client.pending.has("cli_scan") ? "spin" : ""}
                    />
                    {t("Scan", "检测")}
                  </button>
                </div>
                <div className="cli-grid">
                  {app.providers
                    .filter((item) => item.isCLI)
                    .map((item) => (
                      <button
                        key={item.id}
                        className={`cli-choice ${selected === item.id ? "selected" : ""}`}
                        disabled={
                          transaction ||
                          client.pending.has("provider_select") ||
                          client.pending.has("key_remove")
                        }
                        onClick={() =>
                          client.act("provider_select", { provider: item.id })
                        }
                      >
                        <Terminal size={15} />
                        <span>{providerName(item.id, t)}</span>
                        {app.detectedCLIs.some(
                          (cli) => cli.provider === item.id,
                        ) && (
                          <span
                            className="detected-dot"
                            title={t("Detected", "已检测到")}
                          />
                        )}
                        {selected === item.id && <Check size={13} />}
                      </button>
                    ))}
                </div>
                <p className="field-help cli-help">
                  {t(
                    "Uses your existing CLI login. No extra sign-in required.",
                    "使用本地 CLI 的登录状态，无需再次登录。",
                  )}
                </p>
              </div>
            )}
            {provider?.isAPI && (
              <Field label={t("API Endpoint", "API 地址")}>
                <input
                  type="url"
                  disabled={transaction}
                  value={baseURL}
                  placeholder={provider.defaultBaseURL}
                  onChange={(event) => setBaseURL(event.target.value)}
                  spellCheck={false}
                  autoCapitalize="off"
                  autoCorrect="off"
                />
              </Field>
            )}
            {provider?.isCLI && (
              <Field
                label={t("Executable Path", "程序路径")}
                help={t(
                  "Leave blank to find the command automatically.",
                  "留空时自动查找已安装的程序。",
                )}
              >
                <input
                  disabled={transaction}
                  value={cliPath}
                  onChange={(event) => setCliPath(event.target.value)}
                  placeholder={
                    app.detectedCLIs.find((item) => item.provider === selected)
                      ?.path ||
                    (features.isWindows
                      ? "C:\\Users\\…\\codex.exe"
                      : "/usr/local/bin/…")
                  }
                  spellCheck={false}
                  autoCapitalize="off"
                  autoCorrect="off"
                />
              </Field>
            )}
            <Field label={t("Model", "模型")}>
              <input
                disabled={transaction}
                value={model}
                onChange={(event) => setModel(event.target.value)}
                placeholder={
                  provider?.defaultModel ||
                  t("Service default", "使用服务默认模型")
                }
                spellCheck={false}
                autoCapitalize="off"
                autoCorrect="off"
              />
            </Field>
            {selected === "openrouter" && (
              <div className="service-note">
                <CircleDot size={15} />
                <div>
                  <strong>{t("Try free models", "试试免费模型")}</strong>
                  <p>
                    {t(
                      "openrouter/free routes to available free models. Availability and rate limits are set by OpenRouter.",
                      "openrouter/free 会选择可用的免费模型，供应情况与使用限额由 OpenRouter 决定。",
                    )}
                  </p>
                  <button
                    className="text-button"
                    onClick={() =>
                      client.act("open_external", {
                        url: "https://openrouter.ai/keys",
                      })
                    }
                  >
                    {t("Create an OpenRouter Key", "注册并获取 OpenRouter Key")}
                    <ArrowUpRight size={13} />
                  </button>
                </div>
              </div>
            )}
            {provider?.isAPI && (
              <div className="key-section">
                <div className="field-label key-label">
                  <KeyRound size={14} />
                  API Key
                  {app.settings.keyIsSaved && (
                    <span className="saved-badge">
                      <Check size={11} />
                      {features.isWindows
                        ? t("Saved securely", "已安全保存")
                        : t("In Keychain", "已存入钥匙串")}
                    </span>
                  )}
                </div>
                <div className="key-input-row">
                  <input
                    aria-label="API Key"
                    type="password"
                    disabled={transaction}
                    value={apiKey}
                    onChange={(event) => setApiKey(event.target.value)}
                    placeholder={
                      app.settings.keyIsSaved
                        ? t(
                            "Enter a new key to replace it",
                            "输入新 Key 可替换已保存的 Key",
                          )
                        : t("Paste your API key", "粘贴你的 API Key")
                    }
                    autoComplete="off"
                    spellCheck={false}
                    autoCapitalize="off"
                    autoCorrect="off"
                    onKeyDown={(event) => {
                      if (event.key === "Enter" && apiKey.trim())
                        void saveKey();
                    }}
                  />
                  <button
                    className="button subtle"
                    disabled={
                      transaction ||
                      !apiKey.trim() ||
                      client.pending.has("key_save")
                    }
                    onClick={() => void saveKey()}
                  >
                    {client.pending.has("key_save") ? (
                      <Busy />
                    ) : (
                      <Save size={14} />
                    )}
                    {t("Save Key", "保存")}
                  </button>
                  {app.settings.keyIsSaved && (
                    <button
                      className="icon-button danger"
                      aria-label={t("Remove saved key", "移除已保存的 Key")}
                      disabled={transaction || client.pending.has("key_remove")}
                      onClick={() =>
                        client.act("key_remove", {
                          provider: selected,
                          baseURL: app.settings.baseURL,
                        })
                      }
                    >
                      <Trash2 size={16} />
                    </button>
                  )}
                </div>
                <p className="field-help">
                  <LockKeyhole size={11} />
                  {features.isWindows
                    ? t(
                        "Stored in Windows Credential Manager. Never stored in this web interface.",
                        "保存在 Windows 凭据管理器中，网页界面不会保存 Key。",
                      )
                    : t(
                        "Stored in macOS Keychain. Never stored in this web interface.",
                        "保存在 macOS 钥匙串中，网页界面不会保存 Key。",
                      )}
                </p>
                <StatusMessage>{app.status.credential}</StatusMessage>
              </div>
            )}
            <div className="form-actions">
              {dirty && (
                <button
                  className="button subtle"
                  disabled={
                    transaction || client.pending.has("update_settings")
                  }
                  onClick={() => void save().catch(() => {})}
                >
                  <Save size={14} />
                  {t("Save Changes", "保存修改")}
                </button>
              )}
              <button
                className="button primary"
                disabled={
                  transaction ||
                  app.status.testingConnection ||
                  client.pending.has("connection_test")
                }
                onClick={() => void test()}
              >
                {app.status.testingConnection ||
                client.pending.has("connection_test") ? (
                  <Busy />
                ) : (
                  <PlugZap size={14} />
                )}
                {t("Test Connection", "测试连接")}
              </button>
            </div>
            <StatusMessage>{app.status.connection}</StatusMessage>
          </div>
        )}
      </section>
      <p className="footnote">
        <Link2 size={12} />
        {t(
          "Only the selected service receives your text when you translate.",
          "仅在翻译时，将文字发送给你所选的服务。",
        )}
      </p>
    </>
  );
}
