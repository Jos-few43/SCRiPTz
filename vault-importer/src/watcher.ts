import chokidar, { type FSWatcher } from "chokidar";
import { resolve } from "path";
import type { Manifest, ResolvedFile } from "./manifest";
import { transformFile } from "./transformer";
import { writeImportedFile } from "./linker";

function expandTilde(p: string, homeDir: string): string {
  return p.startsWith("~/") ? p.replace("~", homeDir) : p;
}

export function startWatcher(
  manifest: Manifest,
  onImport: (action: string, path: string) => void
): FSWatcher {
  const watchPaths: string[] = [];
  const watchSources = manifest.sources.filter((s) => s.watch);

  for (const source of watchSources) {
    for (const p of source.paths) {
      watchPaths.push(expandTilde(p, manifest.homeDir));
    }
  }

  const ignorePatterns = watchSources.flatMap((s) =>
    s.exclude.map((e) => expandTilde(e, manifest.homeDir))
  );

  const watcher = chokidar.watch(watchPaths, {
    ignored: [
      ...ignorePatterns,
      /node_modules/,
    ],
    persistent: true,
    ignoreInitial: true,
    awaitWriteFinish: {
      stabilityThreshold: 1000,
      pollInterval: 100,
    },
  });

  const handleChange = (filePath: string) => {
    const absPath = resolve(filePath);
    const relativePath = absPath.replace(manifest.homeDir + "/", "");

    const source = watchSources.find((s) =>
      s.paths.some((p) => {
        const expanded = expandTilde(p, manifest.homeDir);
        const globBase = expanded.split("*")[0];
        return absPath.startsWith(globBase);
      })
    );

    if (!source) return;

    const resolved: ResolvedFile = {
      absolutePath: absPath,
      relativePath,
      source,
    };

    try {
      const result = transformFile(resolved);
      const { action, path } = writeImportedFile(result, manifest.vaultRoot);
      onImport(action, path);
    } catch (err) {
      console.error(`[watch] Error importing ${absPath}:`, err);
    }
  };

  watcher
    .on("change", handleChange)
    .on("add", handleChange)
    .on("ready", () => {
      console.log(
        `[watch] Watching ${watchPaths.length} glob patterns for changes...`
      );
    });

  return watcher;
}
