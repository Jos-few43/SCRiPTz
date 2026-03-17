/**
 * utils.ts — Shared utilities for vault-importer scripts.
 *
 * Provides: color codes, FACET_ORDER, frontmatter parsing/serialization,
 * tag normalization, and tag sorting. Consumed by tag-migrator.ts and
 * terminology-integrator.ts (and any future scripts).
 */

import { parse, stringify } from "yaml";

// ---------------------------------------------------------------------------
// Color codes
// ---------------------------------------------------------------------------
export const RESET = "\x1b[0m";
export const RED = "\x1b[31m";
export const GREEN = "\x1b[32m";
export const YELLOW = "\x1b[33m";
export const BLUE = "\x1b[34m";
export const DIM = "\x1b[2m";
export const BOLD = "\x1b[1m";
export const CYAN = "\x1b[36m";

// ---------------------------------------------------------------------------
// Facet sort order
// ---------------------------------------------------------------------------
export const FACET_ORDER = [
  "type",
  "lifecycle",
  "domain",
  "scope",
  "agent",
  "tool",
  "lang",
  "source",
  "topic",
];

// ---------------------------------------------------------------------------
// Frontmatter helpers
// ---------------------------------------------------------------------------

export function parseFrontmatter(content: string): { fm: Record<string, unknown> | null; body: string } {
  const match = content.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!match) return { fm: null, body: content };
  try {
    const fm = parse(match[1]) as Record<string, unknown>;
    return { fm: fm ?? null, body: match[2] };
  } catch {
    return { fm: null, body: content };
  }
}

export function normalizeTags(raw: unknown): string[] {
  if (!raw) return [];
  if (Array.isArray(raw)) return raw.map(String).filter(Boolean);
  if (typeof raw === "string") {
    const trimmed = raw.trim();
    if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
      return trimmed
        .slice(1, -1)
        .split(",")
        .map((t) => t.trim().replace(/^["']|["']$/g, ""))
        .filter(Boolean);
    }
    return [trimmed].filter(Boolean);
  }
  return [];
}

export function serializeFrontmatter(fm: Record<string, unknown>): string {
  const yamlStr = stringify(fm, {
    defaultStringType: "PLAIN",
    defaultKeyType: "PLAIN",
    blockQuote: "literal",
  });
  return `---\n${yamlStr}---\n`;
}

export function sortTags(tags: string[]): string[] {
  return [...tags].sort((a, b) => {
    const facetA = a.includes("/") ? a.split("/")[0] : "topic";
    const facetB = b.includes("/") ? b.split("/")[0] : "topic";
    const orderA = FACET_ORDER.indexOf(facetA);
    const orderB = FACET_ORDER.indexOf(facetB);
    const rankA = orderA === -1 ? FACET_ORDER.length : orderA;
    const rankB = orderB === -1 ? FACET_ORDER.length : orderB;
    if (rankA !== rankB) return rankA - rankB;
    return a.localeCompare(b);
  });
}

// ---------------------------------------------------------------------------
// Code block extraction
// ---------------------------------------------------------------------------

export interface CodeBlockInfo {
  language: string;
  code: string;
  lineCount: number;
}

export function extractCodeBlock(content: string): CodeBlockInfo | null {
  const match = content.match(/```(\w*)\n([\s\S]*?)```/);
  if (!match) return null;

  const language = match[1] || "";
  const code = match[2].trimEnd();
  const lineCount = code.split("\n").length;

  return { language, code, lineCount };
}
