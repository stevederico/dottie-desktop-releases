# Contributing

Thanks for helping with Dottie.

## Setup

macOS 15.4+, Apple Silicon. Xcode + Rust toolchain required.

```bash
git clone --recurse-submodules https://github.com/stevederico/dottie-desktop-releases.git
cd dottie-desktop
cd gateway && cargo build --release && cd ..
open client/Dottie.xcodeproj   # scheme: Dottie
```

Or start the gateway alone:

```bash
bash gateway/scripts/start_gateway.sh
```

Health check: `curl -s http://127.0.0.1:1317/health`

`dottie-mac-use` and `dottie-talk` are **git submodules** (public). Always clone with `--recurse-submodules`, or run `git submodule update --init` after clone.

## Layout

| Path | Role |
|------|------|
| `client/` | SwiftUI app (`Dottie.xcodeproj`) |
| `gateway/` | Rust gateway (`dottie-gateway`) on `:1317` |
| `gateway/dottie-mac-use/` | Mac tools + Accessibility (Node) |
| `gateway/dottie-talk/` | Local STT/TTS façade (Node) |

Signing plists for the app and nested binaries live under `client/Dottie/`.

Local Apple Team ID (optional): `cp client/Release.xcconfig.example client/Release.xcconfig` and edit — that file is gitignored.

## Tests

```bash
cd gateway && cargo test
```

## Pull requests

- Prefer the **smallest change** that fixes the ask
- Match existing SwiftUI / Rust patterns
- Do not commit secrets (`.env`, tokens, API keys, Team IDs)
- Do not commit `.app` / `.zip` / model weights — Release assets only
- Runtime config stays under `~/.dottie/` (not in the repo)

## Docs

- User-facing: [README.md](README.md)
- Agent / maintainer conventions: [AGENTS.md](AGENTS.md)
- Releases: [dottie-desktop-releases](https://github.com/stevederico/dottie-desktop-releases/releases)

## License

[MIT](LICENSE) — Copyright (c) 2026 Steve Derico.
