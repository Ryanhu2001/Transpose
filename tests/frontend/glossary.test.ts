import { describe, expect, it } from "vitest";
import {
  emptyGlossaryDraft,
  filterGlossary,
  upsertGlossaryDraft,
  validateGlossaryDraft,
  type GlossaryDraft,
} from "../../src/lib/glossary";

const entries = [
  {
    id: "agent",
    source: "Agent",
    translation: "智能体",
    note: "AI research",
    enabled: true,
  },
  {
    id: "transpose",
    source: "Transpose",
    translation: "转置",
    note: "矩阵术语",
    enabled: false,
  },
];

describe("glossary drafts", () => {
  it("creates independent empty drafts with enabled entries", () => {
    const draft = emptyGlossaryDraft();
    expect(draft).toEqual({
      source: "",
      translation: "",
      note: "",
      enabled: true,
    });
    draft.source = "Changed";
    expect(emptyGlossaryDraft().source).toBe("");
  });

  it.each([
    ["", "智能体"],
    [" \n\t", "智能体"],
    ["Agent", ""],
    ["Agent", " \n\t"],
  ])(
    "rejects an empty source or translation: %j → %j",
    (source, translation) => {
      expect(
        validateGlossaryDraft({ ...emptyGlossaryDraft(), source, translation })
          .valid,
      ).toBe(false);
    },
  );

  it("trims stored values without altering the draft or enabled preference", () => {
    const draft: GlossaryDraft = {
      id: "agent",
      source: "  Agent\n",
      translation: " 智能体 \t",
      note: "  AI research  ",
      enabled: false,
    };
    const original = { ...draft };

    expect(validateGlossaryDraft(draft)).toEqual({
      valid: true,
      source: "Agent",
      translation: "智能体",
      note: "AI research",
      enabled: false,
    });
    expect(draft).toEqual(original);
  });
});

describe("glossary search", () => {
  it("returns the original entries for an empty query", () => {
    expect(filterGlossary(entries, "")).toBe(entries);
    expect(filterGlossary(entries, " \n\t")).toBe(entries);
  });

  it.each(["aGeNt", "智能", "  AI RESEARCH  "])(
    "searches sources, translations and notes with %j",
    (query) => {
      expect(filterGlossary(entries, query)).toEqual([entries[0]]);
    },
  );

  it("searches Chinese notes and includes disabled terms", () => {
    expect(filterGlossary(entries, "矩阵")).toEqual([entries[1]]);
    expect(filterGlossary(entries, "unmatched")).toEqual([]);
    expect(entries).toHaveLength(2);
  });
});

describe("glossary updates", () => {
  it("replaces the matching ID in place without mutating the original array", () => {
    const originals = entries.map((entry) => ({ ...entry }));
    const draft = {
      ...entries[0],
      source: "AI Agent",
      translation: "人工智能体",
      enabled: false,
    };

    const updated = upsertGlossaryDraft(entries, draft);

    expect(updated.map((entry) => entry.id)).toEqual(["agent", "transpose"]);
    expect(updated[0]).toEqual(draft);
    expect(updated).not.toBe(entries);
    expect(updated[0]).not.toBe(entries[0]);
    expect(updated[0]).not.toBe(draft);
    expect(updated[1]).toBe(entries[1]);
    expect(entries).toEqual(originals);
  });

  it("preserves other entry metadata when editing an existing ID", () => {
    const original = [{ ...entries[0], createdAt: "2026-10-21" }];
    const updated = upsertGlossaryDraft(original, {
      ...entries[0],
      translation: "代理",
    });
    expect(updated[0].createdAt).toBe("2026-10-21");
    expect(original[0].translation).toBe("智能体");
  });

  it("appends a new ID and copies the draft", () => {
    const draft = {
      id: "context",
      source: "Context",
      translation: "上下文",
      note: "",
      enabled: true,
    };
    const updated = upsertGlossaryDraft(entries, draft);

    expect(updated.map((entry) => entry.id)).toEqual([
      "agent",
      "transpose",
      "context",
    ]);
    expect(updated[2]).toEqual(draft);
    expect(updated[2]).not.toBe(draft);
    expect(entries).toHaveLength(2);
  });

  it("creates the first entry in an empty glossary", () => {
    expect(upsertGlossaryDraft([], entries[0])).toEqual([entries[0]]);
  });
});
