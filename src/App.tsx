import {
  AlertCircle,
  BookOpen,
  CircleHelp,
  ExternalLink,
  LoaderCircle,
  PlugZap,
  SlidersHorizontal,
  X,
} from "lucide-react";
import { useEffect, useState } from "react";
import { Brand, translator } from "./components/common";
import { General } from "./components/General";
import { Services } from "./components/Services";
import { Glossary } from "./components/Glossary";
import { Result } from "./components/Result";
import { useNative } from "./lib/useNative";

type Page = "general" | "services" | "glossary";
export default function App() {
  const client = useNative();
  const [page, setPage] = useState<Page>("general");
  const app = client.state?.app ?? null;
  const t = translator(app);
  const isResult = location.hash === "#result";
  useEffect(() => {
    document.documentElement.lang =
      app?.locale === "zh-Hans" ? "zh-Hans" : "en";
    document.body.dataset.route = isResult ? "result" : "settings";
  }, [app?.locale, isResult]);
  if (isResult) return <Result client={client} t={t} />;
  if (!app)
    return (
      <main className="bootstrap">
        <Brand />
        {client.error ? (
          <>
            <AlertCircle size={24} />
            <p role="alert">{client.error}</p>
            <button
              className="button subtle"
              onClick={() => client.act("snapshot")}
            >
              Try Again
            </button>
          </>
        ) : (
          <>
            <LoaderCircle size={23} className="spin" />
            <p>Opening Transpose…</p>
          </>
        )}
      </main>
    );
  return (
    <div className="settings-shell">
      <aside className="sidebar">
        <Brand />
        <nav aria-label={t("Settings sections", "设置导航")}>
          {(
            [
              {
                id: "general",
                label: t("General", "通用"),
                icon: SlidersHorizontal,
              },
              {
                id: "services",
                label: t("Services", "翻译服务"),
                icon: PlugZap,
              },
              {
                id: "glossary",
                label: t("Glossary", "词库与偏好"),
                icon: BookOpen,
              },
            ] as const
          ).map((item) => (
            <button
              key={item.id}
              className={`nav-item ${page === item.id ? "selected" : ""}`}
              aria-current={page === item.id ? "page" : undefined}
              onClick={() => {
                setPage(item.id);
                document.querySelector(".page-scroll")?.scrollTo({ top: 0 });
              }}
            >
              <item.icon size={17} />
              <span>{item.label}</span>
            </button>
          ))}
        </nav>
        <div className="sidebar-bottom">
          <button
            className="help-link"
            onClick={() =>
              client.act("open_external", {
                url: "https://github.com/Ryanhu2001/Transpose",
              })
            }
          >
            <CircleHelp size={14} />
            {t("Help & Source", "帮助与源码")}
            <ExternalLink size={11} />
          </button>
          <span className="app-version">Transpose · {app.version}</span>
        </div>
      </aside>
      <main className="page-scroll">
        <div className="page-body">
          {client.mode === "demo" && (
            <div className="demo-banner">
              <span className="demo-dot" />
              <strong>{t("Demo mode", "演示模式")}</strong>
              <span>
                {t(
                  "Local preview only. No macOS services or network connections.",
                  "仅为本地预览，不调用系统服务或网络。",
                )}
              </span>
            </div>
          )}
          {client.error && (
            <div className="error-banner" role="alert">
              <AlertCircle size={15} />
              <span>{client.error}</span>
              <button
                className="icon-button"
                aria-label={t("Dismiss error", "关闭错误提示")}
                onClick={client.clearError}
              >
                <X size={14} />
              </button>
            </div>
          )}
          <div hidden={page !== "general"}>
            <General
              client={client}
              t={t}
              onServices={() => setPage("services")}
            />
          </div>
          <div hidden={page !== "services"}>
            <Services client={client} t={t} />
          </div>
          <div hidden={page !== "glossary"}>
            <Glossary client={client} t={t} />
          </div>
        </div>
      </main>
    </div>
  );
}
