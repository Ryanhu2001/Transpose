import { Check, ChevronDown, LoaderCircle } from "lucide-react";
import type { ReactNode } from "react";
import type { AppSnapshot, ProviderID } from "../lib/types";
export type Translator = (english: string, chinese: string) => string;
export function translator(app: AppSnapshot | null): Translator {
  return (en, zh) => (app?.locale === "zh-Hans" ? zh : en);
}
export function providerName(id: ProviderID, t: Translator) {
  return {
    apple: t("Apple Translate", "Apple 翻译"),
    deepseek: "DeepSeek",
    openrouter: "OpenRouter",
    customAPI: t("Custom API", "自定义 API"),
    codex: "Codex CLI",
    dsh: "DeepSeek CLI",
    claude: "Claude Code",
    kimi: "Kimi Code",
  }[id];
}
export function Brand({ small = false }: { small?: boolean }) {
  return (
    <span
      className={`brand ${small ? "brand-small" : ""}`}
      aria-label="Transpose"
    >
      <svg className="brand-t" viewBox="0 0 100 100" aria-hidden="true">
        <path
          fill="currentColor"
          transform="translate(0 100) scale(1 -1)"
          d="M17 86 C23 84 29 85 35 85 L75 85 C80 85 83 87 86 89 L81 67 H77 C76 76 68 78 58 78 L55 27 C55 21 57 19 61 18 L65 16 V12 H34 V16 L39 18 C43 19 44 22 44 27 L47 78 C36 78 28 76 24 67 L20 64 H15 Z"
        />
      </svg>
      {!small && (
        <span className="brand-rest" aria-hidden="true">
          ranspose
        </span>
      )}
    </span>
  );
}
export function Toggle({
  value,
  onChange,
  disabled,
  label,
}: {
  value: boolean;
  onChange: (value: boolean) => void;
  disabled?: boolean;
  label: string;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={value}
      aria-label={label}
      className={`toggle ${value ? "on" : ""}`}
      disabled={disabled}
      onClick={() => onChange(!value)}
    >
      <span />
    </button>
  );
}
export function Field({
  label,
  children,
  help,
}: {
  label: string;
  children: ReactNode;
  help?: ReactNode;
}) {
  return (
    <label className="field">
      <span className="field-label">{label}</span>
      {children}
      {help && <span className="field-help">{help}</span>}
    </label>
  );
}
export function Select({
  value,
  onChange,
  label,
  children,
  disabled,
}: {
  value: string;
  onChange: (value: string) => void;
  label: string;
  children: ReactNode;
  disabled?: boolean;
}) {
  return (
    <span className="select-wrap">
      <select
        aria-label={label}
        value={value}
        disabled={disabled}
        onChange={(event) => onChange(event.target.value)}
      >
        {children}
      </select>
      <ChevronDown size={14} aria-hidden="true" />
    </span>
  );
}
export function SettingRow({
  title,
  description,
  children,
}: {
  title: string;
  description?: ReactNode;
  children: ReactNode;
}) {
  return (
    <div className="setting-row">
      <div className="row-copy">
        <div className="row-title">{title}</div>
        {description && <div className="row-description">{description}</div>}
      </div>
      <div className="row-control">{children}</div>
    </div>
  );
}
export function Busy({ busy = true }: { busy?: boolean }) {
  return busy ? (
    <LoaderCircle className="spin" size={15} aria-hidden="true" />
  ) : (
    <Check size={15} aria-hidden="true" />
  );
}
export function StatusMessage({ children }: { children: ReactNode }) {
  return children ? (
    <p className="status-message" role="status">
      {children}
    </p>
  ) : null;
}
