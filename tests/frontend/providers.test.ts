import { describe, expect, it } from "vitest";
import { preferredCLI } from "../../src/lib/providers";
import type { ProviderID } from "../../src/lib/types";

describe("preferred local CLI", () => {
  it("prefers Codex even when another CLI was detected first", () => {
    expect(
      preferredCLI([
        { provider: "claude", path: "/usr/local/bin/claude" },
        { provider: "codex", path: "/usr/local/bin/codex" },
        { provider: "kimi", path: "/usr/local/bin/kimi" },
      ]),
    ).toBe("codex");
  });

  it("preserves detection order among the other supported CLIs", () => {
    const providers: ProviderID[] = ["dsh", "claude", "kimi"];
    for (const first of providers) {
      const ordered = [
        first,
        ...providers.filter((provider) => provider !== first),
      ];
      expect(
        preferredCLI(
          ordered.map((provider) => ({ provider, path: `/bin/${provider}` })),
        ),
      ).toBe(first);
    }
  });

  it("defaults to Codex when no CLI was detected", () => {
    expect(preferredCLI([])).toBe("codex");
  });

  it("ignores API providers in malformed detection results", () => {
    const apiEntries: { provider: ProviderID; path: string }[] = [
      { provider: "apple", path: "" },
      { provider: "deepseek", path: "/invalid/deepseek" },
      { provider: "openrouter", path: "" },
      { provider: "customAPI", path: "" },
    ];
    expect(preferredCLI(apiEntries)).toBe("codex");
    expect(
      preferredCLI([...apiEntries, { provider: "kimi", path: "/bin/kimi" }]),
    ).toBe("kimi");
  });

  it("does not reorder or mutate the original detection results", () => {
    const detected: { provider: ProviderID; path: string }[] = [
      Object.freeze({ provider: "kimi", path: "/bin/kimi" }),
      Object.freeze({ provider: "codex", path: "/bin/codex" }),
      Object.freeze({ provider: "dsh", path: "/bin/dsh" }),
    ];
    const original = detected.map((entry) => ({ ...entry }));
    Object.freeze(detected);

    expect(preferredCLI(detected)).toBe("codex");
    expect(detected).toEqual(original);
  });
});
