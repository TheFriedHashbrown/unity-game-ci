#!/usr/bin/env bash
# Upload a Unity WebGL build to Cloudflare R2 with the metadata the Unity loader needs.
#
# R2 is object storage, not a web server: it will not compress or content-negotiate.
# Whatever Content-Type / Content-Encoding you set at upload time is exactly what the
# browser receives. Get it wrong and Unity dies with
# "Unable to parse Build/<game>.framework.js.br", which is why this uploads file by
# file instead of using `aws s3 sync` (sync sets neither header).
#
# Usage:
#   deploy-r2.sh --source build/WebGL/world-sim --bucket games \
#                --prefix world-sim/preview/pr-12 [--prune] [--dry-run]
#
# Env: R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY
set -euo pipefail

SOURCE="" BUCKET="" PREFIX="" PRUNE=0 DRY_RUN=0 IMMUTABLE=0 JOBS="${UPLOAD_JOBS:-8}"

while [ $# -gt 0 ]; do
  case "$1" in
    --source)    SOURCE="$2"; shift 2 ;;
    --bucket)    BUCKET="$2"; shift 2 ;;
    --prefix)    PREFIX="$2"; shift 2 ;;
    --prune)     PRUNE=1; shift ;;
    --immutable) IMMUTABLE=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

for var in SOURCE BUCKET PREFIX; do
  [ -n "${!var}" ] || { echo "Missing --${var,,}" >&2; exit 2; }
done
for var in R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; do
  [ -n "${!var:-}" ] || { echo "Missing environment variable $var" >&2; exit 2; }
done
[ -d "$SOURCE" ] || { echo "Source directory not found: $SOURCE" >&2; exit 2; }

SOURCE="${SOURCE%/}"
PREFIX="${PREFIX%/}"

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto
export AWS_EC2_METADATA_DISABLED=true
# AWS CLI >= 2.23 sends checksum headers R2 rejects; only send them when required.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

content_type_for() {
  # $1 = filename with any .br/.gz suffix already stripped
  case "${1,,}" in
    *.html)            echo "text/html; charset=utf-8" ;;
    *.js|*.mjs)        echo "text/javascript; charset=utf-8" ;;
    *.css)             echo "text/css; charset=utf-8" ;;
    *.json)            echo "application/json" ;;
    *.wasm)            echo "application/wasm" ;;
    *.data|*.unityweb) echo "application/octet-stream" ;;
    *.symbols)         echo "application/octet-stream" ;;
    *.png)             echo "image/png" ;;
    *.jpg|*.jpeg)      echo "image/jpeg" ;;
    *.gif)             echo "image/gif" ;;
    *.svg)             echo "image/svg+xml" ;;
    *.ico)             echo "image/x-icon" ;;
    *.webp)            echo "image/webp" ;;
    *.woff)            echo "font/woff" ;;
    *.woff2)           echo "font/woff2" ;;
    *.ttf)             echo "font/ttf" ;;
    *.mp3)             echo "audio/mpeg" ;;
    *.ogg)             echo "audio/ogg" ;;
    *.wav)             echo "audio/wav" ;;
    *.mp4)             echo "video/mp4" ;;
    *.txt|*.md)        echo "text/plain; charset=utf-8" ;;
    *)                 echo "application/octet-stream" ;;
  esac
}

cache_control_for() {
  # $1 = path relative to the build root
  #
  # Unity does NOT content-hash its WebGL output: every build writes the same
  # <game>.wasm.br and <game>.data.br. So "immutable" is only safe under a prefix
  # that is never rewritten, i.e. release/<tag>/. Marking it immutable anywhere
  # that gets overwritten pins returning players to the build they first loaded,
  # for a year, while index.html updates around them.
  case "$1" in
    index.html)
      echo "public, max-age=0, must-revalidate" ;;
    Build/*|build/*)
      if [ "$IMMUTABLE" = "1" ]; then
        echo "public, max-age=31536000, immutable"
      else
        # Still cached; revalidated on every load, so an unchanged file costs a 304.
        echo "public, max-age=0, must-revalidate"
      fi ;;
    *)
      echo "public, max-age=3600" ;;
  esac
}

upload_one() {
  local file="$1"
  local rel="${file#"$SOURCE"/}"
  local key="$PREFIX/$rel"

  local stem="$rel" encoding=""
  case "$rel" in
    *.br) stem="${rel%.br}"; encoding="br" ;;
    *.gz) stem="${rel%.gz}"; encoding="gzip" ;;
  esac

  local ctype cache args
  ctype="$(content_type_for "$stem")"
  cache="$(cache_control_for "$stem")"

  args=(s3 cp "$file" "s3://$BUCKET/$key"
        --endpoint-url "$ENDPOINT"
        --content-type "$ctype"
        --cache-control "$cache"
        --only-show-errors)
  [ -n "$encoding" ] && args+=(--content-encoding "$encoding")

  if [ "$DRY_RUN" = "1" ]; then
    printf '  %-55s %-34s %s\n' "$key" "$ctype" "${encoding:-none}"
  else
    aws "${args[@]}"
  fi
}

export -f upload_one content_type_for cache_control_for
export SOURCE BUCKET PREFIX ENDPOINT DRY_RUN IMMUTABLE

file_count="$(find "$SOURCE" -type f | wc -l)"
total_size="$(du -sh "$SOURCE" | cut -f1)"
echo "Uploading $file_count files ($total_size) -> s3://$BUCKET/$PREFIX/"

find "$SOURCE" -type f -print0 \
  | xargs -0 -P "$JOBS" -I{} bash -c 'upload_one "$@"' _ {}

if [ "$PRUNE" = "1" ]; then
  echo "Pruning objects no longer in the build..."
  local_keys="$(mktemp)"; remote_keys="$(mktemp)"
  trap 'rm -f "$local_keys" "$remote_keys"' EXIT

  (cd "$SOURCE" && find . -type f | sed 's|^\./||') | sed "s|^|$PREFIX/|" | sort > "$local_keys"
  aws s3api list-objects-v2 \
      --bucket "$BUCKET" --prefix "$PREFIX/" \
      --endpoint-url "$ENDPOINT" \
      --query 'Contents[].Key' --output text 2>/dev/null \
    | tr '\t' '\n' | grep -v '^None$' | sed '/^$/d' | sort > "$remote_keys" || true

  stale="$(comm -13 "$local_keys" "$remote_keys" || true)"
  if [ -n "$stale" ]; then
    echo "$stale" | while read -r key; do
      [ -n "$key" ] || continue
      if [ "$DRY_RUN" = "1" ]; then
        echo "  would delete $key"
      else
        aws s3 rm "s3://$BUCKET/$key" --endpoint-url "$ENDPOINT" --only-show-errors
      fi
    done
  else
    echo "  nothing to prune"
  fi
fi

echo "Done: s3://$BUCKET/$PREFIX/"
