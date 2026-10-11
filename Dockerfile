FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PORT=8081 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    IVT_ROLE=worker

# Install minimal dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      bash coreutils procps util-linux mawk ca-certificates curl sudo python3-minimal && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /usr/share/doc/* /usr/share/man/* /usr/share/info/* /var/cache/apt/*

# Create directory structure
RUN mkdir -p \
      /ivt/os /etc/ivt/units /etc/ivt/targets/default.wants \
      /run/ivt/ctrl /run/ivt/pids /run/ivt/state /run/ivt/manual /run/ivt/link \
      /var/log/ivt/journal /etc/systemd /lib/systemd /run/systemd /tmp/worker

# Create IVT-D init system (PID 1)
RUN cat > /ivt/os/init << 'INITEOF'
#!/bin/bash
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN=/run/ivt
UNITS=/etc/ivt/units
TARGETS=/etc/ivt/targets
LOG=/var/log/ivt/journal
TARGET_FILE=/etc/ivt/default.target

mkdir -p "$RUN"/ctrl "$RUN"/pids "$RUN"/state "$RUN"/manual "$RUN"/link "$LOG"
[[ ! -f /etc/machine-id ]] && cat /proc/sys/kernel/random/uuid > /etc/machine-id
cat /proc/sys/kernel/random/uuid > "$RUN/boot-id"
date +%s > "$RUN/boottime"

declare -A PIDS=()
declare -A RESTART=()

log_system() { echo "$(date -Is) $*" >> "$LOG/system.log"; }

get_value() {
  mawk -v section="$2" -v key="$3" 'BEGIN{c=""} /^\[/{c=$0;gsub(/[\[\] \t\r]/,"",c);next} c==section{p=index($0,"=");if(p>0){k=substr($0,1,p-1);gsub(/[ \t\r]/,"",k);if(k==key){v=substr($0,p+1);sub(/\r$/,"",v);print v;exit}}}' "$1" 2>/dev/null
}

kill_tree() {
  local pid=$1 sig=${2:-TERM} children=$(pgrep -P $pid 2>/dev/null || true)
  for child in $children; do kill_tree $child $sig; done
  kill -$sig $pid 2>/dev/null || true
}

service_start() {
  local unitfile=$1 name=$(basename $1 .service) pidfile="$RUN/pids/$name.pid"
  [[ -f $pidfile ]] && kill -0 $(cat $pidfile 2>/dev/null) 2>/dev/null && { echo running > $RUN/state/$name; return 0; }
  rm -f "$RUN/manual/$name"
  local execstart=$(get_value $unitfile Service ExecStart) restart=$(get_value $unitfile Service Restart) restartsec=$(get_value $unitfile Service RestartSec)
  restart=${restart:-no}; restartsec=${restartsec:-1}
  [[ -z $execstart ]] && { echo failed > $RUN/state/$name; return 1; }
  echo starting > $RUN/state/$name
  /bin/sh -c "$execstart" >> $LOG/$name.log 2>&1 &
  local pid=$!; echo $pid > $pidfile; echo running > $RUN/state/$name
  PIDS[$pid]=$name; RESTART[$name]="$restart:$restartsec"
  log_system "started $name pid=$pid"
}

service_stop() {
  local name=$1 pidfile="$RUN/pids/$name.pid"
  touch "$RUN/manual/$name"
  if [[ -f $pidfile ]]; then
    local pid=$(cat $pidfile 2>/dev/null || true)
    if [[ -n $pid ]]; then
      kill_tree $pid TERM
      for _ in $(seq 1 20); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
      kill_tree $pid KILL
      unset "PIDS[$pid]" 2>/dev/null || true
    fi
    rm -f $pidfile
  fi
  echo stopped > $RUN/state/$name; log_system "stopped $name"
}

shutdown_system() {
  log_system "shutdown requested"
  for pid in "${!PIDS[@]}"; do kill_tree $pid TERM; done
  sleep 1
  for pid in "${!PIDS[@]}"; do kill_tree $pid KILL; done
  exit 0
}

TARGET=$(cat $TARGET_FILE 2>/dev/null || echo default)
FIFO="$RUN/ctrl/control.fifo"
rm -f $FIFO; mkfifo $FIFO; exec 3<>"$FIFO"
log_system "IVT-D WORKER starting target=$TARGET"

for unit in $TARGETS/$TARGET.wants/*.service; do [[ -e $unit ]] && service_start $unit; done
trap shutdown_system TERM INT

while true; do
  if read -r -t 1 -u 3 cmd; then
    case $cmd in
      start:*) service_start "$UNITS/${cmd#start:}.service" ;;
      stop:*) service_stop "${cmd#stop:}" ;;
      restart:*) service_stop "${cmd#restart:}"; sleep 0.2; service_start "$UNITS/${cmd#restart:}.service" ;;
      shutdown|poweroff) shutdown_system ;;
    esac
  fi
  for pid in "${!PIDS[@]}"; do
    if ! kill -0 $pid 2>/dev/null; then
      name=${PIDS[$pid]}; unset "PIDS[$pid]" 2>/dev/null || true; rm -f "$RUN/pids/$name.pid"
      if [[ -f $RUN/manual/$name ]]; then echo stopped > $RUN/state/$name; continue; fi
      policy=${RESTART[$name]:-no:1}; restart_policy=${policy%%:*}; restart_sec=${policy##*:}
      if [[ $restart_policy == "always" || $restart_policy == "on-failure" ]]; then
        log_system "restarting $name in ${restart_sec}s"; sleep $restart_sec 2>/dev/null || true
        service_start "$UNITS/$name.service"
      else echo exited > $RUN/state/$name; fi
    fi
  done
  sleep 0.5
done
INITEOF

# Create ivtctl control tool
RUN cat > /usr/local/bin/ivtctl << 'CTL_EOF'
#!/bin/bash
set -u
RUN=/run/ivt; FIFO="$RUN/ctrl/control.fifo"; UNITS=/etc/ivt/units; TARGETS=/etc/ivt/targets; LOG=/var/log/ivt/journal
send() { [[ -p $FIFO ]] || { echo "IVT-D not running" >&2; return 1; }; echo "$1" > $FIFO; }
status_pretty() {
  printf '%-20s %-10s %-8s %-8s\n' "UNIT" "STATE" "PID" "ENABLED"
  for unit in $UNITS/*.service; do
    [[ -e $unit ]] || continue
    name=$(basename $unit .service)
    state=$(cat $RUN/state/$name 2>/dev/null || echo inactive)
    pid=$(cat $RUN/pids/$name.pid 2>/dev/null || echo -)
    enabled=no; [[ -e $TARGETS/default.wants/$name.service ]] && enabled=yes
    printf '%-20s %-10s %-8s %-8s\n' "$name" "$state" "$pid" "$enabled"
  done
}
cmd=$1; shift || true
case $cmd in
  start|stop|restart) send "$cmd:${1%.service}"; echo "$cmd request sent: ${1%.service}" ;;
  status) status_pretty ;;
  journal) unit="${1%.service}"; lines=${2:-50}; [[ $unit == "system" || -z $unit ]] && file=$LOG/system.log || file=$LOG/$unit.log; [[ -f $file ]] && tail -n $lines $file || echo "-- No entries --" ;;
  sys) echo "== IVT-OS WORKER =="; . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-IVT-OS}"; echo "Kernel: $(uname -r)"; echo "Uptime: $(( $(cut -d. -f1 /proc/uptime) / 60 )) min"; free -m 2>/dev/null; df -h / 2>/dev/null ;;
  shell) exec /bin/bash ;;
  shutdown) send shutdown; echo "shutdown request sent" ;;
  *) echo "Usage: ivtctl {start|stop|restart|status|journal|sys|shell|shutdown}" ;;
esac
CTL_EOF

# Create systemctl compatibility
RUN cat > /usr/local/bin/systemctl << 'SYSCTL_EOF'
#!/bin/bash
exec /usr/local/bin/ivtctl "$@"
SYSCTL_EOF

# Create journalctl compatibility
RUN cat > /usr/local/bin/journalctl << 'JCTL_EOF'
#!/bin/bash
LOG=/var/log/ivt/journal; unit=""; lines=50; follow=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--unit) shift; unit="${1:-}";; --unit=*) unit="${1#--unit=}";;
    -n|--lines) shift; lines="${1:-50}";; --lines=*) lines="${1#--lines=}";;
    -f|--follow) follow=true;;
  esac; shift || true
done
unit="${unit%.service}"
file="$LOG/${unit:-system}.log"
[[ ! -f $file ]] && { echo "-- No entries --"; exit 0; }
$follow && exec tail -f "$file" || exec tail -n "$lines" "$file"
JCTL_EOF

# Create service compatibility
RUN cat > /usr/local/bin/service << 'SVC_EOF'
#!/bin/bash
[[ $# -lt 2 ]] && { echo "Usage: service <unit> {start|stop|restart|status}" >&2; exit 1; }
exec /usr/local/bin/ivtctl "$2" "$1"
SVC_EOF

# Create hostnamectl compatibility
RUN cat > /usr/local/bin/hostnamectl << 'HCTL_EOF'
#!/bin/bash
cmd="${1:-status}"
case "$cmd" in
  status) echo " Static hostname: $(cat /etc/hostname 2>/dev/null || echo ivt-worker)"; echo "  Operating System: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-IVT-OS}")"; echo "          Kernel: $(uname -r)";;
  set-hostname) echo "${2:-ivt-worker}" > /etc/hostname 2>/dev/null || true;;
  hostname) cat /etc/hostname 2>/dev/null || echo ivt-worker;;
esac
HCTL_EOF

# Create Worker Health API
RUN cat > /ivt/os/worker-api.py << 'WAPI_EOF'
#!/usr/bin/env python3
import html, os, subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
PORT = int(os.environ.get("PORT", 8081))
def run(cmd):
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        return result.stdout.strip()
    except Exception as e:
        return f"ERROR: {e}"
class WorkerHandler(BaseHTTPRequestHandler):
    server_version = "IVT-OS-WORKER"
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
            self.send(200, "OK")
            return
        if self.path == "/api/status":
            self.send(200, run(["ivtctl", "status"]))
            return
        if self.path == "/api/sys":
            self.send(200, run(["ivtctl", "sys"]))
            return
        status = run(["ivtctl", "status"])
        kernel = run(["uname", "-a"])
        page = f"""<html><head><title>IVT-OS WORKER</title></head><body>
<h1>IVT-OS WORKER</h1><p>{html.escape(kernel)}</p>
<h2>Services</h2><pre>{html.escape(status)}</pre></body></html>"""
        self.send(200, page, "text/html; charset=utf-8")
if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), WorkerHandler).serve_forever()
WAPI_EOF

# Create IVT-LINK Worker Agent
RUN cat > /ivt/os/ivt-link-worker.py << 'LINK_EOF'
#!/usr/bin/env python3
import os, json, time, subprocess, threading
import urllib.request
MASTER_URL = os.environ.get("IVT_MASTER_URL", "")
LINK_SECRET = os.environ.get("IVT_LINK_SECRET", "default-secret")
def send_heartbeat():
    while True:
        try:
            data = json.dumps({"secret": LINK_SECRET, "ram": 512, "cpu": 0.2}).encode()
            req = urllib.request.Request(f"{MASTER_URL}/ivt-link/heartbeat", data=data, headers={'Content-Type': 'application/json'})
            urllib.request.urlopen(req, timeout=5)
        except:
            pass
        time.sleep(10)
def poll_tasks():
    while True:
        try:
            req = urllib.request.Request(f"{MASTER_URL}/ivt-link/poll")
            response = urllib.request.urlopen(req, timeout=20)
            if response.status == 200:
                task = json.loads(response.read().decode())
                if task.get("secret") == LINK_SECRET:
                    # Execute task
                    result = subprocess.run(task["cmd"], shell=True, capture_output=True, text=True, timeout=60)
                    # Send result back
                    result_data = json.dumps({"secret": LINK_SECRET, "id": task["id"], "output": result.stdout, "error": result.stderr}).encode()
                    req = urllib.request.Request(f"{MASTER_URL}/ivt-link/result", data=result_data, headers={'Content-Type': 'application/json'})
                    urllib.request.urlopen(req, timeout=5)
        except Exception as e:
            time.sleep(2)
def auth_with_master():
    while True:
        try:
            data = json.dumps({"secret": LINK_SECRET}).encode()
            req = urllib.request.Request(f"{MASTER_URL}/ivt-link/auth", data=data, headers={'Content-Type': 'application/json'})
            response = urllib.request.urlopen(req, timeout=5)
            if response.status == 200:
                print("[IVT-LINK WORKER] Authenticated with MASTER")
                return
        except:
            time.sleep(5)
if __name__ == "__main__":
    print("[IVT-LINK WORKER] Starting...")
    auth_with_master()
    threading.Thread(target=send_heartbeat, daemon=True).start()
    threading.Thread(target=poll_tasks, daemon=True).start()
    while True:
        time.sleep(60)
LINK_EOF

# Create service units
RUN cat > /etc/ivt/units/ivt-worker-api.service << 'UNIT1_EOF'
[Unit]
Description=IVT Worker Health API
[Service]
ExecStart=/usr/bin/python3 /ivt/os/worker-api.py
Restart=always
RestartSec=2
[Install]
Target=default
UNIT1_EOF

RUN cat > /etc/ivt/units/ivt-link-worker.service << 'UNIT2_EOF'
[Unit]
Description=IVT-LINK Worker Agent
[Service]
ExecStart=/usr/bin/python3 /ivt/os/ivt-link-worker.py
Restart=always
RestartSec=2
[Install]
Target=default
UNIT2_EOF

RUN cat > /etc/ivt/units/ivt-heartbeat.service << 'UNIT3_EOF'
[Unit]
Description=IVT Worker Heartbeat
[Service]
ExecStart=/bin/sh -c 'while true; do date +%s > /run/ivt/heartbeat; sleep 5; done'
Restart=always
RestartSec=1
[Install]
Target=default
UNIT3_EOF

# Set permissions and OS identity
RUN chmod +x /ivt/os/init /usr/local/bin/ivtctl /usr/local/bin/systemctl \
      /usr/local/bin/journalctl /usr/local/bin/service /usr/local/bin/hostnamectl && \
    printf 'PRETTY_NAME="IVT-OS WORKER 24.04 LTS"\nNAME="IVT-OS"\nVERSION_ID="24.04"\nID=ivtos\n' > /etc/os-release && \
    echo 'ivt-worker' > /etc/hostname && \
    echo default > /etc/ivt/default.target && \
    ln -sf /etc/ivt/units/ivt-worker-api.service /etc/ivt/targets/default.wants/ && \
    ln -sf /etc/ivt/units/ivt-link-worker.service /etc/ivt/targets/default.wants/ && \
    ln -sf /etc/ivt/units/ivt-heartbeat.service /etc/ivt/targets/default.wants/ && \
    ln -sf /usr/local/bin/systemctl /usr/bin/systemctl && \
    ln -sf /usr/local/bin/journalctl /usr/bin/journalctl && \
    ln -sf /usr/local/bin/service /usr/sbin/service && \
    ln -sf /usr/local/bin/hostnamectl /usr/bin/hostnamectl && \
    ln -sf /etc/ivt/units /etc/systemd/system && \
    ln -sf /etc/ivt/units /lib/systemd/system && \
    echo 'root ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/root && \
    chmod 0440 /etc/sudoers.d/root

EXPOSE 8081

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD curl -sf http://127.0.0.1:8081/health || exit 1

CMD ["/ivt/os/init"]
