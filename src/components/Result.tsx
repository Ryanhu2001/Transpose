import {
  Check,
  Copy,
  LoaderCircle,
  Pin,
  PinOff,
  RotateCcw,
  Settings2,
  X,
} from "lucide-react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useEffect, useState, type PointerEvent } from "react";
import type { NativeClient } from "../lib/useNative";
import {
  RESULT_RESIZE_DIRECTIONS,
  startResultWindowDrag,
  startResultWindowResize,
} from "../lib/resultWindow";
import { Brand, type Translator } from "./common";
export function Result({ client, t }: { client: NativeClient; t: Translator }) {
  const result = client.state?.result;
  const isWindows = client.state?.app.platform === "windows";
  const [copied, setCopied] = useState(false);
  const [windowError, setWindowError] = useState("");
  useEffect(() => {
    setCopied(false);
  }, [result?.id, result?.output]);
  useEffect(() => {
    if (!isWindows) return;
    const close = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      client.act("result_close");
    };
    window.addEventListener("keydown", close);
    return () => window.removeEventListener("keydown", close);
  }, [client.act, isWindows]);
  const copy = async () => {
    try {
      await client.request("result_copy");
      setCopied(true);
      setTimeout(() => setCopied(false), 1800);
    } catch {
      /* client displays error */
    }
  };
  const resize = (
    event: PointerEvent<HTMLElement>,
    direction: (typeof RESULT_RESIZE_DIRECTIONS)[number],
  ) => {
    if (client.mode !== "tauri") return;
    setWindowError("");
    void startResultWindowResize(event, direction, (edge) =>
      getCurrentWindow().startResizeDragging(edge),
    ).catch(() =>
      setWindowError(
        t("Unable to resize this window.", "暂时无法调整窗口大小。"),
      ),
    );
  };
  return (
    <div className="result-shell">
      <header
        className="result-header"
        data-tauri-drag-region={isWindows ? undefined : "deep"}
        onPointerDown={(event) => {
          if (!isWindows || client.mode !== "tauri") return;
          setWindowError("");
          void startResultWindowDrag(event, () =>
            getCurrentWindow().startDragging(),
          ).catch(() =>
            setWindowError(
              t("Unable to move this window.", "暂时无法移动窗口。"),
            ),
          );
        }}
      >
        <div className="result-direction">
          <Brand small />
          <span>
            {result?.sourceLanguage || t("Auto", "自动")}
            <span className="direction-arrow">→</span>
            <strong>
              {result?.targetLanguage || t("Translation", "译文")}
            </strong>
          </span>
        </div>
        <div className="result-header-actions">
          <button
            className={`icon-button ${result?.isPinned ? "active" : ""}`}
            aria-pressed={Boolean(result?.isPinned)}
            aria-label={
              result?.isPinned
                ? t("Unpin window", "取消固定")
                : t("Pin window", "固定窗口")
            }
            title={
              result?.isPinned
                ? t("Unpin window", "取消固定")
                : t("Pin window", "固定窗口")
            }
            onClick={() =>
              client.act("result_pin", { pinned: !result?.isPinned })
            }
          >
            {result?.isPinned ? <PinOff size={15} /> : <Pin size={15} />}
          </button>
          <button
            className="icon-button"
            aria-label={t("Close", "关闭")}
            onClick={() => client.act("result_close")}
          >
            <X size={17} />
          </button>
        </div>
      </header>
      <main className="result-content" tabIndex={0}>
        {result?.error ? (
          <p className="result-error" role="alert">
            {result.error}
          </p>
        ) : result?.output ? (
          <div className="translation-output">
            {result.output}
            {result.isLoading && (
              <span
                className="stream-cursor"
                aria-label={t("Translating", "翻译中")}
              />
            )}
          </div>
        ) : (
          <div className="result-loading">
            {result?.isLoading ? (
              <>
                <LoaderCircle className="spin" size={17} />
                <span>
                  {result.loadingMessage || t("Translating…", "正在翻译…")}
                </span>
              </>
            ) : (
              <span>
                {t("Your translation will appear here.", "译文将在这里显示。")}
              </span>
            )}
          </div>
        )}
        {(client.error || windowError) && (
          <p className="result-error" role="alert">
            {client.error || windowError}
          </p>
        )}
      </main>
      <footer className="result-footer">
        <span className="result-status" title={result?.status}>
          {client.mode === "demo"
            ? "Demo · local preview"
            : result?.status || result?.provider || ""}
        </span>
        <div className="result-tools">
          <button
            className="icon-button"
            disabled={!result?.canRetry || result.isLoading}
            onClick={() => client.act("result_retry")}
            aria-label={t("Translate again", "重新翻译")}
            title={t("Translate again", "重新翻译")}
          >
            <RotateCcw size={14} />
          </button>
          <button
            className="icon-button"
            onClick={() => client.act("open_settings")}
            aria-label={t("Settings", "设置")}
            title={t("Settings", "设置")}
          >
            <Settings2 size={15} />
          </button>
          <button
            className="button copy-button"
            disabled={!result?.output}
            onClick={() => void copy()}
          >
            {copied ? <Check size={14} /> : <Copy size={14} />}
            {copied ? t("Copied", "已复制") : t("Copy", "复制")}
          </button>
        </div>
      </footer>
      {isWindows && (
        <div className="result-resize-borders">
          {RESULT_RESIZE_DIRECTIONS.map((direction) =>
            direction === "SouthEast" ? (
              <button
                key={direction}
                className="result-resize-handle"
                data-resize-direction={direction}
                aria-label={t("Resize translation window", "调整译文窗口大小")}
                tabIndex={-1}
                onPointerDown={(event) => resize(event, direction)}
              >
                <svg viewBox="0 0 16 16" aria-hidden="true">
                  <path d="M5 13 13 5M10 13l3-3" />
                </svg>
              </button>
            ) : (
              <span
                key={direction}
                data-resize-direction={direction}
                aria-hidden="true"
                onPointerDown={(event) => resize(event, direction)}
              />
            ),
          )}
        </div>
      )}
    </div>
  );
}
