import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

export interface UpdateStatus {
  enabled?: boolean;
  revision?: number;
  phase:
    | "idle"
    | "checking"
    | "available"
    | "current"
    | "downloading"
    | "installing"
    | "unavailable"
    | "error";
  currentVersion: string;
  version?: string;
  notes?: string;
  downloaded?: number;
  total?: number;
  message?: string;
  errorCode?:
    | "check_failed"
    | "download_failed"
    | "install_failed"
    | "no_update"
    | "version_changed"
    | "busy"
    | "feed_unavailable";
}

export type UpdateAction = "status" | "check" | "install";
const CHECK_INTERVAL = 24 * 60 * 60 * 1000;
const checkedInSession = new Map<string, number>();

export function updateCheckKey(version: string) {
  return `transpose.update-check.${version}`;
}

export function shouldCheckForUpdates(
  status: UpdateStatus,
  lastChecked: number | null,
  now = Date.now(),
) {
  if (status.enabled === false) return false;
  if (!["idle", "current", "error", "unavailable"].includes(status.phase))
    return false;
  return (
    lastChecked === null ||
    !Number.isFinite(lastChecked) ||
    lastChecked <= 0 ||
    now < lastChecked ||
    now - lastChecked >= CHECK_INTERVAL
  );
}

export function lastUpdateCheck(version: string): number | null {
  const session = checkedInSession.get(version) ?? null;
  try {
    const stored = localStorage.getItem(updateCheckKey(version));
    return stored === null ? session : Number(stored);
  } catch {
    return session;
  }
}

export function rememberUpdateCheck(version: string, now = Date.now()) {
  checkedInSession.set(version, now);
  try {
    localStorage.setItem(updateCheckKey(version), String(now));
  } catch {
    // A session check still prevents repeated requests when storage is blocked.
  }
}

export function updateProgress(status: UpdateStatus): number | null {
  if (
    typeof status.downloaded !== "number" ||
    typeof status.total !== "number" ||
    !Number.isFinite(status.downloaded) ||
    !Number.isFinite(status.total) ||
    status.total <= 0
  )
    return null;
  return Math.min(100, Math.max(0, (status.downloaded / status.total) * 100));
}

export function requestUpdate(action: UpdateAction, version?: string) {
  if (action === "install" && !version)
    return Promise.reject(new Error("Choose an update before installing it."));
  return invoke<UpdateStatus>("app_updates", {
    action,
    ...(action === "install" ? { version } : {}),
  });
}

export function subscribeToUpdates(listener: (status: UpdateStatus) => void) {
  return listen<UpdateStatus>("app:update", (event) => listener(event.payload));
}

export interface UpdateView {
  status: UpdateStatus;
  pending: boolean;
}

// One session belongs to one mounted settings page. Native events are newer
// than in-flight command responses, and a stopped page cannot change its successor.
export class UpdateSession {
  private active = true;
  private revision = 0;
  private stopListening?: () => void;
  private timer?: ReturnType<typeof setTimeout>;
  private view: UpdateView;

  constructor(
    private version: string,
    private notify: (view: UpdateView) => void,
  ) {
    this.view = {
      status: { phase: "idle", currentVersion: version },
      pending: true,
    };
  }

  private emit() {
    if (this.active) this.notify({ ...this.view });
  }

  private receive(status: UpdateStatus, fallbackRevision?: number) {
    if (!this.active) return false;
    const previous = this.view.status.revision;
    if (typeof previous === "number") {
      if (typeof status.revision !== "number" || status.revision < previous)
        return false;
    } else if (
      typeof status.revision !== "number" &&
      fallbackRevision !== undefined &&
      fallbackRevision !== this.revision
    )
      return false;
    this.view.status = status;
    return true;
  }

  async start() {
    this.emit();
    const initialRevision = this.revision;
    try {
      const unsubscribe = await subscribeToUpdates((status) => {
        if (!this.receive(status)) return;
        this.revision++;
        this.emit();
      });
      if (!this.active) {
        unsubscribe();
        return;
      }
      this.stopListening = unsubscribe;
      const revision = this.revision;
      const initial = await requestUpdate("status");
      this.receive(initial, revision);
    } catch {
      if (this.active && initialRevision === this.revision)
        this.view.status = {
          ...this.view.status,
          phase: "error",
          currentVersion: this.version,
          errorCode: "check_failed",
        };
    } finally {
      if (this.active) {
        this.view.pending = false;
        this.emit();
      }
    }
    if (this.active) await this.checkIfDue();
  }

  async run(action: "check" | "install") {
    if (
      !this.active ||
      this.view.status.enabled === false ||
      this.view.pending ||
      ["checking", "downloading", "installing"].includes(this.view.status.phase)
    )
      return;
    const version = this.view.status.version;
    if (
      action === "install" &&
      (this.view.status.phase !== "available" || !version)
    )
      return;
    this.view.pending = true;
    this.view.status = {
      ...this.view.status,
      phase: action === "check" ? "checking" : "downloading",
      errorCode: undefined,
      downloaded: action === "install" ? 0 : undefined,
      total: undefined,
    };
    if (action === "check") rememberUpdateCheck(this.version);
    this.emit();
    const revision = this.revision;
    try {
      const status = await requestUpdate(action, version);
      this.receive(status, revision);
    } catch {
      if (this.active && revision === this.revision)
        this.view.status = {
          ...this.view.status,
          phase: "error",
          currentVersion: this.version,
          errorCode: action === "install" ? "install_failed" : "check_failed",
        };
    } finally {
      if (this.active) {
        this.view.pending = false;
        this.emit();
        this.schedule();
      }
    }
  }

  async checkIfDue() {
    if (!this.active || this.view.status.enabled === false) return;
    if (
      !this.view.pending &&
      shouldCheckForUpdates(this.view.status, lastUpdateCheck(this.version))
    )
      await this.run("check");
    this.schedule();
  }

  private schedule() {
    if (this.timer) clearTimeout(this.timer);
    if (!this.active || this.view.status.enabled === false) return;
    const lastChecked = lastUpdateCheck(this.version);
    const remaining =
      lastChecked === null || !Number.isFinite(lastChecked)
        ? CHECK_INTERVAL
        : CHECK_INTERVAL - (Date.now() - lastChecked);
    // Offered updates and in-progress installs remain untouched. One bounded
    // timer also checks when the settings window stays mounted across days.
    const delay = shouldCheckForUpdates(this.view.status, null)
      ? Math.max(1000, Math.min(CHECK_INTERVAL, remaining))
      : CHECK_INTERVAL;
    this.timer = setTimeout(() => void this.checkIfDue(), delay);
  }

  stop() {
    this.active = false;
    if (this.timer) clearTimeout(this.timer);
    this.stopListening?.();
  }
}
