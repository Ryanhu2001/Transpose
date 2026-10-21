import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type {
  BridgeState,
  NativeAction,
  NativeEvent,
  NativeRequest,
  Payload,
} from "./types";
import { createDemoTransport } from "./demo";

export interface NativeTransport {
  mode: "tauri" | "native" | "demo" | "unavailable";
  request(action: NativeAction, payload?: Payload): Promise<BridgeState>;
  subscribe(listener: (event: NativeEvent) => void): Promise<() => void>;
}
declare global {
  interface Window {
    __TAURI_INTERNALS__?: unknown;
    webkit?: {
      messageHandlers?: {
        transpose?: { postMessage(message: NativeRequest): void };
      };
    };
  }
}
function requestTimeout(action: NativeAction) {
  return [
    "glossary_import",
    "glossary_export",
    "permission",
    "apple_prepare",
    "login_settings",
    "login_set",
  ].includes(action)
    ? 300000
    : 30000;
}
export function createNativeTransport(): NativeTransport {
  if (new URLSearchParams(location.search).get("preview") === "1")
    return createDemoTransport();
  if (window.webkit?.messageHandlers?.transpose) {
    const pending = new Map<
      string,
      {
        resolve: (state: BridgeState) => void;
        reject: (reason: Error) => void;
        timer: ReturnType<typeof setTimeout>;
      }
    >();
    const listeners = new Set<(event: NativeEvent) => void>();
    window.addEventListener("transpose:native", ((
      event: CustomEvent<NativeEvent>,
    ) => {
      const value = event.detail;
      if (!value || typeof value !== "object") return;
      if (value.type === "response") {
        const command = pending.get(value.id);
        if (!command) return;
        clearTimeout(command.timer);
        pending.delete(value.id);
        if (value.ok && value.data) command.resolve(value.data);
        else command.reject(new Error(value.error || "Native request failed."));
      } else listeners.forEach((listener) => listener(value));
    }) as EventListener);
    return {
      mode: "native",
      request: (action, payload = {}) =>
        new Promise((resolve, reject) => {
          if (action === "app_restart") {
            reject(new Error("Open Settings to reopen the app."));
            return;
          }
          const id = crypto.randomUUID();
          const timer = setTimeout(() => {
            pending.delete(id);
            reject(new Error("The app did not respond. Please try again."));
          }, requestTimeout(action));
          pending.set(id, { resolve, reject, timer });
          try {
            window.webkit!.messageHandlers!.transpose!.postMessage({
              id,
              action,
              payload,
            });
          } catch (error) {
            clearTimeout(timer);
            pending.delete(id);
            reject(error);
          }
        }),
      subscribe: async (listener) => {
        listeners.add(listener);
        return () => {
          listeners.delete(listener);
        };
      },
    };
  }
  if (window.__TAURI_INTERNALS__) {
    return {
      mode: "tauri",
      request: async (action, payload = {}) => {
        let timer: ReturnType<typeof setTimeout> | undefined;
        try {
          return await Promise.race([
            invoke<BridgeState>("native_request", { action, payload }),
            new Promise<never>((_, reject) => {
              timer = setTimeout(
                () =>
                  reject(
                    new Error("The app did not respond. Please try again."),
                  ),
                requestTimeout(action),
              );
            }),
          ]);
        } finally {
          clearTimeout(timer);
        }
      },
      subscribe: async (listener) => {
        return listen<NativeEvent>("native:event", (event) =>
          listener(event.payload),
        );
      },
    };
  }
  return {
    mode: "unavailable",
    request: async () => {
      throw new Error(
        "Open Transpose on your Mac to use this interface. For a local visual demo, add ?preview=1.",
      );
    },
    subscribe: async () => () => {},
  };
}
