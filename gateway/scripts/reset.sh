#!/bin/bash
# reset.sh — wipe local Dottie state for a clean-test or fresh-install simulation.
#
# Source of truth: docs/reference/config-files.md
#
# Preserves (multi-GB, slow to re-download / re-install):
#   ~/.dottie/models/, checkpoints/, data/
#   ~/.cache/huggingface/  (not touched at all — shared with other HF tools)
#
# Wipes everything else: chat history, agent.db, logs, prefs, caches, TCC grants.
#
# Usage:  ./reset.sh           # prompts for confirmation
#         ./reset.sh --yes     # skip prompt

set -e

BUNDLE_ID="com.example.dottie"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRESERVE=(models checkpoints data)
PRESERVE_CSV=$(IFS=,; echo "${PRESERVE[*]}")

if [ "$1" != "--yes" ] && [ "$1" != "-y" ]; then
    cat <<EOF
This will permanently delete:
  ~/.dottie/* (except $PRESERVE_CSV)               (chat history, logs, prefs, agent state)
  ~/Library/Preferences/$BUNDLE_ID.plist           (settings, hotkeys, permissions)
  ~/Library/Caches/$BUNDLE_ID/                     (URLSession + WebKit caches)
  ~/Library/HTTPStorages/$BUNDLE_ID/               (cookies)
  macOS TCC permission grants for $BUNDLE_ID       (mic, accessibility, etc.)

Preserved: ~/.dottie/{$PRESERVE_CSV}, ~/.cache/huggingface/

EOF
    read -r -p "Continue? [y/N] " answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) echo "Cancelled."; exit 1 ;;
    esac
fi

echo "Quitting Dottie..."
pkill -9 Dottie 2>/dev/null || true

echo "Stopping backend services..."
"$SCRIPT_DIR/stop_gateway.sh" 2>/dev/null || true
pkill -f 'parakeet-server|koko' 2>/dev/null || true   # STT 1315 / TTS 1314

echo "Wiping ~/.dottie (preserving ${PRESERVE[*]})..."
TMP=$(mktemp -d)
for d in "${PRESERVE[@]}"; do
    [ -e "$HOME/.dottie/$d" ] && mv "$HOME/.dottie/$d" "$TMP/"
done
rm -rf "$HOME/.dottie"
mkdir -p "$HOME/.dottie"
for d in "${PRESERVE[@]}"; do
    [ -e "$TMP/$d" ] && mv "$TMP/$d" "$HOME/.dottie/"
done
rmdir "$TMP" 2>/dev/null || true

echo "Wiping UserDefaults..."
defaults delete "$BUNDLE_ID" 2>/dev/null || true

echo "Wiping AppKit caches..."
rm -rf "$HOME/Library/Caches/$BUNDLE_ID"
rm -rf "$HOME/Library/HTTPStorages/$BUNDLE_ID"

echo "Resetting macOS permission grants (tccutil)..."
tccutil reset All "$BUNDLE_ID" 2>/dev/null || true

echo ""
echo "Reset complete. Next launch will be a first-launch state."
