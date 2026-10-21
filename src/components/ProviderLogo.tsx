import { Server, Terminal } from "lucide-react";
import deepseekLogo from "../assets/providers/deepseek.svg";
import openrouterLogo from "../assets/providers/openrouter.svg";
import openrouterDarkLogo from "../assets/providers/openrouter-dark.svg";
import type { ServiceChannel } from "../lib/platform";

export type { ServiceChannel } from "../lib/platform";

export function ProviderLogo({ channel }: { channel: ServiceChannel }) {
  if (channel === "apple")
    return (
      <span className="apple-glyph" aria-hidden="true">
        
      </span>
    );
  if (channel === "deepseek")
    return (
      <img
        className="official-provider-logo deepseek-logo"
        src={deepseekLogo}
        alt=""
        aria-hidden="true"
      />
    );
  if (channel === "openrouter")
    return (
      <picture className="official-provider-logo">
        <source
          media="(prefers-color-scheme: dark)"
          srcSet={openrouterDarkLogo}
        />
        <img src={openrouterLogo} alt="" aria-hidden="true" />
      </picture>
    );
  return channel === "customAPI" ? (
    <Server size={19} />
  ) : (
    <Terminal size={19} />
  );
}
