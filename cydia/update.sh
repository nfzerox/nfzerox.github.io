#!/bin/zsh
# Regenerate the APT/Cydia repo index from every .deb in debs/. Keep older
# versioned files there: APT/Sileo supports multiple versions of one package.
# No dpkg-scanpackages needed; we extract each deb's control and append the
# Filename/Size/hash fields apt + Cydia expect, then gzip/bzip2 and write Release.
set -e
REPO="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO"
[ -d debs ] || { echo "no debs/ dir"; exit 1; }
# Native depiction URLs must be absolute. Override this while serving the
# repository from a development machine.
REPO_BASE_URL="${REPO_BASE_URL:-https://nfzerox.github.io/cydia}"
REPO_BASE_URL="${REPO_BASE_URL%/}"
DEPICTION_URL="$REPO_BASE_URL/depictions/com.mac.virtual/depiction.json"
if [ "$REPO_BASE_URL" != "https://nfzerox.github.io/cydia" ]; then
  # Sileo honors the development server's cache headers. Give each local
  # origin and depiction revision a distinct URL so it cannot reuse a cached
  # production (or previous development) depiction.
  repo_cache_key=$(
    { printf '%s' "$REPO_BASE_URL"; shasum -a 256 \
        "$REPO/depictions/com.mac.virtual/depiction.json"; } |
      shasum -a 256 | cut -c1-12
  )
  DEPICTION_URL="$DEPICTION_URL?local=$repo_cache_key"
fi

PKGS="$REPO/Packages"
: > "$PKGS"
tmp="$(mktemp -d)"
first=1
for deb in debs/*.deb; do
  [ -e "$deb" ] || continue
  [ $first -eq 1 ] || print "" >> "$PKGS"
  first=0
  # pull the control fields out of the deb (ar -> control.tar.* -> ./control)
  rm -rf "$tmp"; mkdir -p "$tmp"; ( cd "$tmp" && ar x "$REPO/$deb" )
  ctar=$(ls "$tmp"/control.tar.* 2>/dev/null | head -1)
  ( cd "$tmp" && tar xf "$ctar" ./control 2>/dev/null )
  # control fields, minus any trailing blank lines
  awk 'NF{print; blank=0} !NF{blank=1} END{}' "$tmp/control" | sed '/^$/d' >> "$PKGS"
  # Preserve an icon for historical Virtual Mac packages whose embedded
  # control metadata predates the repository artwork.
  if grep -qx 'Package: com.mac.virtual' "$tmp/control" &&
     ! grep -qi '^Icon:' "$tmp/control"; then
    print "Icon: https://raw.githubusercontent.com/nfzerox/VirtualMacOniPad/main/VirtualMac/assets/VirtualMac.png" >> "$PKGS"
  fi
  if grep -qx 'Package: com.mac.virtual' "$tmp/control" &&
     ! grep -qi '^SileoDepiction:' "$tmp/control"; then
    print "SileoDepiction: $DEPICTION_URL" >> "$PKGS"
  fi
  # Installed-Size (unpacked KB) if the control didn't carry one
  if ! grep -qi '^Installed-Size:' "$tmp/control"; then
    dtar=$(ls "$tmp"/data.tar.* 2>/dev/null | head -1)
    ( cd "$tmp" && mkdir -p _d && tar xf "$dtar" -C _d 2>/dev/null )
    isz=$(du -sk "$tmp/_d" 2>/dev/null | awk '{print $1}')
    [ -n "$isz" ] && print "Installed-Size: $isz" >> "$PKGS"
  fi
  sz=$(stat -f%z "$REPO/$deb")
  md5=$(md5 -q "$REPO/$deb")
  sha1=$(shasum -a 1 "$REPO/$deb" | awk '{print $1}')
  sha256=$(shasum -a 256 "$REPO/$deb" | awk '{print $1}')
  print "Filename: $deb" >> "$PKGS"
  print "Size: $sz" >> "$PKGS"
  print "MD5sum: $md5" >> "$PKGS"
  print "SHA1: $sha1" >> "$PKGS"
  print "SHA256: $sha256" >> "$PKGS"
done
rm -rf "$tmp"

# Multiple releases of one package are intentional, but publishing the same
# Package+Version pair under two filenames makes client selection ambiguous.
duplicates=$(awk '
  /^Package:/ { package=$2 }
  /^Version:/ { version=$2; key=package SUBSEP version; count[key]++ }
  END { for (key in count) if (count[key] > 1) print key }
' "$PKGS")
if [ -n "$duplicates" ]; then
  echo "duplicate package/version entries in debs/:" >&2
  echo "$duplicates" | tr '\034' ' ' >&2
  exit 1
fi

gzip  -9 -nkf "$PKGS"      # -> Packages.gz
bzip2    -kf "$PKGS"       # -> Packages.bz2

# Release: repo description + per-index checksums (apt/Sileo/Zebra want these)
REL="$REPO/Release"
cat > "$REL" <<EOF
Origin: nfzerox
Label: nfzerox
Suite: stable
Version: 1.1.1
Codename: ios
Architectures: iphoneos-arm iphoneos-arm64
Components: main
Description: iOS software from nfzerox
EOF
emit_hashes() {  # $1 = algo for shasum (1/256) or "md5"; $2 = header
  print "$2:" >> "$REL"
  for f in Packages Packages.gz Packages.bz2; do
    [ -e "$REPO/$f" ] || continue
    if [ "$1" = "md5" ]; then h=$(md5 -q "$REPO/$f"); else h=$(shasum -a "$1" "$REPO/$f" | awk '{print $1}'); fi
    s=$(stat -f%z "$REPO/$f")
    printf " %s %s %s\n" "$h" "$s" "$f" >> "$REL"
  done
}
emit_hashes md5 MD5Sum
emit_hashes 1   SHA1
emit_hashes 256 SHA256

echo "wrote: Packages (+.gz/.bz2), Release"
echo "packages indexed:"; grep -c '^Package:' "$PKGS"
