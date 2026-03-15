#!/bin/sh
set -e

CONFIG_DIR="/paperclip/instances/default"
CONFIG_FILE="$CONFIG_DIR/config.json"
BOOTSTRAP_DONE="$CONFIG_DIR/.bootstrap-done"

# Create config.json if it doesn't exist
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

# Start the server in background
node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js &
SERVER_PID=$!

# If not yet bootstrapped, wait for server and run bootstrap-ceo
if [ ! -f "$BOOTSTRAP_DONE" ]; then
  echo "[entrypoint] Waiting for server to be ready for bootstrap..."
  for i in $(seq 1 60); do
    if curl -sf "http://localhost:${PORT:-3100}/api/health" > /dev/null 2>&1; then
      echo "[entrypoint] Server ready. Running bootstrap-ceo..."
      RESULT=$(pnpm paperclipai auth bootstrap-ceo 2>&1) || true
      echo "$RESULT"
      # Extract invite URL and log it prominently
      INVITE=$(echo "$RESULT" | grep -o 'http[^ ]*invite/[^ ]*' | head -1)
      if [ -n "$INVITE" ]; then
        # Replace localhost with actual domain
        DOMAIN="${PAPERCLIP_ALLOWED_HOSTNAMES:-localhost:3100}"
        PUBLIC_INVITE=$(echo "$INVITE" | sed "s|http://localhost:[0-9]*|https://$DOMAIN|")
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
