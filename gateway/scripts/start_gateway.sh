#!/bin/bash

# Dottie Agent Service Startup Script
# Starts the Rust gateway binary on port 1317 (talk/mac-use stay Node children).

set -euo pipefail

# Resolve script location early so we can prefer bundled Node for children.
# Script lives at gateway/scripts/ — parent is the gateway package;
# bundled layout: Resources/gateway/scripts + Resources/node + Resources/gateway/bin/dottie-gateway.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLED_NODE_DIR="$SCRIPT_DIR/../../node"
GATEWAY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Ensure common macOS tool paths are available (GUI apps inherit minimal PATH).
# Bundled Node wins on PATH so supervised talk/mac-use `node` invocations work.
if [ -x "$BUNDLED_NODE_DIR/bin/node" ]; then
    export PATH="$BUNDLED_NODE_DIR/bin:/usr/local/bin:/opt/homebrew/bin:$HOME/.deno/bin:$PATH"
else
    export PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.deno/bin:$PATH"
fi

# Configuration
DOTTIE_DIR="$HOME/.dottie"
BUNDLED_AGENT_DIR="$GATEWAY_ROOT"
INSTALLED_AGENT_DIR="$DOTTIE_DIR/gateway"
LOG_DIR="$DOTTIE_DIR/logs"
LOG_FILE="$LOG_DIR/gateway.log"
PID_FILE="$DOTTIE_DIR/gateway.pid"

AGENT_PORT="1317"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Resolve dottie-gateway binary (Resources/bin, gateway/bin, or cargo target).
resolve_gateway_bin() {
    local candidates=(
        "$GATEWAY_ROOT/bin/dottie-gateway"
        "$SCRIPT_DIR/../../bin/dottie-gateway"
        "$GATEWAY_ROOT/target/release/dottie-gateway"
        "$GATEWAY_ROOT/target/debug/dottie-gateway"
    )
    local c
    for c in "${candidates[@]}"; do
        if [ -x "$c" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

# Check Node.js v18+ is installed (still required for talk + mac-use children).
check_node() {
    if ! command -v node &> /dev/null; then
        error "Node.js is not installed (needed for talk/mac-use)"
        error "Install Node.js v18+: https://nodejs.org/"
        exit 1
    fi

    local node_version
    node_version=$(node -v | sed 's/v//' | cut -d. -f1)
    if [ "$node_version" -lt 18 ]; then
        error "Node.js v18+ required, found v$(node -v)"
        exit 1
    fi

    log "Node.js $(node -v) found (children)"
}

# Resolve the agent service directory.
install_gateway() {
    log "Checking install location: SCRIPT_DIR=$SCRIPT_DIR"

    if [[ "$SCRIPT_DIR" == *".app/Contents/Resources"* ]]; then
        log "Detected app bundle location, running from bundle at $BUNDLED_AGENT_DIR"
        AGENT_DIR="$BUNDLED_AGENT_DIR"

        mkdir -p "$DOTTIE_DIR"

        if [ -d "$INSTALLED_AGENT_DIR" ]; then
            log "Removing legacy install at $INSTALLED_AGENT_DIR (no longer needed in 5.12+)"
            rm -rf "$INSTALLED_AGENT_DIR"
        fi
        if [ -f "$DOTTIE_DIR/defaults.json" ]; then
            rm -f "$DOTTIE_DIR/defaults.json"
        fi
    else
        # Development mode — npm install only talk/mac-use; build Rust gateway if needed.
        AGENT_DIR="$BUNDLED_AGENT_DIR"

        MAC_USE_DIR="$AGENT_DIR/dottie-mac-use"
        if [ -f "$MAC_USE_DIR/package.json" ] && [ ! -d "$MAC_USE_DIR/node_modules" ]; then
            log "dottie-mac-use node_modules missing, running npm install..."
            if ! (cd "$MAC_USE_DIR" && npm install); then
                error "npm install failed in $MAC_USE_DIR"
                exit 1
            fi
        fi
        if [ -f "$MAC_USE_DIR/native/build.sh" ] \
            && [ ! -x "$MAC_USE_DIR/bin/dottie-mac-use-ax" ] \
            && [ ! -x "$MAC_USE_DIR/native/.build/dottie-mac-use-ax" ]; then
            log "Building dottie-mac-use-ax..."
            bash "$MAC_USE_DIR/native/build.sh" || log "WARN: dottie-mac-use-ax build failed — AX tools will fail until built"
        fi

        TALK_DIR="$AGENT_DIR/dottie-talk"
        if [ -f "$TALK_DIR/package.json" ] && [ ! -d "$TALK_DIR/node_modules" ]; then
            log "dottie-talk node_modules missing, running npm install..."
            if ! (cd "$TALK_DIR" && npm install); then
                error "npm install failed in $TALK_DIR"
                exit 1
            fi
        fi

        if [ ! -x "$AGENT_DIR/bin/dottie-gateway" ] \
            && [ ! -x "$AGENT_DIR/target/release/dottie-gateway" ] \
            && [ ! -x "$AGENT_DIR/target/debug/dottie-gateway" ]; then
            log "Building dottie-gateway (release)..."
            if ! (cd "$AGENT_DIR" && cargo build --release); then
                error "cargo build --release failed"
                exit 1
            fi
            mkdir -p "$AGENT_DIR/bin"
            cp "$AGENT_DIR/target/release/dottie-gateway" "$AGENT_DIR/bin/dottie-gateway"
        fi
    fi
}

check_agent_dir() {
    if [ ! -d "$AGENT_DIR" ]; then
        error "Agent service directory not found at $AGENT_DIR"
        exit 1
    fi

    if ! resolve_gateway_bin >/dev/null; then
        error "dottie-gateway binary not found (expected gateway/bin/dottie-gateway)"
        exit 1
    fi
}

stop_existing() {
    local pids
    pids=$(lsof -ti TCP:$AGENT_PORT -sTCP:LISTEN 2>/dev/null || true)
    if [ -n "$pids" ]; then
        log "Stopping existing processes on port $AGENT_PORT..."
        for pid in $pids; do
            kill -TERM "$pid" 2>/dev/null || true
        done
        sleep 2

        local remaining
        remaining=$(lsof -ti TCP:$AGENT_PORT -sTCP:LISTEN 2>/dev/null || true)
        if [ -n "$remaining" ]; then
            for pid in $remaining; do
                kill -9 "$pid" 2>/dev/null || true
            done
        fi
    fi

    if [ -f "$PID_FILE" ]; then
        local old_pid
        old_pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [ -n "$old_pid" ] && ! ps -p "$old_pid" >/dev/null 2>&1; then
            rm -f "$PID_FILE"
        fi
    fi
}

ensure_log_dir() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$DOTTIE_DIR/workspace"

    if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt 52428800 ]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
        log "Rotated large log file: $LOG_FILE"
    fi
}

start_agent() {
    log "Starting Agent Service on port $AGENT_PORT..."

    local gateway_bin
    gateway_bin="$(resolve_gateway_bin)"
    log "Using binary: $gateway_bin"

    export PORT="$AGENT_PORT"
    export DOTTIE_GATEWAY_DIR="$AGENT_DIR"
    if [ -x "$BUNDLED_NODE_DIR/bin/node" ]; then
        export DOTTIE_NODE="$BUNDLED_NODE_DIR/bin/node"
    fi

    cd "$AGENT_DIR"
    "$gateway_bin" >> "$LOG_FILE" 2>&1 &
    local agent_pid=$!
    echo "$agent_pid" > "$PID_FILE"
    log "Agent service PID: $agent_pid"

    local attempts=0
    local max_attempts=150
    while [ $attempts -lt $max_attempts ]; do
        if curl -s -f "http://127.0.0.1:$AGENT_PORT/health" >/dev/null 2>&1; then
            log "Agent service started on port $AGENT_PORT after $((attempts * 200))ms"
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 0.2
        if ! kill -0 "$agent_pid" 2>/dev/null; then
            error "Agent service exited before becoming healthy"
            error "See $LOG_FILE"
            return 1
        fi
    done

    if kill -0 "$agent_pid" 2>/dev/null; then
        warning "Agent process alive but /health not ready after 30s — continuing"
        return 0
    fi
    error "Agent service failed to start"
    return 1
}

main() {
    log "Dottie gateway start"
    check_node
    install_gateway
    check_agent_dir
    ensure_log_dir
    stop_existing
    start_agent
}

main "$@"
