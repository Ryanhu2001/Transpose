export interface GlossaryDraft {
  id?: string;
  source: string;
  translation: string;
  note: string;
  enabled: boolean;
}

export function emptyGlossaryDraft(): GlossaryDraft {
  return { source: "", translation: "", note: "", enabled: true };
}

export function validateGlossaryDraft(draft: GlossaryDraft): {
  valid: boolean;
  source: string;
  translation: string;
  note: string;
  enabled: boolean;
} {
  const source = draft.source.trim();
  const translation = draft.translation.trim();

  return {
    valid: source.length > 0 && translation.length > 0,
    source,
    translation,
    note: draft.note.trim(),
    enabled: draft.enabled,
  };
}

export function filterGlossary<
  T extends { source: string; translation: string; note: string },
>(entries: T[], query: string): T[] {
  const search = query.trim().toLowerCase();
  if (!search) return entries;

  return entries.filter((entry) =>
    [entry.source, entry.translation, entry.note].some((value) =>
      value.toLowerCase().includes(search),
    ),
  );
}

export function upsertGlossaryDraft<T extends GlossaryDraft & { id: string }>(
  entries: T[],
  draft: GlossaryDraft & { id: string },
): T[] {
  const index = entries.findIndex((entry) => entry.id === draft.id);
  if (index === -1) return [...entries, { ...draft } as T];

  return entries.map((entry, entryIndex) =>
    entryIndex === index ? { ...entry, ...draft } : entry,
  );
}
