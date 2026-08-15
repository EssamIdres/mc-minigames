#!/bin/bash
set -e

SERVER_NAME="${SERVER_NAME:-$(basename "$(pwd)")}"
DRIVE_ROOT="mcworlds:minecraft/$SERVER_NAME"
JAVA_HEAP="${JAVA_HEAP:-10G}"
BACKUP_KEEP=3
BACKUP_INTERVAL=3600
PAPER_VERSION="${PAPER_VERSION:-1.21.1}"
VELOCITY_VERSION="${VELOCITY_VERSION:-4.0.0}"
VELOCITY_BUILD="${VELOCITY_BUILD:-6}"

mkdir -p ~/.config/rclone

echo "==> Server: $SERVER_NAME"
echo "==> Drive root: $DRIVE_ROOT"

# EULA
echo "eula=true" > eula.txt

# Download Paper if not present
if [ ! -f server.jar ]; then
  echo "==> Downloading Paper $PAPER_VERSION..."
  curl -fsSL -H "User-Agent: mc-bot (https://github.com/EssamIdres)" "https://fill.papermc.io/v3/projects/paper/versions/${PAPER_VERSION}/builds" > /tmp/builds.json
  URL=$(jq -r 'first(.[] | select(.channel == "STABLE") | .downloads."server:default".url)' /tmp/builds.json)
  echo "==> Downloading jar: $URL"
  curl -fsSL -o server.jar "$URL"
fi

# Start playit tunnel
if [ -n "$PLAYIT_SECRET" ]; then
  echo "==> Starting playit tunnel..."
  curl -fsSL -o playit https://github.com/playit-cloud/playit-agent/releases/latest/download/playit-linux-amd64
  chmod +x playit
  printf 'secret_key = "%s"\n' "$PLAYIT_SECRET" > playit.toml
  ./playit --socket-path="$PWD/playitd.sock" --secret-path="$PWD/playit.toml" > playit.log 2>&1 &
  sleep 10
  echo "==> Playit log (find your tunnel address here):"
  cat playit.log
fi

# Velocity proxy (only on the proxy host, e.g. mc-lobby)
if [ "$PROXY_HOST" = "true" ]; then
  echo "==> Setting up Velocity proxy..."
  if [ ! -f velocity.jar ]; then
    VEL_URL=$(curl -fsSL -H "User-Agent: mc-bot (https://github.com/EssamIdres)" \
      "https://fill.papermc.io/v3/projects/velocity/versions/${VELOCITY_VERSION}/builds/${VELOCITY_BUILD}" | \
      jq -r '.downloads."server:default".url')
    echo "==> Downloading Velocity: $VEL_URL"
    curl -fsSL -o velocity.jar "$VEL_URL"
  fi

  if [ -z "$VELOCITY_SECRET" ]; then
    echo "==> ERROR: VELOCITY_SECRET not set. Cannot start proxy."
    exit 1
  fi
  printf '%s' "$VELOCITY_SECRET" > forwarding.secret

  cat > velocity.toml <<'EOF'
config-version = "2.8"
bind = "0.0.0.0:25565"
motd = "<#09add3>MC Network"
show-max-players = 100
online-mode = false
force-key-authentication = false
prevent-client-proxy-connections = false
player-info-forwarding-mode = "modern"
forwarding-secret-file = "forwarding.secret"
announce-forge = false
kick-existing-players = true
ping-passthrough = "DISABLED"
enable-player-address-logging = true

[servers]
lobby = "127.0.0.1:25566"
survival = "tissues-economy.tun.ply.gg:25565"
minigames = "tissues-heard.tun.ply.gg:25565"
creative = "tissues-individuals.tun.ply.gg:25565"

try = ["lobby"]

[forced-hosts]

[advanced]
compression-threshold = 256
compression-level = -1
login-ratelimit = 3000
connection-timeout = 5000
read-timeout = 30000
haproxy-protocol = false
tcp-fast-open = false
bungee-plugin-message-channel = true
show-ping-requests = false
failover-on-unexpected-server-disconnect = true
announce-proxy-commands = true
log-command-executions = false
log-player-connections = true
accepts-transfers = false
enable-reuse-port = false
command-rate-limit = 50
forward-commands-if-rate-limited = true
kick-after-rate-limited-commands = 0
tab-complete-rate-limit = 10
kick-after-rate-limited-tab-completes = 0

[query]
enabled = false
port = 25565
map = "Velocity"
show-plugins = false
EOF

  # Lobby Paper backend must listen on 25566 (internal), proxy takes 25565
  sed -i 's/^server-port=.*/server-port=25566/' server.properties

  echo "==> Starting Velocity proxy..."
  java -Xms512M -Xmx1G -jar velocity.jar > velocity.log 2>&1 &
  VELOCITY_PID=$!
  echo "==> Velocity PID: $VELOCITY_PID"
  sleep 10
  if kill -0 $VELOCITY_PID 2>/dev/null; then
    echo "==> Velocity is UP"
  else
    echo "==> VELOCITY DIED. velocity.log:"
    tail -50 velocity.log
    exit 1
  fi
  echo "==> velocity.log:"
  tail -20 velocity.log
fi

# Configure Velocity modern forwarding on the Paper backend
if [ -n "$VELOCITY_SECRET" ]; then
  echo "==> Configuring Velocity forwarding for Paper..."
  mkdir -p config
  cat > config/paper-global.yml <<EOF
proxies:
  velocity:
    enabled: true
    online-mode: false
    secret: "$VELOCITY_SECRET"
EOF
fi

# Restore latest backup (persistent world) if one exists
if rclone lsf "$DRIVE_ROOT/backups" --dirs-only 2>/dev/null | grep -q .; then
  NEWEST=$(rclone lsf "$DRIVE_ROOT/backups" --dirs-only 2>/dev/null | sort -r | head -1)
  echo "==> Restoring latest backup: $NEWEST"
  rclone copy "$DRIVE_ROOT/backups/$NEWEST/" . 2>&1 | tail -3 || true
else
  echo "==> No backups found — generating a fresh world."
fi

# Named pipe so we can send server commands (save-all) reliably
PIPE=/tmp/mc-in
rm -f "$PIPE"
mkfifo "$PIPE"

# Start server reading commands from the pipe
tail -f "$PIPE" | java -Xms2G -Xmx${JAVA_HEAP} -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 \
     -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch \
     -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M \
     -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 \
     -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 \
     -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem \
     -XX:MaxTenuringThreshold=1 -Dusing.aikars.flags=https://mcflags.emc.gs \
     -Daikars.new.flags=true -jar server.jar nogui > server.log 2>&1 &
SERVER_PID=$!
echo "==> Server PID: $SERVER_PID"

# Open the pipe for writing
exec 3> "$PIPE"

# Wait for startup
echo "==> Waiting for server startup..."
for i in $(seq 1 300); do
  if grep -q "Done (" server.log 2>/dev/null; then
    echo "==> Server is UP!"
    break
  fi
  sleep 2
done

if ! kill -0 $SERVER_PID 2>/dev/null; then
  echo "==> SERVER FAILED TO START. Log:"
  tail -50 server.log
  exit 1
fi

# Telegram live console: stream server.log to chat every 5s
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
  echo "==> Telegram console streaming enabled"
  (
    last=$(wc -c < server.log 2>/dev/null || echo 0)
    while kill -0 $SERVER_PID 2>/dev/null; do
      sleep 5
      now=$(wc -c < server.log 2>/dev/null || echo 0)
      if [ "$now" -gt "$last" ]; then
        msg=$(tail -c +$((last+1)) server.log 2>/dev/null | tail -c 3000)
        last=$now
        if [ -n "$msg" ]; then
          curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
            -d chat_id="$TELEGRAM_CHAT_ID" -d text="$msg" >/dev/null 2>&1 || true
        fi
      fi
    done
  ) &
  TG_STREAM_PID=$!
fi

# Telegram command channel: poll repo for console-cmd.txt and feed to server pipe
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] && [ -n "$GITHUB_TOKEN" ]; then
  (
    while kill -0 $SERVER_PID 2>/dev/null; do
      sleep 4
      line=$(curl -fsSL "https://raw.githubusercontent.com/$GITHUB_REPOSITORY/main/console-cmd.txt" 2>/dev/null | head -1 || true)
      if [ -n "$line" ]; then
        echo "==> TG command: $line"
        echo "$line" >&3
        SHA=$(curl -fsSL -H "Authorization: token $GITHUB_TOKEN" \
          "https://api.github.com/repos/$GITHUB_REPOSITORY/contents/console-cmd.txt" 2>/dev/null | jq -r '.sha' || true)
        if [ -n "$SHA" ] && [ "$SHA" != "null" ]; then
          curl -s -X DELETE -H "Authorization: token $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github+json" -H "Content-Type: application/json" \
            -d "{\"message\":\"delete console cmd\",\"sha\":\"$SHA\"}" \
            "https://api.github.com/repos/$GITHUB_REPOSITORY/contents/console-cmd.txt" >/dev/null 2>&1 || true
        fi
      fi
    done
  ) &
fi

# Backup loop: every 60s, save + upload, keep only newest N
echo "==> Starting backup loop (every ${BACKUP_INTERVAL}s, keep ${BACKUP_KEEP})..."
BACKUP_ROOT="/tmp/backups"
mkdir -p "$BACKUP_ROOT"

while kill -0 $SERVER_PID 2>/dev/null; do
  sleep "$BACKUP_INTERVAL"

  echo "==> Sending save-all"
  echo "save-all" >&3
  sleep 5

  TS=$(date +%Y%m%d-%H%M%S)
  BDIR="$BACKUP_ROOT/$TS"
  mkdir -p "$BDIR"

  for w in world world_nether world_the_end; do
    if [ -d "$w" ]; then
      cp -r "$w" "$BDIR/$w" 2>/dev/null || true
    fi
  done

  if [ -d plugins ]; then
    cp -r plugins "$BDIR/plugins" 2>/dev/null || true
  fi

  echo "==> Uploading backup $TS ..."
  rclone copy "$BDIR" "$DRIVE_ROOT/backups/$TS" 2>&1 | tail -3 || true
  rm -rf "$BDIR"

  # Prune: keep only the newest $BACKUP_KEEP dirs on Drive
  for d in $(rclone lsf "$DRIVE_ROOT/backups" --dirs-only 2>/dev/null | sort -r | tail -n +$((BACKUP_KEEP+1))); do
    echo "==> Pruning old backup: $d"
    rclone purge "$DRIVE_ROOT/backups/$d" 2>&1 | tail -1 || true
  done
done

echo "==> Server stopped. Final log:"
tail -30 server.log