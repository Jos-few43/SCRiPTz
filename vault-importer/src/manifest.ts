import { readFileSync } from "fs";
import { glob } from "glob";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";

export interface SourceEntry {
  name: string;
  paths: string[];
  exclude: string[];
  dest: string;
  transform: "markdown" | "config" | "code" | "env";
  watch: boolean;
  redact: boolean;
  tags: string[];
}

export interface Manifest {
  vaultRoot: string;
  homeDir: string;
  sources: SourceEntry[];
}

export function loadManifest(): Manifest {
  const manifestPath = resolve(
    dirname(fileURLToPath(import.meta.url)),
    "../import-manifest.json"
  );
  const raw = readFileSync(manifestPath, "utf-8");
  return JSON.parse(raw) as Manifest;
}

function expandTilde(p: string, homeDir: string): string {
  return p.startsWith("~/") ? p.replace("~", homeDir) : p;
}

export interface ResolvedFile {
  absolutePath: string;
  relativePath: string;
  source: SourceEntry;
}

function buildExcludeFilter(excludes: string[]): (path: string) => boolean {
  // Convert **/{segment}/** patterns to path-contains checks
  // The glob library's string ignore doesn't reliably match these with absolute paths
  const segments = excludes
    .filter((e) => e.startsWith("**/") && e.endsWith("/**"))
    .map((e) => e.slice(3, -3)); // extract the middle segment

  // Also handle **/filename patterns (no trailing /**)
  const filenamePatterns = excludes
    .filter((e) => e.startsWith("**/") && !e.endsWith("/**") && !e.includes("/", 3))
    .map((e) => e.slice(3)); // extract filename

  return (filePath: string) => {
    for (const seg of segments) {
      if (filePath.includes(`/${seg}/`)) return true;
    }
    for (const name of filenamePatterns) {
      if (filePath.endsWith(`/${name}`)) return true;
    }
    return false;
  };
}

export async function resolveFiles(manifest: Manifest): Promise<ResolvedFile[]> {
  const results: ResolvedFile[] = [];

  for (const source of manifest.sources) {
    const expandedPaths = source.paths.map((p) =>
      expandTilde(p, manifest.homeDir)
    );
    const expandedExcludes = source.exclude.map((p) =>
      expandTilde(p, manifest.homeDir)
    );

    // Split excludes: glob handles tilde-expanded ones, we post-filter ** patterns
    const globExcludes = expandedExcludes.filter(
      (e) => !(e.startsWith("**/"))
    );

    const files = await glob(expandedPaths, {
      ignore: globExcludes,
      nodir: true,
      absolute: true,
    });

    const shouldExclude = buildExcludeFilter(source.exclude);

    for (const file of files) {
      if (shouldExclude(file)) continue;
      const relativePath = file.replace(manifest.homeDir + "/", "");
      results.push({
        absolutePath: file,
        relativePath,
        source,
      });
    }
  }

  return results;
}
