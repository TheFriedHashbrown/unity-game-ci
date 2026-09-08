#!/usr/bin/env bash
# Post-deploy smoke test: does a browser actually get a loadable build?
#
# Catches the two failure modes that survive a green build: files missing from the
# bucket, and compressed files served without Content-Encoding (Unity then fails with
# "Unable to parse Build/<game>.framework.js.br").
#
# Usage: verify-deploy.sh https://games.example.com/world-sim/preview/pr-12/
set -euo pipefail

BASE="${1:?usage: verify-deploy.sh <base-url>}"
BASE="${BASE%/}"
failures=0

check() {
  local url="$1" expect_encoding="$2"
  local headers status encoding
  # Must advertise brotli: Cloudflare transparently decompresses for clients that
  # do not, which hides the stored Content-Encoding and makes this check vacuous.
  headers="$(curl -sS -L -o /dev/null -D - --max-time 300 \
               -H 'Accept-Encoding: br, gzip' "$url" || true)"
  status="$(printf '%s' "$headers" | awk 'BEGIN{IGNORECASE=1} /^HTTP\//{code=$2} END{print code}')"
  encoding="$(printf '%s' "$headers" | awk 'BEGIN{IGNORECASE=1} /^content-encoding:/{gsub(/\r/,""); print $2}' | tail -n1)"

  if [ "$status" != "200" ]; then
    echo "  FAIL  $url -> HTTP ${status:-no response}"
    failures=$((failures + 1))
    return
  fi
  if [ -n "$expect_encoding" ] && [ "${encoding:-none}" != "$expect_encoding" ]; then
    echo "  FAIL  $url -> 200 but Content-Encoding is '${encoding:-none}', expected '$expect_encoding'"
    failures=$((failures + 1))
    return
  fi
  echo "  ok    $url${encoding:+  [$encoding]}"
}

echo "Verifying $BASE/"
index="$(curl -sS -L --max-time 60 "$BASE/index.html")" || {
  echo "::error::Could not fetch $BASE/index.html"; exit 1; }

check "$BASE/index.html" ""

# Unity's template never writes a literal "Build/name" path. It sets
#   var buildUrl = "Build";
# and then builds each URL as buildUrl + "/<game>.wasm.br", so the directory and
# the filenames have to be recombined here.
build_dir="$(printf '%s' "$index" | grep -oE 'buildUrl[[:space:]]*=[[:space:]]*"[^"]+"' \
             | head -n1 | sed 's/.*"\(.*\)"/\1/')"
build_dir="${build_dir:-Build}"

mapfile -t assets < <(printf '%s' "$index" \
  | grep -oE 'buildUrl[[:space:]]*\+[[:space:]]*"/[^"]+"' \
  | sed 's|.*"/\(.*\)"|'"$build_dir"'/\1|' | sort -u)

if [ "${#assets[@]}" -eq 0 ]; then
  # Silently passing here would report a green deploy having verified nothing.
  echo "::error::Found no player files referenced by index.html. Either the page is"
  echo "::error::broken or the Unity template changed shape and this parser needs updating."
  exit 1
fi
echo "Checking ${#assets[@]} player files under $build_dir/"

for asset in "${assets[@]:-}"; do
  [ -n "$asset" ] || continue
  case "$asset" in
    *.br) check "$BASE/$asset" "br" ;;
    *.gz) check "$BASE/$asset" "gzip" ;;
    *)    check "$BASE/$asset" "" ;;
  esac
done

if [ "$failures" -gt 0 ]; then
  echo "::error::$failures deployment check(s) failed."
  exit 1
fi
echo "All checks passed."
