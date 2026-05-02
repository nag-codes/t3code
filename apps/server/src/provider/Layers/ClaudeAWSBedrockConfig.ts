/**
 * Fork-only: AWS Bedrock routing for the Claude provider.
 *
 * The Anthropic Claude Agent SDK can route requests through AWS Bedrock when
 * `CLAUDE_CODE_USE_BEDROCK=1` is set in the spawned process's environment and
 * the `model` option is a Bedrock global inference profile id. T3 Code's
 * `BUILT_IN_MODELS` use friendly slugs (e.g. `claude-sonnet-4-6`); this module
 * translates those slugs to Bedrock profile ids and validates the surrounding
 * env so misconfiguration fails loudly at the start of a turn rather than
 * silently mid-conversation.
 *
 * Touch points in upstream code are intentionally minimal (one wrap site in
 * `ClaudeAdapter.ts`) so this fork stays mergeable against `pingdotgg/t3code`.
 */
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

/**
 * Slug -> Bedrock global inference profile id, for slugs that have a 1:1
 * mapping. Keys must match `BUILT_IN_MODELS[*].slug` in `ClaudeProvider.ts`.
 *
 * Naming style follows what AWS actually exposes today (mix of bare alias,
 * minor-versioned, and fully pinned). We do not normalize.
 */
const AWS_BEDROCK_MODEL_MAP: Record<string, string> = {
  "claude-opus-4-7": "global.anthropic.claude-opus-4-7",
  "claude-opus-4-6": "global.anthropic.claude-opus-4-6-v1",
  "claude-sonnet-4-6": "global.anthropic.claude-sonnet-4-6",
  "claude-haiku-4-5": "global.anthropic.claude-haiku-4-5-20251001-v1:0",
};

/**
 * Slugs that don't have a Bedrock profile of their own get redirected to the
 * nearest newer slug whose capabilities are a superset. Keep this in lockstep
 * with `BUILT_IN_MODELS` whenever upstream adds/removes models.
 *
 * Currently: Opus 4.5 -> Opus 4.6 (4.6 has all of 4.5's options plus
 * `ultrathink` effort and 1M context — safe upgrade).
 */
const AWS_BEDROCK_FALLBACK_MAP: Record<string, string> = {
  "claude-opus-4-5": "claude-opus-4-6",
};

/** Bedrock is enabled when `CLAUDE_CODE_USE_BEDROCK` is `1` or `true`. */
function isBedrockEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  const value = env.CLAUDE_CODE_USE_BEDROCK;
  return value === "1" || value?.toLowerCase() === "true";
}

/**
 * Returns a list of human-readable issues with the current Bedrock setup.
 * Empty array when Bedrock is disabled, or when AWS looks configured.
 *
 * The AWS SDK resolves region and credentials from a chain that includes
 * env vars and the shared config files in `~/.aws/`. We only warn when
 * NEITHER source can plausibly satisfy the SDK — i.e. when env is empty
 * AND the user has not set up `~/.aws/config` or `~/.aws/credentials`.
 *
 * We do not parse the config files (no AWS SDK pulled in) — file presence
 * is treated as "user has set something up, trust them." If the file is
 * present but the selected profile is broken, the SDK will surface a
 * clear error on the first invocation.
 */
function validateBedrockEnv(
  env: NodeJS.ProcessEnv = process.env,
  homeDir: string = os.homedir(),
): readonly string[] {
  if (!isBedrockEnabled(env)) return [];
  const issues: string[] = [];

  const hasConfigFile = fs.existsSync(path.join(homeDir, ".aws", "config"));
  const hasCredentialsFile = fs.existsSync(path.join(homeDir, ".aws", "credentials"));

  const hasRegionEnv = Boolean(env.AWS_REGION || env.AWS_DEFAULT_REGION);
  const hasStaticKeys = Boolean(env.AWS_ACCESS_KEY_ID && env.AWS_SECRET_ACCESS_KEY);

  if (!hasRegionEnv && !hasConfigFile) {
    issues.push(
      "No AWS region available. Set AWS_REGION/AWS_DEFAULT_REGION or configure ~/.aws/config.",
    );
  }

  if (!hasStaticKeys && !hasCredentialsFile && !hasConfigFile) {
    issues.push(
      "No AWS credentials available. Set AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY, or configure ~/.aws/credentials / ~/.aws/config.",
    );
  }

  return issues;
}

let bedrockEnvWarningEmitted = false;

/** Emit Bedrock env warnings once per process. */
function warnAboutBedrockEnvOnce(): void {
  if (bedrockEnvWarningEmitted) return;
  bedrockEnvWarningEmitted = true;
  const issues = validateBedrockEnv();
  if (issues.length === 0) return;
  for (const issue of issues) {
    console.warn(`[ClaudeAWSBedrockConfig] ${issue}`);
  }
}

/**
 * Translate the upstream-resolved api model id into the Bedrock profile id
 * when Bedrock is enabled. No-op when Bedrock is disabled.
 *
 * @param apiModelId - Output of `resolveClaudeApiModelId` (may include `[1m]`).
 * @param slug       - Raw slug from the model selection (without suffix).
 * @returns The model string to pass to the Claude Agent SDK.
 *
 * Rules:
 *  1. Bedrock disabled -> return apiModelId unchanged.
 *  2. Bedrock enabled, slug in primary map -> return Bedrock profile id.
 *     The `[1m]` context-window suffix is implicitly dropped because Bedrock
 *     profile ids don't accept it; the user's other selections (effort,
 *     fastMode, etc.) still apply.
 *  3. Bedrock enabled, slug in fallback map -> return that fallback's
 *     Bedrock profile id. Single hop only — every value in the fallback
 *     map must be a key in the primary map.
 *  4. Bedrock enabled, slug unmapped -> throw with a clear, actionable
 *     message. Only happens for `customModels` or BUILT_IN_MODELS not yet
 *     added to either map.
 */
export function rewriteApiModelIdForBedrock(apiModelId: string, slug: string): string {
  if (!isBedrockEnabled()) return apiModelId;
  warnAboutBedrockEnvOnce();
  return resolveBedrockId(slug);
}

function resolveBedrockId(slug: string): string {
  const direct = AWS_BEDROCK_MODEL_MAP[slug];
  if (direct) return direct;

  const fallbackSlug = AWS_BEDROCK_FALLBACK_MAP[slug];
  const fallbackTarget = fallbackSlug ? AWS_BEDROCK_MODEL_MAP[fallbackSlug] : undefined;
  if (fallbackTarget) return fallbackTarget;

  const supported = Object.keys(AWS_BEDROCK_MODEL_MAP).join(", ");
  throw new Error(
    `Model "${slug}" is not available via AWS Bedrock. Supported slugs: ${supported}.`,
  );
}
