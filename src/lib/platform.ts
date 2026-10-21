import type { AppSnapshot } from "./types";

export type ServiceChannel =
  "apple" | "deepseek" | "openrouter" | "customAPI" | "localCLI";

export function platformFeatures(app: AppSnapshot) {
  const isWindows = app.platform === "windows";
  return {
    isWindows,
    captureShortcut: isWindows ? "Alt + S" : "⌥ S",
    selection: app.capabilities?.selection ?? !isWindows,
    screenCapture: app.capabilities?.screenCapture ?? !isWindows,
    ocr: app.capabilities?.ocr ?? !isWindows,
  };
}

export function serviceChannels(app: AppSnapshot): ServiceChannel[] {
  const channels: ServiceChannel[] = [];
  if (app.platform !== "windows" && app.providers.some((p) => p.id === "apple"))
    channels.push("apple");
  for (const id of ["deepseek", "openrouter", "customAPI"] as const) {
    if (app.providers.some((provider) => provider.id === id)) channels.push(id);
  }
  if (app.providers.some((provider) => provider.isCLI))
    channels.push("localCLI");
  return channels;
}
