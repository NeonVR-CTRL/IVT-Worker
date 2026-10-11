FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PORT=8080 \
    LINK_PORT=8081 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    IVT_ROLE=master

# 1. Standard Docker policy-rc.d fix to prevent apt service hangs
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d

# 2. Minimal, curated dependency tree. No bloat.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      bash coreutils procps util-linux mawk ca-certificates curl sudo python3-minimal systemd-sysv && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /usr/share/doc/* /usr/share/man/* /usr/share/info/* /var/cache/apt/*

# 3. 100% Genuine Ubuntu 24.04 LTS identity. All installers will accept this.
RUN printf 'PRETTY_NAME="Ubuntu 24.04.1 LTS"\nNAME="Ubuntu"\nVERSION_ID="24.04"\nVERSION="24.04.1 LTS (Noble Numbat)"\nVERSION_CODENAME=noble\nID=ubuntu\nID_LIKE=debian\nHOME_URL="https://www.ubuntu.com/"\nSUPPORT_URL="https://help.ubuntu.com/"\nBUG_REPORT_URL="https://bugs.launchpad.net/ubuntu/"\nPRIVACY_POLICY_URL="https://www.ubuntu.com/legal/terms-and-policies/privacy-policy"\nUBUNTU_CODENAME=noble\nLOGO=ubuntu-logo\n' > /etc/os-release

# 4. Organized, purpose-built directory structure
RUN mkdir -p \
      /ivt/os \
      /etc/ivt/units /etc/ivt/targets/default.wants /etc/ivt/targets/multi-user.target.wants \
      /run/ivt/ctrl /run/ivt/pids /run/ivt/state /run/ivt/manual /run/ivt/link \
      /var/log/ivt/journal \
      /etc/systemd/system /lib/systemd/system /run/systemd

# ==============================================================================
# 5. ADVANCED INIT SYSTEM (PID 1): Bulletproof Environment & Process Handling
# ==============================================================================
RUN cat > /ivt/os/init << 'INITEOF'
#!/bin/bash
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN_DIR=/run/ivt
UNITS=/etc/ivt/units
TARGETS=/etc/ivt/targets
LOG=/var/log/ivt/journal
TARGET_FILE=/etc/ivt/default.target

mkdir -p "$RUN_DIR"/{ctrl,pids,state,manual,link} "$LOG"

[[ ! -f /etc/machine-id ]] && cat /proc/sys/kernel/random/uuid > /etc/machine-id
cat /proc/sys/kernel/random/uuid > "$RUN_DIR/boot-id"
date +%s > "$RUN_DIR/boottime"

declare -A PIDS=()
declare -A RESTART=()

log_system() { echo "$(date -Is) $*" >> "$LOG/system.log"; }

get_value() {
  local file="$1" section="$2" key="$3"
  mawk -v section="$section" -v key="$key" '
    BEGIN { c="" }
    /^\[/ { c=$0; gsub(/[\[\] \t\r]/,"",c); next }
    c == section {
      p = index($0,"=")
      if (p > 0) {
        k = substr($0,1,p-1); gsub(/[ \t\r]/,"",k)
        if (k == key) {
          v = substr($0,p+1); sub(/\r$/,"",v)
          print v; exit
        }
      }
    }
  ' "$file" 2>/dev/null
}

kill_tree() {
  local pid="$1" sig="${2:-TERM}"
  local children
  children=$(pgrep -P "$pid" 2>/dev/null || true)
  local child
  for child in $children; do
    kill_tree "$child" "$sig"
  done
  kill -"$sig" "$pid" 2>/dev/null || true
}

service_start() {
  local unitfile="$1"
  local name
  name=$(basename "$1" .service)
  local pidfile="$RUN_DIR/pids/$name.pid"
  
  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
    echo "running" > "$RUN_DIR/state/$name"
    return 0
  fi
  
  rm -f "$RUN_DIR/manual/$name"
  
  local execstart workdir restart restartsec env_file env_vars
  execstart=$(get_value "$unitfile" Service ExecStart)
  workdir=$(get_value "$unitfile" Service WorkingDirectory)
  restart=$(get_value "$unitfile" Service Restart)
  restartsec=$(get_value "$unitfile" Service RestartSec)
  env_file=$(get_value "$unitfile" Service EnvironmentFile)
  env_vars=$(get_value "$unitfile" Service Environment)
  
  restart="${restart:-no}"
  restartsec="${restartsec:-1}"
  
  if [[ -z "$execstart" ]]; then
    echo "failed" > "$RUN_DIR/state/$name"
    log_system "unit $name has no ExecStart"
    return 1
  fi
  
  echo "starting" > "$RUN_DIR/state/$name"
  
  (
    set +e
    if [[ -n "$workdir" ]]; then
      cd "$workdir" || exit 1
    fi
    if [[ -n "$env_file" ]]; then
      local clean_env="${env_file#-}"
      if [[ -f "$clean_env" ]]; then
        set -a
        . "$clean_env" || true
        set +a
      fi
    fi
    if [[ -n "$env_vars" ]]; then
      env_vars="${env_vars%\"}"
      env_vars="${env_vars#\"}"
      env_vars="${env_vars%\'}"
      env_vars="${env_vars#\'}"
      export $env_vars
    fi
    set -e
    exec /bin/sh -c "$execstart" >> "$LOG/$name.log" 2>&1
  ) &
  
  local pid=$!
  echo "$pid" > "$pidfile"
  echo "running" > "$RUN_DIR/state/$name"
  PIDS[$pid]="$name"
  RESTART[$name]="$restart:$restartsec"
  log_system "started $name pid=$pid"
}

service_stop() {
  local name="$1"
  local pidfile="$RUN_DIR/pids/$name.pid"
  touch "$RUN_DIR/manual/$name"
  if [[ -f "$pidfile" ]]; then
    local pid=$(cat "$pidfile" 2>/dev/null || true)
    if [[ -n "$pid" ]]; then
      kill_tree "$pid" TERM
      local i
      for i in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
      kill_tree "$pid" KILL
      unset "PIDS[$pid]" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi
  echo "stopped" > "$RUN_DIR/state/$name"
  log_system "stopped $name"
}

shutdown_system() {
  log_system "shutdown requested"
  local pid
  for pid in "${!PIDS[@]}"; do
    kill_tree "$pid" TERM
  done
  sleep 1
  for pid in "${!PIDS[@]}"; do
    kill_tree "$pid" KILL
  done
  exit 0
}

main() {
  local target cmd name policy restart_policy restart_sec
  target=$(cat "$TARGET_FILE" 2>/dev/null || echo "default")
  local fifo="$RUN_DIR/ctrl/control.fifo"
  rm -f "$fifo"
  mkfifo "$fifo"
  exec 3<>"$fifo"

  log_system "IVT-D MASTER starting target=$target"
  for unit in "$TARGETS/$target.wants"/*.service; do
    [[ -e "$unit" ]] && service_start "$unit"
  done
  trap shutdown_system TERM INT

  while true; do
    if read -r -t 1 -u 3 cmd; then
      case "$cmd" in
        start:*) service_start "$UNITS/${cmd#start:}.service" ;;
        stop:*) service_stop "${cmd#stop:}" ;;
        restart:*) 
          service_stop "${cmd#restart:}"
          sleep 0.2
          service_start "$UNITS/${cmd#restart:}.service"
          ;;
        shutdown|poweroff) shutdown_system ;;
      esac
    fi
    for pid in "${!PIDS[@]}"; do
      if ! kill -0 "$pid" 2>/dev/null; then
        name="${PIDS[$pid]}"
        unset "PIDS[$pid]" 2>/dev/null || true
        rm -f "$RUN_DIR/pids/$name.pid"
        if [[ -f "$RUN_DIR/manual/$name" ]]; then
          echo "stopped" > "$RUN_DIR/state/$name"
          continue
        fi
        policy="${RESTART[$name]:-no:1}"
        restart_policy="${policy%%:*}"
        restart_sec="${policy##*:}"
        if [[ "$restart_policy" == "always" || "$restart_policy" == "on-failure" ]]; then
          log_system "restarting $name in ${restart_sec}s"
          sleep "$restart_sec" 2>/dev/null || true
          service_start "$UNITS/$name.service"
        else
          echo "exited" > "$RUN_DIR/state/$name"
        fi
      fi
    done
    sleep 0.5
  done
}
main "$@"
INITEOF

# ==============================================================================
# 6. 100% UBUNTU COMMAND NAMES: systemctl, service, journalctl
# ==============================================================================
RUN cat > /usr/local/bin/systemctl << 'SYSCTL_EOF'
#!/bin/bash
set -euo pipefail
RUN_DIR=/run/ivt
UNITS=/etc/ivt/units
TARGETS=/etc/ivt/targets
LOG=/var/log/ivt/journal

get_value() {
  local file="$1" section="$2" key="$3"
  mawk -v section="$section" -v key="$key" '
    BEGIN { c="" }
    /^\[/ { c=$0; gsub(/[\[\] \t\r]/,"",c); next }
    c == section {
      p = index($0,"=")
      if (p > 0) {
        k = substr($0,1,p-1); gsub(/[ \t\r]/,"",k)
        if (k == key) {
          v = substr($0,p+1); sub(/\r$/,"",v)
          print v; exit
        }
      }
    }
  ' "$file" 2>/dev/null
}

ensure_unit() {
  local unit="${1%.service}.service"
  local sys_unit="/etc/systemd/system/$unit"
  local ivt_unit="$UNITS/$unit"
  if [[ -f "$sys_unit" && ! -f "$ivt_unit" ]]; then
    cp "$sys_unit" "$ivt_unit"
    chmod 644 "$ivt_unit"
  fi
}

send_cmd() {
  local fifo="$RUN_DIR/ctrl/control.fifo"
  if [[ -p "$fifo" ]]; then
    echo "$1" > "$fifo"
  else
    echo "IVT-D not running" >&2
    return 1
  fi
}

# Helper to extract unit name from arguments, ignoring flags like --property=...
get_unit_from_args() {
  local arg
  for arg in "$@"; do
    if [[ "$arg" != --* ]]; then
      echo "${arg%.service}"
      return 0
    fi
  done
  echo ""
}

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    start|stop|restart)
      local unit=$(get_unit_from_args "$@")
      [[ -n "$unit" ]] && ensure_unit "$unit"
      [[ -n "$unit" ]] && send_cmd "$cmd:$unit" && echo "$cmd request sent: $unit"
      ;;
    enable)
      local unit=$(get_unit_from_args "$@")
      if [[ -n "$unit" ]]; then
        ensure_unit "$unit"
        mkdir -p "$TARGETS/default.wants" "$TARGETS/multi-user.target.wants"
        ln -sf "$UNITS/$unit.service" "$TARGETS/default.wants/$unit.service" 2>/dev/null || true
        ln -sf "$UNITS/$unit.service" "$TARGETS/multi-user.target.wants/$unit.service" 2>/dev/null || true
        echo "Created symlink"
      fi
      ;;
    disable)
      local unit=$(get_unit_from_args "$@")
      if [[ -n "$unit" ]]; then
        rm -f "$TARGETS/default.wants/$unit.service" "$TARGETS/multi-user.target.wants/$unit.service"
        echo "Removed symlink"
      fi
      ;;
    is-active)
      local unit=$(get_unit_from_args "$@")
      if [[ -n "$unit" ]]; then
        ensure_unit "$unit"
        if pgrep -f "$unit" > /dev/null 2>&1; then
          echo "active"; exit 0
        fi
        local state=$(cat "$RUN_DIR/state/$unit" 2>/dev/null || echo "inactive")
        if [[ "$state" == "running" ]]; then
          local pid=$(cat "$RUN_DIR/pids/$unit.pid" 2>/dev/null || echo "")
          if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "active"; exit 0
          fi
        fi
        echo "inactive"; exit 3
      fi
      ;;
    is-enabled)
      local unit=$(get_unit_from_args "$@")
      if [[ -n "$unit" ]]; then
        ensure_unit "$unit"
        if [[ -e "$TARGETS/default.wants/$unit.service" || -e "$TARGETS/multi-user.target.wants/$unit.service" ]]; then
          echo "enabled"; exit 0
        else
          echo "disabled"; exit 1
        fi
      fi
      ;;
    show)
      # THIS IS THE FIX: Properly parse flags to find the unit name
      local unit=$(get_unit_from_args "$@")
      if [[ -n "$unit" ]]; then
        ensure_unit "$unit"
        if pgrep -f "$unit" > /dev/null 2>&1; then
          echo "SubState=running"; exit 0
        fi
        local state=$(cat "$RUN_DIR/state/$unit" 2>/dev/null || echo "inactive")
        if [[ "$state" == "running" ]]; then
          local pid=$(cat "$RUN_DIR/pids/$unit.pid" 2>/dev/null || echo "")
          if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "SubState=running"; exit 0
          fi
        fi
      fi
      echo "SubState=dead"; exit 0
      ;;
    daemon-reload)
      local f
      for f in /etc/systemd/system/*.service; do
        [[ -e "$f" ]] || continue
        cp "$f" "$UNITS/"
      done
      echo "IVT-D: daemon-reload simulated (units synced)"
      ;;
    status)
      local unit=$(get_unit_from_args "$@")
      if [[ -n "$unit" ]]; then
        ensure_unit "$unit"
        local state=$(cat "$RUN_DIR/state/$unit" 2>/dev/null || echo "inactive")
        local pid=$(cat "$RUN_DIR/pids/$unit.pid" 2>/dev/null || echo "-")
        echo "● $unit.service"
        echo "   Active: $state (Main PID: $pid)"
        if [[ -f "$LOG/$unit.log" ]]; then
          echo "   Logs (last 10 lines):"
          tail -n 10 "$LOG/$unit.log" | sed 's/^/     /'
        fi
      else
        printf '%-20s %-10s %-8s %-8s\n' "UNIT" "STATE" "PID" "ENABLED"
        local unit_file unit_name state pid enabled
        declare -A seen=()
        for unit_file in "$UNITS"/*.service /etc/systemd/system/*.service; do
          [[ -e "$unit_file" ]] || continue
          unit_name=$(basename "$unit_file" .service)
          [[ -n "${seen[$unit_name]:-}" ]] && continue
          seen[$unit_name]=1
          state=$(cat "$RUN_DIR/state/$unit_name" 2>/dev/null || echo "inactive")
          pid=$(cat "$RUN_DIR/pids/$unit_name.pid" 2>/dev/null || echo "-")
          enabled="no"
          [[ -e "$TARGETS/default.wants/$unit_name.service" || -e "$TARGETS/multi-user.target.wants/$unit_name.service" ]] && enabled="yes"
          printf '%-20s %-10s %-8s %-8s\n' "$unit_name" "$state" "$pid" "$enabled"
        done
      fi
      ;;
    --version)
      echo "systemd 255 (Ubuntu 24.04)"
      exit 0
      ;;
    *)
      exit 0
      ;;
  esac
}
main "$@"
SYSCTL_EOF

RUN cat > /usr/local/bin/service << 'SVC_EOF'
#!/bin/bash
set -euo pipefail
if [[ $# -lt 2 ]]; then
  echo "Usage: service <unit> {start|stop|restart|status}" >&2
  exit 1
fi
exec /usr/local/bin/systemctl "$2" "${1%.service}"
SVC_EOF

RUN cat > /usr/local/bin/journalctl << 'JCTL_EOF'
#!/bin/bash
set -euo pipefail
LOG=/var/log/ivt/journal
unit=""
lines=50
follow=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--unit) shift; unit="${1:-}";; --unit=*) unit="${1#--unit=}";;
    -n|--lines) shift; lines="${1:-50}";; --lines=*) lines="${1#--lines=}";;
    -f|--follow) follow=true;;
    *) shift;;
  esac
done
unit="${unit%.service}"
file="$LOG/${unit:-system}.log"
if [[ ! -f "$file" ]]; then
  echo "-- No entries --"
  exit 0
fi
if $follow; then
  exec tail -f "$file"
else
  exec tail -n "$lines" "$file"
fi
JCTL_EOF

RUN cat > /usr/local/bin/hostnamectl << 'HCTL_EOF'
#!/bin/bash
set -euo pipefail
main() {
  local cmd="${1:-status}"
  case "$cmd" in
    status) echo " Static hostname: $(cat /etc/hostname 2>/dev/null || echo ivt-master)"; echo "  Operating System: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Ubuntu}")"; echo "          Kernel: $(uname -r)";;
    set-hostname) echo "${2:-ivt-master}" > /etc/hostname 2>/dev/null || true;;
    hostname) cat /etc/hostname 2>/dev/null || echo ivt-master;;
  esac
}
main "$@"
HCTL_EOF

# ==============================================================================
# 7. CORE SERVICES & AGENTS
# ==============================================================================
RUN cat > /ivt/os/api.py << 'API_EOF'
#!/usr/bin/env python3
import html, os, subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
PORT = int(os.environ.get("PORT", 8080))
def run(cmd):
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        return result.stdout.strip()
    except Exception as e:
        return f"ERROR: {e}"
class IVTHandler(BaseHTTPRequestHandler):
    server_version = "IVT-OS-MASTER"
    sys_version = ""
    def log_message(self, *args): pass
    def send(self, code, body, ctype="text/plain; charset=utf-8"):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        if self.path == "/health":
            self.send(200, "OK"); return
        if self.path == "/api/status":
            self.send(200, run(["systemctl", "status"])); return
        if self.path == "/api/sys":
            self.send(200, run(["hostnamectl", "status"])); return
        status = run(["systemctl", "status"])
        kernel = run(["uname", "-a"])
        page = f"""<html><head><title>IVT-OS MASTER</title></head><body>
<h1>IVT-OS MASTER</h1><p>{html.escape(kernel)}</p>
<h2>Services</h2><pre>{html.escape(status)}</pre></body></html>"""
        self.send(200, page, "text/html; charset=utf-8")
if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), IVTHandler).serve_forever()
API_EOF

RUN cat > /ivt/os/ivt-link-master.py << 'LINK_EOF'
#!/usr/bin/env python3
import os, json, time, queue
from http.server import BaseHTTPRequestHandler, HTTPServer
WORKER_URL = os.environ.get("IVT_WORKER_URL", "")
LINK_SECRET = os.environ.get("IVT_LINK_SECRET", "default-secret")
LINK_PORT = int(os.environ.get("LINK_PORT", 8081))
task_queue = queue.Queue()
worker_status = {"state": "DISCONNECTED", "ram": 0, "cpu": 0, "last_seen": 0}
class LinkHandler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        content_len = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_len)
        try: data = json.loads(body)
        except: self.send_response(400); self.end_headers(); return
        if self.path == "/ivt-link/auth":
            if data.get("secret") == LINK_SECRET:
                worker_status["state"] = "CONNECTED"
                worker_status["last_seen"] = time.time()
                self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
                self.wfile.write(json.dumps({"status": "auth_ok"}).encode())
            else: self.send_response(403); self.end_headers()
        elif self.path == "/ivt-link/heartbeat":
            if data.get("secret") == LINK_SECRET:
                worker_status["last_seen"] = time.time()
                worker_status["ram"] = data.get("ram", 0)
                worker_status["cpu"] = data.get("cpu", 0)
                self.send_response(200); self.end_headers()
        elif self.path == "/ivt-link/result":
            if data.get("secret") == LINK_SECRET:
                self.send_response(200); self.end_headers()
    def do_GET(self):
        if self.path == "/ivt-link/poll":
            try:
                task = task_queue.get(timeout=15)
                self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
                self.wfile.write(json.dumps(task).encode())
            except queue.Empty:
                self.send_response(204); self.end_headers()
        else:
            self.send_response(404); self.end_headers()
if __name__ == "__main__":
    print(f"[IVT-LINK MASTER] Listening on port {LINK_PORT}")
    HTTPServer(("0.0.0.0", LINK_PORT), LinkHandler).serve_forever()
LINK_EOF

# ==============================================================================
# 8. SERVICE DEFINITIONS & PERMISSIONS
# ==============================================================================
RUN cat > /etc/ivt/units/ivt-api.service << 'UNIT1_EOF'
[Unit]
Description=IVT Master API & Dashboard
[Service]
ExecStart=/usr/bin/python3 /ivt/os/api.py
Restart=always
RestartSec=2
[Install]
Target=default
UNIT1_EOF

RUN cat > /etc/ivt/units/ivt-link-master.service << 'UNIT2_EOF'
[Unit]
Description=IVT-LINK Master Agent
[Service]
ExecStart=/usr/bin/python3 /ivt/os/ivt-link-master.py
Restart=always
RestartSec=2
[Install]
Target=default
UNIT2_EOF

RUN cat > /etc/ivt/units/ivt-heartbeat.service << 'UNIT3_EOF'
[Unit]
Description=IVT Master Heartbeat
[Service]
ExecStart=/bin/sh -c 'while true; do date +%s > /run/ivt/heartbeat; sleep 5; done'
Restart=always
RestartSec=1
[Install]
Target=default
UNIT3_EOF

RUN chmod +x /ivt/os/init /usr/local/bin/systemctl /usr/local/bin/service /usr/local/bin/journalctl /usr/local/bin/hostnamectl && \
    echo 'ivt-master' > /etc/hostname && \
    echo "default" > /etc/ivt/default.target && \
    ln -sf /etc/ivt/units/ivt-api.service /etc/ivt/targets/default.wants/ && \
    ln -sf /etc/ivt/units/ivt-link-master.service /etc/ivt/targets/default.wants/ && \
    ln -sf /etc/ivt/units/ivt-heartbeat.service /etc/ivt/targets/default.wants/ && \
    ln -sf /usr/local/bin/systemctl /usr/bin/systemctl && \
    ln -sf /usr/local/bin/journalctl /usr/bin/journalctl && \
    ln -sf /usr/local/bin/service /usr/sbin/service && \
    ln -sf /usr/local/bin/hostnamectl /usr/bin/hostnamectl && \
    ln -sf /etc/ivt/units /etc/systemd/system && \
    ln -sf /etc/ivt/units /lib/systemd/system && \
    echo 'root ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/root && \
    chmod 0440 /etc/sudoers.d/root

EXPOSE 8080 8081

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD curl -sf http://127.0.0.1:8080/health || exit 1

CMD ["/ivt/os/init"]
