#!/bin/sh
set -e

CONFIG_DIR="/paperclip/instances/default"
CONFIG_FILE="$CONFIG_DIR/config.json"
BOOTSTRAP_DONE="$CONFIG_DIR/.bootstrap-done"

# ──────────────────────────────────────────────
# Zeabur AI Hub: one key → all agents
# ──────────────────────────────────────────────
# If ZEABUR_AI_HUB_API_KEY is set and looks like a real value,
# wire it into every agent runtime that Paperclip can spawn.
AI_HUB_BASE="https://ai-hub.zeabur.com"
HAS_AI_HUB_KEY=false
case "${ZEABUR_AI_HUB_API_KEY}" in '${'*'}') ;; '') ;; *) HAS_AI_HUB_KEY=true ;; esac

if [ "$HAS_AI_HUB_KEY" = true ]; then
  echo "[entrypoint] Zeabur AI Hub key detected — configuring agent providers"

  # OpenAI-compatible (Codex, GPT agents)
  export OPENAI_API_KEY="${ZEABUR_AI_HUB_API_KEY}"
  export OPENAI_BASE_URL="${AI_HUB_BASE}/v1"

  # Anthropic passthrough (Claude Code)
  export ANTHROPIC_API_KEY="${ZEABUR_AI_HUB_API_KEY}"
  export ANTHROPIC_BASE_URL="${AI_HUB_BASE}/anthropic"

  # Google Gemini via OpenAI compat
  export GOOGLE_API_KEY="${ZEABUR_AI_HUB_API_KEY}"

  echo "[entrypoint] AI Hub providers configured:"
  echo "  OpenAI    → ${AI_HUB_BASE}/v1"
  echo "  Anthropic → ${AI_HUB_BASE}/anthropic"
  echo "  All agents will route through Zeabur AI Hub"
else
  echo "[entrypoint] No Zeabur AI Hub key — agents will use their own API keys"
fi

# ──────────────────────────────────────────────
# Auto-generate config.json if missing
# ──────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
  echo "[entrypoint] Creating config.json..."
  mkdir -p "$CONFIG_DIR"
  node -e "
    const fs = require('fs');
    const config = {
      '\$meta': {version: 1, updatedAt: new Date().toISOString(), source: 'onboard'},
      database: {
        mode: process.env.DATABASE_URL ? 'postgres' : 'embedded-postgres',
        connectionString: process.env.DATABASE_URL || undefined
      },
      logging: {mode: 'file', logDir: '$CONFIG_DIR/logs'},
      server: {
        deploymentMode: process.env.PAPERCLIP_DEPLOYMENT_MODE || 'authenticated',
        exposure: process.env.PAPERCLIP_DEPLOYMENT_EXPOSURE || 'private',
        host: process.env.HOST || '0.0.0.0',
        port: parseInt(process.env.PORT || '3100'),
        allowedHostnames: (process.env.PAPERCLIP_ALLOWED_HOSTNAMES || '').split(',').filter(Boolean),
        serveUi: true
      }
    };
    fs.writeFileSync('$CONFIG_FILE', JSON.stringify(config, null, 2));
    console.log('[entrypoint] config.json created');
  "
fi

# ──────────────────────────────────────────────
# Start server
# ──────────────────────────────────────────────
node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js &
SERVER_PID=$!

# ──────────────────────────────────────────────
# Auto-bootstrap CEO on first boot
# ──────────────────────────────────────────────
if [ ! -f "$BOOTSTRAP_DONE" ]; then
  echo "[entrypoint] Waiting for server to be ready for bootstrap..."
  for i in $(seq 1 60); do
    if curl -sf "http://localhost:${PORT:-3100}/api/health" > /dev/null 2>&1; then
      echo "[entrypoint] Server ready. Running bootstrap-ceo..."
      RESULT=$(pnpm paperclipai auth bootstrap-ceo 2>&1) || true
      echo "$RESULT"
      INVITE=$(echo "$RESULT" | grep -o 'http[^ ]*invite/[^ ]*' | head -1)
      if [ -n "$INVITE" ]; then
        DOMAIN="${PAPERCLIP_ALLOWED_HOSTNAMES%%,*}"
        DOMAIN="${DOMAIN:-localhost:3100}"
        PUBLIC_INVITE=$(echo "$INVITE" | sed "s|http://localhost:[0-9]*|https://$DOMAIN|")
        export PAPERCLIP_INVITE_URL="$PUBLIC_INVITE"
        # Write to file so it persists across restarts
        echo "$PUBLIC_INVITE" > "$CONFIG_DIR/.invite-url"
        echo ""
        echo "============================================"
        echo "  PAPERCLIP CEO INVITE LINK"
        echo "  $PUBLIC_INVITE"
        echo "  (expires in 3 days)"
        echo "============================================"
        echo ""
      fi
      touch "$BOOTSTRAP_DONE"
      break
    fi
    sleep 2
  done
fi

# Wait for server process
wait $SERVER_PID
