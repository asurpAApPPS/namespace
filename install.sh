#!/usr/bin/env bash
# All-in-one installer: Traffmonetizer + Repocket on a fresh Ubuntu/Debian VPS.
#
# Usage (interactive):   bash install.sh
# Usage (unattended):    TM_TOKEN=... RP_EMAIL=... RP_API_KEY=... DEVICE_NAME=vps2 bash install.sh
#
# Safe to re-run: it keeps your existing install folder and just updates/restarts the containers.
# Your keys are saved only in $INSTALL_DIR/.env (readable by you only). Nothing is sent anywhere
# except to the services themselves.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/passive}"

# ---- built-in account values (the script will not ask for anything that is set here) ----
# KEEP THIS FILE PRIVATE: anyone who has it has these keys. Revoke/regenerate them if it leaks.
TM_TOKEN="${TM_TOKEN:-K3kmVtqggzmLOmyRt/3PkRUSlUkadaipGF0pA5yFe4Q=}"
RP_EMAIL="${RP_EMAIL:-johnweedlings@gmail.com}"
RP_API_KEY="${RP_API_KEY:-b4c46d4c-474f-4f46-95fc-b44d3b2d57be}"

say()  { printf '\n==> %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ---- privileges -----------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  command -v sudo >/dev/null 2>&1 || die "Not root and sudo is missing. Run as root or install sudo."
  SUDO="sudo"
fi

# ---- docker ---------------------------------------------------------------
say "Checking Docker"
if ! command -v docker >/dev/null 2>&1; then
  say "Installing Docker (takes a minute or two)"
  command -v curl >/dev/null 2>&1 || { $SUDO apt-get update -y && $SUDO apt-get install -y curl; }
  curl -fsSL https://get.docker.com | $SUDO sh
fi

DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  if $SUDO docker info >/dev/null 2>&1; then
    DOCKER="$SUDO docker"
  else
    # Try to start the daemon on normal systemd servers.
    $SUDO systemctl start docker >/dev/null 2>&1 || true
    sleep 3
    if docker info >/dev/null 2>&1; then DOCKER="docker"
    elif $SUDO docker info >/dev/null 2>&1; then DOCKER="$SUDO docker"
    else die "Docker is installed but its daemon is not running."; fi
  fi
fi
$DOCKER compose version >/dev/null 2>&1 || die "Docker Compose plugin missing. Re-run after: $SUDO apt-get install -y docker-compose-plugin"

# Let the current user run docker without sudo next time (non-root only).
if [ "$(id -u)" -ne 0 ]; then
  $SUDO usermod -aG docker "$USER" >/dev/null 2>&1 || true
fi

# ---- credentials ----------------------------------------------------------
clean() { printf '%s' "$1" | tr -d '"\r\n '\''' ; }   # strip quotes, spaces, CR/LF from pasted values

ask() {  # ask VAR "Prompt" [secret]
  local var="$1" prompt="$2" secret="${3:-}" val="${!1:-}"
  while [ -z "$(clean "$val")" ]; do
    if [ "$secret" = "secret" ]; then read -rsp "$prompt: " val </dev/tty; echo
    else read -rp "$prompt: " val </dev/tty; fi
  done
  printf -v "$var" '%s' "$(clean "$val")"
}

say "Enter your account details (paste each value and press Enter)"
ask TM_TOKEN   "Traffmonetizer token" secret
ask RP_EMAIL   "Repocket email"
ask RP_API_KEY "Repocket API key"     secret
case "$RP_EMAIL" in *@*.*) ;; *) die "Repocket email doesn't look like an email address: $RP_EMAIL" ;; esac

DEVICE_NAME="$(clean "${DEVICE_NAME:-$(hostname)}")"
[ -n "$DEVICE_NAME" ] || DEVICE_NAME="vps1"

# ---- files ----------------------------------------------------------------
say "Writing files to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

( umask 077
  cat > .env <<EOF
DEVICE_NAME=$DEVICE_NAME
TM_TOKEN=$TM_TOKEN
RP_EMAIL=$RP_EMAIL
RP_API_KEY=$RP_API_KEY
EOF
)
chmod 600 .env

cat > docker-compose.yml <<'EOF'
x-limits: &limits
  restart: unless-stopped
  cpus: "0.25"
  mem_limit: 256m
  mem_reservation: 128m
  security_opt:
    - no-new-privileges:true
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "2"

services:
  traffmonetizer:
    <<: *limits
    image: traffmonetizer/cli_v2:latest
    container_name: traffmonetizer
    command: start accept --token ${TM_TOKEN} --device-name ${DEVICE_NAME}

  repocket:
    <<: *limits
    image: repocket/repocket:latest
    container_name: repocket
    environment:
      RP_EMAIL: ${RP_EMAIL}
      RP_API_KEY: ${RP_API_KEY}
EOF

# ---- start ----------------------------------------------------------------
say "Starting containers"
$DOCKER compose pull
$DOCKER compose up -d --remove-orphans

sleep 8
say "Status"
$DOCKER compose ps
# ---- keep running for N hours, then stop everything and exit ----
RUN_HOURS="${RUN_HOURS:-3}"
END=$(( $(date +%s) + RUN_HOURS * 3600 ))
echo "Running until $(date -d @"$END")"

while [ "$(date +%s)" -lt "$END" ]; do
  sleep 600                                  # check every 10 minutes
  $DOCKER compose up -d >/dev/null 2>&1      # restart any container that died
  echo "[$(date '+%H:%M')] still running, $(( (END - $(date +%s)) / 60 )) min left"
done

echo "Time is up, stopping containers"
$DOCKER compose down
exit 0
cat <<EOF

Done. Files live in: $INSTALL_DIR

Useful commands (run inside $INSTALL_DIR):
  $DOCKER compose ps                 # are they Up?
  $DOCKER compose logs --tail 20     # last log lines (check for secrets before sharing)
  $DOCKER compose pull && $DOCKER compose up -d    # update to latest images
  $DOCKER compose down               # stop everything

After a reboot, if the containers are not running, run:  cd $INSTALL_DIR && $DOCKER compose up -d

Next: check the Traffmonetizer and Repocket dashboards in a few minutes to confirm the device is online.
EOF
