import { describe, test, expect } from "bun:test";
import {
  parseFrontmatter,
  splitByHeading,
  groupSections,
  slugify,
  isAtomizationCandidate,
} from "../splitter";

describe("parseFrontmatter", () => {
  test("extracts frontmatter and body", () => {
    const content = `---
title: "Test"
tags: [research]
---

# Heading

Body text here.`;
    const { frontmatter, body } = parseFrontmatter(content);
    expect(frontmatter.title).toBe("Test");
    expect(body).toContain("# Heading");
    expect(body).toContain("Body text here.");
  });

  test("handles no frontmatter", () => {
    const content = "# Just a heading\n\nSome text.";
    const { frontmatter, body } = parseFrontmatter(content);
    expect(frontmatter).toEqual({});
    expect(body).toBe(content);
  });
});

describe("splitByHeading", () => {
  test("splits on H2 boundaries", () => {
    const body = `# Title

Intro text.

## Section One

Content one.

## Section Two

Content two.

## Section Three

Content three.`;
    const { intro, sections } = splitByHeading(body, 2);
    expect(intro).toContain("Intro text.");
    expect(sections).toHaveLength(3);
    expect(sections[0].heading).toBe("## Section One");
    expect(sections[0].content).toContain("Content one.");
  });

  test("falls back to H3 when no H2s", () => {
    const body = `# Title

### Sub One

Content.

### Sub Two

More content.

### Sub Three

Even more.`;
    const { sections } = splitByHeading(body, 3);
    expect(sections).toHaveLength(3);
  });
});

describe("groupSections", () => {
  test("returns sections as-is when <= maxGroups", () => {
    const sections = [
      { heading: "## A", content: "a" },
      { heading: "## B", content: "b" },
      { heading: "## C", content: "c" },
    ];
    const groups = groupSections(sections, 5);
    expect(groups).toHaveLength(3);
  });

  test("groups sections when too many", () => {
    const sections = Array.from({ length: 12 }, (_, i) => ({
      heading: `## Section ${i + 1}`,
      content: `Content ${i + 1}\n`.repeat(10),
    }));
    const groups = groupSections(sections, 5);
    expect(groups.length).toBeGreaterThanOrEqual(3);
    expect(groups.length).toBeLessThanOrEqual(5);
  });
});

describe("slugify", () => {
  test("converts heading to kebab-case", () => {
    expect(slugify("## 1. Community GGUF Availability Check")).toBe(
      "community-gguf-availability-check"
    );
  });

  test("strips wiki links", () => {
    expect(slugify("## [[Ollama]] Import & Modelfile")).toBe(
      "ollama-import-modelfile"
    );
  });

  test("truncates long slugs", () => {
    const long = "## " + "a".repeat(100);
    expect(slugify(long).length).toBeLessThanOrEqual(60);
  });
});

describe("isAtomizationCandidate", () => {
  test("accepts large file with enough sections", () => {
    const content = `---
title: "Big Report"
tags: [research]
---
` + Array.from({ length: 5 }, (_, i) => `\n## Section ${i}\n\n${"Line\n".repeat(80)}`).join("");
    expect(
      isAtomizationCandidate(content, "report.md", "/path/to/01-RESEARCH/AI-Safety", 300)
    ).toBe(true);
  });

  test("rejects MOC files", () => {
    const content = "---\ntitle: MOC\n---\n" + "x\n".repeat(500);
    expect(
      isAtomizationCandidate(content, "AI-Safety-MOC.md", "/path", 300)
    ).toBe(false);
  });

  test("rejects files with atomized: true", () => {
    const content = `---
title: "Done"
atomized: true
---
` + "x\n".repeat(500);
    expect(
      isAtomizationCandidate(content, "report.md", "/path", 300)
    ).toBe(false);
  });

  test("rejects already-atomized files (subfolder exists)", () => {
    const content = `---\ntitle: Test\n---\n` + Array.from({ length: 5 }, (_, i) => `\n## S${i}\n\n${"L\n".repeat(80)}`).join("");
    expect(
      isAtomizationCandidate(content, "report.md", "/path", 300, true)
    ).toBe(false);
  });
});
