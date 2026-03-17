import { loadManifest, resolveFiles } from "./manifest";
import { transformFile } from "./transformer";
import { writeImportedFile, generateImportsMoc } from "./linker";
import { startWatcher } from "./watcher";
import { generateLiteLLMRegistry } from "./litellm";
import { runOrphanCheck } from "./orphans";
import { runChainLinker } from "./chain-linker";
import { runCommandsSync } from "./commands";
import type { TransformResult } from "./transformer";

const RESET = "\x1b[0m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const BLUE = "\x1b[34m";
const DIM = "\x1b[2m";

function log(icon: string, msg: string) {
  console.log(`${icon} ${msg}`);
}

async function runSync(options: {
  dryRun: boolean;
  force: boolean;
}): Promise<TransformResult[]> {
  const manifest = loadManifest();
  log("📦", `Loading manifest: ${manifest.sources.length} source groups`);

  const files = await resolveFiles(manifest);
  log("🔍", `Resolved ${files.length} files to import`);

  const results: TransformResult[] = [];
  const stats = { created: 0, updated: 0, skipped: 0, errors: 0 };

  for (const file of files) {
    try {
      const result = transformFile(file);
      results.push(result);

      const { action, path } = writeImportedFile(
        result,
        manifest.vaultRoot,
        options.dryRun
      );

      // Force mode: treat skipped as updated (rewrite anyway)
      let finalAction = action;
      if (options.force && action === "skipped") {
        finalAction = "updated";
        if (!options.dryRun) {
          const { writeFileSync } = await import("fs");
          const fullPath = `${manifest.vaultRoot}/${result.destPath}`;
          writeFileSync(fullPath, result.content, "utf-8");
        }
      }

      stats[finalAction as keyof typeof stats]++;

      if (finalAction !== "skipped") {
        const color = finalAction === "created" ? GREEN : YELLOW;
        log(
          finalAction === "created" ? "✨" : "🔄",
          `${color}${finalAction}${RESET} ${DIM}${path}${RESET}`
        );
      }
    } catch (err) {
      stats.errors++;
      console.error(`❌ Error processing ${file.absolutePath}:`, err);
    }
  }

  // Generate MOC
  if (!options.dryRun) {
    generateImportsMoc(results, manifest.vaultRoot);
    log("📋", "Updated IMPORTS-MOC.md");
  }

  console.log(
    `\n${GREEN}Done!${RESET} Created: ${stats.created} | Updated: ${stats.updated} | Skipped: ${stats.skipped} | Errors: ${stats.errors}`
  );

  if (options.dryRun) {
    console.log(`${YELLOW}(dry run — no files were written)${RESET}`);
  }

  return results;
}

async function runWatch(): Promise<void> {
  const manifest = loadManifest();
  log("👁️", "Starting filesystem watcher...");

  startWatcher(manifest, (action, path) => {
    const color = action === "created" ? GREEN : action === "updated" ? YELLOW : DIM;
    log("⚡", `${color}${action}${RESET} ${DIM}${path}${RESET}`);
  });

  // Keep process alive
  await new Promise(() => {});
}

// --- CLI ---
const args = process.argv.slice(2);
const command = args[0] ?? "both";
const dryRun = args.includes("--dry-run");
const force = args.includes("--force");

console.log(`${BLUE}╔══════════════════════════════════════╗${RESET}`);
console.log(`${BLUE}║   OpenClaw Vault Importer v1.0.0     ║${RESET}`);
console.log(`${BLUE}╚══════════════════════════════════════╝${RESET}\n`);

switch (command) {
  case "sync":
    await runSync({ dryRun, force });
    break;

  case "watch":
    await runWatch();
    break;

  case "litellm": {
    const manifest = loadManifest();
    log("🔧", "Generating LiteLLM model registry...");
    const result = generateLiteLLMRegistry(manifest.vaultRoot, dryRun);
    console.log(
      `\n${GREEN}Done!${RESET} Generated ${result.filesWritten} files for ${result.models} models`
    );
    if (dryRun) {
      console.log(`${YELLOW}(dry run — no files were written)${RESET}`);
    }
    break;
  }

  case "orphans": {
    const manifest = loadManifest();
    log("🔍", "Scanning for orphaned notes...");
    await runOrphanCheck(manifest.vaultRoot);
    break;
  }

  case "link-chains": {
    const manifest = loadManifest();
    const noCode = args.includes("--no-code");
    log("🔗", `Running chain-linker...${noCode ? " (no inline code)" : ""}`);
    const linkStats = await runChainLinker(manifest.vaultRoot, dryRun, { noCode });
    console.log(
      `\n${GREEN}Done!${RESET} Scanned: ${linkStats.chainsScanned} | Updated: ${linkStats.chainsUpdated} | Skipped: ${linkStats.chainsSkipped} | Matches: ${linkStats.totalMatches}`
    );
    if (dryRun) {
      console.log(`${YELLOW}(dry run — no files were written)${RESET}`);
    }
    break;
  }

  case "commands": {
    const cmdManifest = loadManifest();
    runCommandsSync(cmdManifest.vaultRoot, dryRun);
    break;
  }

  case "both":
  default:
    await runSync({ dryRun, force });
    if (!dryRun) {
      console.log("");
      await runWatch();
    }
    break;
}
