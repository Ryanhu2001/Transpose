import {
  ArrowUpRight,
  CheckCircle2,
  Command,
  Crop,
  ExternalLink,
  Languages,
  Monitor,
  Play,
  ShieldCheck,
  Sparkles,
} from "lucide-react";
import { useState } from "react";
import { PermissionSetup } from "./PermissionSetup";
import { platformFeatures } from "../lib/platform";
import type { NativeClient } from "../lib/useNative";
import {
  Busy,
  providerName,
  Select,
  SettingRow,
  StatusMessage,
  Toggle,
  type Translator,
} from "./common";
export function General({
  client,
  t,
  onServices,
}: {
  client: NativeClient;
  t: Translator;
  onServices: () => void;
}) {
  const app = client.state!.app;
  const features = platformFeatures(app);
  const [sample, setSample] = useState(
    "Good translation carries the thought, not just the words.",
  );
  const loginOn = app.loginItem.status === "enabled";
  return (
    <>
      <header className="page-header">
        <span className="eyebrow">
          {t("YOUR EVERYDAY TRANSLATOR", "随时，读懂另一种语言")}
        </span>
        <h1>{t("General", "通用")}</h1>
        <p>
          {t(
            "A little translation, right where you need it.",
            "划一下，圈一下，翻译就在身边。",
          )}
        </p>
      </header>
      <PermissionSetup client={client} t={t} />
      <section
        className="card settings-card"
        aria-label={t("Translation", "翻译")}
      >
        <SettingRow
          title={t("Selection Translation", "划词翻译")}
          description={
            features.isWindows
              ? t(
                  "Select text in supported apps to reveal one small button.",
                  "在支持划词的应用中选中文字，即可看到翻译按钮。",
                )
              : t(
                  "Select text in any app. One small button appears.",
                  "在应用中选中文字，即可看到轻巧的翻译按钮。",
                )
          }
        >
          <Toggle
            value={app.settings.automaticSelection}
            disabled={!features.selection}
            onChange={(automaticSelection) =>
              client.act("update_settings", { automaticSelection })
            }
            label={t("Selection Translation", "划词翻译")}
          />
        </SettingRow>
        <SettingRow
          title={t("Screen Translation", "圈选翻译")}
          description={t(
            "Draw around any text. Release to translate.",
            "自由圈住文字，松开即可翻译。",
          )}
        >
          <kbd>{features.captureShortcut}</kbd>
          <button
            className="button subtle"
            disabled={!features.screenCapture || !features.ocr}
            onClick={() => client.act("capture")}
          >
            <Crop size={15} />
            {t("Select Area", "开始圈选")}
          </button>
        </SettingRow>
        <SettingRow title={t("Translate To", "翻译为")}>
          <Select
            label={t("Translation language", "目标语言")}
            value={app.settings.target}
            onChange={(target) => client.act("update_settings", { target })}
          >
            <option value="smart">
              {t("Auto: 中文 ↔ English", "自动：中文 ↔ English")}
            </option>
            <option value="simplifiedChinese">中文</option>
            <option value="english">English</option>
            <option value="japanese">日本語</option>
          </Select>
        </SettingRow>
        <SettingRow title={t("App Language", "界面语言")}>
          <Select
            label={t("App Language", "界面语言")}
            value={app.language}
            onChange={(language) => client.act("set_language", { language })}
          >
            <option value="system">{t("System", "跟随系统")}</option>
            <option value="simplifiedChinese">中文</option>
            <option value="english">English</option>
          </Select>
        </SettingRow>
      </section>
      <section className="card login-card">
        <div className="launch-icon">
          <Sparkles size={20} />
        </div>
        <div className="row-copy">
          <div className="row-title">
            {t("Ready when you are", "开机就绪")}
            <span className="recommend">{t("Recommended", "推荐")}</span>
          </div>
          <p className="row-description">
            {t(
              "Start Transpose at login and keep translation a gesture away.",
              "登录电脑时启动 Transpose，让翻译随手可用。",
            )}
          </p>
          {app.loginItem.status === "requiresApproval" && (
            <div className="inline-actions">
              <button
                className="text-button"
                onClick={() => client.act("login_settings")}
              >
                {t(
                  "Approval required in Login Items",
                  "尚需在系统登录项中允许",
                )}
                <ArrowUpRight size={13} />
              </button>
              <button
                className="text-button muted"
                onClick={() => client.act("login_set", { enabled: false })}
              >
                {t("Cancel request", "取消请求")}
              </button>
            </div>
          )}
          {app.loginItem.status === "notFound" && (
            <p className="row-description">
              {features.isWindows
                ? t(
                    "Install Transpose, then reopen it to enable startup.",
                    "请先安装 Transpose，再重新打开以启用开机启动。",
                  )
                : t(
                    "Move Transpose to Applications, then reopen it.",
                    "请将 Transpose 放入“应用程序”后重新打开。",
                  )}
            </p>
          )}
          {app.loginItem.problem && (
            <StatusMessage>{app.loginItem.problem}</StatusMessage>
          )}
        </div>
        <Toggle
          value={loginOn}
          label={t("Start at login", "开机自启动")}
          disabled={
            client.pending.has("login_set") ||
            app.loginItem.status === "requiresApproval" ||
            app.loginItem.status === "notFound"
          }
          onChange={(enabled) => client.act("login_set", { enabled })}
        />
      </section>
      <section className="section">
        <div className="section-heading">
          <h2>
            <Languages size={16} />
            {t("Try a Translation", "试译一下")}
          </h2>
          <button className="text-button muted" onClick={onServices}>
            {providerName(app.settings.provider, t)}
            <ArrowUpRight size={13} />
          </button>
        </div>
        <div className="card trial-card">
          <textarea
            aria-label={t("Text to translate", "试译原文")}
            value={sample}
            onChange={(event) => setSample(event.target.value)}
            rows={3}
            spellCheck={false}
          />
          <div className="trial-footer">
            <span>
              {t("Opens in a floating window.", "译文将在浮窗中显示。")}
            </span>
            <button
              className="button primary"
              disabled={!sample.trim() || client.pending.has("translate")}
              onClick={() => client.act("translate", { text: sample.trim() })}
            >
              {client.pending.has("translate") ? (
                <Busy />
              ) : (
                <Play size={13} fill="currentColor" />
              )}
              {t("Translate", "翻译")}
            </button>
          </div>
        </div>
      </section>
      <section className="section permissions">
        <div className="section-heading">
          <h2>
            {features.isWindows ? (
              <Monitor size={16} />
            ) : (
              <ShieldCheck size={16} />
            )}
            {features.isWindows
              ? t("Windows Integration", "Windows 系统集成")
              : t("Permissions", "系统权限")}
          </h2>
          <span className="quiet">{t("You stay in control", "由你决定")}</span>
        </div>
        <div className="card settings-card">
          {features.isWindows ? (
            <>
              <SettingRow
                title={t("Text Selection", "选中文字")}
                description={t(
                  "Uses Windows UI Automation. For apps without text selection support, use screen translation.",
                  "通过 Windows UI 自动化读取文字；应用不支持划词时，可使用圈选翻译。",
                )}
              >
                <span className="integration-status">
                  {features.selection && <CheckCircle2 size={14} />}
                  {features.selection
                    ? t("Ready", "已就绪")
                    : t("Unavailable", "暂不可用")}
                </span>
              </SettingRow>
              <SettingRow
                title={t("Screen Capture & OCR", "屏幕圈选与文字识别")}
                description={
                  app.capabilities?.ocrStatus ||
                  t(
                    "Windows recognizes text locally using your installed OCR languages.",
                    "使用 Windows 已安装的 OCR 语言，在本机识别文字。",
                  )
                }
              >
                <span className="integration-status">
                  {features.screenCapture && features.ocr && (
                    <CheckCircle2 size={14} />
                  )}
                  {features.screenCapture && features.ocr
                    ? t("Ready", "已就绪")
                    : t("Setup needed", "需要设置")}
                </span>
              </SettingRow>
            </>
          ) : (
            (["accessibility", "screenRecording"] as const).map((kind) => {
              const allowed = app.permissions[kind];
              return (
                <SettingRow
                  key={kind}
                  title={
                    kind === "accessibility"
                      ? t("Accessibility", "辅助功能")
                      : t("Screen Recording", "屏幕录制")
                  }
                  description={
                    kind === "accessibility"
                      ? t(
                          "Read text you select across apps.",
                          "读取其他应用中选中的文字。",
                        )
                      : t(
                          "Recognize text in the area you draw.",
                          "识别圈选区域中的文字。",
                        )
                  }
                >
                  <button
                    className={`button ${allowed ? "permission-ok" : "subtle"}`}
                    onClick={() => client.act("permission", { kind })}
                  >
                    {allowed ? (
                      <CheckCircle2 size={14} />
                    ) : (
                      <ExternalLink size={13} />
                    )}
                    {allowed ? t("Allowed", "已允许") : t("Allow", "授权")}
                  </button>
                </SettingRow>
              );
            })
          )}
        </div>
        {features.isWindows && !features.ocr && (
          <p className="footnote">
            {t(
              "Install an OCR language in Windows Settings → Time & language → Language & region, then reopen Transpose.",
              "请在 Windows 设置 → 时间和语言 → 语言和区域中安装文字识别语言，然后重新打开 Transpose。",
            )}
          </p>
        )}
        <p className="footnote">
          <Command size={12} />
          {t(
            "Screenshots and OCR stay on your device. Online services receive text only.",
            "截图与文字识别在本机完成，在线服务仅接收文字。",
          )}
        </p>
      </section>
    </>
  );
}
