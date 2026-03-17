import { readFileSync, statSync } from "fs";
import { createHash } from "crypto";
import { basename, extname } from "path";
import { redactContent } from "./redactor";
import type { ResolvedFile } from "./manifest";

const EXT_TO_LANG: Record<string, string> = {
  ".ts": "typescript",
  ".js": "javascript",
  ".py": "python",
  ".sh": "bash",
  ".bash": "bash",
  ".zsh": "zsh",
  ".json": "json",
  ".yaml": "yaml",
  ".yml": "yaml",
  ".toml": "toml",
  ".ini": "ini",
  ".conf": "conf",
  ".md": "markdown",
  ".env": "bash",
  ".gitconfig": "ini",
  ".bashrc": "bash",
};

function detectLanguage(filePath: string): string {
  const ext = extname(filePath).toLowerCase();
  if (EXT_TO_LANG[ext]) return EXT_TO_LANG[ext];

  const name = basename(filePath).toLowerCase();
  if (name.startsWith(".env")) return "bash";
  if (name === ".bashrc" || name === ".bash_profile") return "bash";
  if (name === ".gitconfig") return "ini";

  return "";
}

function computeChecksum(content: string): string {
  return createHash("md5").update(content).digest("hex");
}

function getMocLink(sourceName: string): string {
  const mocMap: Record<string, string> = {
    instructions: "KNOWLEDGE-MOC",
    configs: "CONFIGS-MOC",
    scripts: "COMMANDS-MOC",
    skills: "KNOWLEDGE-MOC",
    projects: "PROJECTS-MOC",
    dotfiles: "CONFIGS-MOC",
    "env-files": "CONFIGS-MOC",
    "python-scripts": "COMMANDS-MOC",
    "vault-scripts": "COMMANDS-MOC",
    "vault-importer-src": "KNOWLEDGE-MOC",
  };
  return mocMap[sourceName] ?? "KNOWLEDGE-MOC";
}

function detectProject(relativePath: string): string | null {
  // Match PROJECTz/{project-name}/... or SCRiPTz/...
  const projectMatch = relativePath.match(/^PROJECTz\/([^/]+)\//);
  if (projectMatch) return projectMatch[1];
  if (relativePath.startsWith("SCRiPTz/")) return null;
  // Standalone files in PROJECTz/ root (e.g. PROJECTz/dashboard.py)
  return null;
}

export interface TransformResult {
  content: string;
  checksum: string;
  destPath: string;
}

export function transformFile(file: ResolvedFile): TransformResult {
  const rawContent = readFileSync(file.absolutePath, "utf-8");
  const stat = statSync(file.absolutePath);

  const processedContent = file.source.redact
    ? redactContent(rawContent, file.source.transform, file.absolutePath)
    : rawContent;

  const checksum = computeChecksum(rawContent);
  const lang = detectLanguage(file.absolutePath);
  const now = new Date().toISOString();
  const sourceModified = stat.mtime.toISOString();
  const mocLink = getMocLink(file.source.name);

  const isMarkdownSource =
    file.source.transform === "markdown" && extname(file.absolutePath) === ".md";

  let body: string;
  if (isMarkdownSource) {
    const stripped = processedContent.replace(/^---[\s\S]*?---\n*/m, "");
    body = stripped;
  } else {
    body = `\`\`\`${lang}\n${processedContent}\n\`\`\``;
  }

  const tags = [...file.source.tags];
  if (file.source.redact) tags.push("redacted");
  tags.push("source/auto-generated", "lifecycle/active");

  const tagLines = tags.map(t => `  - ${t}`).join("\n");

  const frontmatter = [
    "---",
    `title: "${file.relativePath}"`,
    `source: "${file.absolutePath}"`,
    `imported: ${now}`,
    `updated: ${now}`,
    `source_modified: ${sourceModified}`,
    `checksum: ${checksum}`,
    `tags:\n${tagLines}`,
    `redacted: ${file.source.redact}`,
    "---",
  ].join("\n");

  const project = detectProject(file.relativePath);
  const projectLink = project ? `\n- **Project**: [[040-projects/repos/${project}|${project}]]` : "";

  const note = `${frontmatter}

# ${file.relativePath}

> Imported from \`~/${file.relativePath}\`

${body}

## Source Info
- **Path**: \`~/${file.relativePath}\`
- **Category**: [[${mocLink}]]${projectLink}
- **Last synced**: ${now}
`;

  const destPath = file.relativePath.endsWith(".md")
    ? `${file.source.dest}/${file.relativePath}`
    : `${file.source.dest}/${file.relativePath}.md`;

  return {
    content: note,
    checksum,
    destPath,
  };
}
