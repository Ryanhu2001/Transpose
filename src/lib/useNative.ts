import { useCallback, useEffect, useRef, useState } from "react";
import { createNativeTransport } from "./bridge";
import type { BridgeState, NativeAction, Payload } from "./types";

const transport = createNativeTransport();
export function useNative() {
  const [state, setState] = useState<BridgeState | null>(null);
  const [error, setError] = useState("");
  const [pending, setPending] = useState<Set<string>>(new Set());
  const mounted = useRef(true);
  const pendingCounts = useRef(new Map<string, number>());
  useEffect(() => {
    mounted.current = true;
    let active = true;
    let unsubscribe: (() => void) | undefined;
    void (async () => {
      try {
        const stop = await transport.subscribe((event) => {
          if (!active) return;
          if (event.type === "snapshot")
            setState((previous) =>
              previous ? { ...previous, app: event.data } : null,
            );
          if (event.type === "result")
            setState((previous) =>
              previous ? { ...previous, result: event.data } : null,
            );
        });
        if (!active) {
          stop();
          return;
        }
        unsubscribe = stop;
        const initial = await transport.request("snapshot");
        if (active) setState(initial);
      } catch (reason) {
        if (active)
          setError(String(reason instanceof Error ? reason.message : reason));
      }
    })();
    return () => {
      active = false;
      mounted.current = false;
      unsubscribe?.();
    };
  }, []);
  const request = useCallback(
    async (action: NativeAction, payload: Payload = {}) => {
      setError("");
      pendingCounts.current.set(
        action,
        (pendingCounts.current.get(action) ?? 0) + 1,
      );
      setPending(new Set(pendingCounts.current.keys()));
      try {
        const next = await transport.request(action, payload);
        if (mounted.current) setState(next);
        return next;
      } catch (reason) {
        const message =
          reason instanceof Error ? reason.message : String(reason);
        if (mounted.current) setError(message);
        throw reason;
      } finally {
        const remaining = (pendingCounts.current.get(action) ?? 1) - 1;
        if (remaining > 0) pendingCounts.current.set(action, remaining);
        else pendingCounts.current.delete(action);
        if (mounted.current) setPending(new Set(pendingCounts.current.keys()));
      }
    },
    [],
  );
  const act = useCallback(
    (action: NativeAction, payload: Payload = {}) => {
      void request(action, payload).catch(() => {});
    },
    [request],
  );
  return {
    state,
    error,
    pending,
    request,
    act,
    clearError: () => setError(""),
    mode: transport.mode,
  };
}
export type NativeClient = ReturnType<typeof useNative>;
