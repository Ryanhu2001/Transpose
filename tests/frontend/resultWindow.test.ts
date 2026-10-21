import { describe, expect, it, vi } from "vitest";
import {
  RESULT_RESIZE_DIRECTIONS,
  startResultWindowDrag,
  startResultWindowResize,
} from "../../src/lib/resultWindow";

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

describe("translation window resizing", () => {
  it.each(RESULT_RESIZE_DIRECTIONS)(
    "hands %s resizing to the native window and prevents title dragging",
    async (direction) => {
      const event = pointer();
      const resize = vi.fn(async () => {});
      await expect(
        startResultWindowResize(event, direction, resize),
      ).resolves.toBe(true);
      expect(resize).toHaveBeenCalledExactlyOnceWith(direction);
      expect(event.preventDefault).toHaveBeenCalledOnce();
      expect(event.stopPropagation).toHaveBeenCalledOnce();
    },
  );

  it.each([{ button: 1 }, { button: 2 }, { isPrimary: false }])(
    "ignores unsupported resize pointers %j",
    async (overrides) => {
      const event = pointer(overrides);
      const resize = vi.fn(async () => {});
      await expect(
        startResultWindowResize(event, "SouthEast", resize),
      ).resolves.toBe(false);
      expect(resize).not.toHaveBeenCalled();
      expect(event.preventDefault).not.toHaveBeenCalled();
    },
  );

  it("accepts the visible resize button without treating it as a title control", async () => {
    const event = pointer({
      target: {
        closest: () => ({ tagName: "BUTTON" }),
      } as unknown as EventTarget,
    });
    const resize = vi.fn(async () => {});
    await expect(
      startResultWindowResize(event, "SouthEast", resize),
    ).resolves.toBe(true);
    expect(resize).toHaveBeenCalledOnce();
  });

  it("reports native resize failures for the result UI to display", async () => {
    const resize = vi.fn(async () => {
      throw new Error("The window is unavailable.");
    });
    await expect(
      startResultWindowResize(pointer(), "East", resize),
    ).rejects.toThrow("The window is unavailable.");
  });
});
