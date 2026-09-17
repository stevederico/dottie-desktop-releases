# private/

Local-only drop zone. Everything here except this README is **gitignored** and must never be published.

Use for:
- Notary / ASC notes
- Real Team ID scratch
- One-off scripts with secrets
- Anything that must not land on `dottie-desktop-releases`

Do not put runtime secrets the app needs at build time here unless you also wire paths yourself — preferred signing override is still `client/Release.xcconfig` (also gitignored).
