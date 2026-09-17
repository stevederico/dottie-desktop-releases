# AGENTS.md

Guidance for humans and coding agents working in this repository.

## Product

Dottie is a native macOS AI voice assistant (bundle ID `com.example.dottie`).  
Swift app + local Rust gateway. Chat defaults to **Dottie Pro** / Grok; optional BYOK clouds, **Ollama**, or **Dottie Local**. Local STT (`parakeet-server`) + TTS (`koko`) stay on-device.

Public source + Release zips live in this repo (`stevederico/dottie-desktop-releases`).

## Docs (read these)

| Doc | Use |
|---|---|
| [README.md](README.md) | Features and user-facing setup |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Clone, build, PR guidelines (public-friendly) |

Release history lives on GitHub Releases (no in-repo changelog).

## Layout

```
client/
  Dottie.xcodeproj
  Dottie/                 SwiftUI sources (feature folders)
    Dottie.entitlements           app target
    EmbeddedRuntime.entitlements  bundled node (V8 JIT)
    inference.entitlements        parakeet / koko signing
    ExportOptions.plist           archive export
    ObjC/                 DTExceptionCatcher only — see Conventions
gateway/                  Rust std gateway on :1317
  scripts/                start_gateway, build_node_bundle, reset, stop
  dottie-mac-use/         git submodule (stevederico/dottie-mac-use) — public
  dottie-talk/            git submodule (stevederico/dottie-talk) — public
```

Voice bins live in `gateway/dottie-talk/bin/` (`parakeet-server`, `koko`, `espeak-ng-data`).

**Clone:** `git clone --recurse-submodules <url>` (or `git submodule update --init` after clone).

## Runtime map

| Port | Role |
|------|------|
| 1317 | Gateway (HTTP + WS `/v1/realtime`) — Swift talks here |
| 1321 | `dottie-mac-use` HTTP — Mac tools façade |
| 1320 | `dottie-talk` HTTP — STT/TTS façade |
| 1319 | `dottie-mac-use-ax` (Accessibility / EventKit) — owned by mac-use |
| 1318 | Dottie Local (optional) — OpenAI-compatible chat |
| 1315 | `parakeet-server` (local STT) — owned by talk |
| 1314 | `koko` (local TTS) — owned by talk |
| 11434 | Ollama (optional) — when Provider = Ollama |

Auth: bearer token at `~/.dottie/agent_token` (except `/health`).  
User config: `~/.dottie/config.json`. Logs: `~/.dottie/logs/`.

## Packages inside the gateway

- **`dottie-mac-use`** — macOS tools + MCP; AX via `dottie-mac-use-ax` CLI
- **`dottie-talk`** — local STT/TTS helpers + MCP

## Conventions

- **UI:** Match existing SwiftUI patterns (SF system font). Orb is the hero; no decorative card/glow sprawl.
- **Swift:** Prefer existing patterns (`GatewayClient`, `RealtimeClient`, `AppLogger`). No raw `print` / `NSLog` on failure paths.
- **ObjC bridge (`client/Dottie/ObjC/`):** Keep. `DTTryBlock` catches AVFoundation `NSException`s (`installTap` / `scheduleBuffer`) that Swift `do/catch` cannot — without it those throws SIGABRT. Bridging header: `Dottie-Bridging-Header.h`. Call sites: `AudioTapInstaller`, `RealtimeClient+AudioPlayback`. Do not delete as “odd exception.”
- **Signing:** Shared defaults in `client/Signing.xcconfig` (`com.example.dottie`, empty Team). Local overrides: `cp client/Release.xcconfig.example client/Release.xcconfig` (gitignored). Never commit `Release.xcconfig`.
- **Signing plists:** App = `Dottie.entitlements`. Nested bins = `inference.entitlements` / `EmbeddedRuntime.entitlements` (same `Dottie/` folder).
- **Gateway:** Rust `std` + system `libsqlite3` / `libcurl`. Use `log` module. No crates.io deps.
- **Talk / mac-use:** Node façades supervised by the gateway. Tool failures logged in wrapExecute — don’t sprinkle per-tool catch logs.
- **Secrets:** Never commit `.env`, tokens, or API keys. Runtime secrets live under `~/.dottie/`, not in the repo.
- **Scope:** Smallest change that fixes the ask. No drive-by refactors.
- **Tests:** `cargo test` under `gateway/`; Swift tests under `client/DottieTests/` when present.

## Local build (Release → `/Applications`)

Use Xcode’s Developer tools and the project’s Release archive/export flow for `client/Dottie.xcodeproj` (scheme `Dottie`).  
Replace `/Applications/Dottie.app` with a fresh copy after export (do not overwrite a signed bundle in place).  
Version format is CalVer: `YYYY.M.D` or `YYYY.M.D.N`.

## What not to do

- Don’t recreate a shared credentials symlink into the bundle.
- Don’t put Team ID, ASC IDs, or notarize secrets in the shared tree.
