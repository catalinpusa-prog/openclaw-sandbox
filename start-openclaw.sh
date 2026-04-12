#!/bin/bash
# Startup script for OpenClaw in Cloudflare Sandbox
# This script:
# 1. Restores config/workspace/skills from R2 via rclone (if configured)
# 2. Runs openclaw onboard --non-interactive to configure from env vars
# 3. Patches config for features onboard doesn't cover (channels, gateway auth)
# 4. Starts a background sync loop (rclone, watches for file changes)
# 5. Starts the gateway

set -e

if pgrep -f "openclaw gateway" > /dev/null 2>&1; then
    echo "OpenClaw gateway is already running, exiting."
    exit 0
fi

CONFIG_DIR="/root/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
WORKSPACE_DIR="/root/clawd"
SKILLS_DIR="/root/clawd/skills"
RCLONE_CONF="/root/.config/rclone/rclone.conf"
LAST_SYNC_FILE="/tmp/.last-sync"

# Backwards compat: MOLTBOT_GATEWAY_TOKEN -> OPENCLAW_GATEWAY_TOKEN
if [ -z "$OPENCLAW_GATEWAY_TOKEN" ] && [ -n "$MOLTBOT_GATEWAY_TOKEN" ]; then
    export OPENCLAW_GATEWAY_TOKEN="$MOLTBOT_GATEWAY_TOKEN"
fi

echo "Config directory: $CONFIG_DIR"

mkdir -p "$CONFIG_DIR"

# ============================================================
# RCLONE SETUP
# ============================================================

r2_configured() {
    [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$CF_ACCOUNT_ID" ]
}

R2_BUCKET="${R2_BUCKET_NAME:-moltbot-data}"

setup_rclone() {
    mkdir -p "$(dirname "$RCLONE_CONF")"
    cat > "$RCLONE_CONF" << EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = $R2_ACCESS_KEY_ID
secret_access_key = $R2_SECRET_ACCESS_KEY
endpoint = https://${CF_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
EOF
    touch /tmp/.rclone-configured
    echo "Rclone configured for bucket: $R2_BUCKET"
}

RCLONE_FLAGS="--transfers=16 --fast-list --s3-no-check-bucket"

# ============================================================
# RESTORE FROM R2
# ============================================================

if r2_configured; then
    setup_rclone

    echo "Checking R2 for existing backup..."
    # Check if R2 has an openclaw config backup
    if rclone ls "r2:${R2_BUCKET}/openclaw/openclaw.json" $RCLONE_FLAGS 2>/dev/null | grep -q openclaw.json; then
        echo "Restoring config from R2..."
        rclone copy "r2:${R2_BUCKET}/openclaw/" "$CONFIG_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: config restore failed with exit code $?"
        echo "Config restored"
    elif rclone ls "r2:${R2_BUCKET}/clawdbot/clawdbot.json" $RCLONE_FLAGS 2>/dev/null | grep -q clawdbot.json; then
        echo "Restoring from legacy R2 backup..."
        rclone copy "r2:${R2_BUCKET}/clawdbot/" "$CONFIG_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: legacy config restore failed with exit code $?"
        if [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ]; then
            mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
        fi
        echo "Legacy config restored and migrated"
    else
        echo "No backup found in R2, starting fresh"
    fi

    # Restore workspace
    REMOTE_WS_COUNT=$(rclone ls "r2:${R2_BUCKET}/workspace/" $RCLONE_FLAGS 2>/dev/null | wc -l)
    if [ "$REMOTE_WS_COUNT" -gt 0 ]; then
        echo "Restoring workspace from R2 ($REMOTE_WS_COUNT files)..."
        mkdir -p "$WORKSPACE_DIR"
        rclone copy "r2:${R2_BUCKET}/workspace/" "$WORKSPACE_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: workspace restore failed with exit code $?"
        echo "Workspace restored"
    fi

    # Restore skills
    REMOTE_SK_COUNT=$(rclone ls "r2:${R2_BUCKET}/skills/" $RCLONE_FLAGS 2>/dev/null | wc -l)
    if [ "$REMOTE_SK_COUNT" -gt 0 ]; then
        echo "Restoring skills from R2 ($REMOTE_SK_COUNT files)..."
        mkdir -p "$SKILLS_DIR"
        rclone copy "r2:${R2_BUCKET}/skills/" "$SKILLS_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: skills restore failed with exit code $?"
        echo "Skills restored"
    fi
else
    echo "R2 not configured, starting fresh"
fi

# ============================================================
# ONBOARD (only if no config exists yet)
# ============================================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, running openclaw onboard..."

    AUTH_ARGS=""
    if [ -n "$CLOUDFLARE_AI_GATEWAY_API_KEY" ] && [ -n "$CF_AI_GATEWAY_ACCOUNT_ID" ] && [ -n "$CF_AI_GATEWAY_GATEWAY_ID" ]; then
        AUTH_ARGS="--auth-choice cloudflare-ai-gateway-api-key \
            --cloudflare-ai-gateway-account-id $CF_AI_GATEWAY_ACCOUNT_ID \
            --cloudflare-ai-gateway-gateway-id $CF_AI_GATEWAY_GATEWAY_ID \
            --cloudflare-ai-gateway-api-key $CLOUDFLARE_AI_GATEWAY_API_KEY"
    elif [ -n "$ANTHROPIC_API_KEY" ]; then
        AUTH_ARGS="--auth-choice apiKey --anthropic-api-key $ANTHROPIC_API_KEY"
    elif [ -n "$OPENAI_API_KEY" ]; then
        AUTH_ARGS="--auth-choice openai-api-key --openai-api-key $OPENAI_API_KEY"
    fi

    openclaw onboard --non-interactive --accept-risk \
        --mode local \
        $AUTH_ARGS \
        --gateway-port 18789 \
        --gateway-bind lan \
        --skip-channels \
        --skip-skills \
        --skip-health

    echo "Onboard completed"
else
    echo "Using existing config"
fi

# ============================================================
# PATCH CONFIG (channels, gateway auth, trusted proxies)
# ============================================================
# openclaw onboard handles provider/model config, but we need to patch in:
# - Channel config (Telegram, Discord, Slack)
# - Gateway token auth
# - Trusted proxies for sandbox networking
# - Base URL override for legacy AI Gateway path
node << 'EOFPATCH'
const fs = require('fs');

const configPath = '/root/.openclaw/openclaw.json';
console.log('Patching config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Migrate stale R2 config: remove keys that are no longer valid in newer OpenClaw versions
if (config.models && config.models.allowed) {
    delete config.models.allowed;
    if (Object.keys(config.models).length === 0) delete config.models;
    console.log('Migrated: removed stale models.allowed key');
}

// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

if (process.env.OPENCLAW_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.OPENCLAW_GATEWAY_TOKEN;
}

config.gateway.controlUi = config.gateway.controlUi || {};

// Always allow insecure auth (Control UI served via CF Worker proxy, not directly)
config.gateway.controlUi.allowInsecureAuth = true;

// Disable device pairing requirement for Control UI.
// Must be at controlUi level — NOT at gateway root (that key is unrecognized at root).
// This sets allowBypass=true which skips the pairing check for operator-role connections.
config.gateway.controlUi.dangerouslyDisableDeviceAuth = true;

// Always set allowedOrigins — hardcoded fallback guarantees Control UI works
// even if WORKER_URL env var is missing (e.g. after upstream overwrites env.ts)
const HARDCODED_WORKER_URL = 'https://openclaw-sandbox.alex-046.workers.dev';
const workerUrl = process.env.WORKER_URL || HARDCODED_WORKER_URL;
config.gateway.controlUi.allowedOrigins = [workerUrl];
console.log('Control UI allowed origin:', workerUrl);

// Legacy AI Gateway base URL override:
// ANTHROPIC_BASE_URL is picked up natively by the Anthropic SDK,
// so we don't need to patch the provider config. Writing a provider
// entry without a models array breaks OpenClaw's config validation.

// AI Gateway model override (CF_AI_GATEWAY_MODEL=provider/model-id)
// Adds a provider entry for any AI Gateway provider and sets it as default model.
// Examples:
//   workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast
//   openai/gpt-4o
//   anthropic/claude-sonnet-4-5
if (process.env.CF_AI_GATEWAY_MODEL) {
    const raw = process.env.CF_AI_GATEWAY_MODEL;
    const slashIdx = raw.indexOf('/');
    const gwProvider = raw.substring(0, slashIdx);
    const modelId = raw.substring(slashIdx + 1);

    const accountId = process.env.CF_AI_GATEWAY_ACCOUNT_ID;
    const gatewayId = process.env.CF_AI_GATEWAY_GATEWAY_ID;
    const apiKey = process.env.CLOUDFLARE_AI_GATEWAY_API_KEY;

    let baseUrl;
    if (accountId && gatewayId) {
        baseUrl = 'https://gateway.ai.cloudflare.com/v1/' + accountId + '/' + gatewayId + '/' + gwProvider;
        if (gwProvider === 'workers-ai') baseUrl += '/v1';
    } else if (gwProvider === 'workers-ai' && process.env.CF_ACCOUNT_ID) {
        baseUrl = 'https://api.cloudflare.com/client/v4/accounts/' + process.env.CF_ACCOUNT_ID + '/ai/v1';
    }

    if (baseUrl && apiKey) {
        const api = gwProvider === 'anthropic' ? 'anthropic-messages' : 'openai-completions';
        const providerName = 'cf-ai-gw-' + gwProvider;

        config.models = config.models || {};
        config.models.providers = config.models.providers || {};
        config.models.providers[providerName] = {
            baseUrl: baseUrl,
            apiKey: apiKey,
            api: api,
            models: [{ id: modelId, name: modelId, contextWindow: 131072, maxTokens: 8192 }],
        };
        config.agents = config.agents || {};
        config.agents.defaults = config.agents.defaults || {};
        config.agents.defaults.model = { primary: providerName + '/' + modelId };
        console.log('AI Gateway model override: provider=' + providerName + ' model=' + modelId + ' via ' + baseUrl);
    } else {
        console.warn('CF_AI_GATEWAY_MODEL set but missing required config (account ID, gateway ID, or API key)');
    }
}

// ── LLM Providers ──────────────────────────────────────────────────────────
// Configured from Worker secrets. Each provider is re-applied on every start
// so that secrets added/changed in Cloudflare take effect after restart.

// OpenRouter provider (qwen3 free, kimi via OpenRouter, etc.)
if (process.env.OPENROUTER_API_KEY) {
    config.models = config.models || {};
    config.models.providers = config.models.providers || {};
    config.models.providers['openrouter'] = {
        baseUrl: 'https://openrouter.ai/api/v1',
        apiKey: process.env.OPENROUTER_API_KEY,
        api: 'openai-completions',
        models: [
            { id: 'qwen/qwen3-235b-a22b:free',  name: 'Qwen3 235B MoE (free)',  contextWindow: 40960,  maxTokens: 8192  },
            { id: 'qwen/qwen3-30b-a3b:free',    name: 'Qwen3 30B MoE (free)',   contextWindow: 40960,  maxTokens: 8192  },
            { id: 'qwen/qwen3-14b:free',         name: 'Qwen3 14B (free)',       contextWindow: 40960,  maxTokens: 8192  },
            { id: 'qwen/qwen3-8b:free',          name: 'Qwen3 8B (free)',        contextWindow: 40960,  maxTokens: 8192  },
            { id: 'moonshotai/kimi-k1.5',        name: 'Kimi K1.5 (OpenRouter)', contextWindow: 131072, maxTokens: 8192  },
            { id: 'moonshotai/kimi-k2:free',     name: 'Kimi K2 (free)',         contextWindow: 131072, maxTokens: 8192  },
        ],
    };
    console.log('OpenRouter provider configured');
}

// Moonshot / Kimi provider (direct API)
if (process.env.MOONSHOT_API_KEY) {
    config.models = config.models || {};
    config.models.providers = config.models.providers || {};
    config.models.providers['moonshot'] = {
        baseUrl: 'https://api.moonshot.cn/v1',
        apiKey: process.env.MOONSHOT_API_KEY,
        api: 'openai-completions',
        models: [
            { id: 'moonshot-v1-128k', name: 'Moonshot 128K',  contextWindow: 131072, maxTokens: 32768 },
            { id: 'moonshot-v1-32k',  name: 'Moonshot 32K',   contextWindow: 32768,  maxTokens: 32768 },
            { id: 'moonshot-v1-8k',   name: 'Moonshot 8K',    contextWindow: 8192,   maxTokens: 8192  },
            { id: 'kimi-k2',          name: 'Kimi K2',         contextWindow: 131072, maxTokens: 8192  },
            { id: 'kimi-latest',      name: 'Kimi latest',     contextWindow: 131072, maxTokens: 8192  },
        ],
    };
    console.log('Moonshot provider configured');
}

// Anthropic models — provider configured via onboard (ANTHROPIC_API_KEY).
// Explicitly register models so they appear in Control UI model picker.
if (process.env.ANTHROPIC_API_KEY) {
    config.models = config.models || {};
    config.models.providers = config.models.providers || {};
    config.models.providers['anthropic'] = {
        baseUrl: 'https://api.anthropic.com',
        api: 'anthropic-messages',
        apiKey: process.env.ANTHROPIC_API_KEY,
        models: [
            { id: 'claude-opus-4-6',              name: 'Claude Opus 4.6',    contextWindow: 200000, maxTokens: 32768 },
            { id: 'claude-sonnet-4-6',             name: 'Claude Sonnet 4.6', contextWindow: 200000, maxTokens: 16384 },
            { id: 'claude-haiku-4-5-20251001',     name: 'Claude Haiku 4.5',  contextWindow: 200000, maxTokens: 16384 },
            { id: 'claude-opus-4-5',               name: 'Claude Opus 4.5',   contextWindow: 200000, maxTokens: 32768 },
            { id: 'claude-sonnet-4-5',             name: 'Claude Sonnet 4.5', contextWindow: 200000, maxTokens: 16384 },
        ],
    };
    // Keep claude-sonnet-4-6 as primary default
    config.agents = config.agents || {};
    config.agents.defaults = config.agents.defaults || {};
    if (!config.agents.defaults.model) {
        config.agents.defaults.model = { primary: 'anthropic/claude-sonnet-4-6' };
    }
    console.log('Anthropic provider configured with', Object.keys(config.models.providers).length, 'total providers');
}

// Telegram configuration
// Overwrite entire channel object to drop stale keys from old R2 backups
// that would fail OpenClaw's strict config validation (see #47)
if (process.env.TELEGRAM_BOT_TOKEN) {
    const dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    config.channels.telegram = {
        botToken: process.env.TELEGRAM_BOT_TOKEN,
        enabled: true,
        dmPolicy: dmPolicy,
    };
    if (process.env.TELEGRAM_DM_ALLOW_FROM) {
        config.channels.telegram.allowFrom = process.env.TELEGRAM_DM_ALLOW_FROM.split(',');
    } else if (dmPolicy === 'open') {
        config.channels.telegram.allowFrom = ['*'];
    }
}

// Discord configuration
// Discord uses a nested dm object: dm.policy, dm.allowFrom (per DiscordDmConfig)
if (process.env.DISCORD_BOT_TOKEN) {
    const dmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
    const dm = { policy: dmPolicy };
    if (dmPolicy === 'open') {
        dm.allowFrom = ['*'];
    }
    config.channels.discord = {
        token: process.env.DISCORD_BOT_TOKEN,
        enabled: true,
        dm: dm,
    };
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = {
        botToken: process.env.SLACK_BOT_TOKEN,
        appToken: process.env.SLACK_APP_TOKEN,
        enabled: true,
    };
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration patched successfully');
EOFPATCH

# ============================================================
# FORCE INITIAL R2 SYNC (push patched config immediately)
# ============================================================
# The background sync loop uses a file-newer-than-marker check.
# Since the patch above runs BEFORE the loop starts, the marker would be
# set AFTER the patch, causing the first loop iteration to miss the change.
# This initial sync ensures the freshly patched config is always in R2.
if r2_configured; then
    echo "Syncing patched config to R2..."
    rclone sync "$CONFIG_DIR/" "r2:${R2_BUCKET}/openclaw/" \
        $RCLONE_FLAGS --exclude='*.lock' --exclude='*.log' --exclude='*.tmp' --exclude='.git/**' 2>/dev/null \
        && echo "Initial config sync to R2 complete" \
        || echo "WARNING: initial config sync to R2 failed (non-fatal)"
fi

# ============================================================
# BACKGROUND SYNC LOOP
# ============================================================
if r2_configured; then
    echo "Starting background R2 sync loop..."
    (
        MARKER=/tmp/.last-sync-marker
        LOGFILE=/tmp/r2-sync.log
        touch "$MARKER"

        while true; do
            sleep 30

            CHANGED=/tmp/.changed-files
            {
                find "$CONFIG_DIR" -newer "$MARKER" -type f -printf '%P\n' 2>/dev/null
                find "$WORKSPACE_DIR" -newer "$MARKER" \
                    -not -path '*/node_modules/*' \
                    -not -path '*/.git/*' \
                    -type f -printf '%P\n' 2>/dev/null
            } > "$CHANGED"

            COUNT=$(wc -l < "$CHANGED" 2>/dev/null || echo 0)

            if [ "$COUNT" -gt 0 ]; then
                echo "[sync] Uploading changes ($COUNT files) at $(date)" >> "$LOGFILE"
                rclone sync "$CONFIG_DIR/" "r2:${R2_BUCKET}/openclaw/" \
                    $RCLONE_FLAGS --exclude='*.lock' --exclude='*.log' --exclude='*.tmp' --exclude='.git/**' 2>> "$LOGFILE"
                if [ -d "$WORKSPACE_DIR" ]; then
                    rclone sync "$WORKSPACE_DIR/" "r2:${R2_BUCKET}/workspace/" \
                        $RCLONE_FLAGS --exclude='skills/**' --exclude='.git/**' --exclude='node_modules/**' 2>> "$LOGFILE"
                fi
                if [ -d "$SKILLS_DIR" ]; then
                    rclone sync "$SKILLS_DIR/" "r2:${R2_BUCKET}/skills/" \
                        $RCLONE_FLAGS 2>> "$LOGFILE"
                fi
                date -Iseconds > "$LAST_SYNC_FILE"
                touch "$MARKER"
                echo "[sync] Complete at $(date)" >> "$LOGFILE"
            fi
        done
    ) &
    echo "Background sync loop started (PID: $!)"
fi

# ============================================================
# HIMALAYA EMAIL CONFIG
# ============================================================
if [ -n "$EMAIL_INFO_PASSWORD" ] || [ -n "$EMAIL_ALEX_PASSWORD" ]; then
    echo "Writing himalaya email config..."
    mkdir -p /root/.config/himalaya
    cat > /root/.config/himalaya/config.toml << HIMALAYA_EOF
[accounts.info-pusa]
email = "info@pusa.ro"
display-name = "Info Pusa"
default = true
backend.type = "imap"
backend.host = "mail.avocatul-meu.ro"
backend.port = 993
backend.encryption.type = "tls"
backend.login = "info@pusa.ro"
backend.auth.type = "password"
backend.auth.cmd = "echo \$EMAIL_INFO_PASSWORD"
message.send.backend.type = "smtp"
message.send.backend.host = "mail.avocatul-meu.ro"
message.send.backend.port = 587
message.send.backend.encryption.type = "start-tls"
message.send.backend.login = "info@pusa.ro"
message.send.backend.auth.type = "password"
message.send.backend.auth.cmd = "echo \$EMAIL_INFO_PASSWORD"

[accounts.alex-pusa]
email = "alex@pusa.ro"
display-name = "Alex Pusa"
backend.type = "imap"
backend.host = "mail.avocatul-meu.ro"
backend.port = 993
backend.encryption.type = "tls"
backend.login = "alex@pusa.ro"
backend.auth.type = "password"
backend.auth.cmd = "echo \$EMAIL_ALEX_PASSWORD"
message.send.backend.type = "smtp"
message.send.backend.host = "mail.avocatul-meu.ro"
message.send.backend.port = 587
message.send.backend.encryption.type = "start-tls"
message.send.backend.login = "alex@pusa.ro"
message.send.backend.auth.type = "password"
message.send.backend.auth.cmd = "echo \$EMAIL_ALEX_PASSWORD"

[accounts.catalin-avocatul]
email = "catalin.pusa@avocatul-meu.ro"
display-name = "Catalin Pusa"
backend.type = "imap"
backend.host = "mail.avocatul-meu.ro"
backend.port = 993
backend.encryption.type = "tls"
backend.login = "catalin.pusa@avocatul-meu.ro"
backend.auth.type = "password"
backend.auth.cmd = "echo \$EMAIL_CATALIN_PASSWORD"
message.send.backend.type = "smtp"
message.send.backend.host = "mail.avocatul-meu.ro"
message.send.backend.port = 587
message.send.backend.encryption.type = "start-tls"
message.send.backend.login = "catalin.pusa@avocatul-meu.ro"
message.send.backend.auth.type = "password"
message.send.backend.auth.cmd = "echo \$EMAIL_CATALIN_PASSWORD"
HIMALAYA_EOF
    echo "Himalaya config written (3 accounts)"
fi

# ============================================================
# INSTALL CLAWHUB SKILLS (background, non-blocking)
# ============================================================
# Runs in background so it doesn't delay gateway startup.
# Skips skills already present (restored from R2 or previously installed).
# After install the R2 sync loop will pick them up and persist to R2.
(
    mkdir -p "$SKILLS_DIR"
    CLAWHUB_SKILLS=(
        "asleep123/caldav-calendar"
        "xk103295870-alt/seedance-prompt-wizard"
        "vassiliylakhonin/vassili-clawhub-cli"
    )
    sleep 5  # brief delay so gateway starts first
    for skill in "${CLAWHUB_SKILLS[@]}"; do
        skill_name="${skill##*/}"
        if [ ! -d "$SKILLS_DIR/$skill_name" ]; then
            echo "[skills] Installing: $skill ..."
            openclaw skills install "$skill" 2>&1 \
                && echo "[skills] Installed: $skill" \
                || echo "[skills] WARNING: failed to install $skill"
        else
            echo "[skills] Already present: $skill_name (skipping)"
        fi
    done
    echo "[skills] ClawHub install complete"
) &
echo "ClawHub skill installation started in background (PID: $!)"

# ============================================================
# START GATEWAY
# ============================================================
echo "Starting OpenClaw Gateway..."
echo "Gateway will be available on port 18789"

rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

# Kill any zombie processes still holding port 18789
# (can happen when gateway/restart kills the tracked process but leaves orphans)
fuser -k 18789/tcp 2>/dev/null || true
pkill -9 -f "openclaw gateway" 2>/dev/null || true
pkill -9 -f "openclaw-gateway" 2>/dev/null || true
sleep 1

echo "Dev mode: ${OPENCLAW_DEV_MODE:-false}"

if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
    exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan --token "$OPENCLAW_GATEWAY_TOKEN"
else
    echo "Starting gateway with device pairing (no token)..."
    exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan
fi


