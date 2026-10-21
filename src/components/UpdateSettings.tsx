import { ArrowUpRight, CheckCircle2, Download, RefreshCw } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import type { NativeClient } from "../lib/useNative";
import {
  UpdateSession,
  updateProgress,
  type UpdateStatus,
  type UpdateView,
} from "../lib/updates";
import { Busy, type Translator } from "./common";
import "./updates.css";

function statusText(status: UpdateStatus, t: Translator) {
  switch (status.phase) {
    case "checking":
      return t("Checking for updates…", "正在检查更新…");
    case "available":
      return t(
        `Version ${status.version} is available.`,
        `${status.version} 版本可用。`,
      );
    case "current":
      return t("You’re up to date.", "已是最新版本。");
    case "downloading": {
      const progress = updateProgress(status);
      return (
        t("Downloading…", "正在下载…") +
        (progress === null ? "" : ` ${Math.floor(progress)}%`)
      );
    }
    case "installing":
      return t(
        "Installing. Transpose will restart.",
        "正在安装，完成后将重启。",
      );
    case "unavailable":
      return t(
        "In-app updates will be available with the next release.",
        "下一次正式发布后即可在应用内更新。",
      );
    case "error":
      switch (status.errorCode) {
        case "download_failed":
          return t("Download failed. Please try again.", "下载失败，请重试。");
        case "install_failed":
          return t(
            "Unable to install. Download the latest version below.",
            "安装失败，可在下方下载最新版本。",
          );
        case "version_changed":
        case "no_update":
          return t(
            "The available version changed. Check again.",
            "可用版本已变化，请重新检查。",
          );
        case "busy":
          return t("An update is already in progress.", "更新正在进行中。");
        default:
          return t(
            "Unable to check for updates. Try again later.",
            "暂时无法检查更新，请稍后重试。",
          );
      }
    default:
      return t("Check for the latest version.", "检查是否有新版本。");
  }
}

export function UpdateSettings({
  client,
  t,
}: {
  client: NativeClient;
  t: Translator;
}) {
  const version = client.state!.app.version;
  const enabled = client.mode === "tauri";
  const [{ status, pending }, setView] = useState<UpdateView>({
    status: { phase: "idle", currentVersion: version },
    pending: enabled,
  });
  const session = useRef<UpdateSession | null>(null);

  useEffect(() => {
    if (!enabled) return;
    const controller = new UpdateSession(version, setView);
    session.current = controller;
    void controller.start();
    const checkWhenFocused = () => void controller.checkIfDue();
    window.addEventListener("focus", checkWhenFocused);
    return () => {
      controller.stop();
      if (session.current === controller) session.current = null;
      window.removeEventListener("focus", checkWhenFocused);
    };
  }, [enabled, version]);

  const busy =
    pending || ["checking", "downloading", "installing"].includes(status.phase);
  const canInstall = status.phase === "available" && !!status.version;
  const progress = updateProgress(status);

  if (status.enabled === false) return null;

  return (
    <section className="section" aria-labelledby="updates-heading">
      <div className="section-heading">
        <h2 id="updates-heading">
          <RefreshCw size={16} />
          {t("App Updates", "应用更新")}
        </h2>
        <span className="quiet">{`v${status.currentVersion || version}`}</span>
      </div>
      <div className="card update-card">
        <div className="update-main">
          <div className="row-copy">
            <p
              className={`row-title update-status ${status.phase === "error" ? "update-error" : ""}`}
              role="status"
              aria-live="polite"
            >
              {status.phase === "current" && <CheckCircle2 size={15} />}
              {statusText(status, t)}
            </p>
            <p className="row-description">
              {t(
                "Checks automatically. You choose when to install and restart.",
                "自动检查更新，由你决定何时安装并重启。",
              )}
            </p>
          </div>
          <button
            className={`button ${canInstall ? "primary" : "subtle"}`}
            disabled={!enabled || busy}
            onClick={() =>
              void session.current?.run(canInstall ? "install" : "check")
            }
          >
            {busy ? (
              <Busy />
            ) : canInstall ? (
              <Download size={14} />
            ) : (
              <RefreshCw size={14} />
            )}
            {canInstall
              ? t("Download & Install", "下载并安装")
              : busy
                ? status.phase === "installing"
                  ? t("Installing…", "正在安装…")
                  : status.phase === "downloading"
                    ? t("Downloading…", "正在下载…")
                    : t("Checking…", "正在检查…")
                : status.phase === "error"
                  ? t("Try Again", "重试")
                  : t("Check for Updates", "检查更新")}
          </button>
        </div>
        {status.phase === "downloading" && (
          <progress
            className="update-progress"
            max={100}
            value={progress ?? undefined}
            aria-label={t("Update download progress", "更新下载进度")}
          />
        )}
        {status.phase === "available" && status.notes?.trim() && (
          <p className="update-notes">{status.notes.trim()}</p>
        )}
        {(status.phase === "error" || status.phase === "unavailable") && (
          <button
            className="text-button update-release-link"
            onClick={() =>
              client.act("open_external", {
                url: "https://github.com/Ryanhu2001/Transpose/releases/latest",
              })
            }
          >
            {t("Download from GitHub", "前往 GitHub 下载")}
            <ArrowUpRight size={13} />
          </button>
        )}
      </div>
    </section>
  );
}
