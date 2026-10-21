import type { PointerEvent } from "react";

const WINDOW_CONTROLS =
  'button, a, input, textarea, select, [role="button"], [contenteditable="true"], [tabindex]:not([tabindex="-1"])';

/** Only the title area moves the floating window; its controls keep their clicks. */
export async function startResultWindowDrag(
  event: Pick<
    PointerEvent<HTMLElement>,
    "button" | "isPrimary" | "target" | "preventDefault" | "stopPropagation"
  >,
  startDragging: () => Promise<void>,
): Promise<boolean> {
  const target = event.target as Element | null;
  if (
    event.button !== 0 ||
    event.isPrimary === false ||
    target?.closest?.(WINDOW_CONTROLS)
  ) {
    return false;
  }
  event.preventDefault();
  event.stopPropagation();
  await startDragging();
  return true;
}
