/**
 * litellm.ts — Parse LiteLLM YAML configs and generate Obsidian model registry notes.
 *
 * Reads blue (local) and green (cloud) config.yaml files plus haproxy.cfg,
 * generates structured notes for each model, deployment overviews, and a MOC.
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync } from "fs";
import { parse as parseYaml } from "yaml";

const RESET = "\x1b[0m";
const GREEN = "\x1b[32m";
const BLUE = "\x1b[34m";
const DIM = "\x1b[2m";

interface LiteLLMModel {
  model_name: string;
  litellm_params: {
    model: string;
    api_key?: string;
    api_base?: string;
  };
}

interface LiteLLMConfig {
  model_list: LiteLLMModel[];
  litellm_settings?: Record<string, unknown>;
  general_settings?: Record<string, unknown>;
}

interface ParsedModel {
  name: string;
  litellmModel: string;
  provider: string;
  deployment: "blue" | "green";
  apiBase?: string;
  usesEnvKey: boolean;
  port: number;
}

const CONFIG_PATHS = {
  blue: "/var/home/yish/litellm-stack/blue/config.yaml",
  green: "/var/home/yish/litellm-stack/green/config.yaml",
  router: "/var/home/yish/litellm-stack/router/haproxy.cfg",
};

function detectProvider(model: string): string {
  if (model.startsWith("ollama/")) return "Ollama (local)";
  if (model.startsWith("anthropic/")) return "Anthropic";
  if (model.startsWith("openai/")) return "OpenAI";
  if (model.startsWith("groq/")) return "Groq";
  if (model.startsWith("gemini/")) return "Google Gemini";
  if (model.startsWith("openrouter/")) return "OpenRouter";
  return "Unknown";
}

function slugify(name: string): string {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
}

function parseConfig(
  path: string,
  deployment: "blue" | "green"
): ParsedModel[] {
  const raw = readFileSync(path, "utf-8");
  const config = parseYaml(raw) as LiteLLMConfig;
  const port =
    (config.general_settings?.port as number) ??
    (deployment === "blue" ? 4001 : 4002);

  return config.model_list.map((m) => ({
    name: m.model_name,
    litellmModel: m.litellm_params.model,
    provider: detectProvider(m.litellm_params.model),
    deployment,
    apiBase: m.litellm_params.api_base,
    usesEnvKey: typeof m.litellm_params.api_key === "string" &&
      m.litellm_params.api_key.startsWith("os.environ/"),
    port,
  }));
}

function generateModelNote(model: ParsedModel): string {
  const isLocal = model.provider === "Ollama (local)";
  const routePath = isLocal
    ? `localhost:4000 → haproxy → ${model.port} → ollama:11434`
    : `localhost:4000 → haproxy → ${model.port} → ${model.provider} API`;

  const tags = [
    "model",
    isLocal ? "local" : "cloud",
    slugify(model.provider),
    model.deployment,
  ];

  return `---
title: "${model.name}"
type: model-registry
provider: "${model.provider}"
deployment: ${model.deployment}
port: ${model.port}
litellm_model: "${model.litellmModel}"
tags: [${tags.join(", ")}]
---

# ${model.name}

| Field | Value |
|-------|-------|
| **Provider** | ${model.provider} |
| **LiteLLM Model** | \`${model.litellmModel}\` |
| **Deployment** | ${model.deployment} (port ${model.port}) |
| **Route** | \`${routePath}\` |
| **API Base** | ${model.apiBase ? `\`${model.apiBase}\`` : "Provider default"} |
| **Auth** | ${model.usesEnvKey ? "Environment variable" : isLocal ? "None (local)" : "Direct key"} |

## Backlinks

- [[LITELLM-MOC]] — Model Registry
- [[CONFIGS-MOC]] — Configuration Files
- [[060-imports/configs/litellm-stack/${model.deployment}/config.yaml.md|${model.deployment} config]]
`;
}

function generateDeploymentNote(
  deployment: "blue" | "green",
  models: ParsedModel[],
  config: string
): string {
  const port = models[0]?.port ?? (deployment === "blue" ? 4001 : 4002);
  const isLocal = deployment === "blue";
  const desc = isLocal
    ? "Local Ollama models running on the host GPU"
    : "Cloud API models (Anthropic, OpenAI, Groq, Gemini, OpenRouter)";

  const modelList = models
    .map((m) => `- [[models/${slugify(m.name)}|${m.name}]] — \`${m.litellmModel}\``)
    .join("\n");

  return `---
title: "${deployment} deployment"
type: deployment-overview
deployment: ${deployment}
port: ${port}
tags: [litellm, deployment, ${deployment}]
---

# ${deployment.charAt(0).toUpperCase() + deployment.slice(1)} Deployment

> ${desc}

| Field | Value |
|-------|-------|
| **Port** | ${port} |
| **Models** | ${models.length} |
| **Type** | ${isLocal ? "Local (Ollama)" : "Cloud APIs"} |
| **Config** | \`~/litellm-stack/${deployment}/config.yaml\` |

## Models

${modelList}

## Raw Config

\`\`\`yaml
${config}
\`\`\`

## Backlinks

- [[LITELLM-MOC]] — Model Registry
- [[router|Router Config]]
`;
}

function generateRouterNote(haproxyConfig: string): string {
  return `---
title: "LiteLLM Router (HAProxy)"
type: router-config
tags: [litellm, router, haproxy]
---

# LiteLLM Router

> HAProxy reverse proxy routing traffic to the active LiteLLM deployment.

| Field | Value |
|-------|-------|
| **Frontend** | \`*:4000\` |
| **Active Backend** | \`127.0.0.1:4001\` (blue) |
| **Stats** | \`http://localhost:4099/stats\` |
| **Config** | \`~/litellm-stack/router/haproxy.cfg\` |

## Route Flow

\`\`\`
Client → :4000 (haproxy) → :4001 (blue/local) or :4002 (green/cloud)
                         └→ :4099 (stats dashboard)
\`\`\`

## Raw Config

\`\`\`haproxy
${haproxyConfig}
\`\`\`

## Backlinks

- [[LITELLM-MOC]] — Model Registry
- [[blue-deployment|Blue Deployment]]
- [[green-deployment|Green Deployment]]
`;
}

function generateMoc(
  blueModels: ParsedModel[],
  greenModels: ParsedModel[]
): string {
  const allModels = [...blueModels, ...greenModels];
  const byProvider = new Map<string, ParsedModel[]>();
  for (const m of allModels) {
    const list = byProvider.get(m.provider) ?? [];
    list.push(m);
    byProvider.set(m.provider, list);
  }

  const providerSections = [...byProvider.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([provider, models]) => {
      const items = models
        .map(
          (m) =>
            `- [[models/${slugify(m.name)}|${m.name}]] — \`${m.litellmModel}\` (${m.deployment}:${m.port})`
        )
        .join("\n");
      return `### ${provider}\n\n${items}`;
    })
    .join("\n\n");

  const now = new Date().toISOString();

  return `---
title: LITELLM MOC
tags: [MOC, litellm, model-registry]
type: index
updated: ${now}
---

# LITELLM MOC

> Model registry for the LiteLLM blue-green deployment stack.

## Overview

| Metric | Value |
|--------|-------|
| **Total models** | ${allModels.length} |
| **Blue (local)** | ${blueModels.length} models on port 4001 |
| **Green (cloud)** | ${greenModels.length} models on port 4002 |
| **Router** | HAProxy on port 4000 |
| **Last generated** | ${now} |

## Deployments

- [[routes/blue-deployment|Blue Deployment]] — Local Ollama models (port 4001)
- [[routes/green-deployment|Green Deployment]] — Cloud API models (port 4002)
- [[routes/router|Router Config]] — HAProxy routing (port 4000)

## Models by Provider

${providerSections}

## Backlinks

- [[DASHBOARD]] — Main navigation
- [[CONFIGS-MOC]] — Configuration files
- [[060-imports/IMPORTS-MOC]] — Auto-imported files

---

*Auto-generated by vault-importer \`litellm\` command. Do not edit manually.*
`;
}

// --- Main export ---

export interface LiteLLMGenerateResult {
  filesWritten: number;
  models: number;
}

export function generateLiteLLMRegistry(
  vaultRoot: string,
  dryRun: boolean = false
): LiteLLMGenerateResult {
  const outBase = `${vaultRoot}/060-imports/litellm`;
  const modelsDir = `${outBase}/models`;
  const routesDir = `${outBase}/routes`;

  if (!dryRun) {
    mkdirSync(modelsDir, { recursive: true });
    mkdirSync(routesDir, { recursive: true });
  }

  let filesWritten = 0;

  // Parse configs
  const blueModels = parseConfig(CONFIG_PATHS.blue, "blue");
  const greenModels = parseConfig(CONFIG_PATHS.green, "green");
  const allModels = [...blueModels, ...greenModels];

  console.log(
    `${BLUE}[litellm]${RESET} Found ${blueModels.length} blue + ${greenModels.length} green models`
  );

  // Generate model notes
  for (const model of allModels) {
    const slug = slugify(model.name);
    const path = `${modelsDir}/${slug}.md`;
    const content = generateModelNote(model);

    if (!dryRun) {
      writeFileSync(path, content, "utf-8");
    }
    console.log(
      `  ${GREEN}✨${RESET} ${DIM}models/${slug}.md${RESET}`
    );
    filesWritten++;
  }

  // Generate deployment notes
  const blueConfig = readFileSync(CONFIG_PATHS.blue, "utf-8");
  const greenConfig = readFileSync(CONFIG_PATHS.green, "utf-8");

  if (!dryRun) {
    writeFileSync(
      `${routesDir}/blue-deployment.md`,
      generateDeploymentNote("blue", blueModels, blueConfig),
      "utf-8"
    );
    writeFileSync(
      `${routesDir}/green-deployment.md`,
      generateDeploymentNote("green", greenModels, greenConfig),
      "utf-8"
    );
  }
  console.log(`  ${GREEN}✨${RESET} ${DIM}routes/blue-deployment.md${RESET}`);
  console.log(`  ${GREEN}✨${RESET} ${DIM}routes/green-deployment.md${RESET}`);
  filesWritten += 2;

  // Generate router note
  const haproxyConfig = existsSync(CONFIG_PATHS.router)
    ? readFileSync(CONFIG_PATHS.router, "utf-8")
    : "# haproxy config not found";

  if (!dryRun) {
    writeFileSync(
      `${routesDir}/router.md`,
      generateRouterNote(haproxyConfig),
      "utf-8"
    );
  }
  console.log(`  ${GREEN}✨${RESET} ${DIM}routes/router.md${RESET}`);
  filesWritten++;

  // Generate MOC
  if (!dryRun) {
    writeFileSync(
      `${outBase}/LITELLM-MOC.md`,
      generateMoc(blueModels, greenModels),
      "utf-8"
    );
  }
  console.log(`  ${GREEN}📋${RESET} ${DIM}LITELLM-MOC.md${RESET}`);
  filesWritten++;

  return { filesWritten, models: allModels.length };
}
