import { describe, test, expect } from "bun:test";
import { extractCodeBlock } from "../utils";

describe("extractCodeBlock", () => {
  test("extracts fenced code block with language", () => {
    const content = `---
title: "my-script.sh"
---

# my-script.sh

\`\`\`bash
#!/usr/bin/env bash
echo "hello"
\`\`\`

## Source Info
`;
    const result = extractCodeBlock(content);
    expect(result).not.toBeNull();
    expect(result!.language).toBe("bash");
    expect(result!.code).toContain('echo "hello"');
    expect(result!.lineCount).toBe(2);
  });

  test("extracts first code block when multiple exist", () => {
    const content = `---
title: "test.py"
---

# test.py

\`\`\`python
def hello():
    print("hi")
\`\`\`

## Source Info

\`\`\`bash
pip install something
\`\`\`
`;
    const result = extractCodeBlock(content);
    expect(result).not.toBeNull();
    expect(result!.language).toBe("python");
    expect(result!.code).toContain("def hello()");
  });

  test("returns null when no code block exists", () => {
    const content = `---
title: "notes.md"
---

# Some Notes

Just plain text here.
`;
    const result = extractCodeBlock(content);
    expect(result).toBeNull();
  });

  test("handles code block without language specifier", () => {
    const content = `---
title: "config"
---

\`\`\`
some content
\`\`\`
`;
    const result = extractCodeBlock(content);
    expect(result).not.toBeNull();
    expect(result!.language).toBe("");
    expect(result!.code).toBe("some content");
  });

  test("counts lines correctly for multi-line code", () => {
    const content = `\`\`\`yaml
key1: value1
key2: value2
key3: value3
nested:
  sub: val
\`\`\``;
    const result = extractCodeBlock(content);
    expect(result).not.toBeNull();
    expect(result!.lineCount).toBe(5);
  });
});
