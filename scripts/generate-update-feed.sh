#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 5 ]]; then
    echo "Usage: $0 MergeTether.zip OUTPUT_DIRECTORY OWNER/REPOSITORY TAG BUILD" >&2
    exit 2
fi
archive="$1" output="$2" repo="$3" tag="$4" build="$5"
[[ -f "$archive" && "$(basename "$archive")" == MergeTether.zip && -d "$output" &&
   "$repo" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ && "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ &&
   "$build" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid Sparkle release inputs.' >&2; exit 2; }

private_key="${MERGETETHER_SPARKLE_PRIVATE_KEY:?Missing Sparkle update signing key}"
unset MERGETETHER_SPARKLE_PRIVATE_KEY
umask 077
scratch="$(mktemp -d "${TMPDIR:-/tmp}/mergetether-appcast.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT

sparkle_version=2.10.1
sparkle_checksum=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
curl --fail --silent --show-error --location --retry 3 \
    "https://github.com/sparkle-project/Sparkle/releases/download/${sparkle_version}/Sparkle-${sparkle_version}.tar.xz" \
    -o "$scratch/Sparkle.tar.xz"
printf '%s  %s\n' "$sparkle_checksum" "$scratch/Sparkle.tar.xz" | shasum -a 256 -c -
tar -xJf "$scratch/Sparkle.tar.xz" -C "$scratch" bin/generate_appcast bin/sign_update

mkdir "$scratch/updates"
ln "$archive" "$scratch/updates/MergeTether.zip" 2>/dev/null || cp "$archive" "$scratch/updates/MergeTether.zip"
downloads="https://github.com/${repo}/releases/download/${tag}/"
feed="$scratch/updates/appcast.xml"
printf '%s' "$private_key" | "$scratch/bin/generate_appcast" --ed-key-file - \
    --maximum-deltas 0 --download-url-prefix "$downloads" \
    --link "https://github.com/${repo}/releases/tag/${tag}" -o "$feed" "$scratch/updates"

signature="$(python3 - "$feed" "$archive" "$downloads" "${tag#v}" "$build" <<'PY'
import base64
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

feed, archive, downloads, version, build = sys.argv[1:]
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
items = ET.parse(feed).findall("./channel/item")
if len(items) != 1:
    sys.exit("Sparkle feed must contain the one release being published.")
item = items[0]
enclosure = item.find("enclosure")
if (enclosure is None or enclosure.get("url") != downloads + "MergeTether.zip"
        or enclosure.get("length") != str(Path(archive).stat().st_size)
        or item.findtext("sparkle:version", namespaces=ns) != build
        or item.findtext("sparkle:shortVersionString", namespaces=ns) != version):
    sys.exit("Sparkle feed does not match the published release archive and version.")
signature = enclosure.get(f"{{{ns['sparkle']}}}edSignature", "")
if len(base64.b64decode(signature, validate=True)) != 64:
    sys.exit("Sparkle feed lacks a valid archive signature.")
print(signature)
PY
)"
printf '%s' "$private_key" | "$scratch/bin/sign_update" --ed-key-file - --verify "$archive" "$signature"
printf '%s' "$private_key" | "$scratch/bin/sign_update" --ed-key-file - --verify "$feed"
cp "$feed" "$output/appcast.xml"
