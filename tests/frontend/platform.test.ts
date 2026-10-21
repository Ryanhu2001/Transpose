import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { afterEach, describe, expect, it, vi } from "vitest";
import { General } from "../../src/components/General";
import { PermissionSetup } from "../../src/components/PermissionSetup";
import { Result } from "../../src/components/Result";
import { Services } from "../../src/components/Services";
import { translator } from "../../src/components/common";
import { createDemoTransport } from "../../src/lib/demo";
import { platformFeatures, serviceChannels } from "../../src/lib/platform";
import type { BridgeState } from "../../src/lib/types";
import type { NativeClient } from "../../src/lib/useNative";

async function clientFor(search: string) {
  vi.stubGlobal("location", { search, hash: "" });
  const state = await createDemoTransport().request("snapshot");
  return {
    state,
    error: "",
    pending: new Set<string>(),
    request: vi.fn(async () => state),
    act: vi.fn(),
    clearError: vi.fn(),
    mode: "demo",
  } as NativeClient;
}

afterEach(() => vi.unstubAllGlobals());

describe("platform capabilities", () => {
  it("preserves macOS behavior for older Swift snapshots without platform fields", async () => {
    const client = await clientFor("?preview=1");
    const app = { ...client.state!.app };
    delete app.platform;
    delete app.capabilities;

    expect(platformFeatures(app)).toEqual({
      isWindows: false,
      captureShortcut: "⌥ S",
      selection: true,
      screenCapture: true,
      ocr: true,
    });
    expect(serviceChannels(app)).toEqual([
      "apple",
      "deepseek",
      "openrouter",
      "customAPI",
      "localCLI",
    ]);
  });

  it("requires explicit Windows capabilities and never offers Apple translation", async () => {
    const client = await clientFor("?preview=1&platform=windows");
    const app = { ...client.state!.app };
    delete app.capabilities;

    expect(platformFeatures(app)).toEqual({
      isWindows: true,
      captureShortcut: "Alt + S",
      selection: false,
      screenCapture: false,
      ocr: false,
    });
    // The preview includes Apple in its provider catalog to verify the platform guard.
    expect(app.providers.some((provider) => provider.id === "apple")).toBe(
      true,
    );
    expect(serviceChannels(app)).toEqual([
      "deepseek",
      "openrouter",
      "customAPI",
      "localCLI",
    ]);
  });

  it("does not invent service channels omitted by the native backend", async () => {
    const client = await clientFor("?preview=1&platform=windows");
    const app = {
      ...client.state!.app,
      providers: client.state!.app.providers.filter(
        (provider) => provider.id === "deepseek",
      ),
    };
    expect(serviceChannels(app)).toEqual(["deepseek"]);
  });
});

describe("Windows settings", () => {
  it("shows Alt + S, integration readiness, and no macOS permission requests", async () => {
    const client = await clientFor("?preview=1&platform=windows");
    const html = renderToStaticMarkup(
      createElement(General, {
        client,
        t: translator(client.state!.app),
        onServices: vi.fn(),
      }),
    );

    expect(html).toContain("Alt + S");
    expect(html).toContain("Windows Integration");
    expect(html).toContain("Windows UI Automation");
    expect(html).not.toContain("Accessibility");
    expect(html).not.toContain("Screen Recording");
    expect(html).not.toContain("⌥ S");
    expect(html).not.toContain("macOS");
    expect(
      renderToStaticMarkup(
        createElement(PermissionSetup, {
          client,
          t: translator(client.state!.app),
        }),
      ),
    ).toBe("");
  });

  it("shows OCR installation guidance and disables capture when no language pack is available", async () => {
    const client = await clientFor("?preview=1&platform=windows&ocr=missing");
    const html = renderToStaticMarkup(
      createElement(General, {
        client,
        t: translator(client.state!.app),
        onServices: vi.fn(),
      }),
    );

    expect(html).toContain("Setup needed");
    expect(html).toContain("Install an OCR language");
    const captureButton = html
      .match(/<button\b[^>]*>[\s\S]*?<\/button>/g)
      ?.find((button) => button.includes("Select Area"));
    expect(captureButton).toContain('disabled=""');
  });

  it("uses Windows credential wording and API services without Apple controls", async () => {
    const client = await clientFor("?preview=1&platform=windows");
    client.state!.app.settings.keyIsSaved = true;
    const html = renderToStaticMarkup(
      createElement(Services, {
        client,
        t: translator(client.state!.app),
      }),
    );

    expect(html).toContain("Windows Credential Manager");
    expect(html).toContain("Saved securely");
    expect(html).toContain('data-channels="4"');
    expect(html).not.toContain("Apple Translate");
    expect(html).not.toContain("Prepare Language Packs");
    expect(html).not.toContain("Keychain");
    expect(html).not.toContain("Mac");
  });

  it("keeps Windows setup and credential text localized in Chinese", async () => {
    const client = await clientFor("?preview=1&platform=windows&lang=zh");
    const t = translator(client.state!.app);
    const general = renderToStaticMarkup(
      createElement(General, { client, t, onServices: vi.fn() }),
    );
    const services = renderToStaticMarkup(
      createElement(Services, { client, t }),
    );

    expect(general).toContain("Windows 系统集成");
    expect(general).toContain("屏幕圈选与文字识别");
    expect(services).toContain("Windows 凭据管理器");
    expect(services).not.toContain("钥匙串");
  });

  it("keeps macOS permission setup and Apple translation available", async () => {
    const client = await clientFor("?preview=1");
    const t = translator(client.state!.app);
    const general = renderToStaticMarkup(
      createElement(General, { client, t, onServices: vi.fn() }),
    );
    const services = renderToStaticMarkup(
      createElement(Services, { client, t }),
    );

    expect(general).toContain("Accessibility");
    expect(general).toContain("Screen Recording");
    expect(general).toContain("⌥ S");
    expect(services).toContain("Apple Translate");
    expect(services).toContain("Prepare Language Packs");
  });

  it("uses explicit Windows header dragging while keeping result controls available", async () => {
    const client = await clientFor("?preview=1&platform=windows");
    const state = client.state as BridgeState;
    state.result = null;
    const html = renderToStaticMarkup(
      createElement(Result, {
        client,
        t: translator(state.app),
      }),
    );

    expect(html).not.toContain("data-tauri-drag-region");
    expect(html).toContain('aria-label="Pin window"');
    expect(html).toContain('aria-label="Close"');
    expect(html).toContain('aria-label="Resize translation window"');
    expect(html.match(/data-resize-direction=/g)).toHaveLength(8);
  });

  it("leaves native macOS result resizing with the existing system bridge", async () => {
    const client = await clientFor("?preview=1");
    const html = renderToStaticMarkup(
      createElement(Result, { client, t: translator(client.state!.app) }),
    );

    expect(html).not.toContain("result-resize-handle");
    expect(html).not.toContain("data-resize-direction");
    expect(html).toMatch(/<header[^>]*data-tauri-drag-region="deep"/);
  });
});
