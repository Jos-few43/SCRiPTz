/**
 * tag-migrator.ts — Migrate vault tags to faceted hierarchical namespace system.
 *
 * Maps organic flat tags and frontmatter fields to structured facet/value tags.
 * Supports --dry-run flag for inspection without writing.
 *
 * Usage:
 *   bun run src/tag-migrator.ts
 *   bun run src/tag-migrator.ts --dry-run
 */

import { readFileSync, writeFileSync, mkdirSync } from "fs";
import { glob } from "glob";
import { join, relative, dirname } from "path";
import {
  parseFrontmatter,
  normalizeTags,
  serializeFrontmatter,
  sortTags,
  FACET_ORDER,
  RESET, RED, GREEN, YELLOW, BLUE, DIM, BOLD,
} from "./utils";

// ---------------------------------------------------------------------------
// Vault paths
// ---------------------------------------------------------------------------
const VAULT_ROOT = join(import.meta.dir, "../../../..");

// ---------------------------------------------------------------------------
// Tag mapping tables
// ---------------------------------------------------------------------------

const TYPE_MAP: Record<string, string> = {
  chain: "type/chain",
  concept: "type/concept",
  research: "type/research",
  terminology: "type/concept",
  moc: "type/moc",
  MOC: "type/moc",
  project: "type/project",
  repo: "type/repo",
  "repo-index": "type/moc",
  import: "type/import",
  imported: "type/import",
  daily: "type/daily",
  index: "type/moc",
  log: "type/log",
  tool: "type/tool",
  template: "type/template",
  admin: "type/admin",
  stub: "type/stub",
  guide: "type/admin",
  meta: "type/admin",
  summary: "type/admin",
};

const DOMAIN_MAP: Record<string, string> = {
  "ai-safety": "domain/safety",
  safety: "domain/safety",
  security: "domain/security",
  infrastructure: "domain/infra",
  infra: "domain/infra",
  devops: "domain/devops",
  devexp: "domain/devexp",
  ml: "domain/ml",
  ai: "domain/ml",
  llm: "domain/ml",
  "local-models": "domain/ml",
  linux: "domain/infra",
  gcp: "domain/infra",
  ops: "domain/ops",
  automation: "domain/ops",
  data: "domain/data",
  certification: "domain/research",
  "multi-agent": "domain/ml",
};

const TOOL_MAP: Record<string, string> = {
  "claude-code": "tool/claude-code",
  opencode: "tool/opencode",
  openclaw: "tool/openclaw",
  ollama: "tool/ollama",
  docker: "tool/docker",
  kubernetes: "tool/kubernetes",
  obsidian: "tool/obsidian",
  litellm: "tool/litellm",
  mcp: "tool/mcp",
  cortex: "tool/cortex",
  n8n: "tool/n8n",
  grafana: "tool/grafana",
  prometheus: "tool/prometheus",
  traefik: "tool/traefik",
  chezmoi: "tool/chezmoi",
  distrobox: "tool/distrobox",
};

const LANG_MAP: Record<string, string> = {
  python: "lang/python",
  typescript: "lang/typescript",
  javascript: "lang/javascript",
  bash: "lang/bash",
  go: "lang/go",
  rust: "lang/rust",
  lua: "lang/lua",
  yaml: "lang/yaml",
};

const LIFECYCLE_MAP: Record<string, string> = {
  active: "lifecycle/active",
  draft: "lifecycle/draft",
  deprecated: "lifecycle/deprecated",
  archived: "lifecycle/archived",
  complete: "lifecycle/active",
  unknown: "lifecycle/draft",
};

const SOURCE_MAP: Record<string, string> = {
  "auto-generated": "source/auto-generated",
  synced: "source/synced",
};

// repo/* compound tag decomposition
const REPO_TAG_MAP: Record<string, string | null> = {
  "repo/active": "lifecycle/active",
  "repo/stale": "lifecycle/deprecated",
  "repo/archived": "lifecycle/archived",
  "repo/local": "scope/project",
  "repo/agents": "domain/ml",
  "repo/tools": "domain/devexp",
  "repo/infrastructure": "domain/infra",
  "repo/media": "domain/ops",
  "repo/docs": "domain/general",
  "repo/scripts": "domain/devexp",
  // drop these
  "repo/public": null,
  "repo/private": null,
  "repo/own": null,
  "repo/fork": null,
  "repo/upstream": null,
  "repo/projects": null,
  "repo/uncategorized": null,
};

const SKIP_TAGS = new Set([
  "imported",
  "redacted",
  "config",
  "identity",
  "soul",
  "protocols",
  "brain",
  "persistent",
  "history",
  "memory",
  "heartbeat",
  "cron",
  "sync",
  "git",
  "codebase",
  "reference",
  "implementation",
  "hub",
  "shadow-mode",
  "fsm",
  "needs-research",
  "documentation",
  "instruction",
  "skill",
  "script",
  "dotfile",
  "env",
  "command",
  "plugin",
  "hooks",
  "media-stack",
  "Monday",
  "Tuesday",
  "Wednesday",
  "Thursday",
  "Friday",
  "Saturday",
  "Sunday",
]);

// Folder → inferred type tag
const FOLDER_TYPE_MAP: Array<[RegExp, string]> = [
  [/^010-chains\//, "type/chain"],
  [/^020-concepts\/index\//, "type/moc"],
  [/^020-concepts\/terminology\//, "type/concept"],
  [/^030-sources\/research\//, "type/research"],
  [/^040-projects\/repos\//, "type/repo"],
  [/^040-projects\//, "type/project"],
  [/^050-runtime\//, "type/log"],
  [/^060-imports\//, "type/import"],
  [/^070-tools\//, "type/tool"],
  [/^000-admin\/templates\//, "type/template"],
  [/^000-admin\//, "type/admin"],
];

// ---------------------------------------------------------------------------
// Tag mapping logic
// ---------------------------------------------------------------------------

function mapTag(tag: string): string[] {
  // Already namespaced — keep as-is if valid facet, otherwise treat as topic
  if (tag.includes("/")) {
    // Handle repo/* compound tags
    if (tag.startsWith("repo/")) {
      const mapped = REPO_TAG_MAP[tag];
      if (mapped === undefined) {
        // Unknown repo/* tag — treat as topic
        return [`topic/${tag.replace("/", "-")}`];
      }
      // null means drop
      return mapped ? [mapped, "type/repo"] : ["type/repo"];
    }
    // Check if it matches a known facet prefix
    const facet = tag.split("/")[0];
    if (FACET_ORDER.includes(facet)) return [tag];
    // Unknown namespace — wrap as topic
    return [`topic/${tag.replace("/", "-")}`];
  }

  // Skip tags
  if (SKIP_TAGS.has(tag)) return [];

  // Check maps in priority order
  if (TYPE_MAP[tag]) return [TYPE_MAP[tag]];
  if (DOMAIN_MAP[tag]) return [DOMAIN_MAP[tag]];
  if (TOOL_MAP[tag]) return [TOOL_MAP[tag]];
  if (LANG_MAP[tag]) return [LANG_MAP[tag]];
  if (LIFECYCLE_MAP[tag]) return [LIFECYCLE_MAP[tag]];
  if (SOURCE_MAP[tag]) return [SOURCE_MAP[tag]];

  // Fallback: topic/<tag>
  return [`topic/${tag}`];
}

function inferTypeFromFolder(relPath: string): string | null {
  for (const [pattern, typeTag] of FOLDER_TYPE_MAP) {
    if (pattern.test(relPath)) return typeTag;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Frontmatter field migration
// ---------------------------------------------------------------------------

function migrateFields(fm: Record<string, unknown>, tags: Set<string>): Record<string, unknown> {
  const result = { ...fm };

  // type field
  if (typeof result.type === "string") {
    const mapped = TYPE_MAP[result.type];
    if (mapped) tags.add(mapped);
    // Handle imported-* types
    else if (result.type.startsWith("imported-")) tags.add("type/import");
    delete result.type;
  }

  // status field → lifecycle
  if (typeof result.status === "string") {
    const mapped = LIFECYCLE_MAP[result.status.toLowerCase()];
    if (mapped) tags.add(mapped);
    delete result.status;
  }

  // domain field
  if (typeof result.domain === "string") {
    const mapped = DOMAIN_MAP[result.domain.toLowerCase()];
    if (mapped) tags.add(mapped);
    delete result.domain;
  }

  // category field → domain tag
  if (typeof result.category === "string") {
    const cat = result.category.toLowerCase();
    const mapped = DOMAIN_MAP[cat];
    if (mapped) {
      tags.add(mapped);
    } else {
      // Map known category values
      const categoryFallback: Record<string, string> = {
        config: "domain/devexp",
        configs: "domain/devexp",
        instructions: "domain/devexp",
        scripts: "domain/devexp",
        skills: "domain/devexp",
        dotfiles: "domain/devexp",
        "env-files": "domain/devexp",
        projects: "domain/general",
        "python-scripts": "domain/devexp",
      };
      if (categoryFallback[cat]) tags.add(categoryFallback[cat]);
    }
    delete result.category;
  }

  // language field
  if (typeof result.language === "string") {
    const mapped = LANG_MAP[result.language.toLowerCase()];
    if (mapped) tags.add(mapped);
    delete result.language;
  }

  return result;
}

// ---------------------------------------------------------------------------
// Migration stats
// ---------------------------------------------------------------------------

interface FileMigrationResult {
  path: string;
  relPath: string;
  oldTags: string[];
  newTags: string[];
  fieldsRemoved: string[];
  warnings: string[];
  changed: boolean;
}

interface MigrationReport {
  totalFiles: number;
  changedFiles: number;
  skippedFiles: number;
  results: FileMigrationResult[];
  warnings: string[];
  dryRun: boolean;
}

// ---------------------------------------------------------------------------
// Core migration function
// ---------------------------------------------------------------------------

function migrateFile(
  filePath: string,
  vaultRoot: string
): FileMigrationResult | null {
  const content = readFileSync(filePath, "utf-8");
  const relPath = relative(vaultRoot, filePath);

  const { fm, body } = parseFrontmatter(content);
  if (!fm) return null; // No frontmatter — skip

  const warnings: string[] = [];
  const fieldsRemoved: string[] = [];

  // Collect original tags
  const originalTags = normalizeTags(fm.tags);

  // Build new tag set
  const newTagSet = new Set<string>();

  // Map existing tags
  for (const tag of originalTags) {
    const mapped = mapTag(tag);
    for (const t of mapped) newTagSet.add(t);
  }

  // Migrate frontmatter fields (modifies newTagSet in place)
  const hasBefore = (field: string) => field in fm;
  const removedFields = ["type", "status", "domain", "category", "language"].filter(hasBefore);
  const migratedFm = migrateFields(fm, newTagSet);

  for (const field of removedFields) {
    if (!(field in migratedFm)) fieldsRemoved.push(field);
  }

  // Infer type from folder if no type tag present
  const hasTypeTag = [...newTagSet].some((t) => t.startsWith("type/"));
  if (!hasTypeTag) {
    const inferred = inferTypeFromFolder(relPath);
    if (inferred) newTagSet.add(inferred);
  }

  // Add source tags based on folder
  if (relPath.startsWith("060-imports/")) {
    newTagSet.add("source/auto-generated");
  }
  if (relPath.startsWith("040-projects/repos/")) {
    newTagSet.add("source/synced");
  }

  // Add defaults if missing
  const hasLifecycle = [...newTagSet].some((t) => t.startsWith("lifecycle/"));
  if (!hasLifecycle) {
    newTagSet.add("lifecycle/active");
  }

  const hasDomain = [...newTagSet].some((t) => t.startsWith("domain/"));
  if (!hasDomain) {
    newTagSet.add("domain/general");
    warnings.push(`No domain tag — defaulted to domain/general`);
  }

  const newTags = sortTags([...newTagSet]);

  // Check if anything changed
  const tagsChanged =
    JSON.stringify(originalTags.slice().sort()) !== JSON.stringify(newTags.slice().sort());
  const fieldsChanged = fieldsRemoved.length > 0;
  const changed = tagsChanged || fieldsChanged;

  // Update frontmatter
  const updatedFm = { ...migratedFm, tags: newTags };

  const newContent = serializeFrontmatter(updatedFm) + body;

  return {
    path: filePath,
    relPath,
    oldTags: originalTags,
    newTags,
    fieldsRemoved,
    warnings,
    changed: changed || newContent !== content,
  };
}

// ---------------------------------------------------------------------------
// Write updated file
// ---------------------------------------------------------------------------

function writeFile(
  filePath: string,
  fm: Record<string, unknown>,
  body: string
): void {
  const newContent = serializeFrontmatter(fm) + body;
  writeFileSync(filePath, newContent, "utf-8");
}

// ---------------------------------------------------------------------------
// Report generation
// ---------------------------------------------------------------------------

function generateReport(report: MigrationReport): string {
  const lines: string[] = [];
  const now = new Date().toISOString().split("T")[0];

  lines.push("---");
  lines.push(`title: "Tag Migration Report"`);
  lines.push(`created: ${now}`);
  lines.push(`updated: ${now}`);
  lines.push(`status: active`);
  lines.push(`tags:`);
  lines.push(`  - type/admin`);
  lines.push(`  - domain/devexp`);
  lines.push("---");
  lines.push("");
  lines.push("# Tag Migration Report");
  lines.push("");
  lines.push(`> Generated: ${new Date().toISOString()}`);
  lines.push(`> Mode: ${report.dryRun ? "DRY RUN (no files written)" : "LIVE"}`);
  lines.push("");
  lines.push("## Summary");
  lines.push("");
  lines.push(`| Metric | Value |`);
  lines.push(`|---|---|`);
  lines.push(`| Total files scanned | ${report.totalFiles} |`);
  lines.push(`| Files changed | ${report.changedFiles} |`);
  lines.push(`| Files skipped (no frontmatter) | ${report.skippedFiles} |`);
  lines.push(`| Files with warnings | ${report.results.filter(r => r.warnings.length > 0).length} |`);
  lines.push("");

  if (report.warnings.length > 0) {
    lines.push("## Global Warnings");
    lines.push("");
    for (const w of report.warnings) {
      lines.push(`- ${w}`);
    }
    lines.push("");
  }

  lines.push("## Changed Files");
  lines.push("");

  const changed = report.results.filter(r => r.changed);
  if (changed.length === 0) {
    lines.push("_No files required changes._");
    lines.push("");
  } else {
    for (const result of changed) {
      lines.push(`### \`${result.relPath}\``);
      lines.push("");

      if (result.fieldsRemoved.length > 0) {
        lines.push(`**Fields removed:** ${result.fieldsRemoved.join(", ")}`);
        lines.push("");
      }

      const added = result.newTags.filter(t => !result.oldTags.includes(t));
      const removed = result.oldTags.filter(t => !result.newTags.includes(t));

      if (removed.length > 0) {
        lines.push(`**Tags removed:** \`${removed.join("`, `")}\``);
      }
      if (added.length > 0) {
        lines.push(`**Tags added:** \`${added.join("`, `")}\``);
      }

      if (result.warnings.length > 0) {
        lines.push("");
        for (const w of result.warnings) {
          lines.push(`> Warning: ${w}`);
        }
      }

      lines.push("");
    }
  }

  lines.push("## Files with Warnings");
  lines.push("");
  const withWarnings = report.results.filter(r => r.warnings.length > 0);
  if (withWarnings.length === 0) {
    lines.push("_No warnings._");
  } else {
    for (const result of withWarnings) {
      lines.push(`- \`${result.relPath}\`: ${result.warnings.join("; ")}`);
    }
  }
  lines.push("");

  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const dryRun = process.argv.includes("--dry-run");

  console.log(`\n${BOLD}Tag Migrator${RESET} — vault: ${DIM}${VAULT_ROOT}${RESET}`);
  if (dryRun) {
    console.log(`${YELLOW}DRY RUN mode — no files will be written${RESET}\n`);
  } else {
    console.log(`${RED}LIVE mode — files will be modified${RESET}\n`);
  }

  // Walk all .md files, excluding specified directories
  const allFiles = await glob("**/*.md", {
    cwd: VAULT_ROOT,
    absolute: true,
    ignore: [
      "**/.obsidian/**",
      "**/node_modules/**",
      "**/900-archive/**",
      "**/.git/**",
      "**/.*/**",
    ],
  });

  console.log(`${DIM}Found ${allFiles.length} markdown files${RESET}`);

  const report: MigrationReport = {
    totalFiles: allFiles.length,
    changedFiles: 0,
    skippedFiles: 0,
    results: [],
    warnings: [],
    dryRun,
  };

  let processed = 0;
  let changed = 0;
  let skipped = 0;
  let warned = 0;

  for (const filePath of allFiles) {
    const result = migrateFile(filePath, VAULT_ROOT);

    if (!result) {
      skipped++;
      report.skippedFiles++;
      continue;
    }

    report.results.push(result);

    if (result.warnings.length > 0) {
      warned++;
    }

    if (result.changed) {
      changed++;
      report.changedFiles++;

      if (!dryRun) {
        // Re-parse to get fresh fm and body for writing
        const content = readFileSync(filePath, "utf-8");
        const { fm, body } = parseFrontmatter(content);
        if (fm) {
          // Rebuild tags set from mapping
          const newTagSet = new Set<string>();
          const originalTags = normalizeTags(fm.tags);
          for (const tag of originalTags) {
            for (const t of mapTag(tag)) newTagSet.add(t);
          }
          const migratedFm = migrateFields(fm, newTagSet);

          const hasTypeTag = [...newTagSet].some(t => t.startsWith("type/"));
          if (!hasTypeTag) {
            const relPath = relative(VAULT_ROOT, filePath);
            const inferred = inferTypeFromFolder(relPath);
            if (inferred) newTagSet.add(inferred);
          }

          const relPath = relative(VAULT_ROOT, filePath);
          if (relPath.startsWith("060-imports/")) newTagSet.add("source/auto-generated");
          if (relPath.startsWith("040-projects/repos/")) newTagSet.add("source/synced");

          if (![...newTagSet].some(t => t.startsWith("lifecycle/"))) {
            newTagSet.add("lifecycle/active");
          }
          if (![...newTagSet].some(t => t.startsWith("domain/"))) {
            newTagSet.add("domain/general");
          }

          const newTags = sortTags([...newTagSet]);
          const updatedFm = { ...migratedFm, tags: newTags };
          writeFile(filePath, updatedFm, body ?? "");
        }
      }

      // Log changed files
      const relPath = relative(VAULT_ROOT, filePath);
      const addedTags = result.newTags.filter(t => !result.oldTags.includes(t));
      const removedTags = result.oldTags.filter(t => !result.newTags.includes(t));

      const parts: string[] = [];
      if (result.fieldsRemoved.length > 0) parts.push(`fields: ${result.fieldsRemoved.join(",")}`);
      if (removedTags.length > 0) parts.push(`-${removedTags.length} tags`);
      if (addedTags.length > 0) parts.push(`+${addedTags.length} tags`);

      console.log(`  ${GREEN}~${RESET} ${DIM}${relPath}${RESET} ${parts.join(" ")}`);
    }

    if (result.warnings.length > 0 && !result.changed) {
      // Show warnings for unchanged files too
      const relPath = relative(VAULT_ROOT, filePath);
      for (const w of result.warnings) {
        console.log(`  ${YELLOW}!${RESET} ${DIM}${relPath}${RESET}: ${w}`);
      }
    }

    processed++;
  }

  console.log(`\n${BOLD}Summary${RESET}`);
  console.log(`  Scanned:  ${allFiles.length}`);
  console.log(`  ${GREEN}Changed:  ${changed}${RESET}`);
  console.log(`  ${DIM}Skipped:  ${skipped} (no frontmatter)${RESET}`);
  console.log(`  ${YELLOW}Warnings: ${warned}${RESET}`);

  // Write report
  const reportContent = generateReport(report);
  const reportPath = join(VAULT_ROOT, "docs/plans/tag-migration-report.md");

  if (!dryRun) {
    const reportDir = dirname(reportPath);
    mkdirSync(reportDir, { recursive: true });
    writeFileSync(reportPath, reportContent, "utf-8");
    console.log(`\n${BLUE}Report written:${RESET} docs/plans/tag-migration-report.md`);
  } else {
    console.log(`\n${DIM}[dry-run] Would write report to: docs/plans/tag-migration-report.md${RESET}`);
  }
}

main().catch(err => {
  console.error(`${RED}Fatal error:${RESET}`, err);
  process.exit(1);
});
