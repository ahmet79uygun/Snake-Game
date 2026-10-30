#!/usr/bin/env bash
# Environment setup for snake-game: a Python turtle/tkinter desktop game.
# Installs Tk + Xvfb (headless runs) and KasmVNC, a web desktop on port 8080 where
# the game is launched so it can be viewed and played in the browser.
set -euo pipefail

if [ "${AIR_STARTUP_MODE:-}" = warmup ]; then WARMUP=1; else WARMUP=; fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KASMVNC_VERSION=1.3.4
VNC_DISPLAY=:1
VNC_PORT=8080

log() { echo "[startup] $*"; }

# --- System packages (cached in the warm-up snapshot) -------------------------
PKGS=(python3-tk xvfb xauth x11-utils xfce4 xfce4-terminal dbus-x11 curl)
missing=()
for p in "${PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if [ ${#missing[@]} -gt 0 ]; then
  log "installing apt packages: ${missing[*]}"
  sudo apt-get update -q
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"
  log "apt packages installed"
fi

if ! command -v vncserver >/dev/null 2>&1 || ! dpkg -s kasmvncserver >/dev/null 2>&1; then
  log "installing KasmVNC ${KASMVNC_VERSION}"
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  deb="/tmp/kasmvncserver_${codename}_${KASMVNC_VERSION}_amd64.deb"
  curl -fsSL -o "$deb" \
    "https://github.com/kasmtech/KasmVNC/releases/download/v${KASMVNC_VERSION}/kasmvncserver_${codename}_${KASMVNC_VERSION}_amd64.deb"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$deb"
  rm -f "$deb"
  log "KasmVNC installed"
fi

# --- KasmVNC configuration ------------------------------------------------------
# TLS is terminated by the environment's port proxy, so KasmVNC serves plain HTTP.
mkdir -p "$HOME/.vnc"
cat > "$HOME/.vnc/kasmvnc.yaml" <<YAML
network:
  protocol: http
  interface: 0.0.0.0
  websocket_port: ${VNC_PORT}
  ssl:
    require_ssl: false
    pem_certificate:
    pem_key:
  udp:
    public_ip: 127.0.0.1
desktop:
  resolution:
    width: 1280
    height: 800
YAML
printf '#!/bin/sh\nexec startxfce4\n' > "$HOME/.vnc/xstartup"
chmod +x "$HOME/.vnc/xstartup"
touch "$HOME/.vnc/.de-was-selected"
# vncserver refuses to start non-interactively without a write-access user; the
# web client itself runs with -disableBasicAuth, so this password is never prompted.
if [ ! -s "$HOME/.kasmpasswd" ]; then
  printf 'snakegame\nsnakegame\n' | kasmvncpasswd -u "$(whoami)" -w >/dev/null
fi

# --- Login-shell environment: GUI programs go to the VNC desktop -----------------
ENV_FILE="$HOME/.snake-game-env.sh"
echo "export DISPLAY=\${DISPLAY:-${VNC_DISPLAY}}" > "$ENV_FILE"
MARKER="# snake-game-env"
profile="$HOME/.profile"
for f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
  if [ -f "$f" ]; then profile="$f"; break; fi
done
for f in "$profile" "$HOME/.bashrc"; do
  grep -qF "$MARKER" "$f" 2>/dev/null || echo "[ -f \"$ENV_FILE\" ] && . \"$ENV_FILE\" $MARKER" >> "$f"
done

# --- Runtime: start the web desktop and the game (background) --------------------
if ! pgrep -x Xvnc >/dev/null 2>&1; then
  log "starting KasmVNC on display ${VNC_DISPLAY}, port ${VNC_PORT}"
  rm -f "/tmp/.X${VNC_DISPLAY#:}-lock" "/tmp/.X11-unix/X${VNC_DISPLAY#:}"
  nohup vncserver "$VNC_DISPLAY" -disableBasicAuth -select-de manual </dev/null >/tmp/kasmvnc.log 2>&1 &
fi
(
  # Wait for the X display, then launch the game on the web desktop.
  until DISPLAY="$VNC_DISPLAY" xdpyinfo >/dev/null 2>&1; do sleep 1; done
  cd "$REPO_DIR" && DISPLAY="$VNC_DISPLAY" nohup python3 main.py </dev/null >/tmp/snake-game.log 2>&1 &
) >/dev/null 2>&1 &

healthcheck() {
  log "healthcheck: tkinter import"
  python3 -c 'import tkinter, turtle; print("tk", tkinter.TkVersion)'

  # The game loop never ends on its own: still running after a few seconds = OK.
  log "healthcheck: headless game smoke test (Xvfb)"
  set +e
  (cd "$REPO_DIR" && timeout 5 xvfb-run -a python3 main.py) >/tmp/snake-smoke.log 2>&1
  rc=$?
  set -e
  if [ "$rc" -ne 124 ]; then
    log "game exited early (rc=$rc):"; cat /tmp/snake-smoke.log; return 1
  fi
  log "game ran for 5s without errors"

  log "healthcheck: waiting for KasmVNC web client on port ${VNC_PORT}"
  n=0
  until curl -fsS -H 'Host: preview.example.com' "http://localhost:${VNC_PORT}/" 2>/dev/null | grep -qi kasm; do
    n=$((n + 1))
    if [ $((n % 10)) -eq 0 ]; then log "still waiting for KasmVNC..."; tail -3 /tmp/kasmvnc.log || true; fi
    sleep 2
  done
  log "KasmVNC web client is up"
}

if [ -n "${WARMUP:-}" ]; then healthcheck; fi
log "done"
