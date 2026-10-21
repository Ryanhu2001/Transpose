import { describe, expect, it } from "vitest";
import {
  permissionSetup,
  type PermissionKind,
} from "../../src/lib/permissions";

describe("permission setup", () => {
  it.each<{
    accessibility: boolean;
    screenRecording: boolean;
    completed: number;
    next: PermissionKind | null;
  }>([
    {
      accessibility: false,
      screenRecording: false,
      completed: 0,
      next: "accessibility",
    },
    {
      accessibility: true,
      screenRecording: false,
      completed: 1,
      next: "screenRecording",
    },
    {
      accessibility: false,
      screenRecording: true,
      completed: 1,
      next: "accessibility",
    },
    { accessibility: true, screenRecording: true, completed: 2, next: null },
  ])(
    "reports the next step for accessibility=$accessibility, screenRecording=$screenRecording",
    (scenario) => {
      const state = permissionSetup(scenario);

      expect(state.completed).toBe(scenario.completed);
      expect(state.total).toBe(2);
      expect(state.visible).toBe(scenario.completed < 2);
      expect(state.next).toBe(scenario.next);
      expect(state.steps).toEqual([
        {
          kind: "accessibility",
          allowed: scenario.accessibility,
          isNext: scenario.next === "accessibility",
        },
        {
          kind: "screenRecording",
          allowed: scenario.screenRecording,
          isNext: scenario.next === "screenRecording",
        },
      ]);
      expect(state.steps.filter((step) => step.isNext)).toHaveLength(
        scenario.next === null ? 0 : 1,
      );
    },
  );

  it("leaves the input unchanged and returns independent step state", () => {
    const permissions = Object.freeze({
      accessibility: false,
      screenRecording: true,
    });
    const original = { ...permissions };
    const first = permissionSetup(permissions);
    const second = permissionSetup(permissions);

    expect(permissions).toEqual(original);
    expect(first).toEqual(second);
    expect(first).not.toBe(second);
    expect(first.steps).not.toBe(second.steps);
    expect(first.steps[0]).not.toBe(second.steps[0]);

    first.steps[0].allowed = true;
    expect(second.steps[0].allowed).toBe(false);
    expect(permissions.accessibility).toBe(false);
  });

  it("reflects newly granted permissions on the next calculation", () => {
    const permissions = { accessibility: false, screenRecording: false };
    const before = permissionSetup(permissions);
    permissions.accessibility = true;
    const after = permissionSetup(permissions);

    expect(before.next).toBe("accessibility");
    expect(before.completed).toBe(0);
    expect(after.next).toBe("screenRecording");
    expect(after.completed).toBe(1);
  });
});
