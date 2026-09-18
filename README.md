<div align="center">
  <a href="https://www.dottie.ai">
    <img src="client/Dottie/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" width="96" height="96" alt="Dottie">
  </a>
  <h1 style="border-bottom: none; margin-bottom: 0;">Dottie</h1>
  <h3 style="margin-top: 0; font-weight: normal;">
    desktop voice assistant - rust gateway, on-device speech, grok by default
  </h3>
  <p>
    <a href="https://www.dottie.ai"><strong>Website</strong></a>
    ·
    <a href="https://github.com/stevederico/dottie-desktop-releases/releases"><strong>Releases</strong></a>
  </p>
</div>

<br />

## 🚀 Quick Start

**Users**

1. Download the latest app from [Releases](https://github.com/stevederico/dottie-desktop-releases/releases)
2. Open **Dottie.app** (macOS 15.4+, Apple Silicon)
3. Create an account and grant mic / accessibility when asked
4. Chat uses **Dottie Pro** by default — optional **Dottie Local** / **Ollama** or BYOK **xAI** in Settings

**Developers**

```bash
git clone --recurse-submodules https://github.com/stevederico/dottie-desktop-releases.git
cd dottie-desktop
cd gateway && cargo build --release && cd ..
open client/Dottie.xcodeproj   # scheme: Dottie
```

Gateway listens on **http://127.0.0.1:1317**. Health: `curl -s http://127.0.0.1:1317/health`

Or: `bash gateway/scripts/start_gateway.sh`

<br />

## ✨ What's Included

Everything you need for a private Mac voice agent with a cloud-default brain:

### 🎙️ **Voice & Dictation**
- **Push-to-talk** — hold `Option+Space`, release to type at the cursor
- **Live transcription** — streaming STT with end-of-utterance detection
- **Grok Voice** — Pro / xAI send mic audio through the relay (or BYOK xAI)
- **On-device STT** — Parakeet (`parakeet-server`, Metal) for Dottie Local / Ollama and non-Grok paths
- **VoiceWake** — “Hey Dottie” via Apple Speech (Settings → Voice)

### 🔊 **Text-to-Speech**
- **koko (Kokoros)** — local TTS, `kokoro-v1.0` voice family
- **Voice + speed** — picker and 0.5×–2.0×
- **Auto-speak** — assistant replies spoken when enabled
- **Sanitize before synth** — markdown, emoji, URLs, and code stripped server-side

### 💬 **AI Chat**
- **Dottie Pro (default)** — Grok via `api.dottie.ai` (sign in, no pasted key)
- **Dottie Local** — on-device llama.cpp via [dottie-local](https://github.com/stevederico/dottie-local) façade `127.0.0.1:1318` (OpenAI-compat + `/api/tags`, no API key)
- **Ollama** — local models on `127.0.0.1:11434` (OpenAI-compat, no API key)
- **BYOK xAI** — your own Grok key in the Keychain
- **History** — SQLite sessions in `~/.dottie/agent.db`, synced over the gateway
- **Realtime socket** — one WS (`/v1/realtime`) for text, voice, and TTS

### 🛠️ **Agent Tools**
- **~150 tools** via **dottie-mac-use** (calendar, mail, Safari, files, AX, …)
- **Permission scopes default off** — enable only what you want
- **Confirmation UI** — destructive actions ask before running
- **Standalone MCP** — Claude / Cursor can use mac-use and talk without Dottie.app

### 🧠 **Memory**
- **Rust SQLite** — learned facts in `agent.db`
- **Editable mirror** — `~/.dottie/dottie-memory.md`
- **Survives restarts** — and clearing a single chat

### 🖥️ **Desktop UX**
- **Menu bar avatar** — idle / working / speaking / listening / error states
- **Floating orb** — Metal + Web avatar options
- **Read Aloud / Dictate Key** — Settings → Shortcuts
- **System Health** — gateway + talk + mac-use status

<br />

## 📖 Configuration

Runtime state lives under `~/.dottie/` (not in the repo):

| Path | Purpose |
|------|---------|
| `agent_token` | Bearer for gateway HTTP/WS (mode `0600`) |
| `config.json` | Provider, model, preferences pushed from Settings |
| `agent.db` | Sessions, memories, events (SQLite) |
| `dottie-memory.md` | Human-readable memory mirror |
| `logs/` | Gateway + helper logs |

**Dottie Local (optional)**

```bash
# llama-server on PATH; then:
dottie-local start
```

Then Settings → Provider → **Dottie Local (llama.cpp)** → set **Endpoint** if needed (default `http://127.0.0.1:1318`) → pick model → **Test Connection**.
Env `DOTTIE_LOCAL_URL` still overrides the gateway if set.

**Ollama (optional)**

```bash
ollama serve
ollama pull llama3.2
```

Then Settings → Provider → **Ollama** → pick model → **Test Connection**.

**Auth note:** every gateway route except `GET /health` needs:

```http
Authorization: Bearer <token from ~/.dottie/agent_token>
```

Never commit `.env`, tokens, or API keys. Secrets stay under `~/.dottie/` or the Keychain.

<br />

## 🏗️ Tech Stack

| Technology | Version | Purpose |
|------------|---------|---------|
| **Swift / SwiftUI** | 5 / macOS 15.4+ | Face (chat, voice, Settings) |
| **Rust** | 2021 edition | Zero-crate `dottie-gateway` on `:1317` |
| **SQLite** | system `libsqlite3` | Sessions + memory |
| **libcurl** | system | HTTPS to Pro / xAI |
| **Node.js** | 24 (bundled) | talk + mac-use façades only |
| **parakeet-server** | bundled | Local STT (C++ / ggml, Metal) |
| **koko** | bundled | Local TTS (Kokoros) |
| **Dottie Local** | optional | Local chat via dottie-local on `:1318` |
| **Ollama** | optional | Local chat on `:11434` |
| **xAI / Grok** | cloud | Default brain via Dottie Pro |

<br />

## Architecture

Face talks to the gateway on **`:1317` only**. The Rust binary owns the agent loop, auth, SQLite memory, and supervision. Node children handle Mac tools and speech. Chat goes to **Dottie Pro**, **xAI**, **Dottie Local**, or **Ollama**.

```
Dottie.app (Swift)  ──WS/HTTP──▶  Gateway :1317 (Rust dottie-gateway)
                                      │
              ┌───────────────────────┼───────────────────────┐
              ▼                       ▼                       ▼
     Providers (chat)            mac-use :1321            talk :1320
  Pro / xai / Local / Ollama    tools + AX :1319       STT :1315 / TTS :1314
```

| Service | Port | Runtime | Role |
|---------|------|---------|------|
| Gateway | 1317 | Rust | WS + HTTP + agent loop; supervises kids |
| Dottie Local (optional) | 1318 | dottie-local | Local chat when Provider = Dottie Local |
| Ollama (optional) | 11434 | Ollama | Local chat when Provider = Ollama |
| dottie-mac-use | 1321 | Node | Mac tools façade; owns AX CLI |
| dottie-talk | 1320 | Node | Audio façade; owns STT/TTS bins |
| `dottie-mac-use-ax` | 1319 | Swift CLI | Accessibility + EventKit |
| `parakeet-server` | 1315 | C++ | Local STT |
| `koko` | 1314 | Rust | Local TTS |

`dottie-mac-use` and `dottie-talk` are **public git submodules**. Clone with `--recurse-submodules`.

App downloads and (soon) scrubbed source live in [dottie-desktop-releases](https://github.com/stevederico/dottie-desktop-releases).

<br />

## 🔒 Privacy

- **Dottie Pro (default):** chat and cloud voice go through `api.dottie.ai` to xAI. Account required.
- **Dottie Local / Ollama:** chat stays on your Mac. STT/TTS stay local via talk.
- **BYOK xAI:** prompts (and Grok Voice audio) go to xAI.
- **Tools:** scopes default **off**. Desktop emits no product analytics events.
- **Logs:** local under `~/.dottie/logs/`

<br />

## ⌨️ Shortcuts

| Shortcut | Action |
|----------|--------|
| `Option+Space` (hold) | Push-to-talk |
| `ESC` | Stop recording / playback / TTS |
| Menu bar avatar | Toggle conversation mode |

Customize PTT and hold duration in Settings → Voice.

<br />

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, tests, and PR guidelines.

```bash
git clone --recurse-submodules https://github.com/stevederico/dottie-desktop-releases.git
cd dottie-desktop
cd gateway && cargo test && cargo build --release
open client/Dottie.xcodeproj
```

Maintainer / agent conventions: [AGENTS.md](AGENTS.md).  
Release history: [GitHub Releases](https://github.com/stevederico/dottie-desktop-releases/releases) (no in-repo changelog).

<br />

## 📬 Community & Support

- **X**: [@stevederico](https://x.com/stevederico)
- **Issues**: [GitHub Issues](https://github.com/stevederico/dottie-desktop/issues)
- **Website**: [dottie.ai](https://www.dottie.ai)

<br />

## 🙏 Acknowledgements

- [SwiftUI](https://developer.apple.com/xcode/swiftui/) — native Mac UI
- [Rust](https://www.rust-lang.org) — zero-crate gateway
- [SQLite](https://sqlite.org) — local sessions and memory
- [dottie-local](https://github.com/stevederico/dottie-local) — optional on-device llama.cpp chat
- [Ollama](https://ollama.com) — optional local chat
- [xAI](https://x.ai) — Grok for Dottie Pro and BYOK
- [Kokoros / koko](https://github.com/lucasjinreal/Kokoros) — local TTS
- [NVIDIA Parakeet](https://huggingface.co/nvidia) — STT model family (via parakeet.cpp)

<br />

## 🎪 Related Projects

- [dottie-mac-use](https://github.com/stevederico/dottie-mac-use) — macOS tools + AX CLI (MCP / HTTP)
- [dottie-talk](https://github.com/stevederico/dottie-talk) — local STT/TTS (MCP / HTTP)
- [dottie-local](https://github.com/stevederico/dottie-local) — on-device llama.cpp façade (`:1318`)
- [dottie-desktop-releases](https://github.com/stevederico/dottie-desktop-releases) — public downloads (+ OSS home)

<br />

## 🚀 Ready?

```bash
# Users
open https://github.com/stevederico/dottie-desktop-releases/releases

# Developers
git clone --recurse-submodules https://github.com/stevederico/dottie-desktop-releases.git
cd dottie-desktop/gateway && cargo build --release
```

<br />

## 📄 License

[MIT License](LICENSE) — Copyright (c) 2026 Steve Derico

<br />

---

<div align="center">

Built with ❤️ for the Mac

⭐ Star the repo — it helps!

</div>
