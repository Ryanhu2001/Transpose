# Translation services and glossary

Choose **Services / 翻译服务** in Settings: Apple, DeepSeek, OpenRouter, Custom API or Local CLI.

## Services

| Service | Setup |
| --- | --- |
| Apple Translation | macOS 15+, supported language pair and installed language packs |
| DeepSeek | Your API key and model; endpoint is editable |
| OpenRouter | Your API key; free router is subject to quota and availability |
| Custom API | OpenAI-compatible endpoint, model and a key if required |
| Local CLI | Install and authenticate `codex`, `claude`, `kimi` or `dsh` separately |

Apple Translation runs locally once its language pair is ready. Apple manages language downloads separately from the app. Very short or mixed-language text may be detected incorrectly.

API keys are scoped to the provider and endpoint in macOS Keychain. Test a connection after changing it. A successful test does not guarantee future quota or model availability.

OpenRouter provides [registration](https://openrouter.ai/) and [API keys](https://openrouter.ai/settings/keys). Free routes have limits; choosing another model may cost money. Transpose does not buy credits or silently switch to a paid route.

CLI detection finds an executable; it does not verify login or model access. Transpose does not rewrite global CLI configuration.

## Preferences and glossary

AI channels accept writing preferences and matching enabled glossary entries with the source text. Apple Translation uses system output and **does not apply them**. This is prompt guidance, not model training or an accuracy guarantee.

Each term has a source, translation, optional note and enabled switch. Confirm a validated draft to save it. Import JSON, CSV or TSV; export JSON. Duplicate source terms update their saved translation and note.

```json
[
  {
    "source": "environment scaling",
    "translation": "环境扩展",
    "note": "AI agent research",
    "enabled": true
  }
]
```

CSV/TSV headers are `source,translation,note,enabled`; the first two are required. Use UTF-8 and standard CSV quoting. See the [example glossary](example-glossary.json).

Imports are limited to 2 MB; the glossary supports 1,000 entries and 200,000 total characters. Per-entry limits: source 160, translation 360 and note 600 characters. Avoid putting secrets or unrelated private text in notes.
