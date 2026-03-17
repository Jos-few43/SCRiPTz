/**
 * orphans.ts — Scan the vault for notes not linked from any MOC or index file.
 *
 * A file is "orphaned" if no MOC/index file contains a wikilink to it.
 * MOC/index files are identified by:
 *   - Filename contains "MOC" or "INDEX" or "DASHBOARD"
 *   - Frontmatter contains type: index
 *   - File is named _index.md
 */

import { readFileSync } from "fs";
import { glob } from "glob";
import { basename, dirname, relative, resolve } from "path";

const RESET = "\x1b[0m";
const RED = "\x1b[31m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const DIM = "\x1b[2m";

const EXCLUDED_DIRS = [
  "**/node_modules/**",
  "**/scripts/**",
  "**/.obsidian/**",
  "**/.trash/**",
];

function isMocOrIndex(filePath: string, content: string): boolean {
  const name = basename(filePath, ".md").toUpperCase();
  if (
    name.includes("MOC") ||
    name.includes("INDEX") ||
    name === "DASHBOARD" ||
    name === "CHAIN-CATALOG" ||
    name.startsWith("THEME-")  // Theme files are also MOCs
  ) {
    return true;
  }

  // Check frontmatter for type: index
  const fmMatch = content.match(/^---\n([\s\S]*?)\n---/);
  if (fmMatch) {
    const fm = fmMatch[1];
    if (/^type:\s*index/m.test(fm)) return true;
  }

  return false;
}

function extractWikilinks(content: string): string[] {
  const links: string[] = [];
  const regex = /\[\[([^\]|]+)(?:\|[^\]]+)?\]\]/g;
  let match;
  while ((match = regex.exec(content)) !== null) {
    const link = match[1].replace(/^\//, "").trim();
    links.push(link);
  }
  return links;
}

function normalizeForMatch(filePath: string, vaultRoot: string): string[] {
  const rel = relative(vaultRoot, filePath).replace(/\.md$/, "");
  const name = basename(filePath, ".md");

  return [rel, name, rel.toLowerCase(), name.toLowerCase()];
}

export async function runOrphanCheck(vaultRoot: string): Promise<void> {
  const allFiles = await glob("**/*.md", {
    cwd: vaultRoot,
    absolute: true,
    ignore: EXCLUDED_DIRS,
  });

  // Phase 1: Read all files, identify MOCs, collect their outlinks
  const mocLinks = new Set<string>();
  const mocFiles: string[] = [];

  for (const filePath of allFiles) {
    const content = readFileSync(filePath, "utf-8");

    if (isMocOrIndex(filePath, content)) {
      mocFiles.push(filePath);
      const links = extractWikilinks(content);
      const fileDir = dirname(filePath);
      for (const link of links) {
        // Add the raw link as-is
        mocLinks.add(link.toLowerCase());
        // Also resolve relative links from the MOC's directory
        const resolved = relative(
          vaultRoot,
          resolve(fileDir, link)
        );
        mocLinks.add(resolved.toLowerCase());
      }
    }
  }

  console.log(
    `${DIM}Found ${allFiles.length} notes, ${mocFiles.length} MOC/index files${RESET}`
  );

  // Phase 2: Check each non-MOC file for orphan status
  const orphans: string[] = [];

  for (const filePath of allFiles) {
    const content = readFileSync(filePath, "utf-8");

    if (isMocOrIndex(filePath, content)) continue;

    const candidates = normalizeForMatch(filePath, vaultRoot);
    const isLinked = candidates.some((c) => mocLinks.has(c.toLowerCase()));

    if (!isLinked) {
      orphans.push(relative(vaultRoot, filePath));
    }
  }

  // Report
  if (orphans.length === 0) {
    console.log(`\n${GREEN}No orphaned notes found!${RESET} All notes are linked from a MOC.`);
  } else {
    console.log(
      `\n${YELLOW}Found ${orphans.length} orphaned notes${RESET} (not linked from any MOC):\n`
    );
    for (const orphan of orphans.sort()) {
      console.log(`  ${RED}•${RESET} ${DIM}${orphan}${RESET}`);
    }
    console.log(
      `\n${DIM}To fix: add [[wikilinks]] to these files in the appropriate MOC.${RESET}`
    );
  }
}
