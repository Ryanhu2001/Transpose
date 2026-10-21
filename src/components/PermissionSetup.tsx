import { ArrowUpRight, Check, ShieldCheck } from "lucide-react";
import { useState } from "react";
import { permissionSetup } from "../lib/permissions";
import type { NativeClient } from "../lib/useNative";
import type { Translator } from "./common";

export function PermissionSetup({
  client,
  t,
}: {
  client: NativeClient;
  t: Translator;
}) {
  const setup = permissionSetup(client.state!.app.permissions);
  const needsRestart = Boolean(
    client.state!.app.permissions.screenRecordingNeedsRestart,
  );
  const [previewReopened, setPreviewReopened] = useState(false);
  if (client.state!.app.platform === "windows" || !setup.visible) return null;

  return (
    <section
      className="card setup-card"
      aria-label={t("Finish Setup", "完成设置")}
    >
      <div className="setup-heading">
        <h2>
          <ShieldCheck size={15} />
          {t("Finish Setup", "完成设置")}
        </h2>
        <span className="setup-progress" role="status">
          {setup.completed}/{setup.total} {t("complete", "已完成")}
        </span>
      </div>
      <div className="setup-steps">
        {setup.steps.map((step, index) => (
          <div
            className={`setup-step ${step.isNext ? "next-step" : ""}`}
            key={step.kind}
          >
            <span
              className={`setup-number ${step.allowed ? "done" : ""}`}
              aria-hidden="true"
            >
              {step.allowed ? <Check size={12} /> : index + 1}
            </span>
            <div className="setup-step-copy">
              <strong>
                {step.kind === "accessibility"
                  ? t("Accessibility", "辅助功能")
                  : t("Screen Recording", "屏幕录制")}
              </strong>
              <p>
                {step.kind === "accessibility"
                  ? t(
                      "For automatic selection translation.",
                      "用于自动划词翻译。",
                    )
                  : t(
                      "For recognizing text in screen areas.",
                      "用于识别圈选区域的文字。",
                    )}
              </p>
            </div>
            <button
              className={`button ${step.allowed ? "setup-allowed" : step.isNext ? "primary" : "subtle"}`}
              disabled={
                step.allowed ||
                client.pending.has("permission") ||
                client.pending.has("app_restart")
              }
              onClick={() => {
                if (step.kind === "screenRecording" && needsRestart) {
                  void client
                    .request("app_restart")
                    .then(() => setPreviewReopened(client.mode === "demo"))
                    .catch(() => {});
                } else client.act("permission", { kind: step.kind });
              }}
              aria-label={
                step.kind === "screenRecording" && needsRestart
                  ? t("Reopen App", "重新打开")
                  : `${step.allowed ? t("Review", "查看") : t("Allow", "允许")} ${step.kind === "accessibility" ? t("Accessibility", "辅助功能") : t("Screen Recording", "屏幕录制")}`
              }
            >
              {step.allowed ? <Check size={12} /> : <ArrowUpRight size={12} />}
              {step.allowed
                ? t("Allowed", "已允许")
                : step.kind === "screenRecording" && needsRestart
                  ? t("Reopen App", "重新打开")
                  : t("Allow", "允许")}
            </button>
          </div>
        ))}
      </div>
      <p className="setup-hint">
        {previewReopened
          ? t("Demo: the app was not reopened.", "演示模式：不会重新打开应用。")
          : needsRestart
            ? t(
                "macOS has not applied screen recording access yet. Reopen the app to continue.",
                "macOS 尚未让屏幕录制权限生效，重新打开应用后继续。",
              )
            : t(
                "Return here after enabling access. Follow any macOS prompt to reopen the app.",
                "开启后返回即可更新状态；如 macOS 提示重新打开，请按提示继续。",
              )}
      </p>
    </section>
  );
}
