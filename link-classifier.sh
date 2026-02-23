#!/usr/bin/env bash
set -euo pipefail

# link-classifier.sh — Classify a URL and output a JSON action plan
# Usage: bash link-classifier.sh <url> [source]
# source: "telegram", "cli", "watch" (default: "cli")
# Output: JSON to stdout

URL="${1:?Usage: link-classifier.sh <url> [source]}"
SOURCE="${2:-cli}"
TODAY="$(date +%Y-%m-%d)"
TIMESTAMP="$(date -u +%Y-%m-%dT%H-%M-%S)"

###############################################################################
# Pattern-based classification (fast, no API call)
###############################################################################

classify_by_pattern() {
  local url="$1"
  case "$url" in
    *arxiv.org/abs/*|*arxiv.org/pdf/*)
      echo "paper" ;;
    *github.com/*/*)
      if echo "$url" | grep -qE 'github\.com/[^/]+/[^/]+/?$'; then
        echo "repo"
      elif echo "$url" | grep -qE '/issues/|/pull/|/discussions/'; then
        echo "github-thread"
      else
        echo "repo"
      fi ;;
    *huggingface.co/*)
      if echo "$url" | grep -qE '/datasets/'; then
        echo "dataset"
      elif echo "$url" | grep -qE '/spaces/'; then
        echo "space"
      else
        echo "model"
      fi ;;
    *youtube.com/watch*|*youtu.be/*)
      echo "video" ;;
    *.pdf)
      echo "pdf" ;;
    *twitter.com/*|*x.com/*/status/*)
      echo "social" ;;
    *npmjs.com/package/*|*www.npmjs.com/package/*)
      echo "package-npm" ;;
    *pypi.org/project/*)
      echo "package-pypi" ;;
    *news.ycombinator.com/item*)
      echo "news-hn" ;;
    *techcrunch.com/*|*arstechnica.com/*|*theverge.com/*|*wired.com/*)
      echo "news" ;;
    *.readthedocs.io/*|*docs.*)
      echo "docs" ;;
    *)
      echo "unknown" ;;
  esac
}

###############################################################################
# Map type to action and vault path
###############################################################################

map_type_to_action() {
  local type="$1"
  case "$type" in
    paper)                        echo "research" ;;
    repo|model|dataset|space)     echo "summarize" ;;
    video)                        echo "summarize" ;;
    pdf)                          echo "extract" ;;
    social|news|news-hn)          echo "summarize" ;;
    package-npm|package-pypi)     echo "summarize" ;;
    docs)                         echo "extract" ;;
    github-thread)                echo "summarize" ;;
    *)                            echo "summarize" ;;
  esac
}

map_type_to_vault_subfolder() {
  local type="$1"
  case "$type" in
    paper)                        echo "01-RESEARCH" ;;
    pdf)                          echo "00-INBOX" ;;
    *)                            echo "11-LINKS" ;;
  esac
}

map_type_to_tags() {
  local type="$1"
  case "$type" in
    paper)          echo '["research", "arxiv", "paper"]' ;;
    repo)           echo '["github", "repo"]' ;;
    model)          echo '["huggingface", "model"]' ;;
    dataset)        echo '["huggingface", "dataset"]' ;;
    space)          echo '["huggingface", "space"]' ;;
    video)          echo '["youtube", "video", "media"]' ;;
    pdf)            echo '["pdf", "document"]' ;;
    social)         echo '["social", "thread"]' ;;
    news|news-hn)   echo '["news", "tech"]' ;;
    package-npm)    echo '["npm", "package", "javascript"]' ;;
    package-pypi)   echo '["pypi", "package", "python"]' ;;
    docs)           echo '["documentation"]' ;;
    github-thread)  echo '["github", "discussion"]' ;;
    *)              echo '["uncategorized"]' ;;
  esac
}

###############################################################################
# Generate slug from URL
###############################################################################

url_to_slug() {
  local url="$1"
  local type="$2"
  local slug=""
  case "$type" in
    paper)
      slug="$(echo "$url" | grep -oP '\d{4}\.\d{4,5}' | head -1 | sed 's/\./-/')" ;;
    repo)
      slug="$(echo "$url" | grep -oP 'github\.com/\K[^/]+/[^/?#]+' | tr '/' '-' | tr '[:upper:]' '[:lower:]')" ;;
    model|dataset|space)
      slug="$(echo "$url" | grep -oP 'huggingface\.co/\K[^?#]+' | tr '/' '-' | tr '[:upper:]' '[:lower:]')" ;;
    video)
      slug="$(echo "$url" | grep -oP '[?&]v=\K[^&]+' | head -1)" ;;
    *)
      slug="$(echo "$url" | sed 's|https\?://||; s|www\.||; s|[^a-zA-Z0-9]|-|g; s|--*|-|g; s|^-||; s|-$||')" ;;
  esac
  # Truncate and fallback
  slug="${slug:0:50}"
  if [ -z "$slug" ]; then
    slug="link-${TIMESTAMP}"
  fi
  echo "$slug"
}

###############################################################################
# AI classification for unknown URLs (Haiku — fast and cheap)
###############################################################################

classify_with_ai() {
  local url="$1"
  if ! command -v claude &>/dev/null; then
    echo "unknown"
    return
  fi
  local result
  result="$(claude --print --model haiku \
    "Classify this URL into exactly one category. Respond with ONLY the category name, nothing else.
Categories: paper, repo, model, dataset, video, pdf, social, news, docs, package, tutorial, blog, tool, other

URL: ${url}" 2>/dev/null)" || { echo "unknown"; return; }
  echo "$result" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'
}

###############################################################################
# Main
###############################################################################

TYPE="$(classify_by_pattern "$URL")"

# If pattern matching failed, try AI classification
if [ "$TYPE" = "unknown" ]; then
  TYPE="$(classify_with_ai "$URL")"
fi

ACTION="$(map_type_to_action "$TYPE")"
VAULT_SUBFOLDER="$(map_type_to_vault_subfolder "$TYPE")"
TAGS="$(map_type_to_tags "$TYPE")"
SLUG="$(url_to_slug "$URL" "$TYPE")"

STUB_FILENAME="${TODAY}-${SLUG}.md"
STUB_PATH="${VAULT_SUBFOLDER}/${STUB_FILENAME}"
QUEUE_FILENAME="${TIMESTAMP}_${SLUG}.json"

# Topics to add (only for research-worthy types)
TOPICS_TO_ADD="[]"
if [ "$TYPE" = "paper" ] || [ "$ACTION" = "research" ]; then
  TOPICS_TO_ADD="[\"${SLUG}\"]"
fi

# Output JSON
jq -n \
  --arg url "$URL" \
  --arg type "$TYPE" \
  --arg action "$ACTION" \
  --arg source "$SOURCE" \
  --arg received "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg stub_path "$STUB_PATH" \
  --arg queue_file "$QUEUE_FILENAME" \
  --arg slug "$SLUG" \
  --arg vault_subfolder "$VAULT_SUBFOLDER" \
  --argjson tags "$TAGS" \
  --argjson topics_to_add "$TOPICS_TO_ADD" \
  '{
    url: $url,
    type: $type,
    action: $action,
    source: $source,
    received: $received,
    status: "pending",
    slug: $slug,
    stub_path: $stub_path,
    queue_file: $queue_file,
    vault_subfolder: $vault_subfolder,
    tags: $tags,
    topics_to_add: $topics_to_add
  }'
