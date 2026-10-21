import type { PointerEvent } from "react";

const WINDOW_CONTROLS =
  'button, a, input, textarea, select, [role="button"], [contenteditable="true"], [tabindex]:not([tabindex="-1"])';

export const RESULT_RESIZE_DIRECTIONS = [
  "North",
  "NorthEast",
  "East",
  "SouthEast",
  "South",
  "SouthWest",
  "West",
  "NorthWest",
] as const;

type WindowPointer = Pick<
  PointerEvent<HTMLElement>,
  "button" | "isPrimary" | "target" | "preventDefault" | "stopPropagation"
>;
type ResultResizeDirection = (typeof RESULT_RESIZE_DIRECTIONS)[number];

function claimWindowPointer(event: WindowPointer): boolean {
  if (event.button !== 0 || event.isPrimary === false) return false;
  event.preventDefault();
  event.stopPropagation();
  return true;
}

/** Only the title area moves the floating window; its controls keep their clicks. */
export async function startResultWindowDrag(
  event: WindowPointer,
  startDragging: () => Promise<void>,
): Promise<boolean> {
  const target = event.target as Element | null;
  if (target?.closest?.(WINDOW_CONTROLS) || !claimWindowPointer(event)) {
    return false;
  }
  await startDragging();
  return true;
}

/** Windows owns pointer capture and enforces the native minimum window size. */
export async function startResultWindowResize(
  event: WindowPointer,
  direction: ResultResizeDirection,
  startResizeDragging: (direction: ResultResizeDirection) => Promise<void>,
): Promise<boolean> {
  if (!claimWindowPointer(event)) return false;
  await startResizeDragging(direction);
  return true;
}
