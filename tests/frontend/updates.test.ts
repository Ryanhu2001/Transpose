import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  lastUpdateCheck,
  rememberUpdateCheck,
  requestUpdate,
  shouldCheckForUpdates,
  subscribeToUpdates,
  updateCheckKey,
  updateProgress,
  UpdateSession,
  type UpdateStatus,
  type UpdateView,
} from "../../src/lib/updates";

const tauri = vi.hoisted(() => ({ invoke: vi.fn(), listen: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: tauri.invoke }));
vi.mock("@tauri-apps/api/event", () => ({ listen: tauri.listen }));

const day = 24 * 60 * 60 * 1000;
const now = 1_800_000_000_000;
const idle: UpdateStatus = { phase: "idle", currentVersion: "0.6.0" };

beforeEach(() => {
  tauri.invoke.mockReset();
  tauri.listen.mockReset();
});
afterEach(() => vi.unstubAllGlobals());

describe("update checks", () => {
  it("checks at most daily and allows a manual clock correction", () => {
    expect(shouldCheckForUpdates(idle, null, now)).toBe(true);
    expect(shouldCheckForUpdates(idle, now - day + 1, now)).toBe(false);
    expect(shouldCheckForUpdates(idle, now - day, now)).toBe(true);
    expect(shouldCheckForUpdates(idle, now + 1, now)).toBe(true);
    expect(shouldCheckForUpdates(idle, Number.NaN, now)).toBe(true);
  });

  it.each<UpdateStatus["phase"]>([
    "checking",
    "available",
    "downloading",
    "installing",
  ])("preserves an existing %s operation or offered version", (phase) => {
    expect(shouldCheckForUpdates({ ...idle, phase }, null, now)).toBe(false);
  });

  it("can check again when a release feed becomes available", () => {
    expect(
      shouldCheckForUpdates({ ...idle, phase: "unavailable" }, null, now),
    ).toBe(true);
  });

  it("stores check time by installed version", () => {
    const storage = new Map<string, string>();
    vi.stubGlobal("localStorage", {
      getItem: (key: string) => storage.get(key) ?? null,
      setItem: (key: string, value: string) => storage.set(key, value),
    });
    rememberUpdateCheck("storage-test", now);
    expect(storage.get(updateCheckKey("storage-test"))).toBe(String(now));
    expect(lastUpdateCheck("storage-test")).toBe(now);
    expect(lastUpdateCheck("new-installed-version")).toBeNull();
  });

  it("limits checks within the session when browser storage is blocked", () => {
    vi.stubGlobal("localStorage", {
      getItem: () => {
        throw new Error("Storage blocked");
      },
      setItem: () => {
        throw new Error("Storage blocked");
      },
    });
    expect(() =>
      rememberUpdateCheck("blocked-storage-test", now),
    ).not.toThrow();
    expect(lastUpdateCheck("blocked-storage-test")).toBe(now);
    expect(
      shouldCheckForUpdates(idle, lastUpdateCheck("blocked-storage-test"), now),
    ).toBe(false);
  });
});

describe("update progress", () => {
  it("handles absent length and clamps finite progress", () => {
    expect(updateProgress({ ...idle, downloaded: 100 })).toBeNull();
    expect(updateProgress({ ...idle, downloaded: 100, total: 0 })).toBeNull();
    expect(
      updateProgress({ ...idle, downloaded: Infinity, total: 100 }),
    ).toBeNull();
    expect(updateProgress({ ...idle, downloaded: 125, total: 100 })).toBe(100);
    expect(updateProgress({ ...idle, downloaded: -1, total: 100 })).toBe(0);
    expect(updateProgress({ ...idle, downloaded: 25, total: 100 })).toBe(25);
  });
});

describe("updater bridge", () => {
  it("passes the version the user chose to the native installer", async () => {
    tauri.invoke.mockResolvedValue({ ...idle, phase: "installing" });
    await requestUpdate("install", "0.7.0");
    expect(tauri.invoke).toHaveBeenCalledExactlyOnceWith("app_updates", {
      action: "install",
      version: "0.7.0",
    });
  });

  it("rejects an install without a chosen version before native IPC", async () => {
    await expect(requestUpdate("install")).rejects.toThrow(
      "Choose an update before installing it.",
    );
    expect(tauri.invoke).not.toHaveBeenCalled();
  });

  it("only checks the network when explicitly requested", async () => {
    tauri.invoke.mockResolvedValue(idle);
    await requestUpdate("status");
    expect(tauri.invoke).toHaveBeenCalledExactlyOnceWith("app_updates", {
      action: "status",
    });
  });

  it("subscribes to native download progress and releases its listener", async () => {
    const stop = vi.fn();
    const listener = vi.fn();
    tauri.listen.mockResolvedValue(stop);
    const unsubscribe = await subscribeToUpdates(listener);
    const [channel, receive] = tauri.listen.mock.calls[0];
    expect(channel).toBe("app:update");
    const status = {
      ...idle,
      phase: "downloading",
      downloaded: 20,
      total: 100,
    };
    receive({ payload: status });
    expect(listener).toHaveBeenCalledExactlyOnceWith(status);
    unsubscribe();
    expect(stop).toHaveBeenCalledOnce();
  });
});

describe("settings update session", () => {
  let event: (value: { payload: UpdateStatus }) => void;
  let stopListening: ReturnType<typeof vi.fn>;
  const current = (version: string, revision = 0): UpdateStatus => ({
    phase: "current",
    currentVersion: version,
    revision,
  });

  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(now);
    const storage = new Map<string, string>();
    vi.stubGlobal("localStorage", {
      getItem: (key: string) => storage.get(key) ?? null,
      setItem: (key: string, value: string) => storage.set(key, value),
    });
    stopListening = vi.fn();
    tauri.listen.mockImplementation(async (_, callback) => {
      event = callback;
      return stopListening;
    });
  });

  afterEach(() => {
    vi.clearAllTimers();
    vi.useRealTimers();
  });

  it("keeps one timer and checks again after a resident settings page reaches a day", async () => {
    const version = "daily-session";
    tauri.invoke.mockResolvedValue(current(version));
    const session = new UpdateSession(version, vi.fn());
    await session.start();
    expect(tauri.invoke.mock.calls.map((call) => call[1].action)).toEqual([
      "status",
      "check",
    ]);
    expect(vi.getTimerCount()).toBe(1);

    await session.checkIfDue();
    expect(vi.getTimerCount()).toBe(1);
    await vi.advanceTimersByTimeAsync(day - 1);
    expect(tauri.invoke).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(1);
    expect(tauri.invoke.mock.calls.at(-1)?.[1].action).toBe("check");
    expect(tauri.invoke).toHaveBeenCalledTimes(3);
    expect(vi.getTimerCount()).toBe(1);
    session.stop();
    expect(vi.getTimerCount()).toBe(0);
    expect(stopListening).toHaveBeenCalledOnce();
  });

  it("never downloads an offered release until the user chooses install", async () => {
    const version = "offered-session";
    const offered: UpdateStatus = {
      phase: "available",
      currentVersion: version,
      version: "0.7.0",
      revision: 1,
    };
    tauri.invoke
      .mockResolvedValueOnce(current(version))
      .mockResolvedValue(offered);
    const session = new UpdateSession(version, vi.fn());
    await session.start();
    await vi.advanceTimersByTimeAsync(day);
    await session.checkIfDue();
    expect(tauri.invoke).toHaveBeenCalledTimes(2);

    await session.run("install");
    expect(tauri.invoke).toHaveBeenLastCalledWith("app_updates", {
      action: "install",
      version: "0.7.0",
    });
    session.stop();
  });

  it("preserves newer progress events over older command replies and late events", async () => {
    const version = "event-race-session";
    rememberUpdateCheck(version, now);
    let resolveCheck!: (value: UpdateStatus) => void;
    tauri.invoke.mockResolvedValueOnce(current(version)).mockImplementationOnce(
      () =>
        new Promise<UpdateStatus>((resolve) => {
          resolveCheck = resolve;
        }),
    );
    let latest!: UpdateView;
    const session = new UpdateSession(version, (view) => {
      latest = view;
    });
    await session.start();
    const checking = session.run("check");
    event({
      payload: {
        ...current(version, 3),
        phase: "available",
        version: "0.7.0",
      },
    });
    resolveCheck({ ...current(version, 2), phase: "checking" });
    await checking;
    expect(latest.status.phase).toBe("available");
    expect(latest.pending).toBe(false);
    event({ payload: { ...current(version, 1), phase: "checking" } });
    expect(latest.status.phase).toBe("available");
    session.stop();
  });

  it("accepts a newer native reply even if an earlier progress event arrived first", async () => {
    const version = "reply-race-session";
    rememberUpdateCheck(version, now);
    let resolveCheck!: (value: UpdateStatus) => void;
    tauri.invoke.mockResolvedValueOnce(current(version)).mockImplementationOnce(
      () =>
        new Promise<UpdateStatus>((resolve) => {
          resolveCheck = resolve;
        }),
    );
    let latest!: UpdateView;
    const session = new UpdateSession(version, (view) => {
      latest = view;
    });
    await session.start();
    const checking = session.run("check");
    event({ payload: { ...current(version, 1), phase: "checking" } });
    resolveCheck({ ...current(version, 2), phase: "current" });
    await checking;
    expect(latest.status.phase).toBe("current");
    expect(latest.status.revision).toBe(2);
    session.stop();
  });

  it("ignores an old mount after cleanup while the replacement is active", async () => {
    const version = "remount-session";
    rememberUpdateCheck(version, now);
    let resolveOld!: (value: UpdateStatus) => void;
    tauri.invoke.mockImplementationOnce(
      () =>
        new Promise<UpdateStatus>((resolve) => {
          resolveOld = resolve;
        }),
    );
    const oldNotify = vi.fn();
    const old = new UpdateSession(version, oldNotify);
    const oldStart = old.start();
    await vi.advanceTimersByTimeAsync(0);
    old.stop();
    const notificationsBefore = oldNotify.mock.calls.length;
    tauri.invoke.mockResolvedValue(current(version, 2));
    let latest!: UpdateView;
    const replacement = new UpdateSession(version, (view) => {
      latest = view;
    });
    await replacement.start();
    resolveOld({ ...current(version, 1), phase: "error" });
    await oldStart;
    expect(oldNotify).toHaveBeenCalledTimes(notificationsBefore);
    expect(latest.status.phase).toBe("current");
    expect(vi.getTimerCount()).toBe(1);
    replacement.stop();
  });

  it("keeps diagnostic sessions inert without stamping a network check", async () => {
    const version = "diagnostic-session";
    tauri.invoke.mockResolvedValue({ ...current(version), enabled: false });
    const session = new UpdateSession(version, vi.fn());
    await session.start();
    await session.checkIfDue();
    await session.run("check");
    await session.run("install");
    expect(tauri.invoke).toHaveBeenCalledExactlyOnceWith("app_updates", {
      action: "status",
    });
    expect(lastUpdateCheck(version)).toBeNull();
    expect(vi.getTimerCount()).toBe(0);
    session.stop();
  });
});
