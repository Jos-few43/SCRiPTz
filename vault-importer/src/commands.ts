/**
 * commands.ts — Parse shell history and agent logs to build a Command Mastersheet.
 *
 * Sources: zsh history, bash history, Claude Code JSONL logs, OpenClaw/OpenCode/Gemini/Qwen logs.
 * Output: aggregated CommandEntry map, ready for note generation.
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from "fs";
import { join, relative, basename } from "path";
import { parse as parseYaml, stringify as stringifyYaml } from "yaml";

// ANSI colors (matches project convention)
const RESET = "\x1b[0m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const CYAN = "\x1b[36m";
const DIM = "\x1b[2m";
const RED = "\x1b[31m";

// ---------------------------------------------------------------------------
// Part 1: Types and Interfaces
// ---------------------------------------------------------------------------

export interface CommandEntry {
  command: string;
  fullCommand: string;
  category: string;
  usageCount: number;
  firstSeen: string;
  lastSeen: string;
  sources: string[];
  riskLevel: "safe" | "caution" | "destructive";
  requiresSudo: boolean;
  shell: string;
}

export interface CommandsResult {
  created: number;
  updated: number;
  skipped: number;
  totalCommands: number;
  categories: number;
}

interface RawCommand {
  command: string;
  timestamp?: Date;
  source: string;
  shell: string;
}

// Risk patterns
const DESTRUCTIVE_PATTERNS = [
  /^rm\s+-rf/,
  /^rm\s+--force/,
  /^rmdir/,
  /git\s+reset\s+--hard/,
  /git\s+push\s+--force/,
  /git\s+push\s+-f\b/,
  /DROP\s+TABLE/i,
  /DELETE\s+FROM/i,
  /TRUNCATE/i,
  /docker\s+system\s+prune/,
  /docker\s+volume\s+rm/,
];

const CAUTION_PATTERNS = [
  /^sudo\s+/,
  /^chmod\s+/,
  /^chown\s+/,
  /git\s+rebase/,
  /docker\s+rm/,
  /docker\s+stop/,
  /^kill\s+/,
  /^pkill\s+/,
  /^killall\s+/,
  /systemctl\s+(stop|disable|mask)/,
];

const IGNORE_COMMANDS = new Set([
  "cd", "ls", "clear", "exit", "pwd", "echo", "cat", "head", "tail",
  "history", "which", "whoami", "date", "true", "false", "",
  "test", "source", "export", "unset", "alias", "unalias", "set",
  "eval", "exec", "return", "shift", "trap", "wait", "type",
  "builtin", "command", "declare", "local", "readonly", "typeset",
  "rehash", "compdef", "autoload", "zle", "bindkey",
]);

// Filter out lines that aren't real commands
function isValidCommand(cmd: string): boolean {
  const first = cmd.split(/\s+/)[0];
  // Must start with a lowercase letter (real CLI commands are lowercase)
  if (!/^[a-z]/.test(first)) return false;
  // Skip if first word contains special chars (not a real command name)
  if (/[^a-z0-9._-]/i.test(first)) return false;
  // Skip error/output fragments
  if (/^(TypeError|Error|Warning|SyntaxError|ReferenceError|undefined|null|NaN|Waiting)\b/i.test(cmd)) return false;
  // Skip Python/script keywords that leak from multi-line pastes
  if (/^(def|class|import|from|try|except|finally|with|yield|return|raise|pass|continue|break|elif|lambda|assert|global|nonlocal)\b/.test(first)) return false;
  // Skip shell scripting constructs (not standalone commands)
  if (/^(if|then|else|fi|do|done|for|while|in|case|esac|select|until|function)\b/.test(first)) return false;
  // Skip lines with backslash continuations (mid-script fragments)
  if (/\\$/.test(cmd)) return false;
  // Skip assignment-only lines (VAR=value with no command after)
  if (/^[a-zA-Z_]\w*=/.test(cmd) && !/^[a-zA-Z_]\w*=\S+\s+\w/.test(cmd)) return false;
  // Skip lines containing Python-style syntax
  if (/\(f['"]|\.append\(|\.join\(|\.split\(/.test(cmd)) return false;
  // Skip bare numbers
  if (/^\d+$/.test(cmd)) return false;
  // Skip very short "words" that aren't known commands (likely typos/fragments)
  if (first.length <= 1) return false;
  // Skip heredoc/EOF markers
  if (/^(EOL|EOF|EOT)\b/.test(first)) return false;
  // Skip Python variable-like names (fragments from pasted scripts)
  if (/^(content|links|path|mocs|frontmatter|clean_links|end_idx|is|can|has|get|put|run|let|var|const|new)\b/.test(first)
    && cmd.split(/\s+/).length <= 2) return false;
  // Skip if the "command" looks like a script filename (not a command invocation)
  if (/\.(sh|py|js|ts|rb|pl)\b/.test(first) && !first.includes("/")) return false;
  return true;
}

// ---------------------------------------------------------------------------
// Part 2: Shell History Parsers
// ---------------------------------------------------------------------------

/**
 * Parse zsh extended history format (`: timestamp:0;command`) with plain
 * format fallback for lines that don't match the extended format.
 */
export function parseZshHistory(path: string): RawCommand[] {
  if (!existsSync(path)) return [];

  const results: RawCommand[] = [];

  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return [];
  }

  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    // Extended format: `: 1700000000:0;git commit -m "msg"`
    const extMatch = trimmed.match(/^:\s*(\d+):\d+;(.+)$/);
    if (extMatch) {
      const ts = parseInt(extMatch[1], 10);
      results.push({
        command: extMatch[2].trim(),
        timestamp: new Date(ts * 1000),
        source: "zsh-history",
        shell: "zsh",
      });
      continue;
    }

    // Plain format fallback — skip lines that look like zsh metadata
    if (trimmed.startsWith(":")) continue;
    results.push({
      command: trimmed,
      source: "zsh-history",
      shell: "zsh",
    });
  }

  return results;
}

/**
 * Parse bash plain-line history, skipping `#` timestamp comment lines and
 * bare numeric lines that HISTTIMEFORMAT injects.
 */
export function parseBashHistory(path: string): RawCommand[] {
  if (!existsSync(path)) return [];

  const results: RawCommand[] = [];

  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return [];
  }

  let pendingTimestamp: Date | undefined;

  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    // HISTTIMEFORMAT comment: `#1700000000`
    if (/^#\d+$/.test(trimmed)) {
      const ts = parseInt(trimmed.slice(1), 10);
      pendingTimestamp = new Date(ts * 1000);
      continue;
    }

    // Skip other comment lines
    if (trimmed.startsWith("#")) continue;

    // Skip pure-number lines
    if (/^\d+$/.test(trimmed)) continue;

    results.push({
      command: trimmed,
      timestamp: pendingTimestamp,
      source: "bash-history",
      shell: "bash",
    });
    pendingTimestamp = undefined;
  }

  return results;
}

// ---------------------------------------------------------------------------
// Part 3: Agent Log Parsers
// ---------------------------------------------------------------------------

/**
 * Recursively walk a directory and collect all files with the given extensions.
 */
function collectFiles(dir: string, extensions: string[]): string[] {
  const files: string[] = [];
  if (!existsSync(dir)) return files;

  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...collectFiles(full, extensions));
    } else if (extensions.some((ext) => entry.name.endsWith(ext))) {
      files.push(full);
    }
  }
  return files;
}

/**
 * Recursively extract Bash tool calls from a parsed JSON object.
 * Handles three formats:
 *   1. `{ type: "tool_use", name: "Bash", input: { command } }`
 *   2. Nested `content` arrays (Anthropic message format)
 *   3. `tool_calls` arrays with `function.name === "Bash"`
 */
export function extractBashCommands(
  obj: any,
  commands: RawCommand[],
  source: string
): void {
  if (!obj || typeof obj !== "object") return;

  // Format 1: tool_use block
  if (obj.type === "tool_use" && obj.name === "Bash" && obj.input?.command) {
    commands.push({
      command: String(obj.input.command),
      source,
      shell: "bash",
    });
    return;
  }

  // Format 3: OpenAI-style tool_calls array
  if (Array.isArray(obj.tool_calls)) {
    for (const tc of obj.tool_calls) {
      if (tc?.function?.name === "Bash") {
        let cmd: string | undefined;
        try {
          const args =
            typeof tc.function.arguments === "string"
              ? JSON.parse(tc.function.arguments)
              : tc.function.arguments;
          cmd = args?.command;
        } catch {
          // malformed arguments — skip
        }
        if (cmd) {
          commands.push({ command: String(cmd), source, shell: "bash" });
        }
      }
    }
  }

  // Recurse into arrays and nested objects
  if (Array.isArray(obj)) {
    for (const item of obj) extractBashCommands(item, commands, source);
  } else {
    // Format 2: content array
    if (Array.isArray(obj.content)) {
      for (const item of obj.content) extractBashCommands(item, commands, source);
    }
    // Also recurse into common envelope fields
    for (const key of ["messages", "turns", "events", "data"]) {
      if (Array.isArray(obj[key])) {
        for (const item of obj[key]) extractBashCommands(item, commands, source);
      }
    }
  }
}

/**
 * Parse Claude Code JSONL/JSON session logs, extracting Bash tool calls.
 * Walks the full directory tree under `basePath`.
 */
export function parseClaudeCodeLogs(basePath: string): RawCommand[] {
  const results: RawCommand[] = [];
  const files = collectFiles(basePath, [".jsonl", ".json"]);

  for (const file of files) {
    const source = `claude-code:${basename(file)}`;
    let raw: string;
    try {
      raw = readFileSync(file, "utf8");
    } catch {
      continue;
    }

    // JSONL: one JSON object per line
    if (file.endsWith(".jsonl")) {
      for (const line of raw.split("\n")) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        try {
          const obj = JSON.parse(trimmed);
          extractBashCommands(obj, results, source);
        } catch {
          // skip malformed lines
        }
      }
    } else {
      // Plain JSON file
      try {
        const obj = JSON.parse(raw);
        extractBashCommands(obj, results, source);
      } catch {
        // skip unparseable files
      }
    }
  }

  return results;
}

/**
 * Parse generic agent logs (OpenClaw, OpenCode, Gemini, Qwen) using the same
 * recursive walk + extractBashCommands pattern.
 */
export function parseGenericAgentLogs(basePath: string, source: string): RawCommand[] {
  const results: RawCommand[] = [];
  const files = collectFiles(basePath, [".jsonl", ".json"]);

  for (const file of files) {
    const fileSource = `${source}:${basename(file)}`;
    let raw: string;
    try {
      raw = readFileSync(file, "utf8");
    } catch {
      continue;
    }

    if (file.endsWith(".jsonl")) {
      for (const line of raw.split("\n")) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        try {
          const obj = JSON.parse(trimmed);
          extractBashCommands(obj, results, fileSource);
        } catch {
          // skip
        }
      }
    } else {
      try {
        const obj = JSON.parse(raw);
        extractBashCommands(obj, results, fileSource);
      } catch {
        // skip
      }
    }
  }

  return results;
}

// ---------------------------------------------------------------------------
// Part 4: Normalization and Aggregation
// ---------------------------------------------------------------------------

/**
 * Normalize a raw command string:
 * - Trim leading/trailing whitespace
 * - Collapse line-continuation backslashes into a single line
 * - Strip trailing inline comments (` # ...`)
 */
export function normalizeCommand(raw: string): string {
  // Collapse multi-line continuations: `cmd \\\n  --flag` → `cmd --flag`
  let cmd = raw.replace(/\\\n\s*/g, " ");
  // Strip trailing comments: `git status # show status` → `git status`
  cmd = cmd.replace(/\s+#[^'"].*$/, "");
  return cmd.trim();
}

// Multi-word tool prefixes whose second token is significant
const MULTI_WORD_TOOLS = new Set([
  "git", "docker", "bun", "systemctl", "npm", "cargo",
  "pip", "distrobox", "gh", "kubectl",
]);

/**
 * Extract the base command from a normalized command string.
 * - Strips leading env-var assignments (FOO=bar cmd)
 * - Strips `sudo` prefix
 * - Returns first word; for multi-word tools, returns "tool subcommand"
 */
export function extractBaseCommand(cmd: string): string {
  let rest = cmd.trim();

  // Strip env var prefix(es): `KEY=value KEY2=value2 realcmd ...`
  while (/^[A-Z_][A-Z0-9_]*=\S*\s+/.test(rest)) {
    rest = rest.replace(/^[A-Z_][A-Z0-9_]*=\S*\s+/, "");
  }

  // Strip sudo
  if (rest.startsWith("sudo ")) {
    rest = rest.slice(5).trim();
    // Strip sudo flags: `sudo -u root cmd` → `cmd`
    rest = rest.replace(/^-\S+\s+\S+\s+/, "").trim();
  }

  const tokens = rest.split(/\s+/).filter(Boolean);
  if (tokens.length === 0) return "";

  const first = tokens[0];
  if (MULTI_WORD_TOOLS.has(first) && tokens.length >= 2) {
    // Skip flags for the subcommand position
    const sub = tokens.find((t, i) => i > 0 && !t.startsWith("-"));
    if (sub) return `${first} ${sub}`;
  }

  return first;
}

/**
 * Classify a command's risk level by matching against pattern arrays.
 * Destructive takes precedence over caution.
 */
export function classifyRisk(cmd: string): "safe" | "caution" | "destructive" {
  for (const pattern of DESTRUCTIVE_PATTERNS) {
    if (pattern.test(cmd)) return "destructive";
  }
  for (const pattern of CAUTION_PATTERNS) {
    if (pattern.test(cmd)) return "caution";
  }
  return "safe";
}

/**
 * Extract the display category from a base command (the first word).
 */
export function extractCategory(baseCommand: string): string {
  return baseCommand.split(/\s+/)[0] ?? "misc";
}

/**
 * Aggregate raw commands into a deduplicated map keyed by base command.
 * Tracks usage counts, first/last seen dates, source union, and risk level.
 * Skips ignored commands and single-character strings.
 */
export function aggregateCommands(rawCommands: RawCommand[]): Map<string, CommandEntry> {
  const map = new Map<string, CommandEntry>();

  for (const raw of rawCommands) {
    const normalized = normalizeCommand(raw.command);
    if (!normalized) continue;

    const base = extractBaseCommand(normalized);
    if (!base || base.length <= 1) continue;
    if (IGNORE_COMMANDS.has(base.split(/\s+/)[0])) continue;
    if (!isValidCommand(base)) continue;

    const existing = map.get(base);
    const ts = raw.timestamp?.toISOString() ?? new Date(0).toISOString();

    if (existing) {
      existing.usageCount += 1;
      // Update firstSeen / lastSeen
      if (ts < existing.firstSeen) existing.firstSeen = ts;
      if (ts > existing.lastSeen) existing.lastSeen = ts;
      // Union sources
      if (!existing.sources.includes(raw.source)) {
        existing.sources.push(raw.source);
      }
      // Escalate risk if needed
      const newRisk = classifyRisk(normalized);
      if (
        newRisk === "destructive" ||
        (newRisk === "caution" && existing.riskLevel === "safe")
      ) {
        existing.riskLevel = newRisk;
      }
      // Capture a longer fullCommand if we have one
      if (normalized.length > existing.fullCommand.length) {
        existing.fullCommand = normalized;
      }
    } else {
      map.set(base, {
        command: base,
        fullCommand: normalized,
        category: extractCategory(base),
        usageCount: 1,
        firstSeen: ts,
        lastSeen: ts,
        sources: [raw.source],
        riskLevel: classifyRisk(normalized),
        requiresSudo: /^sudo\s+/.test(normalized) || /\bsudo\b/.test(normalized),
        shell: raw.shell,
      });
    }
  }

  return map;
}

// ---------------------------------------------------------------------------
// Part 5: Individual Command Note Generation
// ---------------------------------------------------------------------------

/**
 * Convert a command string to a kebab-case filename slug.
 */
export function toKebabCase(str: string): string {
  return str
    .toLowerCase()
    .replace(/\s+/g, "-")
    .replace(/[^a-z0-9-]/g, "");
}

/**
 * Capitalize the first letter of a string.
 */
export function capitalize(s: string): string {
  if (!s) return s;
  return s.charAt(0).toUpperCase() + s.slice(1);
}

/**
 * Generate one Obsidian note per CommandEntry.
 * Returns "created", "updated", or "skipped".
 */
export function generateCommandNote(
  entry: CommandEntry,
  outputDir: string,
  dryRun: boolean
): "created" | "updated" | "skipped" {
  mkdirSync(outputDir, { recursive: true });

  const slug = toKebabCase(entry.command);
  const filePath = join(outputDir, `${slug}.md`);

  const today = new Date().toISOString().slice(0, 10);

  // Normalize ISO timestamps to YYYY-MM-DD for frontmatter
  const firstSeenDate = entry.firstSeen.startsWith("1970")
    ? today
    : entry.firstSeen.slice(0, 10);
  const lastSeenDate = entry.lastSeen.startsWith("1970")
    ? today
    : entry.lastSeen.slice(0, 10);

  // Normalize source labels (strip filename suffix from agent sources)
  const normalizedSources = [
    ...new Set(
      entry.sources.map((s) => {
        if (s.startsWith("claude-code:")) return "claude-code";
        if (s.startsWith("openclaw:")) return "openclaw";
        if (s.startsWith("opencode:")) return "opencode";
        if (s.startsWith("gemini:")) return "gemini";
        if (s.startsWith("qwen:")) return "qwen";
        if (s === "zsh-history" || s === "bash-history") return "shell-history";
        return s;
      })
    ),
  ];

  if (existsSync(filePath)) {
    // --- Merge existing note ---
    let existing: string;
    try {
      existing = readFileSync(filePath, "utf8");
    } catch {
      existing = "";
    }

    // Split frontmatter from body
    const fmMatch = existing.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
    let existingFm: Record<string, any> = {};
    let existingBody = "";

    if (fmMatch) {
      try {
        existingFm = parseYaml(fmMatch[1]) ?? {};
      } catch {
        existingFm = {};
      }
      existingBody = fmMatch[2] ?? "";
    } else {
      existingBody = existing;
    }

    // Merge counts and dates
    const mergedUsageCount = Math.max(
      entry.usageCount,
      Number(existingFm.usage_count ?? 0)
    );
    const existingFirst = String(existingFm.first_seen ?? "9999-99-99");
    const existingLast = String(existingFm.last_seen ?? "0000-00-00");
    const mergedFirst =
      firstSeenDate < existingFirst ? firstSeenDate : existingFirst;
    const mergedLast =
      lastSeenDate > existingLast ? lastSeenDate : existingLast;

    // Union sources
    const existingSources: string[] = Array.isArray(existingFm.source)
      ? existingFm.source
      : existingFm.source
      ? [existingFm.source]
      : [];
    const mergedSources = [...new Set([...existingSources, ...normalizedSources])];

    // Detect changes
    const unchanged =
      mergedUsageCount === Number(existingFm.usage_count ?? 0) &&
      mergedLast === existingLast &&
      mergedSources.length === existingSources.length;

    if (unchanged) return "skipped";

    // Preserve manually set fields; update computed fields
    const updatedFm: Record<string, any> = {
      ...existingFm,
      usage_count: mergedUsageCount,
      first_seen: mergedFirst,
      last_seen: mergedLast,
      source: mergedSources,
      updated: today,
    };

    const content = `---\n${stringifyYaml(updatedFm)}---\n${existingBody}`;
    if (!dryRun) writeFileSync(filePath, content, "utf8");
    return "updated";
  }

  // --- Create new note ---
  const fm: Record<string, any> = {
    title: entry.command,
    command: entry.command,
    category: entry.category,
    usage_count: entry.usageCount,
    first_seen: firstSeenDate,
    last_seen: lastSeenDate,
    source: normalizedSources,
    risk_level: entry.riskLevel,
    requires_sudo: entry.requiresSudo,
    shell: entry.shell,
    tags: [
      "type/command",
      "lifecycle/active",
      "domain/devops",
      `tool/${entry.category}`,
      "source/auto-generated",
    ],
    related: [
      `"[[070-tools/commands/by-tool/${entry.category}-commands|${capitalize(entry.category)} Commands]]"`,
    ],
    parent: "[[070-tools/commands/Commands-Mastersheet]]",
    aliases: [slug],
    created: today,
    updated: today,
  };

  const body = `
> ${entry.command}

**Usage:** \`${entry.fullCommand}\`

**Category:** ${capitalize(entry.category)} | **Risk:** \`${entry.riskLevel}\`
`;

  const content = `---\n${stringifyYaml(fm)}---\n${body}`;
  if (!dryRun) writeFileSync(filePath, content, "utf8");
  return "created";
}

// ---------------------------------------------------------------------------
// Part 6: Group Files and Mastersheet
// ---------------------------------------------------------------------------

/**
 * Generate one group file per tool category.
 */
export function generateGroupFile(
  category: string,
  commands: CommandEntry[],
  groupDir: string,
  _outputDir: string,
  dryRun: boolean
): void {
  mkdirSync(groupDir, { recursive: true });

  const today = new Date().toISOString().slice(0, 10);
  const totalUsage = commands.reduce((sum, c) => sum + c.usageCount, 0);
  const filename = `${category}-commands.md`;
  const filePath = join(groupDir, filename);

  const fm: Record<string, any> = {
    title: `${capitalize(category)} Commands`,
    category,
    total_commands: commands.length,
    total_usage: totalUsage,
    updated: today,
    tags: [
      "type/moc",
      "lifecycle/active",
      "domain/devops",
      `tool/${category}`,
      "source/auto-generated",
    ],
    parent: "[[070-tools/commands/Commands-Mastersheet]]",
  };

  const sortedByUsage = [...commands].sort((a, b) => b.usageCount - a.usageCount);

  const embeds = sortedByUsage
    .map((c) => `![[${toKebabCase(c.command)}]]`)
    .join("\n");

  const body = `
# ${capitalize(category)} Commands

**${commands.length} commands** | **${totalUsage} total uses**

\`\`\`dataview
TABLE command, usage_count, risk_level, last_seen
FROM "070-tools/commands"
WHERE contains(tags, "type/command") AND category = "${category}"
SORT usage_count DESC
\`\`\`

---

${embeds}

---

[[070-tools/commands/Commands-Mastersheet|Back to Commands Mastersheet]]
`;

  const content = `---\n${stringifyYaml(fm)}---\n${body}`;
  if (!dryRun) writeFileSync(filePath, content, "utf8");

  console.log(
    `  ${CYAN}${filename}${RESET} (${commands.length} commands, ${totalUsage} uses)`
  );
}

/**
 * Generate the top-level Commands Mastersheet MOC.
 */
export function generateMastersheet(
  allCommands: CommandEntry[],
  categories: Map<string, CommandEntry[]>,
  outputDir: string,
  _groupDir: string,
  dryRun: boolean
): void {
  mkdirSync(outputDir, { recursive: true });

  const today = new Date().toISOString().slice(0, 10);
  const totalUsage = allCommands.reduce((sum, c) => sum + c.usageCount, 0);
  const filePath = join(outputDir, "Commands-Mastersheet.md");

  const fm: Record<string, any> = {
    title: "Commands Mastersheet",
    total_commands: allCommands.length,
    total_usage: totalUsage,
    total_categories: categories.size,
    updated: today,
    tags: [
      "type/moc",
      "lifecycle/active",
      "domain/devops",
      "topic/commands",
      "topic/leaderboard",
      "source/auto-generated",
    ],
  };

  // Build categories table
  const categoryRows = [...categories.entries()]
    .sort((a, b) => b[1].length - a[1].length)
    .map(([cat, cmds]) => {
      const uses = cmds.reduce((s, c) => s + c.usageCount, 0);
      return `| [[070-tools/commands/by-tool/${cat}-commands\\|${capitalize(cat)}]] | ${cmds.length} | ${uses} |`;
    })
    .join("\n");

  const agents = ["claude-code", "openclaw", "opencode", "shell-history"];

  const agentSections = agents
    .map((agent) => {
      const label = agent
        .split("-")
        .map(capitalize)
        .join(" ");
      return `### ${label}

\`\`\`dataview
TABLE command, usage_count, last_seen
FROM "070-tools/commands"
WHERE contains(tags, "type/command") AND contains(source, "${agent}")
SORT usage_count DESC
LIMIT 15
\`\`\`
`;
    })
    .join("\n");

  const body = `
# Commands Mastersheet

**${allCommands.length} commands** | **${categories.size} categories** | **${totalUsage} total uses**

---

## Leaderboard — Top 25

\`\`\`dataview
TABLE command, category, usage_count, risk_level, last_seen
FROM "070-tools/commands"
WHERE contains(tags, "type/command")
SORT usage_count DESC
LIMIT 25
\`\`\`

---

## Recently Used

\`\`\`dataview
TABLE command, category, usage_count, last_seen
FROM "070-tools/commands"
WHERE contains(tags, "type/command")
SORT last_seen DESC
LIMIT 15
\`\`\`

---

## Destructive Commands

\`\`\`dataview
TABLE command, category, usage_count, last_seen
FROM "070-tools/commands"
WHERE contains(tags, "type/command") AND risk_level = "destructive"
SORT usage_count DESC
\`\`\`

---

## Caution Commands

\`\`\`dataview
TABLE command, category, usage_count, last_seen
FROM "070-tools/commands"
WHERE contains(tags, "type/command") AND risk_level = "caution"
SORT usage_count DESC
\`\`\`

---

## By Source — Agent Breakdown

${agentSections}

---

## Categories

| Category | Commands | Total Uses |
|----------|----------|------------|
${categoryRows}

---

## All Commands

\`\`\`dataview
TABLE command, category, usage_count, risk_level, first_seen, last_seen
FROM "070-tools/commands"
WHERE contains(tags, "type/command")
SORT usage_count DESC
\`\`\`
`;

  const content = `---\n${stringifyYaml(fm)}---\n${body}`;
  if (!dryRun) writeFileSync(filePath, content, "utf8");

  console.log(
    `\n${GREEN}Mastersheet${RESET}: ${allCommands.length} commands, ${categories.size} categories, ${totalUsage} total uses`
  );
}

// ---------------------------------------------------------------------------
// Part 6: Main Entry Function
// ---------------------------------------------------------------------------

export interface CommandSourceConfig {
  shell_history: string[];
  agent_logs: Record<string, string>;
  ignore_commands?: string[];
}

export function runCommandsSync(
  vaultRoot: string,
  dryRun: boolean = false,
  sourceConfig?: CommandSourceConfig,
): CommandsResult {
  const homeDir = process.env.HOME || "/var/home/yish";

  const config: CommandSourceConfig = sourceConfig || {
    shell_history: [
      join(homeDir, ".bash_history"),
      join(homeDir, ".zsh_history"),
    ],
    agent_logs: {
      "claude-code": join(homeDir, ".claude/projects"),
      "openclaw": "/opt/openclaw/config/logs",
      "opencode": join(homeDir, "opt-ai-agents/opencode/logs"),
      "gemini": join(homeDir, ".gemini"),
      "qwen": join(homeDir, ".qwen"),
    },
  };

  if (config.ignore_commands) {
    for (const cmd of config.ignore_commands) IGNORE_COMMANDS.add(cmd);
  }

  const outputDir = join(vaultRoot, "070-tools/commands");
  const groupDir = join(vaultRoot, "070-tools/commands/by-tool");

  console.log(`\n${CYAN}Command Mastersheet Sync${RESET}`);
  console.log(`${DIM}Output: ${outputDir}${RESET}`);
  if (dryRun) console.log(`${YELLOW}[DRY RUN]${RESET}`);

  // Phase 1: Collect
  console.log(`\n${CYAN}Collecting commands...${RESET}`);
  const allRaw: RawCommand[] = [];

  for (const histPath of config.shell_history) {
    const expanded = histPath.replace(/^~/, homeDir);
    if (expanded.includes(".zsh_history")) {
      const cmds = parseZshHistory(expanded);
      console.log(`  ${GREEN}zsh${RESET}: ${cmds.length} commands from ${expanded}`);
      allRaw.push(...cmds);
    } else {
      const cmds = parseBashHistory(expanded);
      console.log(`  ${GREEN}bash${RESET}: ${cmds.length} commands from ${expanded}`);
      allRaw.push(...cmds);
    }
  }

  for (const [agent, logPath] of Object.entries(config.agent_logs)) {
    const expanded = logPath.replace(/^~/, homeDir);
    let cmds: RawCommand[];
    if (agent === "claude-code") {
      cmds = parseClaudeCodeLogs(expanded);
    } else {
      cmds = parseGenericAgentLogs(expanded, agent);
    }
    console.log(`  ${GREEN}${agent}${RESET}: ${cmds.length} commands from ${expanded}`);
    allRaw.push(...cmds);
  }

  console.log(`\n${DIM}Total raw commands: ${allRaw.length}${RESET}`);

  // Phase 2: Aggregate
  console.log(`\n${CYAN}Aggregating...${RESET}`);
  const commandMap = aggregateCommands(allRaw);
  console.log(`  ${GREEN}Unique commands: ${commandMap.size}${RESET}`);

  // Phase 3: Generate notes
  console.log(`\n${CYAN}Generating command notes...${RESET}`);
  let created = 0, updated = 0, skipped = 0;

  for (const entry of commandMap.values()) {
    const action = generateCommandNote(entry, outputDir, dryRun);
    if (action === "created") created++;
    else if (action === "updated") updated++;
    else skipped++;
  }

  console.log(`  ${GREEN}Created: ${created}${RESET} | ${YELLOW}Updated: ${updated}${RESET} | ${DIM}Skipped: ${skipped}${RESET}`);

  // Phase 4: Generate group files
  console.log(`\n${CYAN}Generating group files...${RESET}`);
  const categories = new Map<string, CommandEntry[]>();
  for (const entry of commandMap.values()) {
    const cat = entry.category;
    if (!categories.has(cat)) categories.set(cat, []);
    categories.get(cat)!.push(entry);
  }

  for (const [cat, cmds] of categories) {
    generateGroupFile(cat, cmds, groupDir, outputDir, dryRun);
  }

  // Phase 5: Generate mastersheet
  console.log(`\n${CYAN}Generating mastersheet...${RESET}`);
  generateMastersheet([...commandMap.values()], categories, outputDir, groupDir, dryRun);

  const result: CommandsResult = {
    created,
    updated,
    skipped,
    totalCommands: commandMap.size,
    categories: categories.size,
  };

  console.log(`\n${GREEN}Done!${RESET} ${result.totalCommands} commands in ${result.categories} categories\n`);
  return result;
}
