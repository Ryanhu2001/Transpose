# Contributing

Issues and focused PRs are welcome in English or Chinese.

1. Read [Development](docs/development.md) and [Privacy](docs/privacy.md).
2. Create a feature branch from **`main`** and open your PR against **`main`**.
3. Keep interface code in `src/`, Rust in `src-tauri/` and macOS functionality in `native/Sources/TransposeNative/`.
4. Run `npm ci`, `./verify.sh` and `./build.sh`.
5. Describe the problem, change, checks and any interactions not tested.

Maintainers develop on a local **`dev`** branch. Only **`main`** is kept permanently on the remote; publish a feature branch when needed for a PR, then remove it after merging. Tags and download releases are separate maintainer actions.

Preserve the small translation entry point, source-app focus, explicit permissions and optional login startup. Document the purpose of new dependencies, permissions and service adapters. Do not commit credentials, provider accounts, private preferences or generated bundles.

Bug reports should include the version or commit, macOS version, service, source app and reproduction steps. Remove private content. Report sensitive issues through [private vulnerability reporting](https://github.com/Ryanhu2001/Transpose/security/advisories/new).
