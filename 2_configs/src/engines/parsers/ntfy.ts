import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { parse as parseYaml } from "yaml";
import { svcDir } from "./resolve-service-dir";

export interface NtfyTopic {
  name: string;
  category: string;
  desc: string;
  publishers: string[];
}

export interface NtfyProfile {
  id: string;
  title: string;
  feed: string;
  channels: Array<{ name: string; desc: string; feed: string }>;
}

export interface NtfyConfig {
  topics: NtfyTopic[];
  profiles: NtfyProfile[];
  users: string[];
  enable_login: boolean;
  auth_default_access: string;
  base_url?: string;
}

export function parseNtfy(solutionsDir: string): NtfyConfig | null {
  // Topics now live in bc-obs_ntfy/build.json (SoT) — independent of any
  // built artefacts. Previously gated extraction behind the existence of
  // dist/etc/server.yml, but that file is gitignored and absent on clean
  // checkouts, so the entire `configs.ntfy` block dropped out of the
  // consolidated config (and the downstream build-mattermost.json
  // ntfy_topics field came out empty). server.yml is now only used for
  // its scalar fields; absence means fall-back to documented defaults.
  const topics = extractTopicsFromScanner(solutionsDir);

  let doc: any = null;
  const configPath = join(svcDir(solutionsDir, "ntfy", "bc-obs_ntfy"), "dist", "etc", "server.yml");
  if (existsSync(configPath)) {
    try {
      doc = parseYaml(readFileSync(configPath, "utf-8"));
    } catch {
      doc = null;
    }
  }

  // If neither topics nor a server.yml are available, the ntfy block carries
  // no information — leave it out of the consolidated to keep the schema clean.
  if (topics.length === 0 && doc == null) return null;

  const buildJsonPath2 = join(svcDir(solutionsDir, "ntfy", "bc-obs_ntfy"), "build.json");
  const profiles = extractProfilesFromBuildJson(buildJsonPath2, topics);
  const domain = (() => {
    try {
      return JSON.parse(readFileSync(buildJsonPath2, "utf-8"))?.domain ?? undefined;
    } catch { return undefined; }
  })();

  return {
    topics,
    profiles,
    users: extractUsersFromCompose(solutionsDir),
    enable_login: doc?.["enable-login"] ?? false,
    auth_default_access: doc?.["auth-default-access"] ?? "read-write",
    ...(domain ? { base_url: `https://${domain}/feed` } : {}),
  };
}

function extractTopicsFromScanner(solutionsDir: string): NtfyTopic[] {
  // PRIMARY (FIRE RULE 4 — data-driven): topics live in bc-obs_ntfy/build.json
  // under .topics as an array of { name, category, desc, publishers? }. This is
  // the single source of truth — topic-scanner.py, parsers/ntfy.ts, derive's
  // build-mattermost.json emitter, and chat-mattermost's compose.nix all
  // consume from here. Adding a topic = edit build.json + rebuild.
  const buildJsonPath = join(svcDir(solutionsDir, "ntfy", "bc-obs_ntfy"), "build.json");
  if (existsSync(buildJsonPath)) {
    try {
      const buildJson = JSON.parse(readFileSync(buildJsonPath, "utf-8"));
      if (Array.isArray(buildJson?.topics) && buildJson.topics.length > 0) {
        const publishers = extractPublisherMap(solutionsDir);
        return buildJson.topics.map((t: any): NtfyTopic => ({
          name: String(t.name),
          category: String(t.category ?? String(t.name).split("_")[0]),
          desc: String(t.desc ?? t.name),
          publishers: Array.isArray(t.publishers) && t.publishers.length > 0
            ? t.publishers.map(String)
            : publishers.get(String(t.name)) ?? ["system"],
        }));
      }
    } catch {
      // Fall through to legacy extraction if build.json is malformed.
    }
  }

  // LEGACY fallback (kept until topic-scanner.py is migrated to read from
  // build.json itself; remove this branch after that migration).
  const scannerPath = join(svcDir(solutionsDir, "ntfy", "bc-obs_ntfy"), "src", "code", "topic-scanner.py");
  if (!existsSync(scannerPath)) return [];

  const content = readFileSync(scannerPath, "utf-8");

  // Extract CONFIGURED_TOPICS block
  const blockMatch = content.match(/CONFIGURED_TOPICS\s*=\s*\[([\s\S]*?)\]/);
  if (!blockMatch) return [];

  // Build publisher map from bridge scripts
  const publishers = extractPublisherMap(solutionsDir);

  const topics: NtfyTopic[] = [];
  // Match each "topic_name", with optional inline # comment
  for (const m of blockMatch[1].matchAll(/"([^"]+)"[^#\n]*(?:#\s*(.*))?/g)) {
    const name = m[1];
    const desc = m[2]?.trim() ?? name;
    const category = name.split("_")[0];
    topics.push({
      name,
      category,
      desc,
      publishers: publishers.get(name) ?? ["system"],
    });
  }

  return topics;
}

function extractProfilesFromBuildJson(buildJsonPath: string, topics: NtfyTopic[]): NtfyProfile[] {
  if (!existsSync(buildJsonPath)) return [];
  try {
    const buildJson = JSON.parse(readFileSync(buildJsonPath, "utf-8"));
    const rawProfiles: any[] = buildJson?.profiles ?? [];
    const domain: string = buildJson?.domain ?? "rss.diegonmarcos.com";
    return rawProfiles.map((p: any): NtfyProfile => {
      const matched = Array.isArray(p.topics)
        ? topics.filter(t => (p.topics as string[]).includes(t.name))
        : topics.filter(t => (p.categories as string[] ?? []).includes(t.category));
      return {
        id: String(p.id),
        title: String(p.title),
        feed: `/feed/${p.id}.atom`,
        channels: matched.map(t => ({
          name: t.name,
          desc: t.desc,
          feed: `/feed/c/${t.name}.atom`,
        })),
      };
    });
  } catch {
    return [];
  }
}

/** Scan bridge scripts for topic constants to build publisher mapping */
function extractPublisherMap(solutionsDir: string): Map<string, string[]> {
  const map = new Map<string, string[]>();
  const srcDir = join(svcDir(solutionsDir, "ntfy", "bc-obs_ntfy"), "src");

  const bridges: { file: string; publisher: string }[] = [
    { file: "github-rss-to-ntfy.py", publisher: "github-rss" },
    { file: "syslog-to-ntfy.py", publisher: "syslog-bridge" },
  ];

  for (const bridge of bridges) {
    const path = join(srcDir, bridge.file);
    if (!existsSync(path)) continue;
    const content = readFileSync(path, "utf-8");
    // Match TOPIC_* = 'name' or NTFY_TOPIC = 'name'
    for (const m of content.matchAll(/(?:TOPIC_\w+|NTFY_TOPIC)\s*=\s*['"]([^'"]+)['"]/g)) {
      const existing = map.get(m[1]) ?? [];
      existing.push(bridge.publisher);
      map.set(m[1], existing);
    }
  }

  return map;
}

function extractUsersFromCompose(solutionsDir: string): string[] {
  // Users are created via CLI commands in compose or setup scripts
  // For now, extract from docker-compose.yml entrypoint/command if present
  const composePath = join(svcDir(solutionsDir, "ntfy", "bc-obs_ntfy"), "dist", "docker-compose.yml");
  if (!existsSync(composePath)) return [];

  const content = readFileSync(composePath, "utf-8");
  const users: string[] = [];

  // Look for `ntfy user add` commands
  const userMatches = content.matchAll(/ntfy\s+user\s+add\s+(\w+)/g);
  for (const m of userMatches) {
    users.push(m[1]);
  }

  return users;
}
