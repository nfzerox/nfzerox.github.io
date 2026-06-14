#!/bin/zsh
# Regenerate the APT/Cydia repo index from the .deb(s) in debs/.
# No dpkg-scanpackages needed; we extract each deb's control and append the
# Filename/Size/hash fields apt + Cydia expect, then gzip/bzip2 and write Release.
set -e
REPO="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO"
[ -d debs ] || { echo "no debs/ dir"; exit 1; }

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

gzip  -9 -nkf "$PKGS"      # -> Packages.gz
bzip2    -kf "$PKGS"       # -> Packages.bz2

# Release: repo description + per-index checksums (apt/Sileo/Zebra want these)
REL="$REPO/Release"
cat > "$REL" <<EOF
Origin: nfzerox
Label: nfzerox
Suite: stable
Version: 1.0
Codename: ios
Architectures: iphoneos-arm
Components: main
Description: TLSFix: modern HTTPS for legacy iOS
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
