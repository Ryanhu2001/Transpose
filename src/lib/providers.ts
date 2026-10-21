import type { ProviderID } from "./types";

export function preferredCLI(
  detected: { provider: ProviderID; path: string }[],
): ProviderID {
  if (detected.some((entry) => entry.provider === "codex")) return "codex";
  return (
    detected.find(
      (entry) =>
        entry.provider === "dsh" ||
        entry.provider === "claude" ||
        entry.provider === "kimi",
    )?.provider ?? "codex"
  );
}
