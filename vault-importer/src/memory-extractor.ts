#!/usr/bin/env bun
/**
 * memory-extractor.ts — Extract memory-worthy items from Claude Code session transcripts.
 *
 * Usage: bun run memory-extractor.ts <transcript_path>
 *
 * Scans JSONL transcripts for:
 *   - User preference signals ("always", "never", "prefer", "remember")
 *   - TaskCreate/TaskUpdate activity → project state
 *   - Skips sessions where memory files were already written
 *
 * Appends extracted items to the appropriate memory topic file with dedup.
 */

import { readFileSync, appendFileSync, existsSync } from "fs";

const MEMORY_DIR =
  "/var/home/yish/.claude/projects/-var-home-yish/memory";

const PREFERENCE_KEYWORDS = [
  "always",
  "never",
  "prefer",
  "remember",
  "don't ever",
  "make sure to",
  "from now on",
  "stop doing",
];

interface TranscriptLine {
  type: string;
  content?: string;
  tool_name?: string;
  tool_input?: Record<string, unknown>;
  timestamp?: string;
}

function readTranscript(path: string): TranscriptLine[] {
  const raw = readFileSync(path, "utf-8");
  const lines: TranscriptLine[] = [];
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    try {
      lines.push(JSON.parse(line));
    } catch {
      // skip malformed lines
    }
  }
  return lines;
}

function extractPreferences(lines: TranscriptLine[]): string[] {
  const prefs: string[] = [];

  for (const line of lines) {
    if (line.type !== "user" || !line.content) continue;

    // Strip XML tags from content
    const cleaned = line.content
      .replace(/<[a-zA-Z_][a-zA-Z0-9_-]*(?:\s[^>]*)?>[\s\S]*?<\/[a-zA-Z_][a-zA-Z0-9_-]*>/g, "")
      .replace(/<[a-zA-Z_][a-zA-Z0-9_-]*\/>/g, "")
      .trim();

    if (!cleaned) continue;

    // Check each sentence for preference signals
    const sentences = cleaned.split(/[.!?\n]+/).map((s) => s.trim()).filter(Boolean);
    for (const sentence of sentences) {
      const lower = sentence.toLowerCase();
      const hasKeyword = PREFERENCE_KEYWORDS.some((kw) => lower.includes(kw));
      if (hasKeyword && sentence.length > 10 && sentence.length < 200) {
        prefs.push(sentence);
      }
    }
  }

  return prefs;
}

function extractProjectState(lines: TranscriptLine[]): string[] {
  const items: string[] = [];

  for (const line of lines) {
    if (line.type !== "tool_use") continue;

    if (line.tool_name === "TaskCreate" && line.tool_input) {
      const subject = line.tool_input.subject as string;
      if (subject) {
        items.push(`Task created: ${subject}`);
      }
    }

    if (
      line.tool_name === "TaskUpdate" &&
      line.tool_input &&
      (line.tool_input as Record<string, unknown>).status === "completed"
    ) {
      const taskId = (line.tool_input as Record<string, unknown>).taskId as string;
      if (taskId) {
        items.push(`Task #${taskId} completed`);
      }
    }
  }

  return items;
}

function sessionAlreadyWroteMemory(lines: TranscriptLine[]): boolean {
  for (const line of lines) {
    if (line.type !== "tool_use") continue;
    if (
      (line.tool_name === "Write" || line.tool_name === "Edit") &&
      line.tool_input
    ) {
      const path =
        (line.tool_input.file_path as string) ??
        (line.tool_input.filePath as string) ??
        "";
      if (path.includes("/memory/") && path.endsWith(".md")) {
        return true;
      }
    }
  }
  return false;
}

function dedup(filePath: string, newItems: string[]): string[] {
  if (!existsSync(filePath)) return newItems;

  const existing = readFileSync(filePath, "utf-8").toLowerCase();
  return newItems.filter((item) => {
    // Check if key phrases (first 40 chars) already exist
    const key = item.toLowerCase().slice(0, 40);
    return !existing.includes(key);
  });
}

function appendToFile(filePath: string, _section: string, items: string[]): void {
  if (items.length === 0) return;

  const timestamp = new Date().toISOString().split("T")[0];
  const block = `\n## Auto-extracted (${timestamp})\n${items.map((i) => `- ${i}`).join("\n")}\n`;

  appendFileSync(filePath, block, "utf-8");
}

// --- Main ---
const transcriptPath = process.argv[2];
if (!transcriptPath) {
  console.error("Usage: bun run memory-extractor.ts <transcript_path>");
  process.exit(1);
}

if (!existsSync(transcriptPath)) {
  console.error(`Transcript not found: ${transcriptPath}`);
  process.exit(1);
}

const lines = readTranscript(transcriptPath);

// Skip if session already wrote to memory files
if (sessionAlreadyWroteMemory(lines)) {
  console.log("[memory-extractor] Session already wrote memory, skipping");
  process.exit(0);
}

// Extract preferences
const rawPrefs = extractPreferences(lines);
const prefsFile = `${MEMORY_DIR}/user-preferences.md`;
const newPrefs = dedup(prefsFile, rawPrefs);
if (newPrefs.length > 0) {
  appendToFile(prefsFile, "Auto-extracted preferences", newPrefs);
  console.log(`[memory-extractor] Added ${newPrefs.length} preferences`);
}

// Extract project state
const rawState = extractProjectState(lines);
const stateFile = `${MEMORY_DIR}/project-state.md`;
const newState = dedup(stateFile, rawState);
if (newState.length > 0) {
  appendToFile(stateFile, "Auto-extracted project state", newState);
  console.log(`[memory-extractor] Added ${newState.length} project state items`);
}

if (newPrefs.length === 0 && newState.length === 0) {
  console.log("[memory-extractor] No new memory items found");
}
