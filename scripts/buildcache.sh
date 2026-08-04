#!/usr/bin/env bash
set -euo pipefail

# Helper for the local BuildKit cache registry on self-hosted runners.
#
#   verify  <repo> <tag>          exit 0 if the manifest and every blob it
#                                 references is present and complete
#   usable  <repo> <tag>...       report which of the candidates may be imported
#   promote <repo> <from> <to>    verify <from>, then publish it as <to>
#   purge   <repo> <tag>          delete a tag, best effort
#
# Blobs live per repository, tags are only pointers into it. Promoting is
# therefore a single manifest PUT, no data is copied.

REGISTRY="${BUILDCACHE_REGISTRY:-http://localhost:5000}"

ACCEPT='application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# awk's IGNORECASE is a gawk extension, so header names have to be lowered by
# hand to also work with mawk and BSD awk.
header_value() { # <header dump> <lowercase header name>
  tr -d '\r' < "$1" | awk -v k="$2:" 'tolower($1) == k { v = $2 } END { print v }'
}

fetch_manifest() {
  local repo="$1" ref="$2" body="$3" hdr="$4" code
  code="$(curl -sS -o "$body" -D "$hdr" -w '%{http_code}' \
    -H "Accept: ${ACCEPT}" "${REGISTRY}/v2/${repo}/manifests/${ref}")"
  [ "$code" = "200" ] || { echo "  manifest ${repo}:${ref} -> HTTP ${code}"; return 1; }
}

# HEAD is not enough. Registry answers it from its own metadata, so a blob whose
# file on disk is empty still reports the full Content-Length and only the body
# comes up short -- which is exactly the "short read: expected N bytes but got 0"
# that kills a build. Reading the last byte back is what actually proves the
# data is there, and it stays O(1) even for a several hundred MB layer.
check_blob() {
  local repo="$1" digest="$2" want="$3" hdr="${TMP}/blob.hdr" code have last probe

  code="$(curl -sS -I -o /dev/null -D "$hdr" -w '%{http_code}' \
    "${REGISTRY}/v2/${repo}/blobs/${digest}")"
  if [ "$code" != "200" ]; then
    echo "  blob ${digest} -> HTTP ${code}"
    return 1
  fi

  have="$(header_value "$hdr" content-length)"
  if [ -n "$want" ] && [ "$want" != "null" ] && [ "$have" != "$want" ]; then
    echo "  blob ${digest} -> registry reports ${have} bytes, manifest says ${want}"
    return 1
  fi
  [ -n "$have" ] && [ "$have" -gt 0 ] 2>/dev/null || return 0

  last=$((have - 1))
  if ! probe="$(curl -sS -o /dev/null -w '%{http_code} %{size_download}' \
      -H "Range: bytes=${last}-${last}" \
      "${REGISTRY}/v2/${repo}/blobs/${digest}" 2>/dev/null)"; then
    probe="transfer failed"
  fi
  case "$probe" in
    '206 1'|"200 ${have}") ;;
    *) echo "  blob ${digest} -> truncated, last byte unreadable (${probe})"; return 1 ;;
  esac
}

verify_manifest() {
  local repo="$1" ref="$2" body="${TMP}/m.json" hdr="${TMP}/m.hdr" media child

  fetch_manifest "$repo" "$ref" "$body" "$hdr" || return 1

  media="$(jq -r '.mediaType // empty' "$body")"
  case "$media" in
    *manifest.list.v2+json | *image.index.v1+json)
      while read -r child; do
        [ -n "$child" ] || continue
        verify_manifest "$repo" "$child" || return 1
      done < <(jq -r '.manifests[]?.digest' "$body")
      return 0
      ;;
  esac

  while read -r digest size; do
    [ -n "$digest" ] || continue
    check_blob "$repo" "$digest" "$size" || return 1
  done < <(jq -r '[.config] + (.layers // []) | .[] | select(.digest) | "\(.digest) \(.size)"' "$body")
}

cmd_verify() {
  local repo="$1" tag="$2"
  if verify_manifest "$repo" "$tag"; then
    echo "cache ${repo}:${tag} is intact"
    return 0
  fi
  echo "cache ${repo}:${tag} is incomplete"
  return 1
}

# Picks the cache refs a build may safely import. A missing ref is normal (a new
# scope), a corrupt one is not: it imports fine and only kills the build seconds
# later when a blob is read, so it has to be sorted out up front.
# Prints one "use <tag>" or "skip <tag> <reason>" line per candidate.
cmd_usable() {
  local repo="$1" tag
  shift
  for tag in "$@"; do
    if [ -z "$(resolve_digest "$repo" "$tag")" ]; then
      echo "skip ${tag} missing"
    elif verify_manifest "$repo" "$tag"; then
      echo "use ${tag}"
    else
      echo "skip ${tag} corrupt"
    fi
  done
}

cmd_promote() {
  local repo="$1" from="$2" to="$3" body="${TMP}/p.json" hdr="${TMP}/p.hdr" ctype code

  if ! verify_manifest "$repo" "$from"; then
    echo "refusing to promote ${repo}:${from} -> :${to}, cache is incomplete"
    return 1
  fi

  fetch_manifest "$repo" "$from" "$body" "$hdr"
  ctype="$(header_value "$hdr" content-type)"
  [ -n "$ctype" ] || ctype="application/vnd.oci.image.manifest.v1+json"

  code="$(curl -sS -o /dev/null -w '%{http_code}' -X PUT \
    -H "Content-Type: ${ctype}" --data-binary "@${body}" \
    "${REGISTRY}/v2/${repo}/manifests/${to}")"

  case "$code" in
    20*) echo "promoted ${repo}:${from} -> :${to}" ;;
    *)   echo "promoting ${repo}:${from} -> :${to} failed with HTTP ${code}"; return 1 ;;
  esac
}

resolve_digest() { # <repo> <tag>, empty output if the tag does not resolve
  local repo="$1" tag="$2" hdr="${TMP}/r.hdr" code
  code="$(curl -sS -I -o /dev/null -D "$hdr" -w '%{http_code}' \
    -H "Accept: ${ACCEPT}" "${REGISTRY}/v2/${repo}/manifests/${tag}")"
  [ "$code" = "200" ] || return 0
  header_value "$hdr" docker-content-digest
}

cmd_purge() {
  local repo="$1" tag="$2" body="${TMP}/t.json" code digest other

  digest="$(resolve_digest "$repo" "$tag")"
  [ -n "$digest" ] || { echo "nothing to purge for ${repo}:${tag}"; return 0; }

  # Registry deletes manifests by digest only, and a promoted cache is the very
  # same revision under a second tag. Deleting this run tag would take the
  # promoted scope with it, so anything another tag still points at stays.
  code="$(curl -sS -o "$body" -w '%{http_code}' "${REGISTRY}/v2/${repo}/tags/list")"
  if [ "$code" = "200" ]; then
    while read -r other; do
      [ -n "$other" ] && [ "$other" != "$tag" ] || continue
      if [ "$(resolve_digest "$repo" "$other")" = "$digest" ]; then
        echo "keeping ${repo}:${tag}, same revision is tagged :${other}"
        return 0
      fi
    done < <(jq -r '.tags[]?' "$body")
  fi

  code="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
    "${REGISTRY}/v2/${repo}/manifests/${digest}")"
  echo "purged ${repo}:${tag} (${digest}) -> HTTP ${code}"
}

case "${1:-}" in
  verify)  shift; cmd_verify "$@" ;;
  usable)  shift; cmd_usable "$@" ;;
  promote) shift; cmd_promote "$@" ;;
  purge)   shift; cmd_purge "$@" ;;
  *) echo "usage: $(basename "$0") {verify|usable|promote|purge} <repo> <args...>" >&2; exit 2 ;;
esac
