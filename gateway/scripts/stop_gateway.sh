#!/bin/bash

# Dottie Agent Service Shutdown Script
# Gracefully stops the agent service on port 1317

set -e

# Configuration
DOTTIE_DIR="$HOME/.dottie"
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

# Check if server is running on a port
check_port_running() {
    local port=$1
    if lsof -ti TCP:$port -sTCP:LISTEN >/dev/null 2>&1; then
        local pids
        pids=$(lsof -ti TCP:$port -sTCP:LISTEN 2>/dev/null)
        echo "$pids"
        return 0
    fi
    return 1
}

# Stop processes on agent port
stop_agent_port() {
    local pids

    if pids=$(check_port_running $AGENT_PORT); then
        log "Stopping agent service processes on port $AGENT_PORT..."

        for pid in $pids; do
            if [ -n "$pid" ]; then
                log "Stopping process $pid..."
                if kill -TERM "$pid" 2>/dev/null; then
                    log "Sent shutdown signal to process $pid"
                else
                    warning "Could not send signal to process $pid"
                fi
            fi
        done

        sleep 2

        local remaining
        remaining=$(lsof -ti TCP:$AGENT_PORT -sTCP:LISTEN 2>/dev/null || true)
        if [ -n "$remaining" ]; then
            warning "Some processes did not stop gracefully, force killing..."
            for pid in $remaining; do
                log "Force killing process $pid"
                kill -9 "$pid" 2>/dev/null || true
            done
            sleep 1
        fi

        if lsof -ti TCP:$AGENT_PORT -sTCP:LISTEN >/dev/null 2>&1; then
            error "Failed to stop agent service - port $AGENT_PORT still in use"
            return 1
        else
            log "Agent service stopped successfully"
            return 0
        fi
    else
        log "Agent service is not currently running (port $AGENT_PORT)"
        return 0
    fi
}

# Stop using PID file
stop_by_pid() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; then
            log "Stopping agent service PID $pid from PID file..."
            kill -TERM "$pid" 2>/dev/null || true
            sleep 2
            if ps -p "$pid" >/dev/null 2>&1; then
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$PID_FILE"
    fi
}

# Clean up any lingering gateway processes (Rust binary).
stop_by_process_name() {
    local pids
    pids=$(pgrep -f "dottie-gateway" 2>/dev/null || true)

    if [ -n "$pids" ]; then
        warning "Found additional agent service processes:"
        while read -r pid; do
            if [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; then
                log "Stopping process $pid..."
                kill -TERM "$pid" 2>/dev/null || true
            fi
        done < <(echo "$pids")

        sleep 2

        local remaining
        remaining=$(pgrep -f "dottie-gateway" 2>/dev/null || true)
        if [ -n "$remaining" ]; then
            warning "Force killing remaining processes..."
            for pid in $remaining; do
                kill -KILL "$pid" 2>/dev/null || true
            done
        fi
    fi
}

# Show agent service status
show_status() {
    log "Agent Service Status:"
    log "====================="

    local agent_pid
    if agent_pid=$(check_port_running $AGENT_PORT); then
        log "Agent Service: RUNNING on port $AGENT_PORT"
        if curl -s -f "http://127.0.0.1:$AGENT_PORT/health" >/dev/null 2>&1; then
            log "  Responding to health checks"
        else
            warning "  Process exists but not responding"
        fi
    else
        log "Agent Service: NOT RUNNING"
    fi

    if [ -f "$LOG_FILE" ] && [ -r "$LOG_FILE" ]; then
        echo ""
        log "Recent log entries:"
        tail -n 5 "$LOG_FILE" 2>/dev/null || true
    fi
}

# Display usage
show_usage() {
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  stop        Stop agent service (default)"
    echo "  status      Show agent service status"
    echo "  force-stop  Force stop all agent service processes"
    echo "  help        Show this help message"
    echo ""
    echo "Agent Service: port $AGENT_PORT"
}

# Main execution
main() {
    local action="${1:-stop}"

    case "$action" in
        "stop")
            log "Dottie Agent Service Shutdown"
            log "=============================="
            stop_by_pid
            stop_agent_port
            rm -f "$PID_FILE"
            ;;
        "status")
            show_status
            ;;
        "force-stop")
            log "Dottie Agent Service Force Stop"
            log "================================"
            stop_by_pid
            stop_agent_port
            stop_by_process_name
            rm -f "$PID_FILE"
            ;;
        "help"|"-h"|"--help")
            show_usage
            ;;
        *)
            error "Unknown option: $action"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

trap 'error "Script interrupted"; exit 130' INT TERM

main "$@"
