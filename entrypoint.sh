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
      echo "[entrypoint] Server ready. Creating admin invite..."
      # Use PAPERCLIP_BOOTSTRAP_TOKEN env var as the invite token
      # This is set from ${PASSWORD} in the template, so it's predictable
      # and can be shown in Instructions tab
      BOOT_TOKEN="${PAPERCLIP_BOOTSTRAP_TOKEN:-}"
      if [ -n "$BOOT_TOKEN" ]; then
        INVITE_TOKEN="pcp_bootstrap_$BOOT_TOKEN"
        node -e "
          const crypto = require('crypto');
          const { createDb, invites, instanceUserRoles } = require('@paperclipai/db');
          const dbUrl = process.env.DATABASE_URL;
          if (!dbUrl) { console.log('[entrypoint] No DATABASE_URL, skipping bootstrap'); process.exit(0); }
          const db = createDb(dbUrl);
          (async () => {
            try {
              const admins = await db.select().from(instanceUserRoles).then(r => r.filter(x => x.role === 'instance_admin'));
              if (admins.length > 0) { console.log('[entrypoint] Admin already exists, skipping bootstrap'); process.exit(0); }
              const token = '$INVITE_TOKEN';
              const hash = crypto.createHash('sha256').update(token).digest('hex');
              await db.insert(invites).values({
                inviteType: 'bootstrap_ceo',
                tokenHash: hash,
                allowedJoinTypes: 'human',
                expiresAt: new Date(Date.now() + 72 * 60 * 60 * 1000),
                invitedByUserId: 'system',
              });
              console.log('[entrypoint] Bootstrap CEO invite created');
            } catch (e) { console.log('[entrypoint] Bootstrap error:', e.message); }
            finally { await db.\$client?.end?.({ timeout: 5 }).catch(() => {}); }
          })();
        " 2>&1 || true
      else
        echo "[entrypoint] No PAPERCLIP_BOOTSTRAP_TOKEN set, running CLI bootstrap..."
        pnpm paperclipai auth bootstrap-ceo 2>&1 || true
      fi
      touch "$BOOTSTRAP_DONE"
      break
    fi
    sleep 2
  done
fi

# Wait for server process
wait $SERVER_PID
