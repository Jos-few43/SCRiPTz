#!/usr/bin/env bash
set -euo pipefail

# vault-gap-scanner.sh — Scan an Obsidian vault for knowledge gaps
# Output: JSON array of gaps sorted by priority, limited to top 20

VAULT="${VAULT_PATH:-$HOME/Documents/OpenClaw-Vault}"

# Validate vault exists
if [[ ! -d "$VAULT" ]]; then
  echo '[]'
  exit 0
fi

# Temp dir for intermediate data
TMPDIR_SCAN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SCAN"' EXIT

###############################################################################
# Phase 1: Build file indexes (fast, one-time)
###############################################################################

# All .md files as relative paths without .md extension
find "$VAULT" -not -type l -name '*.md' -print0 2>/dev/null \
  | while IFS= read -r -d '' f; do
      rel="${f#"$VAULT"/}"
      echo "${rel%.md}"
    done \
  | sort -u > "$TMPDIR_SCAN/all_files.txt"

# Basenames only (for bare wikilink resolution)
awk -F/ '{print $NF}' "$TMPDIR_SCAN/all_files.txt" \
  | sort -u > "$TMPDIR_SCAN/all_basenames.txt"

###############################################################################
# Phase 2: Extract all wikilinks from 00-INDEX/ and 01-RESEARCH/ in bulk
###############################################################################

# Output format: source_rel_path<TAB>raw_link
# This avoids per-file grep loops
extract_wikilinks() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -not -type l -name '*.md' -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        local rel="${f#"$VAULT"/}"
        local base
        base="$(basename "$rel")"
        # Skip excluded files
        [[ "$base" == "TOPICS.md" ]] && continue
        [[ "$base" == "RESEARCH-MOC.md" ]] && continue
        [[ "$rel" == 12-LOGS/* ]] && continue
        # Extract wikilinks and prefix with source path
        grep -oP '\[\[\K[^\]]+' "$f" 2>/dev/null | while IFS= read -r raw; do
          printf '%s\t%s\n' "$rel" "$raw"
        done
      done
}

extract_wikilinks "$VAULT/00-INDEX" > "$TMPDIR_SCAN/wikilinks_raw.tsv"
extract_wikilinks "$VAULT/01-RESEARCH" >> "$TMPDIR_SCAN/wikilinks_raw.tsv"

###############################################################################
# Phase 3: Process wikilinks — find dead links and MOC gaps
###############################################################################

# First: clean raw wikilinks (strip display name, backslash, filter skipped patterns)
awk -F'\t' '{
  target = $2
  # Strip display name after |
  sub(/\|.*/, "", target)
  # Strip trailing backslash
  sub(/\\$/, "", target)
  # Skip filtered patterns
  if (target ~ /http/) next
  if (target ~ /#/) next
  if (target ~ /03-DAILY/) next
  if (target == "") next
  print $1 "\t" target
}' "$TMPDIR_SCAN/wikilinks_raw.tsv" > "$TMPDIR_SCAN/wikilinks_clean.tsv"

# Use awk to do bulk set-difference: check each link against file sets
awk -F'\t' '
  # Load full paths (NR==FNR for first file)
  FILENAME == ARGV[1] { full[$0] = 1; next }
  # Load basenames (second file)
  FILENAME == ARGV[2] { bases[$0] = 1; next }
  # Process wikilinks (third file)
  {
    src = $1; target = $2
    # Check full path
    if (target in full) next
    # Check basename (last component)
    n = split(target, parts, "/")
    base = parts[n]
    if (base in bases) next
    # Dead link
    print src "\t" target
  }
' "$TMPDIR_SCAN/all_files.txt" "$TMPDIR_SCAN/all_basenames.txt" "$TMPDIR_SCAN/wikilinks_clean.tsv" \
  > "$TMPDIR_SCAN/dead_links.tsv"

###############################################################################
# Phase 4: Detect stubs in 01-RESEARCH/
###############################################################################

> "$TMPDIR_SCAN/stubs.tsv"

if [[ -d "$VAULT/01-RESEARCH" ]]; then
  find "$VAULT/01-RESEARCH" -not -type l -name '*.md' -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        rel="${f#"$VAULT"/}"
        base="$(basename "$rel")"
        [[ "$base" == "TOPICS.md" ]] && continue
        [[ "$base" == "RESEARCH-MOC.md" ]] && continue

        lines="$(wc -l < "$f")"
        if (( lines < 5 )); then
          printf '%s\t%s\n' "$rel" "File has only $lines lines"
        elif grep -qPi '#stub|TODO|TBD|needs-research' "$f" 2>/dev/null; then
          printf '%s\t%s\n' "$rel" "Contains stub marker"
        fi
      done > "$TMPDIR_SCAN/stubs.tsv"
fi

###############################################################################
# Phase 5: Detect stale files (90+ days) in 01-RESEARCH/
###############################################################################

> "$TMPDIR_SCAN/stale.tsv"

if [[ -d "$VAULT/01-RESEARCH" ]]; then
  cutoff_date="$(date -d '90 days ago' +%Y-%m-%d)"
  now_epoch="$(date +%s)"
  find "$VAULT/01-RESEARCH" -not -type l -name '*.md' -not -newermt "$cutoff_date" -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        rel="${f#"$VAULT"/}"
        base="$(basename "$rel")"
        [[ "$base" == "TOPICS.md" ]] && continue
        [[ "$base" == "RESEARCH-MOC.md" ]] && continue

        mtime="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
        days_ago=$(( (now_epoch - mtime) / 86400 ))
        printf '%s\t%s\n' "$rel" "Not modified in ${days_ago} days"
      done > "$TMPDIR_SCAN/stale.tsv"
fi

###############################################################################
# Phase 6: Detect bare terms (terminology with no research reference)
###############################################################################

> "$TMPDIR_SCAN/bare_terms.tsv"

if [[ -d "$VAULT/06-TERMINOLOGY" && -d "$VAULT/01-RESEARCH" ]]; then
  # Pre-extract all wikilink basenames from research files (once)
  find "$VAULT/01-RESEARCH" -not -type l -name '*.md' -print0 2>/dev/null \
    | xargs -0 grep -ohP '\[\[\K[^\]]+' 2>/dev/null \
    | sed 's/|.*//' \
    | sed 's/.*\///' \
    | sort -u > "$TMPDIR_SCAN/research_link_basenames.txt"

  find "$VAULT/06-TERMINOLOGY" -not -type l -name '*.md' -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        rel="${f#"$VAULT"/}"
        base_name="$(basename "$rel" .md)"
        if ! grep -qF "$base_name" "$TMPDIR_SCAN/research_link_basenames.txt" 2>/dev/null; then
          printf '%s\t%s\n' "$rel" "No reference to [[$base_name]] found in 01-RESEARCH/"
        fi
      done > "$TMPDIR_SCAN/bare_terms.tsv"
fi

###############################################################################
# Phase 7: Assemble JSON output
###############################################################################

# Helper functions for JSON generation
infer_subfolder() {
  local src="$1"
  case "$src" in
    01-RESEARCH/*)
      local sub
      sub="$(echo "$src" | cut -d/ -f2)"
      if [[ "$sub" == *.md ]]; then echo "General"; else echo "$sub"; fi
      ;;
    00-INDEX/Theme-AI-Safety*) echo "AI-Safety" ;;
    00-INDEX/Theme-Container-Architecture*) echo "Infrastructure" ;;
    00-INDEX/Theme-GCP-Infrastructure*) echo "Infrastructure" ;;
    00-INDEX/Theme-GPU-Hardware*) echo "Infrastructure" ;;
    00-INDEX/Theme-Local-Models*) echo "Local-Models" ;;
    00-INDEX/Theme-Multi-Agent*) echo "AI-Safety" ;;
    00-INDEX/Theme-Prompt-Engineering*) echo "General" ;;
    00-INDEX/Theme-Token-Efficiency*) echo "Token-Efficiency" ;;
    *) echo "General" ;;
  esac
}

topic_from_target() {
  local target="$1"
  basename "$target" | sed 's/\\//g; s/-/ /g; s/\b\(.\)/\u\1/g'
}

# Build all gaps as JSON lines, deduplicating by topic
declare -A SEEN_TOPICS
GAPS_FILE="$TMPDIR_SCAN/gaps.jsonl"
> "$GAPS_FILE"

emit() {
  local topic="$1" gap_type="$2" priority="$3" source_file="$4" subfolder="$5" context="$6"
  local key
  key="$(echo "$topic" | tr '[:upper:]' '[:lower:]')"
  if [[ -n "${SEEN_TOPICS[$key]+x}" ]]; then return; fi
  SEEN_TOPICS["$key"]=1
  jq -cn \
    --arg topic "$topic" \
    --arg gap_type "$gap_type" \
    --arg priority "$priority" \
    --arg source_file "$source_file" \
    --arg subfolder "$subfolder" \
    --arg context "$context" \
    '{
      topic: $topic,
      gap_type: $gap_type,
      priority: $priority,
      source_file: $source_file,
      suggested_subfolder: $subfolder,
      related_files: [],
      context: $context
    }' >> "$GAPS_FILE"
}

# Dead links / MOC gaps (P1)
while IFS=$'\t' read -r src target; do
  topic="$(topic_from_target "$target")"
  subfolder="$(infer_subfolder "$src")"
  src_base="$(basename "$src")"
  if [[ "$src_base" == Theme-*.md ]]; then
    emit "$topic" "moc-gap" "P1" "$src" "$subfolder" "Dead wikilink [[$target]] in $src_base"
  else
    emit "$topic" "dead-link" "P1" "$src" "$subfolder" "Dead wikilink [[$target]] in $src_base"
  fi
done < "$TMPDIR_SCAN/dead_links.tsv"

# Stubs (P2)
while IFS=$'\t' read -r rel reason; do
  base="$(basename "$rel" .md)"
  topic="$(topic_from_target "$base")"
  subfolder="$(infer_subfolder "$rel")"
  emit "$topic" "stub" "P2" "$rel" "$subfolder" "$reason in $(basename "$rel")"
done < "$TMPDIR_SCAN/stubs.tsv"

# Stale (P3)
while IFS=$'\t' read -r rel reason; do
  base="$(basename "$rel" .md)"
  topic="$(topic_from_target "$base")"
  subfolder="$(infer_subfolder "$rel")"
  emit "$topic" "stale" "P3" "$rel" "$subfolder" "$reason"
done < "$TMPDIR_SCAN/stale.tsv"

# Bare terms (P3)
while IFS=$'\t' read -r rel reason; do
  base="$(basename "$rel" .md)"
  topic="$(topic_from_target "$base")"
  emit "$topic" "bare-term" "P3" "$rel" "General" "$reason"
done < "$TMPDIR_SCAN/bare_terms.tsv"

# Sort by priority and limit to top 20
if [[ -s "$GAPS_FILE" ]]; then
  jq -s '
    sort_by(
      if .priority == "P1" then 0
      elif .priority == "P2" then 1
      else 2
      end
    ) | .[0:20]
  ' "$GAPS_FILE"
else
  echo '[]'
fi
