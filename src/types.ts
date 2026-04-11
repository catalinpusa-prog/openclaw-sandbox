import type { Sandbox } from '@cloudflare/sandbox';

/**
 * Environment bindings for the OpenClaw Worker
 */
export interface OpenClawEnv {
  Sandbox: DurableObjectNamespace<Sandbox>;
  ASSETS: Fetcher; // Assets binding for admin UI static files
  BACKUP_BUCKET: R2Bucket; // R2 bucket for Sandbox SDK backup/restore
  // Cloudflare AI Gateway configuration (preferred)
  CF_AI_GATEWAY_ACCOUNT_ID?: string; // Cloudflare account ID for AI Gateway
  CF_AI_GATEWAY_GATEWAY_ID?: string; // AI Gateway ID
  CLOUDFLARE_AI_GATEWAY_API_KEY?: string; // API key for requests through the gateway
  CF_AI_GATEWAY_MODEL?: string; // Override model: "provider/model-id"
  // Legacy AI Gateway configuration (still supported for backward compat)
  AI_GATEWAY_API_KEY?: string; // API key for the provider configured in AI Gateway
  AI_GATEWAY_BASE_URL?: string; // AI Gateway URL
  // Direct provider configuration
  ANTHROPIC_API_KEY?: string;
  ANTHROPIC_BASE_URL?: string;
  OPENAI_API_KEY?: string;
  OPENROUTER_API_KEY?: string; // OpenRouter API key
  GROQ_API_KEY?: string; // Groq API key
  MOONSHOT_API_KEY?: string; // Moonshot API key
  MOLTBOT_GATEWAY_TOKEN?: string; // Gateway token (mapped to OPENCLAW_GATEWAY_TOKEN for container)
  DEV_MODE?: string; // Set to 'true' for local dev
  E2E_TEST_MODE?: string; // Set to 'true' for E2E tests
  DEBUG_ROUTES?: string; // Set to 'true' to enable /debug/* routes
  SANDBOX_SLEEP_AFTER?: string; // How long before sandbox sleeps
  TELEGRAM_BOT_TOKEN?: string;
  TELEGRAM_DM_POLICY?: string;
  DISCORD_BOT_TOKEN?: string;
  DISCORD_DM_POLICY?: string;
  SLACK_BOT_TOKEN?: string;
  SLACK_APP_TOKEN?: string;
  // Cloudflare Access configuration for admin routes
  CF_ACCESS_TEAM_DOMAIN?: string;
  CF_ACCESS_AUD?: string;
  // R2 credentials for rclone-based sync in container (set via wrangler secret)
  R2_ACCESS_KEY_ID?: string;
  R2_SECRET_ACCESS_KEY?: string;
  CLOUDFLARE_ACCOUNT_ID?: string; // Cloudflare account ID (mapped to CF_ACCOUNT_ID for container)
  BACKUP_BUCKET_NAME?: string; // R2 bucket name for backup storage
  // Browser Rendering binding for CDP shim
  BROWSER?: Fetcher;
  CDP_SECRET?: string; // Shared secret for CDP endpoint authentication
  WORKER_URL?: string; // Public URL of the worker (for CDP endpoint and Control UI origins)

  // Cron wake-ahead: wake container before OpenClaw cron jobs fire
  CRON_WAKE_AHEAD_MINUTES?: string;

  // Email account passwords for Himalaya IMAP/SMTP configuration
  EMAIL_INFO_PASSWORD?: string; // Password for info@pusa.ro
  EMAIL_ALEX_PASSWORD?: string; // Password for alex@pusa.ro
  EMAIL_CATALIN_PASSWORD?: string; // Password for catalin.pusa@avocatul-meu.ro
}

/**
 * Authenticated user from Cloudflare Access
 */
export interface AccessUser {
  email: string;
  name?: string;
}

/**
 * Hono app environment type
 */
export type AppEnv = {
  Bindings: OpenClawEnv;
  Variables: {
    sandbox: Sandbox;
    accessUser?: AccessUser;
  };
};

/**
 * JWT payload from Cloudflare Access
 */
export interface JWTPayload {
  aud: string[];
  email: string;
  exp: number;
  iat: number;
  iss: string;
  name?: string;
  sub: string;
  type: string;
}
