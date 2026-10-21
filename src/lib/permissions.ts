export type PermissionKind = "accessibility" | "screenRecording";

export function permissionSetup(permissions: {
  accessibility: boolean;
  screenRecording: boolean;
}): {
  completed: number;
  total: 2;
  visible: boolean;
  next: PermissionKind | null;
  steps: { kind: PermissionKind; allowed: boolean; isNext: boolean }[];
} {
  const kinds: PermissionKind[] = ["accessibility", "screenRecording"];
  const next = kinds.find((kind) => !permissions[kind]) ?? null;
  const completed = kinds.filter((kind) => permissions[kind]).length;

  return {
    completed,
    total: 2,
    visible: completed < 2,
    next,
    steps: kinds.map((kind) => ({
      kind,
      allowed: permissions[kind],
      isNext: kind === next,
    })),
  };
}
