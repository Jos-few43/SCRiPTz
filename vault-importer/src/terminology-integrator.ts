/**
 * terminology-integrator.ts — Bidirectional terminology tag integration.
 *
 * Phase 1: Build a lookup map from all 020-concepts/terminology/ notes
 *          (title + aliases + filename stem -> topic/ slug).
 * Phase 2: Tag each terminology note with its own topic/ slug + agent/definition.
 * Phase 3: Scan the full vault for wikilinks; add matching topic/ tags to
 *          any note that references a known terminology concept.
 * Phase 4: Write a report to docs/plans/terminology-integration-report.md.
 *
 * Usage:
 *   bun run src/terminology-integrator.ts
 *   bun run src/terminology-integrator.ts --dry-run
 */

import { readFileSync, writeFileSync, mkdirSync } from "fs";
import { glob } from "glob";
import { join, relative, basename, dirname } from "path";
import {
  parseFrontmatter,
  normalizeTags,
  serializeFrontmatter,
  sortTags,
  RESET, RED, GREEN, YELLOW, BLUE, DIM, BOLD, CYAN,
} from "./utils";

// ---------------------------------------------------------------------------
// Vault paths
// ---------------------------------------------------------------------------
const VAULT_ROOT = join(import.meta.dir, "../../../..");
const TERMINOLOGY_DIR = join(VAULT_ROOT, "020-concepts/terminology");

// Directories to skip when scanning for wikilinks (too noisy or auto-generated)
const SKIP_DIRS_WIKILINK_SCAN = [
  "**/.obsidian/**",
  "**/node_modules/**",
  "**/900-archive/**",
  "**/.git/**",
  "**/.*/**",
  "**/050-runtime/logs/**",
  "**/060-imports/**",
];

// ---------------------------------------------------------------------------
// Slug normalization
// ---------------------------------------------------------------------------

/**
 * Convert a concept name to a topic/ slug.
 * "Mixture of Experts" -> "topic/mixture-of-experts"
 * "Chain of Thought"   -> "topic/chain-of-thought"
 * "DDPM-DDIM"          -> "topic/ddpm-ddim"
 * "DPO"                -> "topic/dpo"
 */
function toTopicSlug(name: string): string {
  const slug = name
    .toLowerCase()
    .replace(/[^a-z0-9\s\-]/g, "") // strip special chars (keep hyphens)
    .replace(/\s+/g, "-")           // spaces -> hyphens
    .replace(/-+/g, "-")            // collapse multiple hyphens
    .replace(/^-|-$/g, "");         // trim leading/trailing hyphens
  return `topic/${slug}`;
}

// ---------------------------------------------------------------------------
// Phase 1: Build terminology map
// ---------------------------------------------------------------------------

interface TerminologyEntry {
  filePath: string;
  relPath: string;
  title: string;
  topicTag: string;    // canonical topic/ slug
  allNames: string[];  // title + aliases + filename stem
}

async function buildTerminologyMap(): Promise<{
  entries: TerminologyEntry[];
  lookup: Map<string, string>; // lowercased name -> topic/ slug
}> {
  const termFiles = await glob("**/*.md", {
    cwd: TERMINOLOGY_DIR,
    absolute: true,
    ignore: ["**/node_modules/**"],
  });

  const entries: TerminologyEntry[] = [];
  const lookup = new Map<string, string>();

  for (const filePath of termFiles) {
    const content = readFileSync(filePath, "utf-8");
    const { fm } = parseFrontmatter(content);

    const filenameStem = basename(filePath, ".md");

    // Determine concept title: frontmatter title > filename stem
    const title =
      typeof fm?.title === "string" && fm.title.trim()
        ? fm.title.trim()
        : filenameStem;

    const topicTag = toTopicSlug(title);

    // Collect all names: title, filename stem, and any aliases
    const allNames: string[] = [title];

    if (filenameStem !== title) {
      allNames.push(filenameStem);
    }

    const aliases = fm?.aliases;
    if (Array.isArray(aliases)) {
      for (const a of aliases) {
        if (typeof a === "string" && a.trim()) {
          allNames.push(a.trim());
        }
      }
    } else if (typeof aliases === "string" && aliases.trim()) {
      allNames.push(aliases.trim());
    }

    const entry: TerminologyEntry = {
      filePath,
      relPath: relative(VAULT_ROOT, filePath),
      title,
      topicTag,
      allNames,
    };
    entries.push(entry);

    // Register all name variants in the lookup (case-insensitive)
    for (const name of allNames) {
      lookup.set(name.toLowerCase(), topicTag);
      // Also register the slug form of each name
      const slugVariant = name
        .toLowerCase()
        .replace(/\s+/g, "-")
        .replace(/[^a-z0-9\-]/g, "");
      if (slugVariant) lookup.set(slugVariant, topicTag);
    }
  }

  return { entries, lookup };
}

// ---------------------------------------------------------------------------
// Phase 2: Tag terminology notes (self-referencing + agent/definition)
// ---------------------------------------------------------------------------

interface TermTagResult {
  relPath: string;
  topicTag: string;
  tagsAdded: string[];
  changed: boolean;
}

function tagTerminologyNote(entry: TerminologyEntry, dryRun: boolean): TermTagResult {
  const content = readFileSync(entry.filePath, "utf-8");
  const { fm, body } = parseFrontmatter(content);

  const result: TermTagResult = {
    relPath: entry.relPath,
    topicTag: entry.topicTag,
    tagsAdded: [],
    changed: false,
  };

  if (!fm) return result;

  const existingTags = normalizeTags(fm.tags);
  const tagSet = new Set(existingTags);

  const tagsToAdd: string[] = [];

  if (!tagSet.has(entry.topicTag)) {
    tagsToAdd.push(entry.topicTag);
  }
  if (!tagSet.has("agent/definition")) {
    tagsToAdd.push("agent/definition");
  }

  if (tagsToAdd.length === 0) return result;

  for (const t of tagsToAdd) tagSet.add(t);
  const newTags = sortTags([...tagSet]);

  result.tagsAdded = tagsToAdd;
  result.changed = true;

  if (!dryRun) {
    const updatedFm = { ...fm, tags: newTags };
    const newContent = serializeFrontmatter(updatedFm) + body;
    writeFileSync(entry.filePath, newContent, "utf-8");
  }

  return result;
}

// ---------------------------------------------------------------------------
// Phase 3: Scan vault for wikilinks -> add topic/ tags
// ---------------------------------------------------------------------------

interface WikilinkScanResult {
  relPath: string;
  topicTagsAdded: string[];
  changed: boolean;
}

/**
 * Extract wikilink targets from body content.
 * [[Target]]               -> "Target"
 * [[path/to/Target|Label]] -> "path/to/Target"
 */
function extractWikilinkTargets(body: string): string[] {
  const targets: string[] = [];
  const regex = /\[\[([^\]|]+)(?:\|[^\]]+)?\]\]/g;
  let match: RegExpExecArray | null;
  while ((match = regex.exec(body)) !== null) {
    targets.push(match[1].trim());
  }
  return targets;
}

/**
 * Strip path prefix from wikilink target.
 * "020-concepts/terminology/AI-ML/Mixture of Experts" -> "Mixture of Experts"
 */
function stripPathPrefix(target: string): string {
  const lastSlash = target.lastIndexOf("/");
  if (lastSlash !== -1) {
    return target.slice(lastSlash + 1);
  }
  return target;
}

function scanFileForWikilinks(
  filePath: string,
  lookup: Map<string, string>,
  dryRun: boolean
): WikilinkScanResult | null {
  const content = readFileSync(filePath, "utf-8");
  const { fm, body } = parseFrontmatter(content);

  const relPath = relative(VAULT_ROOT, filePath);

  if (!fm) return null;

  const wikilinkTargets = extractWikilinkTargets(body);
  const matchedTopicTags = new Set<string>();

  for (const raw of wikilinkTargets) {
    // Try the raw target first, then strip path prefix
    const candidates = [raw, stripPathPrefix(raw)];

    for (const candidate of candidates) {
      const lower = candidate.toLowerCase();
      if (lookup.has(lower)) {
        matchedTopicTags.add(lookup.get(lower)!);
        break;
      }
      // Also try slug variant
      const slug = lower.replace(/\s+/g, "-").replace(/[^a-z0-9\-]/g, "");
      if (slug && lookup.has(slug)) {
        matchedTopicTags.add(lookup.get(slug)!);
        break;
      }
    }
  }

  if (matchedTopicTags.size === 0) {
    return { relPath, topicTagsAdded: [], changed: false };
  }

  const existingTags = normalizeTags(fm.tags);
  const tagSet = new Set(existingTags);

  const tagsToAdd: string[] = [];
  for (const tag of matchedTopicTags) {
    if (!tagSet.has(tag)) {
      tagsToAdd.push(tag);
    }
  }

  if (tagsToAdd.length === 0) {
    return { relPath, topicTagsAdded: [], changed: false };
  }

  for (const t of tagsToAdd) tagSet.add(t);
  const newTags = sortTags([...tagSet]);

  if (!dryRun) {
    const updatedFm = { ...fm, tags: newTags };
    const newContent = serializeFrontmatter(updatedFm) + body;
    writeFileSync(filePath, newContent, "utf-8");
  }

  return { relPath, topicTagsAdded: tagsToAdd, changed: true };
}

// ---------------------------------------------------------------------------
// Phase 4: Report generation
// ---------------------------------------------------------------------------

function generateReport(opts: {
  dryRun: boolean;
  entries: TerminologyEntry[];
  termTagResults: TermTagResult[];
  wikilinkResults: WikilinkScanResult[];
  totalVaultFiles: number;
}): string {
  const { dryRun, entries, termTagResults, wikilinkResults, totalVaultFiles } = opts;
  const now = new Date().toISOString().split("T")[0];

  const termNotesTagged = termTagResults.filter((r) => r.changed).length;
  const notesUpdated = wikilinkResults.filter((r) => r.changed).length;
  const totalTopicTagsAdded = wikilinkResults.reduce((sum, r) => sum + r.topicTagsAdded.length, 0);
  const totalTermTagsAdded = termTagResults.reduce((sum, r) => sum + r.tagsAdded.length, 0);

  const lines: string[] = [];
  lines.push("---");
  lines.push(`title: "Terminology Integration Report"`);
  lines.push(`created: ${now}`);
  lines.push(`updated: ${now}`);
  lines.push(`status: active`);
  lines.push(`tags:`);
  lines.push(`  - type/admin`);
  lines.push(`  - domain/devexp`);
  lines.push("---");
  lines.push("");
  lines.push("# Terminology Integration Report");
  lines.push("");
  lines.push(`> Generated: ${new Date().toISOString()}`);
  lines.push(`> Mode: ${dryRun ? "DRY RUN (no files written)" : "LIVE"}`);
  lines.push("");
  lines.push("## Summary");
  lines.push("");
  lines.push(`| Metric | Value |`);
  lines.push(`|---|---|`);
  lines.push(`| Terminology notes processed | ${entries.length} |`);
  lines.push(`| Terminology notes tagged (self + agent/definition) | ${termNotesTagged} |`);
  lines.push(`| Tags added to terminology notes | ${totalTermTagsAdded} |`);
  lines.push(`| Vault files scanned for wikilinks | ${totalVaultFiles} |`);
  lines.push(`| Notes updated with topic/ tags | ${notesUpdated} |`);
  lines.push(`| Total topic/ tags added via wikilinks | ${totalTopicTagsAdded} |`);
  lines.push("");

  lines.push("## Concept to Tag Mappings");
  lines.push("");
  lines.push(`| Concept | Topic Tag | Aliases |`);
  lines.push(`|---|---|---|`);
  for (const e of entries.sort((a, b) => a.title.localeCompare(b.title))) {
    const aliases = e.allNames.filter((n) => n !== e.title).join(", ");
    lines.push(`| ${e.title} | \`${e.topicTag}\` | ${aliases || "none"} |`);
  }
  lines.push("");

  if (termNotesTagged > 0) {
    lines.push("## Terminology Notes Updated");
    lines.push("");
    for (const r of termTagResults.filter((r) => r.changed)) {
      lines.push(`- \`${r.relPath}\`: +\`${r.tagsAdded.join("`, `")}\``);
    }
    lines.push("");
  }

  const updatedWikilinks = wikilinkResults.filter((r) => r.changed);
  if (updatedWikilinks.length > 0) {
    lines.push("## Notes Updated via Wikilink Matching");
    lines.push("");
    for (const r of updatedWikilinks.sort((a, b) => a.relPath.localeCompare(b.relPath))) {
      lines.push(`- \`${r.relPath}\`: +\`${r.topicTagsAdded.join("`, `")}\``);
    }
    lines.push("");
  } else {
    lines.push("## Notes Updated via Wikilink Matching");
    lines.push("");
    lines.push("_No notes required new topic/ tags from wikilink matching._");
    lines.push("");
  }

  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const dryRun = process.argv.includes("--dry-run");

  console.log(`\n${BOLD}Terminology Integrator${RESET} -- vault: ${DIM}${VAULT_ROOT}${RESET}`);
  if (dryRun) {
    console.log(`${YELLOW}DRY RUN mode -- no files will be written${RESET}\n`);
  } else {
    console.log(`${RED}LIVE mode -- files will be modified${RESET}\n`);
  }

  // Phase 1: Build terminology map
  console.log(`${CYAN}Phase 1:${RESET} Building terminology map...`);
  const { entries, lookup } = await buildTerminologyMap();
  console.log(`  ${DIM}Found ${entries.length} terminology notes, ${lookup.size} name variants${RESET}`);

  // Phase 2: Tag terminology notes
  console.log(`\n${CYAN}Phase 2:${RESET} Tagging terminology notes...`);
  const termTagResults: TermTagResult[] = [];

  for (const entry of entries) {
    const result = tagTerminologyNote(entry, dryRun);
    termTagResults.push(result);
    if (result.changed) {
      console.log(
        `  ${GREEN}+${RESET} ${DIM}${entry.relPath}${RESET} -> ${result.tagsAdded.map((t) => `\`${t}\``).join(", ")}`
      );
    }
  }

  const phase2Changed = termTagResults.filter((r) => r.changed).length;
  console.log(`  ${DIM}${phase2Changed} terminology notes updated${RESET}`);

  // Phase 3: Scan vault for wikilinks
  console.log(`\n${CYAN}Phase 3:${RESET} Scanning vault for wikilinks...`);

  const allVaultFiles = await glob("**/*.md", {
    cwd: VAULT_ROOT,
    absolute: true,
    ignore: SKIP_DIRS_WIKILINK_SCAN,
  });

  console.log(`  ${DIM}Scanning ${allVaultFiles.length} files...${RESET}`);

  const wikilinkResults: WikilinkScanResult[] = [];
  let wikilinkMatches = 0;

  for (const filePath of allVaultFiles) {
    // Skip terminology notes -- already handled in Phase 2
    const relPath = relative(VAULT_ROOT, filePath);
    if (relPath.startsWith("020-concepts/terminology/")) continue;

    const result = scanFileForWikilinks(filePath, lookup, dryRun);
    if (!result) continue;

    wikilinkResults.push(result);
    if (result.changed) {
      wikilinkMatches++;
      console.log(
        `  ${GREEN}~${RESET} ${DIM}${result.relPath}${RESET} +${result.topicTagsAdded.length} topic tags`
      );
    }
  }

  console.log(`  ${DIM}${wikilinkMatches} notes updated with topic/ tags${RESET}`);

  // Summary
  const totalTopicTagsAdded = wikilinkResults.reduce((s, r) => s + r.topicTagsAdded.length, 0);
  const totalTermTagsAdded = termTagResults.reduce((s, r) => s + r.tagsAdded.length, 0);

  console.log(`\n${BOLD}Summary${RESET}`);
  console.log(`  Terminology notes processed:   ${entries.length}`);
  console.log(`  ${GREEN}Term notes updated:            ${phase2Changed} (+${totalTermTagsAdded} tags)${RESET}`);
  console.log(`  Vault files scanned:           ${allVaultFiles.length}`);
  console.log(`  ${GREEN}Notes updated (wikilinks):     ${wikilinkMatches} (+${totalTopicTagsAdded} topic/ tags)${RESET}`);

  // Phase 4: Report
  const reportContent = generateReport({
    dryRun,
    entries,
    termTagResults,
    wikilinkResults,
    totalVaultFiles: allVaultFiles.length,
  });

  const reportPath = join(VAULT_ROOT, "docs/plans/terminology-integration-report.md");

  if (!dryRun) {
    mkdirSync(dirname(reportPath), { recursive: true });
    writeFileSync(reportPath, reportContent, "utf-8");
    console.log(`\n${BLUE}Report written:${RESET} docs/plans/terminology-integration-report.md`);
  } else {
    console.log(
      `\n${DIM}[dry-run] Would write report to: docs/plans/terminology-integration-report.md${RESET}`
    );
  }
}

main().catch((err) => {
  console.error(`${RED}Fatal error:${RESET}`, err);
  process.exit(1);
});
