import {
  ArrowDownToLine,
  ArrowRight,
  ArrowUpFromLine,
  BookOpen,
  Check,
  ChevronDown,
  Pencil,
  Plus,
  Search,
  SlidersHorizontal,
  Trash2,
  X,
} from "lucide-react";
import { useEffect, useRef, useState } from "react";
import {
  emptyGlossaryDraft,
  filterGlossary,
  validateGlossaryDraft,
  type GlossaryDraft,
} from "../lib/glossary";
import type { GlossaryEntry } from "../lib/types";
import type { NativeClient } from "../lib/useNative";
import { Busy, Field, StatusMessage, Toggle, type Translator } from "./common";

function TermEditor({
  draft,
  onChange,
  onSave,
  onCancel,
  saving,
  t,
  newTerm = false,
}: {
  draft: GlossaryDraft;
  onChange: (draft: GlossaryDraft) => void;
  onSave: () => void;
  onCancel: () => void;
  saving: boolean;
  t: Translator;
  newTerm?: boolean;
}) {
  return (
    <form
      className="term-editor"
      onSubmit={(event) => {
        event.preventDefault();
        if (validateGlossaryDraft(draft).valid && !saving) onSave();
      }}
      onKeyDown={(event) => {
        if (event.key === "Enter" && event.nativeEvent.isComposing)
          event.preventDefault();
      }}
    >
      <div className="term-input-grid">
        <Field label={t("Original term", "原词")}>
          <input
            autoFocus={newTerm}
            value={draft.source}
            onChange={(event) =>
              onChange({ ...draft, source: event.target.value })
            }
            placeholder={t("e.g. context window", "例如 context window")}
            spellCheck={false}
          />
        </Field>
        <ArrowRight className="term-arrow" size={16} />
        <Field label={t("Preferred translation", "期望译法")}>
          <input
            value={draft.translation}
            onChange={(event) =>
              onChange({ ...draft, translation: event.target.value })
            }
            placeholder={t("e.g. 上下文窗口", "例如 上下文窗口")}
            spellCheck={false}
          />
        </Field>
      </div>
      <Field label={t("Context or note", "语境或备注")}>
        <input
          value={draft.note}
          onChange={(event) => onChange({ ...draft, note: event.target.value })}
          placeholder={t(
            "Optional · when this translation applies",
            "可选，说明适用场景",
          )}
        />
      </Field>
      <div className="editor-actions">
        <div className="enabled-control">
          <Toggle
            value={draft.enabled}
            onChange={(enabled) => onChange({ ...draft, enabled })}
            label={t("Use this term", "启用此术语")}
          />
          <span>{t("Use this term", "启用此术语")}</span>
        </div>
        <div className="button-group">
          <button type="button" className="button plain" onClick={onCancel}>
            {t("Cancel", "取消")}
          </button>
          <button
            type="submit"
            className="button primary"
            disabled={!validateGlossaryDraft(draft).valid || saving}
          >
            {saving ? (
              <Busy />
            ) : newTerm ? (
              <Plus size={14} />
            ) : (
              <Check size={14} />
            )}
            {newTerm ? t("Add Term", "添加词条") : t("Save", "保存")}
          </button>
        </div>
      </div>
    </form>
  );
}
export function Glossary({
  client,
  t,
}: {
  client: NativeClient;
  t: Translator;
}) {
  const app = client.state!.app;
  const [query, setQuery] = useState("");
  const [adding, setAdding] = useState(false);
  const [newDraft, setNewDraft] = useState(emptyGlossaryDraft);
  const [editing, setEditing] = useState<string | null>(null);
  const [drafts, setDrafts] = useState<Record<string, GlossaryDraft>>({});
  const [preference, setPreference] = useState(app.settings.preferences);
  const [composing, setComposing] = useState(false);
  const [preferenceSaving, setPreferenceSaving] = useState(false);
  const preferenceRef = useRef(preference);
  const persistedRef = useRef(app.settings.preferences);
  const debounce = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => {
    if (preferenceRef.current === persistedRef.current) {
      preferenceRef.current = app.settings.preferences;
      setPreference(app.settings.preferences);
    }
    persistedRef.current = app.settings.preferences;
  }, [app.settings.preferences]);
  useEffect(() => {
    if (composing || preference === persistedRef.current) return;
    debounce.current = setTimeout(() => {
      setPreferenceSaving(true);
      void client
        .request("update_settings", { preferences: preference })
        .catch(() => {})
        .finally(() => setPreferenceSaving(false));
    }, 600);
    return () => {
      if (debounce.current) clearTimeout(debounce.current);
    };
  }, [preference, composing, client.request]);
  useEffect(() => {
    // Deleted or imported-over entries must not keep an editable stale row.
    if (editing && !app.glossary.some((entry) => entry.id === editing))
      setEditing(null);
  }, [editing, app.glossary]);
  const flushPreferences = () => {
    if (debounce.current) clearTimeout(debounce.current);
    if (composing || preferenceRef.current === persistedRef.current) return;
    setPreferenceSaving(true);
    void client
      .request("update_settings", { preferences: preferenceRef.current })
      .catch(() => {})
      .finally(() => setPreferenceSaving(false));
  };
  const startEdit = (entry: GlossaryEntry) => {
    setEditing(entry.id);
    setDrafts((current) => ({
      ...current,
      [entry.id]: current[entry.id] || { ...entry },
    }));
  };
  const clearDraft = (id: string) => {
    setDrafts((current) => {
      const next = { ...current };
      delete next[id];
      return next;
    });
    setEditing(null);
  };
  const saveDraft = async (draft: GlossaryDraft, isNew: boolean) => {
    const normalized = validateGlossaryDraft(draft);
    if (!normalized.valid) return;
    const entry = {
      source: normalized.source,
      translation: normalized.translation,
      note: normalized.note,
      enabled: normalized.enabled,
    };
    try {
      await client.request("glossary_upsert", {
        entry: { ...entry, ...(draft.id ? { id: draft.id } : {}) },
      });
      if (isNew) {
        setNewDraft(emptyGlossaryDraft());
        setAdding(false);
      } else if (draft.id) clearDraft(draft.id);
    } catch {
      /* retain the draft so the user can retry */
    }
  };
  let entries = filterGlossary(app.glossary, query);
  const activeEntry = app.glossary.find((entry) => entry.id === editing);
  if (activeEntry && !entries.some((entry) => entry.id === activeEntry.id))
    entries = [activeEntry, ...entries];
  return (
    <>
      <header className="page-header">
        <span className="eyebrow">
          {t("SOUNDS MORE LIKE YOU", "让翻译更懂你的表达")}
        </span>
        <h1>{t("Glossary & Preferences", "词库与偏好")}</h1>
        <p>
          {t(
            "A few familiar words make a world of difference.",
            "记住熟悉的术语，也记住你喜欢的表达。",
          )}
        </p>
      </header>
      <section className="section preference-section">
        <div className="section-heading">
          <h2>
            <SlidersHorizontal size={16} />
            {t("Translation Preferences", "翻译偏好")}
          </h2>
          <span className="quiet" role="status">
            {preferenceSaving
              ? t("Saving…", "保存中…")
              : preference === app.settings.preferences
                ? t("Saved automatically", "自动保存")
                : t("Editing", "编辑中")}
          </span>
        </div>
        <div className="card preference-card">
          <textarea
            rows={3}
            aria-label={t("Translation Preferences", "翻译偏好")}
            value={preference}
            onChange={(event) => {
              preferenceRef.current = event.target.value;
              setPreference(event.target.value);
            }}
            onCompositionStart={() => setComposing(true)}
            onCompositionEnd={() => setComposing(false)}
            onBlur={flushPreferences}
            placeholder={t(
              "For example: Keep product names in English. Use concise, natural Chinese. My field is machine learning.",
              "例如：产品名称保留英文，中文表达自然简洁，我的专业领域是机器学习。",
            )}
            spellCheck={false}
          />
        </div>
        <p className="footnote">
          {t(
            "Preferences and glossary terms guide AI services. Apple Translate uses its own on-device translation.",
            "偏好和术语会用于 AI 翻译服务，Apple 翻译使用系统自身的翻译方式。",
          )}
        </p>
      </section>
      <section className="section">
        <div className="section-heading">
          <h2>
            <BookOpen size={16} />
            {t("Your Terms", "我的词库")}
            <span className="count-badge">{app.glossary.length}</span>
          </h2>
          <div className="button-group">
            <button
              className="icon-button"
              aria-label={t("Import glossary", "导入词库")}
              title={t("Import glossary", "导入词库")}
              disabled={client.pending.has("glossary_import")}
              onClick={() => {
                const before = JSON.stringify(app.glossary);
                void client
                  .request("glossary_import")
                  .then((next) => {
                    if (JSON.stringify(next.app.glossary) !== before) {
                      setEditing(null);
                      setDrafts({});
                    }
                  })
                  .catch(() => {});
              }}
            >
              <ArrowDownToLine size={16} />
            </button>
            <button
              className="icon-button"
              aria-label={t("Export glossary", "导出词库")}
              title={t("Export glossary", "导出词库")}
              disabled={client.pending.has("glossary_export")}
              onClick={() => client.act("glossary_export")}
            >
              <ArrowUpFromLine size={16} />
            </button>
            <button
              className="button primary"
              onClick={() => setAdding(!adding)}
              aria-expanded={adding}
            >
              {adding ? <ChevronDown size={14} /> : <Plus size={14} />}
              {t("Add Term", "添加词条")}
            </button>
          </div>
        </div>
        {adding && (
          <div className="card new-term-card">
            <TermEditor
              draft={newDraft}
              onChange={setNewDraft}
              onSave={() => void saveDraft(newDraft, true)}
              onCancel={() => {
                setAdding(false);
                setNewDraft(emptyGlossaryDraft());
              }}
              saving={client.pending.has("glossary_upsert")}
              t={t}
              newTerm
            />
          </div>
        )}
        <div className="search-field">
          <Search size={15} />
          <input
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder={t(
              "Find a word, translation, or note",
              "搜索原词、译词或备注",
            )}
            aria-label={t("Search glossary", "搜索词库")}
          />
          {query && (
            <button
              className="icon-button"
              aria-label={t("Clear search", "清除搜索")}
              onClick={() => setQuery("")}
            >
              <X size={13} />
            </button>
          )}
        </div>
        <div className="card glossary-list">
          {entries.length === 0 ? (
            <div className="empty-state">
              <BookOpen size={26} />
              <h3>
                {query
                  ? t("No matching terms", "没有找到匹配词条")
                  : t("Your words belong here.", "在这里，留下你的专属词汇。")}
              </h3>
              <p>
                {query
                  ? t(
                      "Try another word or clear the search.",
                      "换个关键词试试，或清除搜索。",
                    )
                  : t(
                      "Add names, technical terms, and the translations you prefer.",
                      "添加人名、专业术语，以及你喜欢的译法。",
                    )}
              </p>
            </div>
          ) : (
            entries.map((entry) => (
              <div className="glossary-entry" key={entry.id}>
                {editing === entry.id && drafts[entry.id] ? (
                  <TermEditor
                    draft={drafts[entry.id]}
                    onChange={(draft) =>
                      setDrafts((current) => ({
                        ...current,
                        [entry.id]: draft,
                      }))
                    }
                    onSave={() => void saveDraft(drafts[entry.id], false)}
                    onCancel={() => clearDraft(entry.id)}
                    saving={client.pending.has("glossary_upsert")}
                    t={t}
                  />
                ) : (
                  <div
                    className={`term-row ${entry.enabled ? "" : "disabled-term"}`}
                  >
                    <div className="term-copy">
                      <div className="term-pair">
                        <strong>{entry.source}</strong>
                        <ArrowRight size={13} />
                        <span>{entry.translation}</span>
                      </div>
                      {entry.note && <p>{entry.note}</p>}
                    </div>
                    <div className="term-tools">
                      <button
                        className="icon-button"
                        onClick={() => startEdit(entry)}
                        aria-label={`${t("Edit", "编辑")} ${entry.source}`}
                      >
                        <Pencil size={14} />
                      </button>
                      <button
                        className="icon-button danger"
                        disabled={client.pending.has("glossary_delete")}
                        onClick={() =>
                          client.act("glossary_delete", { id: entry.id })
                        }
                        aria-label={`${t("Delete", "删除")} ${entry.source}`}
                      >
                        <Trash2 size={14} />
                      </button>
                      <Toggle
                        value={entry.enabled}
                        label={`${t("Use term", "启用词条")} ${entry.source}`}
                        disabled={client.pending.has("glossary_upsert")}
                        onChange={(enabled) => {
                          void client
                            .request("glossary_upsert", {
                              entry: { ...entry, enabled },
                            })
                            .then(() => {
                              // Preserve an unfinished text edit while keeping its
                              // switch in sync with a confirmed change to the row.
                              setDrafts((current) =>
                                current[entry.id]
                                  ? {
                                      ...current,
                                      [entry.id]: {
                                        ...current[entry.id],
                                        enabled,
                                      },
                                    }
                                  : current,
                              );
                            })
                            .catch(() => {});
                        }}
                      />
                    </div>
                  </div>
                )}
              </div>
            ))
          )}
        </div>
        <StatusMessage>{app.status.glossary}</StatusMessage>
      </section>
    </>
  );
}
