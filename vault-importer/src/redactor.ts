const SENSITIVE_KEY_PATTERNS = [
  /passw(or)?d/i,
  /secret/i,
  /token/i,
  /api[_-]?key/i,
  /credentials?/i,
  /auth/i,
  /bearer/i,
  /private[_-]?key/i,
  /access[_-]?key/i,
  /client[_-]?secret/i,
  /signing[_-]?key/i,
  /encryption[_-]?key/i,
  /database[_-]?url/i,
  /connection[_-]?string/i,
  /smtp/i,
  /webhook/i,
];

const SECRET_VALUE_PATTERNS = [
  /^(sk|pk|ghp|gho|ghs|ghu|glpat|xoxb|xoxp|xoxs)[-_][A-Za-z0-9]{20,}/,
  /^eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/,
  /^[A-Fa-f0-9]{32,}$/,
  /^AKIA[0-9A-Z]{16}$/,
];

function isSensitiveKey(key: string): boolean {
  return SENSITIVE_KEY_PATTERNS.some((p) => p.test(key));
}

function isSensitiveValue(value: string): boolean {
  return SECRET_VALUE_PATTERNS.some((p) => p.test(value.trim()));
}

export function redactEnvContent(content: string): string {
  return content
    .split("\n")
    .map((line) => {
      const trimmed = line.trim();
      if (trimmed.startsWith("#") || !trimmed.includes("=")) return line;

      const eqIndex = line.indexOf("=");
      const key = line.slice(0, eqIndex);
      const value = line.slice(eqIndex + 1);

      if (value.trim() === "" || value.trim() === '""' || value.trim() === "''")
        return line;

      return `${key}=[REDACTED]`;
    })
    .join("\n");
}

export function redactJsonContent(content: string): string {
  try {
    const obj = JSON.parse(content);
    const redacted = redactObject(obj);
    return JSON.stringify(redacted, null, 2);
  } catch {
    return redactLineLevel(content);
  }
}

function redactObject(obj: unknown): unknown {
  if (obj === null || obj === undefined) return obj;
  if (typeof obj === "string") return obj;
  if (typeof obj === "number" || typeof obj === "boolean") return obj;

  if (Array.isArray(obj)) {
    return obj.map((item) => redactObject(item));
  }

  if (typeof obj === "object") {
    const result: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(obj as Record<string, unknown>)) {
      if (isSensitiveKey(key) && typeof value === "string" && value.length > 0) {
        result[key] = "[REDACTED]";
      } else if (typeof value === "string" && isSensitiveValue(value)) {
        result[key] = "[REDACTED]";
      } else {
        result[key] = redactObject(value);
      }
    }
    return result;
  }

  return obj;
}

export function redactYamlContent(content: string): string {
  return redactLineLevel(content);
}

function redactLineLevel(content: string): string {
  return content
    .split("\n")
    .map((line) => {
      const trimmed = line.trim();
      if (trimmed.startsWith("#") || trimmed === "") return line;

      const kvMatch = trimmed.match(/^(["\s\w._-]+)\s*[:=]\s*(.+)$/);
      if (!kvMatch) return line;

      const [, key, value] = kvMatch;
      const cleanKey = key.trim().replace(/["']/g, "");
      const cleanValue = value.trim().replace(/["']/g, "");

      if (
        (isSensitiveKey(cleanKey) && cleanValue.length > 0) ||
        isSensitiveValue(cleanValue)
      ) {
        const prefix = line.slice(0, line.indexOf(key.trim()));
        const separator = line.includes(": ") ? ": " : line.includes("=") ? "=" : ": ";
        return `${prefix}${key.trim()}${separator}[REDACTED]`;
      }

      return line;
    })
    .join("\n");
}

export function redactContent(
  content: string,
  transform: "env" | "config" | "markdown" | "code",
  filePath: string
): string {
  if (transform === "env" || filePath.includes(".env")) {
    return redactEnvContent(content);
  }

  const ext = filePath.split(".").pop()?.toLowerCase() ?? "";

  if (ext === "json") return redactJsonContent(content);
  if (["yaml", "yml", "toml", "ini", "conf"].includes(ext))
    return redactYamlContent(content);

  return redactLineLevel(content);
}
