#!/bin/bash
# Generate hierarchical CLAUDE.md files for a project tree.
# Usage: bash init-deep.sh [root-dir] [--apply]
set -eo pipefail

ROOT="${1:-.}"
ROOT=$(cd "$ROOT" && pwd)
APPLY="${2:-}"

SKIP_DIRS="node_modules|.git|venv|__pycache__|dist|build|.next|.cache|target|vendor|.mypy_cache|.pytest_cache|.tox|coverage|.nyc_output|.turbo"
SOURCE_EXTS="py|ts|tsx|js|jsx|go|rs|java|kt|rb|php|c|cpp|h|hpp|cs|swift|sh|sql|yaml|yml|toml|json"

PREVIEW_DIR="/tmp/init-deep-preview"
rm -rf "$PREVIEW_DIR"
mkdir -p "$PREVIEW_DIR"

GENERATED=()

generate_claude_md() {
  local dir="$1"
  local rel_path="${dir#$ROOT}"
  rel_path="${rel_path#/}"
  [ -z "$rel_path" ] && rel_path="."

  # Count source files
  local file_count=0
  local file_types=""
  for ext in $(echo "$SOURCE_EXTS" | tr '|' ' '); do
    local count
    count=$(find "$dir" -maxdepth 1 -name "*.$ext" 2>/dev/null | wc -l)
    if [ "$count" -gt 0 ]; then
      file_count=$((file_count + count))
      file_types+="$ext($count) "
    fi
  done

  # Skip directories with no source files
  [ "$file_count" -eq 0 ] && return 0

  # Skip if CLAUDE.md already exists
  [ -f "$dir/CLAUDE.md" ] && return 0

  # Gather key files
  local key_files=""
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    local basename
    basename=$(basename "$f")
    echo "$basename" | grep -qE "\.($SOURCE_EXTS)$" || continue
    local desc=""
    desc=$(head -5 "$f" 2>/dev/null | grep -E '^\s*(#|//|/\*|\*|"""|from|import|export|package|module|pub |def |class |func |fn )' | head -1 | sed 's/^[[:space:]]*//' | cut -c1-80)
    if [ -n "$desc" ]; then
      key_files+="- \`$basename\` — $desc"$'\n'
    else
      key_files+="- \`$basename\`"$'\n'
    fi
  done

  # Detect patterns
  local patterns=""
  ls "$dir" 2>/dev/null | grep -qi "test\|spec" && patterns+="tests, "
  ls "$dir" 2>/dev/null | grep -qi "config\|\.env\|settings" && patterns+="configuration, "
  ls "$dir" 2>/dev/null | grep -qi "util\|helper\|lib" && patterns+="utilities, "
  ls "$dir" 2>/dev/null | grep -qi "screen\|page\|view\|component" && patterns+="UI components, "
  ls "$dir" 2>/dev/null | grep -qi "model\|schema\|entity" && patterns+="data models, "
  ls "$dir" 2>/dev/null | grep -qi "route\|handler\|controller\|api" && patterns+="API/routing, "
  patterns="${patterns%, }"

  # Build content
  local content="# CLAUDE.md"$'\n\n'
  content+="## What This Directory Contains"$'\n\n'
  content+="**Path:** \`$rel_path/\`"$'\n'
  content+="**Files:** $file_count source files ($file_types)"$'\n'
  [ -n "$patterns" ] && content+="**Patterns:** $patterns"$'\n'
  content+=$'\n'"## Key Files"$'\n\n'
  content+="$key_files"

  # Check for subdirectories with source files
  local subdirs=""
  for subdir in "$dir"/*/; do
    [ -d "$subdir" ] || continue
    local subname
    subname=$(basename "$subdir")
    echo "$subname" | grep -qE "^($SKIP_DIRS)$" && continue
    local sub_count
    sub_count=$(find "$subdir" -maxdepth 2 \( -name "*.py" -o -name "*.ts" -o -name "*.go" -o -name "*.rs" -o -name "*.js" \) 2>/dev/null | wc -l)
    [ "$sub_count" -gt 0 ] && subdirs+="- \`$subname/\` ($sub_count source files)"$'\n'
  done

  if [ -n "$subdirs" ]; then
    content+=$'\n'"## Subdirectories"$'\n\n'"$subdirs"
  fi

  # Write preview
  local safe_name
  safe_name=$(echo "$rel_path" | tr '/' '_')
  [ "$safe_name" = "." ] && safe_name="ROOT"
  echo "$content" > "$PREVIEW_DIR/$safe_name.md"
  GENERATED+=("$dir/CLAUDE.md")
  echo "  Generated: $rel_path/CLAUDE.md"
}

echo "Scanning $ROOT for directories with source files..."
echo "Skipping: $SKIP_DIRS"
echo ""

# Walk directory tree
while IFS= read -r dir; do
  if echo "$dir" | grep -qE "/($SKIP_DIRS)(/|$)"; then continue; fi
  generate_claude_md "$dir" || true
done < <(find "$ROOT" -type d 2>/dev/null | sort)

echo ""
echo "Generated ${#GENERATED[@]} CLAUDE.md preview(s) in $PREVIEW_DIR/"
echo ""

if [ "${#GENERATED[@]}" -eq 0 ]; then
  echo "No directories needed CLAUDE.md files (all either have one or lack source files)."
  exit 0
fi

echo "Preview files:"
for f in "$PREVIEW_DIR"/*.md; do
  [ -f "$f" ] && echo "  $f"
done

if [ "$APPLY" = "--apply" ]; then
  echo ""
  echo "Applying..."
  for target in "${GENERATED[@]}"; do
    local_rel="${target#$ROOT/}"
    local_rel="${local_rel%/CLAUDE.md}"
    safe_name=$(echo "$local_rel" | tr '/' '_')
    [ -z "$local_rel" ] && safe_name="ROOT"
    preview="$PREVIEW_DIR/$safe_name.md"
    if [ -f "$preview" ]; then
      cp "$preview" "$target"
      echo "  Applied: $target"
    fi
  done
  echo ""
  echo "Done. Review and commit: git add */CLAUDE.md && git commit -m 'docs: generate hierarchical CLAUDE.md files via /init-deep'"
else
  echo ""
  echo "To apply, run: bash $0 $ROOT --apply"
  echo "To commit: git add */CLAUDE.md && git commit -m 'docs: generate hierarchical CLAUDE.md files via /init-deep'"
fi
