import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createNativeTransport } from "../../src/lib/bridge";
import type {
  BridgeState,
  NativeAction,
  NativeEvent,
  NativeRequest,
} from "../../src/lib/types";

const tauri = vi.hoisted(() => ({ invoke: vi.fn(), listen: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: tauri.invoke }));
vi.mock("@tauri-apps/api/event", () => ({ listen: tauri.listen }));

function snapshot(version = "test"): BridgeState {
  return {
    app: {
      version,
      language: "english",
      locale: "en",
      settings: {
        provider: "apple",
        target: "smart",
        automaticSelection: true,
        preferences: "",
        baseURL: "",
        model: "",
        cliPath: "",
        keyIsSaved: false,
      },
      providers: [],
      glossary: [],
      detectedCLIs: [],
      permissions: { accessibility: false, screenRecording: false },
      loginItem: { status: "notRegistered" },
      apple: { supported: true, status: "" },
      status: {
        credential: "",
        connection: "",
        testingConnection: false,
        glossary: "",
      },
    },
    result: null,
  };
}

function installWindow(search = "") {
  const browser = new EventTarget();
  vi.stubGlobal("window", browser);
  vi.stubGlobal("location", { search, hash: "#/settings" });
  return browser;
}

function installWebKit() {
  const browser = installWindow();
  const messages: NativeRequest[] = [];
  const postMessage = vi.fn((message: NativeRequest) => messages.push(message));
  Object.assign(browser, {
    webkit: { messageHandlers: { transpose: { postMessage } } },
  });
  return { browser, messages, postMessage };
}

function emit(browser: EventTarget, detail: NativeEvent) {
  browser.dispatchEvent(new CustomEvent("transpose:native", { detail }));
}

beforeEach(() => {
  vi.useFakeTimers();
  tauri.invoke.mockReset();
  tauri.listen.mockReset();
});

afterEach(() => {
  vi.clearAllTimers();
  vi.useRealTimers();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("WebKit native transport", () => {
  it("matches out-of-order responses by request ID and clears their timers", async () => {
    const { browser, messages } = installWebKit();
    const transport = createNativeTransport();
    const first = transport.request("snapshot");
    const second = transport.request("provider_select", {
      provider: "deepseek",
    });

    expect(transport.mode).toBe("native");
    expect(messages).toHaveLength(2);
    expect(messages[0].id).not.toBe(messages[1].id);
    expect(messages[0]).toMatchObject({ action: "snapshot", payload: {} });
    expect(messages[1]).toMatchObject({
      action: "provider_select",
      payload: { provider: "deepseek" },
    });

    emit(browser, {
      type: "response",
      id: messages[1].id,
      ok: true,
      data: snapshot("second"),
    });
    emit(browser, {
      type: "response",
      id: messages[0].id,
      ok: true,
      data: snapshot("first"),
    });

    await expect(second).resolves.toEqual(snapshot("second"));
    await expect(first).resolves.toEqual(snapshot("first"));
    expect(vi.getTimerCount()).toBe(0);
  });

  it("rejects native errors without consuming another pending request", async () => {
    const { browser, messages } = installWebKit();
    const transport = createNativeTransport();
    const failed = transport.request("connection_test");
    const successful = transport.request("snapshot");
    const rejection = expect(failed).rejects.toThrow("Invalid API key.");

    emit(browser, {
      type: "response",
      id: messages[0].id,
      ok: false,
      error: "Invalid API key.",
    });
    emit(browser, {
      type: "response",
      id: "unrelated-id",
      ok: true,
      data: snapshot("unknown"),
    });
    emit(browser, {
      type: "response",
      id: messages[1].id,
      ok: true,
      data: snapshot("valid"),
    });

    await rejection;
    await expect(successful).resolves.toEqual(snapshot("valid"));
    expect(vi.getTimerCount()).toBe(0);
  });

  it("rejects an ordinary request after 30 seconds", async () => {
    const { browser, messages } = installWebKit();
    const transport = createNativeTransport();
    const request = transport.request("snapshot");
    const rejection = expect(request).rejects.toThrow(
      "The app did not respond. Please try again.",
    );
    const settled = vi.fn();
    void request.then(settled, settled);

    await vi.advanceTimersByTimeAsync(29_999);
    expect(settled).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    await rejection;
    expect(settled).toHaveBeenCalledTimes(1);
    expect(vi.getTimerCount()).toBe(0);

    // A late reply cannot revive a timed-out command.
    emit(browser, {
      type: "response",
      id: messages[0].id,
      ok: true,
      data: snapshot("late"),
    });
    expect(settled).toHaveBeenCalledTimes(1);
  });

  it.each<NativeAction>([
    "glossary_import",
    "glossary_export",
    "permission",
    "apple_prepare",
    "login_settings",
    "login_set",
  ])("allows five minutes for the system interaction %s", async (action) => {
    installWebKit();
    const request = createNativeTransport().request(action);
    const rejection = expect(request).rejects.toThrow(
      "The app did not respond. Please try again.",
    );
    const settled = vi.fn();
    void request.then(settled, settled);

    await vi.advanceTimersByTimeAsync(299_999);
    expect(settled).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    await rejection;
    expect(settled).toHaveBeenCalledTimes(1);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("forwards native events until the listener unsubscribes", async () => {
    const { browser } = installWebKit();
    const transport = createNativeTransport();
    const listener = vi.fn();
    const unsubscribe = await transport.subscribe(listener);
    const event: NativeEvent = { type: "snapshot", data: snapshot().app };

    emit(browser, event);
    expect(listener).toHaveBeenCalledExactlyOnceWith(event);
    unsubscribe();
    emit(browser, { type: "open_settings" });
    expect(listener).toHaveBeenCalledTimes(1);
  });

  it("rejects a synchronous bridge send error and releases its timer", async () => {
    const { postMessage } = installWebKit();
    postMessage.mockImplementation(() => {
      throw new Error("Bridge disconnected.");
    });
    await expect(createNativeTransport().request("snapshot")).rejects.toThrow(
      "Bridge disconnected.",
    );
    expect(vi.getTimerCount()).toBe(0);
  });

  it("rejects restart from the result WebKit bridge without posting a native command", async () => {
    const { postMessage, messages } = installWebKit();
    const request = createNativeTransport().request("app_restart");

    expect(postMessage).not.toHaveBeenCalled();
    expect(messages).toEqual([]);
    expect(vi.getTimerCount()).toBe(0);
    await expect(request).rejects.toThrow("Open Settings to reopen the app.");
  });
});

describe("browser and preview boundaries", () => {
  it("exposes a screen-recording restart requirement in the explicit restart preview", async () => {
    installWindow("?preview=1&permissions=restart");
    const transport = createNativeTransport();
    const state = await transport.request("snapshot");

    expect(transport.mode).toBe("demo");
    expect(state.app.permissions).toEqual({
      accessibility: true,
      screenRecording: false,
      screenRecordingNeedsRestart: true,
    });
  });

  it("keeps restart-required permissions unchanged when demo restart only shows guidance", async () => {
    installWindow("?preview=1&permissions=restart");
    const fetch = vi.fn();
    vi.stubGlobal("fetch", fetch);
    const transport = createNativeTransport();
    const before = await transport.request("snapshot");
    const response = await transport.request("app_restart");
    const after = await transport.request("snapshot");

    expect(response.app.status.connection).toMatch(/demo/i);
    expect(after.app.status.connection).toBe(response.app.status.connection);
    expect(response.app.permissions).toEqual(before.app.permissions);
    expect(after.app.permissions).toEqual({
      accessibility: true,
      screenRecording: false,
      screenRecordingNeedsRestart: true,
    });
    expect(fetch).not.toHaveBeenCalled();
    expect(tauri.invoke).not.toHaveBeenCalled();
  });

  it.each(["", "?preview=0", "?preview=true"])(
    "rejects unknown browsers at %j without entering demo mode",
    async (search) => {
      installWindow(search);
      const fetch = vi.fn();
      vi.stubGlobal("fetch", fetch);
      const transport = createNativeTransport();

      expect(transport.mode).toBe("unavailable");
      await expect(transport.request("snapshot")).rejects.toThrow(
        "Open the Transpose app",
      );
      expect(fetch).not.toHaveBeenCalled();
      expect(vi.getTimerCount()).toBe(0);
    },
  );

  it("explicitly marks preview as demo and never returns or transmits API key input", async () => {
    installWindow("?preview=1");
    const fetch = vi.fn();
    vi.stubGlobal("fetch", fetch);
    const transport = createNativeTransport();
    expect(transport.mode).toBe("demo");

    const initial = await transport.request("snapshot");
    expect(initial.app.settings.keyIsSaved).toBe(false);
    const secret = "test-secret-must-never-appear-in-state";
    const afterSave = await transport.request("key_save", {
      key: secret,
      apiKey: secret,
    });
    const next = await transport.request("snapshot");

    expect(JSON.stringify([initial, afterSave, next])).not.toContain(secret);
    expect(next.app.settings).not.toHaveProperty("apiKey");
    expect(next.app.settings).not.toHaveProperty("key");
    expect(fetch).not.toHaveBeenCalled();
    expect(tauri.invoke).not.toHaveBeenCalled();
  });
});

describe("Tauri transport", () => {
  it("invokes the native command and clears the completed timeout", async () => {
    const browser = installWindow();
    Object.assign(browser, { __TAURI_INTERNALS__: {} });
    tauri.invoke.mockResolvedValue(snapshot("tauri"));
    const transport = createNativeTransport();

    expect(transport.mode).toBe("tauri");
    await expect(
      transport.request("provider_select", { provider: "apple" }),
    ).resolves.toEqual(snapshot("tauri"));
    expect(tauri.invoke).toHaveBeenCalledExactlyOnceWith("native_request", {
      action: "provider_select",
      payload: { provider: "apple" },
    });
    expect(vi.getTimerCount()).toBe(0);
  });

  it("passes Tauri event payloads to subscribers and returns the native cleanup", async () => {
    const browser = installWindow();
    Object.assign(browser, { __TAURI_INTERNALS__: {} });
    const cleanup = vi.fn();
    tauri.listen.mockResolvedValue(cleanup);
    const listener = vi.fn();
    const unsubscribe = await createNativeTransport().subscribe(listener);
    const [channel, receive] = tauri.listen.mock.calls[0];
    expect(channel).toBe("native:event");
    const event: NativeEvent = { type: "open_settings" };
    receive({ payload: event });
    expect(listener).toHaveBeenCalledExactlyOnceWith(event);
    unsubscribe();
    expect(cleanup).toHaveBeenCalledTimes(1);
  });
});
