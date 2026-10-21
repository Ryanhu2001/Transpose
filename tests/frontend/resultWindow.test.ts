import { describe, expect, it, vi } from "vitest";
import { startResultWindowDrag } from "../../src/lib/resultWindow";

function pointer(overrides: Record<string, unknown> = {}) {
  return {
    button: 0,
    isPrimary: true,
    target: { closest: vi.fn(() => null) } as unknown as EventTarget,
    preventDefault: vi.fn(),
    stopPropagation: vi.fn(),
    ...overrides,
  };
}

describe("translation window dragging", () => {
  it("starts one native move on a primary header press and prevents text selection", async () => {
    const event = pointer();
    const move = vi.fn(async () => {});
    await expect(startResultWindowDrag(event, move)).resolves.toBe(true);
    expect(move).toHaveBeenCalledOnce();
    expect(event.preventDefault).toHaveBeenCalledOnce();
    expect(event.stopPropagation).toHaveBeenCalledOnce();
  });

  it.each([1, 2])("leaves mouse button %s alone", async (button) => {
    const event = pointer({ button });
    const move = vi.fn(async () => {});
    await expect(startResultWindowDrag(event, move)).resolves.toBe(false);
    expect(move).not.toHaveBeenCalled();
    expect(event.preventDefault).not.toHaveBeenCalled();
  });

  it("leaves a secondary touch alone", async () => {
    const move = vi.fn(async () => {});
    await expect(
      startResultWindowDrag(pointer({ isPrimary: false }), move),
    ).resolves.toBe(false);
    expect(move).not.toHaveBeenCalled();
  });

  it("keeps pin and close button descendants clickable", async () => {
    const target = { closest: vi.fn(() => ({ tagName: "BUTTON" })) };
    const event = pointer({ target: target as unknown as EventTarget });
    const move = vi.fn(async () => {});
    await expect(startResultWindowDrag(event, move)).resolves.toBe(false);
    expect(target.closest).toHaveBeenCalledWith(
      expect.stringContaining("button"),
    );
    expect(event.preventDefault).not.toHaveBeenCalled();
    expect(move).not.toHaveBeenCalled();
  });

  it("reports native move failures for the result UI to display", async () => {
    const move = vi.fn(async () => {
      throw new Error("The window is unavailable.");
    });
    await expect(startResultWindowDrag(pointer(), move)).rejects.toThrow(
      "The window is unavailable.",
    );
  });
});
