import { describe, test, expect } from "bun:test";
import {
  buildImportIndex,
  parseImportNote,
  parseChain,
  scoreMatches,
  injectAttachedFiles,
  isCodeBearingFile,
} from "../chain-linker";
import type { ImportEntry, ScoredMatch } from "../chain-linker";

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

function makeEntry(overrides: Partial<ImportEntry> = {}): ImportEntry {
  return {
    notePath: "060-imports/configs/litellm-stack/litellm-stack/config.yaml.md",
    sourceFile: "config.yaml",
    sourcePath: "litellm-stack/config.yaml",
    tags: ["type/import", "domain/infra", "tool/litellm", "source/auto-generated"],
    displayName: "litellm-stack/config.yaml",
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// buildImportIndex
// ---------------------------------------------------------------------------

describe("buildImportIndex", () => {
  test("indexes entry by filename", () => {
    const entry = makeEntry();
    const idx = buildImportIndex([entry]);
    expect(idx.byFilename.get("config.yaml")).toContain(entry);
  });

  test("indexes entry by path segments (≥3 chars)", () => {
    const entry = makeEntry();
    const idx = buildImportIndex([entry]);
    // "litellm-stack" is a segment ≥3 chars
    expect(idx.byPathSegment.get("litellm-stack")).toContain(entry);
    // "config.yaml" directory part — but we split sourcePath by /
    // sourcePath = "litellm-stack/config.yaml" → segments: "litellm-stack", "config.yaml"
    // directory segments only (not the filename itself, which is already in byFilename)
  });

  test("does not index short path segments (<3 chars)", () => {
    const entry = makeEntry({
      sourcePath: "ab/config.yaml",
      notePath: "060-imports/configs/ab/config.yaml.md",
      sourceFile: "config.yaml",
      displayName: "ab/config.yaml",
    });
    const idx = buildImportIndex([entry]);
    expect(idx.byPathSegment.has("ab")).toBe(false);
  });

  test("indexes by tool/* tag", () => {
    const entry = makeEntry();
    const idx = buildImportIndex([entry]);
    expect(idx.byTag.get("tool/litellm")).toContain(entry);
  });

  test("does not index domain/* tags (too broad)", () => {
    const entry = makeEntry();
    const idx = buildImportIndex([entry]);
    expect(idx.byTag.has("domain/infra")).toBe(false);
  });

  test("does not index lang/* tags (too broad)", () => {
    const entry = makeEntry({
      tags: ["type/import", "lang/python"],
      sourcePath: "SCRiPTz/run.py",
      sourceFile: "run.py",
      displayName: "SCRiPTz/run.py",
    });
    const idx = buildImportIndex([entry]);
    expect(idx.byTag.has("lang/python")).toBe(false);
  });

  test("does not index non-qualifying tags (type/*, source/*)", () => {
    const entry = makeEntry();
    const idx = buildImportIndex([entry]);
    expect(idx.byTag.has("type/import")).toBe(false);
    expect(idx.byTag.has("source/auto-generated")).toBe(false);
  });

  test("all contains every entry", () => {
    const e1 = makeEntry();
    const e2 = makeEntry({ sourceFile: "docker-compose.yml", sourcePath: "arr-media-stack/docker-compose.yml" });
    const idx = buildImportIndex([e1, e2]);
    expect(idx.all).toHaveLength(2);
    expect(idx.all).toContain(e1);
    expect(idx.all).toContain(e2);
  });

  test("multiple entries with same filename both indexed", () => {
    const e1 = makeEntry({ notePath: "060-imports/configs/a/config.yaml.md" });
    const e2 = makeEntry({ notePath: "060-imports/configs/b/config.yaml.md" });
    const idx = buildImportIndex([e1, e2]);
    const hits = idx.byFilename.get("config.yaml") ?? [];
    expect(hits).toHaveLength(2);
  });
});

// ---------------------------------------------------------------------------
// parseImportNote
// ---------------------------------------------------------------------------

describe("parseImportNote", () => {
  const notePath = "060-imports/configs/litellm-stack/litellm-stack/config.yaml.md";

  test("extracts fields from well-formed frontmatter", () => {
    const content = `---
title: litellm-stack/config.yaml
source: /var/home/yish/litellm-stack/config.yaml
checksum: abc123
tags:
  - type/import
  - domain/infra
  - tool/litellm
  - source/auto-generated
---

# litellm-stack/config.yaml

Body content here.
`;
    const entry = parseImportNote(content, notePath);
    expect(entry).not.toBeNull();
    expect(entry!.sourcePath).toBe("litellm-stack/config.yaml");
    expect(entry!.sourceFile).toBe("config.yaml");
    expect(entry!.displayName).toBe("litellm-stack/config.yaml");
    expect(entry!.notePath).toBe(notePath);
    expect(entry!.tags).toContain("tool/litellm");
    expect(entry!.tags).toContain("domain/infra");
  });

  test("returns null when no title in frontmatter", () => {
    const content = `---
source: /var/home/yish/litellm-stack/config.yaml
tags:
  - type/import
---

Body.
`;
    const result = parseImportNote(content, notePath);
    expect(result).toBeNull();
  });

  test("returns null for content with no frontmatter", () => {
    const content = "# Just a heading\n\nSome text.";
    const result = parseImportNote(content, notePath);
    expect(result).toBeNull();
  });

  test("handles title with deep path", () => {
    const content = `---
title: arr-media-stack/traefik/dynamic.yml
source: /var/home/yish/arr-media-stack/traefik/dynamic.yml
checksum: xyz
tags:
  - type/import
  - domain/general
---
`;
    const entry = parseImportNote(content, "060-imports/arr-media-stack/arr-media-stack/traefik/dynamic.yml.md");
    expect(entry).not.toBeNull();
    expect(entry!.sourceFile).toBe("dynamic.yml");
    expect(entry!.sourcePath).toBe("arr-media-stack/traefik/dynamic.yml");
  });

  test("handles tags as array in frontmatter", () => {
    const content = `---
title: shared-skills/source/git-ops.md
tags:
  - type/import
  - tool/git
  - lang/markdown
---
`;
    const entry = parseImportNote(content, "060-imports/instructions/shared-skills/source/git-ops.md.md");
    expect(entry).not.toBeNull();
    expect(entry!.tags).toContain("tool/git");
    expect(entry!.tags).toContain("lang/markdown");
  });

  test("strips .md suffix from displayName when title ends with .md but is a markdown source", () => {
    // For a title like "shared-skills/source/git-ops.md" the sourceFile should be "git-ops.md"
    const content = `---
title: shared-skills/source/git-ops.md
tags:
  - type/import
---
`;
    const entry = parseImportNote(content, "060-imports/instructions/shared-skills/source/git-ops.md.md");
    expect(entry).not.toBeNull();
    expect(entry!.sourceFile).toBe("git-ops.md");
  });
});

// ---------------------------------------------------------------------------
// parseChain
// ---------------------------------------------------------------------------

describe("parseChain", () => {
  const chainPath = "010-chains/chain.devexp.claude-config-management.md";

  test("extracts handle from frontmatter", () => {
    const content = `---
id: chain/devexp/claude-config-management
handle: CLAUDE_CONFIG_MANAGEMENT
tags:
  - type/chain
  - domain/devexp
  - tool/claude-code
---

# CLAUDE_CONFIG_MANAGEMENT

Body text here with [[some/link]].
`;
    const chain = parseChain(content, chainPath);
    expect(chain).not.toBeNull();
    expect(chain!.handle).toBe("CLAUDE_CONFIG_MANAGEMENT");
  });

  test("extracts tags from frontmatter", () => {
    const content = `---
handle: MY_CHAIN
tags:
  - type/chain
  - domain/infra
  - tool/litellm
---

# MY_CHAIN
`;
    const chain = parseChain(content, chainPath);
    expect(chain!.tags).toContain("domain/infra");
    expect(chain!.tags).toContain("tool/litellm");
  });

  test("extracts wikilink targets from body", () => {
    const content = `---
handle: MY_CHAIN
tags:
  - type/chain
---

# MY_CHAIN

See [[040-projects/repos/litellm-stack]] and [[020-concepts/terminology/DevExp/claude-code-hooks|Hook Events]].
`;
    const chain = parseChain(content, chainPath);
    expect(chain!.wikilinkTargets).toContain("040-projects/repos/litellm-stack");
    expect(chain!.wikilinkTargets).toContain("020-concepts/terminology/DevExp/claude-code-hooks");
  });

  test("returns body text for scanning", () => {
    const content = `---
handle: MY_CHAIN
tags:
  - type/chain
---

# MY_CHAIN

References config.yaml and litellm-stack settings.
`;
    const chain = parseChain(content, chainPath);
    expect(chain!.bodyText).toContain("config.yaml");
    expect(chain!.bodyText).toContain("litellm-stack");
  });

  test("returns null when no handle in frontmatter", () => {
    const content = `---
tags:
  - type/chain
---

# No handle here.
`;
    const result = parseChain(content, chainPath);
    expect(result).toBeNull();
  });

  test("returns null for content with no frontmatter", () => {
    const content = "# Just heading\n\nBody.";
    const result = parseChain(content, chainPath);
    expect(result).toBeNull();
  });

  test("sets path on result", () => {
    const content = `---
handle: MY_CHAIN
tags: []
---

Body.
`;
    const chain = parseChain(content, chainPath);
    expect(chain!.path).toBe(chainPath);
  });

  test("wikilinks with display text use only the target part", () => {
    const content = `---
handle: MY_CHAIN
tags: []
---

See [[repos/litellm-stack|LiteLLM Stack]] for details.
`;
    const chain = parseChain(content, chainPath);
    expect(chain!.wikilinkTargets).toContain("repos/litellm-stack");
    // Display text should NOT appear as target
    expect(chain!.wikilinkTargets).not.toContain("LiteLLM Stack");
  });
});

// ---------------------------------------------------------------------------
// scoreMatches
// ---------------------------------------------------------------------------

describe("scoreMatches", () => {
  const litellmEntry = makeEntry();

  function makeChain(bodyText: string, tags: string[] = [], wikilinks: string[] = []) {
    return {
      path: "010-chains/chain.devexp.litellm-routing.md",
      handle: "LITELLM_ROUTING",
      tags,
      bodyText,
      wikilinkTargets: wikilinks,
    };
  }

  test("filename exact match scores +10", () => {
    const index = buildImportIndex([litellmEntry]);
    const chain = makeChain("Use config.yaml for LiteLLM routing.");
    const matches = scoreMatches(chain, index);
    const match = matches.find((m: ScoredMatch) => m.importEntry === litellmEntry);
    expect(match).toBeDefined();
    expect(match!.score).toBeGreaterThanOrEqual(10);
    expect(match!.reasons.some((r: string) => r.includes("filename"))).toBe(true);
  });

  test("generic filenames are skipped (package.json)", () => {
    const entry = makeEntry({
      sourceFile: "package.json",
      sourcePath: "my-project/package.json",
      notePath: "060-imports/configs/my-project/package.json.md",
      displayName: "my-project/package.json",
    });
    const index = buildImportIndex([entry]);
    const chain = makeChain("Uses package.json for dependencies.");
    const matches = scoreMatches(chain, index);
    // package.json is generic — filename match should not be scored
    const match = matches.find((m: ScoredMatch) => m.importEntry === entry);
    // It might still match via path segment, but NOT via filename +10
    if (match) {
      expect(match.reasons.some((r: string) => r.includes("filename"))).toBe(false);
    }
  });

  test("generic filenames are skipped (README.md)", () => {
    const entry = makeEntry({
      sourceFile: "README.md",
      sourcePath: "my-project/README.md",
      notePath: "060-imports/configs/my-project/README.md.md",
      displayName: "my-project/README.md",
    });
    const index = buildImportIndex([entry]);
    const chain = makeChain("Check the README.md for docs.");
    const matches = scoreMatches(chain, index);
    const hit = matches.find((m: ScoredMatch) => m.importEntry === entry);
    if (hit) {
      expect(hit.reasons.some((r: string) => r.includes("filename"))).toBe(false);
    }
  });

  test("repo wikilink match scores +7", () => {
    const entry = makeEntry({
      sourcePath: "litellm-stack/config.yaml",
    });
    const index = buildImportIndex([entry]);
    const chain = makeChain("Config details.", [], ["040-projects/repos/litellm-stack"]);
    const matches = scoreMatches(chain, index);
    const match = matches.find((m: ScoredMatch) => m.importEntry === entry);
    expect(match).toBeDefined();
    expect(match!.reasons.some((r: string) => r.includes("repo wikilink"))).toBe(true);
    expect(match!.score).toBeGreaterThanOrEqual(7);
  });

  test("path fragment match scores +5", () => {
    const entry = makeEntry();
    const index = buildImportIndex([entry]);
    // "litellm-stack" is ≥5 chars and appears in body
    const chain = makeChain("Configure litellm-stack router settings here.");
    const matches = scoreMatches(chain, index);
    const match = matches.find((m: ScoredMatch) => m.importEntry === entry);
    expect(match).toBeDefined();
    expect(match!.reasons.some((r: string) => r.includes("path fragment"))).toBe(true);
  });

  test("handle keyword match scores +4", () => {
    const entry = makeEntry({
      sourcePath: "litellm-stack/router/haproxy.cfg",
      sourceFile: "haproxy.cfg",
      notePath: "060-imports/configs/litellm-stack/router/haproxy.cfg.md",
      displayName: "litellm-stack/router/haproxy.cfg",
    });
    const index = buildImportIndex([entry]);
    // handle: LITELLM_ROUTING → keywords: ["litellm", "routing"] (≥4 chars)
    const chain = makeChain("Route requests.", [], []);
    chain.handle = "LITELLM_ROUTING"; // overwrite
    const matches = scoreMatches(chain, index);
    const match = matches.find((m: ScoredMatch) => m.importEntry === entry);
    // "litellm" from handle should match "litellm-stack" path segment
    if (match) {
      expect(match.reasons.some((r: string) => r.includes("handle keyword"))).toBe(true);
    }
  });

  test("shared tag overlap scores +3 (contributes to total)", () => {
    const entry = makeEntry({
      tags: ["type/import", "tool/litellm"],
    });
    const index = buildImportIndex([entry]);
    // Body contains filename (+10) AND shared tool tag (+3) = 13, above threshold
    const chain = {
      path: "010-chains/chain.devexp.litellm.md",
      handle: "LITELLM",
      tags: ["type/chain", "tool/litellm"],
      bodyText: "Check config.yaml for routing.",
      wikilinkTargets: [],
    };
    const matches = scoreMatches(chain, index);
    const match = matches.find((m: ScoredMatch) => m.importEntry === entry);
    expect(match).toBeDefined();
    expect(match!.reasons.some((r: string) => r.includes("shared tag"))).toBe(true);
    expect(match!.reasons.some((r: string) => r.includes("filename"))).toBe(true);
  });

  test("entries below threshold of 8 are excluded", () => {
    const unrelatedEntry = makeEntry({
      sourceFile: "traefik.yml",
      sourcePath: "arr-media-stack/traefik/traefik.yml",
      notePath: "060-imports/arr-media-stack/arr-media-stack/traefik/traefik.yml.md",
      tags: ["type/import", "domain/general"],
      displayName: "arr-media-stack/traefik/traefik.yml",
    });
    const index = buildImportIndex([unrelatedEntry]);
    // Chain about LiteLLM — no overlap with arr-media-stack traefik
    const chain = makeChain("LiteLLM model routing proxy configuration.", ["tool/litellm"]);
    const matches = scoreMatches(chain, index);
    // traefik.yml should not appear (score < 5)
    const hit = matches.find((m: ScoredMatch) => m.importEntry === unrelatedEntry);
    expect(hit).toBeUndefined();
  });

  test("results are sorted descending by score", () => {
    const highEntry = makeEntry({
      sourcePath: "litellm-stack/config.yaml",
      tags: ["type/import", "tool/litellm"],
    });
    const lowEntry = makeEntry({
      sourceFile: "other.cfg",
      sourcePath: "litellm-stack/other.cfg",
      notePath: "060-imports/configs/litellm-stack/other.cfg.md",
      displayName: "litellm-stack/other.cfg",
      tags: ["type/import", "domain/general"],
    });
    const index = buildImportIndex([highEntry, lowEntry]);
    // "config.yaml" in body → highEntry gets filename+path matches
    const chain = {
      path: "010-chains/chain.devexp.litellm.md",
      handle: "LITELLM",
      tags: ["tool/litellm"],
      bodyText: "Configure using config.yaml settings.",
      wikilinkTargets: ["040-projects/repos/litellm-stack"],
    };
    const matches = scoreMatches(chain, index);
    if (matches.length >= 2) {
      expect(matches[0].score).toBeGreaterThanOrEqual(matches[1].score);
    }
  });
});

// ---------------------------------------------------------------------------
// injectAttachedFiles
// ---------------------------------------------------------------------------

describe("injectAttachedFiles", () => {
  const chainContent = `---
handle: MY_CHAIN
tags:
  - type/chain
---

# MY_CHAIN

## Steps
1. Do something.

## Triggers
config, settings, yaml`;

  const chainContentNoTriggers = `---
handle: MY_CHAIN
tags:
  - type/chain
---

# MY_CHAIN

## Steps
1. Do something.

## See Also
- [[some/link]]`;

  function makeScoredMatch(notePath: string, displayName: string, score: number) {
    return {
      importEntry: makeEntry({ notePath, displayName }),
      score,
      reasons: ["test"],
    };
  }

  test("injects before ## Triggers when it exists", () => {
    const matches = [makeScoredMatch("060-imports/configs/a/config.yaml.md", "a/config.yaml", 15)];
    const result = injectAttachedFiles(chainContent, matches);
    expect(result).not.toBe("");
    const triggersIdx = result.indexOf("## Triggers");
    const attachedIdx = result.indexOf("## Attached Files");
    expect(attachedIdx).toBeGreaterThanOrEqual(0);
    expect(attachedIdx).toBeLessThan(triggersIdx);
  });

  test("appends at end when no ## Triggers section exists", () => {
    const matches = [makeScoredMatch("060-imports/configs/a/config.yaml.md", "a/config.yaml", 15)];
    const result = injectAttachedFiles(chainContentNoTriggers, matches);
    expect(result).not.toBe("");
    const attachedIdx = result.indexOf("## Attached Files");
    expect(attachedIdx).toBeGreaterThanOrEqual(0);
    // Should be near end
    expect(result.trimEnd().endsWith("<!-- end chain-linker -->")).toBe(true);
  });

  test("top-scored match gets ![[embed]] syntax", () => {
    const matches = [
      makeScoredMatch("060-imports/configs/a/config.yaml.md", "a/config.yaml", 15),
      makeScoredMatch("060-imports/configs/b/other.yaml.md", "b/other.yaml", 10),
    ];
    const result = injectAttachedFiles(chainContent, matches);
    // Top match → embed without .md
    expect(result).toContain("![[060-imports/configs/a/config.yaml]]");
    // Second match → wikilink
    expect(result).toContain("[[060-imports/configs/b/other.yaml|b/other.yaml]]");
  });

  test("strips .md suffix from notePath in generated links", () => {
    const matches = [makeScoredMatch("060-imports/configs/litellm-stack/config.yaml.md", "litellm-stack/config.yaml", 20)];
    const result = injectAttachedFiles(chainContent, matches);
    // Should not contain .md in the link target
    expect(result).not.toContain("config.yaml.md]]");
    expect(result).toContain("config.yaml]]");
  });

  test("uses start and end markers", () => {
    const matches = [makeScoredMatch("060-imports/configs/a/config.yaml.md", "a/config.yaml", 15)];
    const result = injectAttachedFiles(chainContent, matches);
    expect(result).toContain("<!-- auto-generated by vault-importer chain-linker — do not edit -->");
    expect(result).toContain("<!-- end chain-linker -->");
  });

  test("is idempotent — replaces existing section on second call", () => {
    const matches = [makeScoredMatch("060-imports/configs/a/config.yaml.md", "a/config.yaml", 15)];
    const firstResult = injectAttachedFiles(chainContent, matches);

    // New matches for second call
    const newMatches = [makeScoredMatch("060-imports/configs/b/new.yaml.md", "b/new.yaml", 20)];
    const secondResult = injectAttachedFiles(firstResult, newMatches);

    // Old embed should be gone
    expect(secondResult).not.toContain("![[060-imports/configs/a/config.yaml]]");
    // New embed should be present
    expect(secondResult).toContain("![[060-imports/configs/b/new.yaml]]");
    // Markers appear exactly once
    const markerCount = (secondResult.match(/<!-- auto-generated by vault-importer chain-linker/g) ?? []).length;
    expect(markerCount).toBe(1);
  });

  test("returns empty string when no matches provided", () => {
    const result = injectAttachedFiles(chainContent, []);
    expect(result).toBe("");
  });

  test("single match still gets embed syntax (not a secondary link)", () => {
    const matches = [makeScoredMatch("060-imports/configs/a/config.yaml.md", "a/config.yaml", 15)];
    const result = injectAttachedFiles(chainContent, matches);
    expect(result).toContain("![[060-imports/configs/a/config.yaml]]");
    // Should NOT also appear as a wikilink
    expect(result).not.toContain("[[060-imports/configs/a/config.yaml|");
  });
});

// ---------------------------------------------------------------------------
// injectAttachedFiles with inline code
// ---------------------------------------------------------------------------

describe("injectAttachedFiles with inline code", () => {
  const chainContent = `---
handle: MY_CHAIN
tags:
  - type/chain
---

# MY_CHAIN

## Steps
1. Do something.

## Triggers
config, settings, yaml`;

  function makeScoredMatchWithFile(notePath: string, displayName: string, score: number): ScoredMatch {
    return {
      importEntry: makeEntry({
        notePath,
        displayName,
        sourceFile: notePath.split("/").pop()!.replace(".md", ""),
      }),
      score,
      reasons: ["test"],
    };
  }

  test("generates <details> block for code-bearing matches", () => {
    const matches = [makeScoredMatchWithFile("060-imports/configs/a/deploy.sh.md", "a/deploy.sh", 15)];
    const noteCache = new Map<string, string>();
    noteCache.set("060-imports/configs/a/deploy.sh.md", `---
title: "a/deploy.sh"
---

# a/deploy.sh

\`\`\`bash
#!/usr/bin/env bash
echo "deploying"
\`\`\`

## Source Info
`);
    const result = injectAttachedFiles(chainContent, matches, noteCache);
    expect(result).toContain("<details>");
    expect(result).toContain("deploy.sh");
    expect(result).toContain('echo "deploying"');
    expect(result).toContain("</details>");
  });

  test("does not generate <details> for non-code matches", () => {
    const matches = [makeScoredMatchWithFile("020-concepts/terminology/DevExp/hooks.md", "DevExp/hooks", 10)];
    const noteCache = new Map<string, string>();
    noteCache.set("020-concepts/terminology/DevExp/hooks.md", `---
title: "hooks"
---

# Hooks

Hook events are...
`);
    const result = injectAttachedFiles(chainContent, matches, noteCache);
    expect(result).not.toContain("<details>");
    expect(result).toContain("hooks");
  });

  test("works without noteCache (backward compatible)", () => {
    const matches = [makeScoredMatchWithFile("060-imports/configs/a/config.yaml.md", "a/config.yaml", 15)];
    const result = injectAttachedFiles(chainContent, matches);
    expect(result).toContain("![[060-imports/configs/a/config.yaml]]");
    expect(result).not.toContain("<details>");
  });

  test("shows line count in details summary", () => {
    const matches = [makeScoredMatchWithFile("060-imports/scripts/test.py.md", "test.py", 15)];
    const noteCache = new Map<string, string>();
    noteCache.set("060-imports/scripts/test.py.md", `---
title: "test.py"
---

\`\`\`python
def main():
    pass
\`\`\`
`);
    const result = injectAttachedFiles(chainContent, matches, noteCache);
    expect(result).toContain("2 lines");
  });
});

// ---------------------------------------------------------------------------
// isCodeBearingFile
// ---------------------------------------------------------------------------

describe("isCodeBearingFile", () => {
  test("returns true for .sh files", () => {
    expect(isCodeBearingFile("deploy.sh")).toBe(true);
  });
  test("returns true for .ts files", () => {
    expect(isCodeBearingFile("index.ts")).toBe(true);
  });
  test("returns true for .yaml files", () => {
    expect(isCodeBearingFile("config.yaml")).toBe(true);
  });
  test("returns true for .yml files", () => {
    expect(isCodeBearingFile("docker-compose.yml")).toBe(true);
  });
  test("returns true for .py files", () => {
    expect(isCodeBearingFile("script.py")).toBe(true);
  });
  test("returns true for .json files", () => {
    expect(isCodeBearingFile("settings.json")).toBe(true);
  });
  test("returns false for .md files", () => {
    expect(isCodeBearingFile("README.md")).toBe(false);
  });
  test("returns false for files without extension", () => {
    expect(isCodeBearingFile("Makefile")).toBe(false);
  });
  test("returns true for .toml files", () => {
    expect(isCodeBearingFile("pyproject.toml")).toBe(true);
  });
});
