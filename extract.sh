#!/bin/bash
# Build a minimal Metal shader toolchain (metal + metallib) from Apple's
# MetalToolchain MobileAsset, without Xcode.app. See README.md.
#
# Requires macOS and the Xcode Command Line Tools (for lipo). Uses only tools
# that ship with macOS or the Command Line Tools, plus 7zz if it is on PATH.
set -euo pipefail

ASSET_DIR=/System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain
CATALOG=$ASSET_DIR/com_apple_MobileAsset_MetalToolchain.xml

# Fallback for machines without a local catalog: build 17B54 (Oct 2025).
DEFAULT_URL=https://updates.cdn-apple.com/2025/mobileassets/022-20354/192ADD28-31EE-43C8-972D-E5BED5FB1845/com_apple_MobileAsset_MetalToolchain/637B0E26-E00A-488B-BA3B-CB50A8ECFD74.aar
DEFAULT_KEY=v7VbaT39JmQPp5p4N3HoVPAKcZ5vyhY+nnjMRD79z5E=

here=$(cd "$(dirname "$0")" && pwd)
out=$here/toolchain
dmg=
download=0
universal=0
reader=auto

usage() {
    cat <<USAGE
usage: $0 [--dmg PATH | --download] [--universal] [--reader hdiutil|7zz] [--out DIR]

  (default)       use the toolchain DMG already cached in $ASSET_DIR
  --dmg PATH      use this toolchain DMG
  --download      fetch the encrypted asset from Apple's CDN and unpack it with aa
  --universal     keep x86_64 + arm64 slices (default: thin to $(uname -m) only)
  --reader R      how to read the DMG: hdiutil (mount read-only) or 7zz (no mount);
                  default: 7zz if it is on PATH, otherwise hdiutil
  --out DIR       output directory (default: $out)
USAGE
    exit 2
}

while [ $# -gt 0 ]; do
    case $1 in
        --dmg) dmg=$2; shift 2 ;;
        --download) download=1; shift ;;
        --universal) universal=1; shift ;;
        --reader) reader=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        *) usage ;;
    esac
done

# /usr/bin/lipo is only a launcher; without the Command Line Tools it opens the
# install dialog instead of running. Check first so the failure is clear.
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find lipo >/dev/null 2>&1; then
    echo "the Xcode Command Line Tools are required: xcode-select --install" >&2
    exit 1
fi

if [ "$reader" = auto ]; then
    if command -v 7zz >/dev/null; then reader=7zz; else reader=hdiutil; fi
fi
case $reader in
    hdiutil | 7zz) ;;
    *) usage ;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/mini-metal-toolchain.XXXXXX")
mnt=$work/mnt
cleanup() {
    if [ -d "$mnt" ] && mount | grep -q " on $mnt "; then
        hdiutil detach -quiet "$mnt" || hdiutil detach -quiet -force "$mnt" || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT

source_desc=
if [ "$download" = 1 ]; then
    url=$DEFAULT_URL key=$DEFAULT_KEY
    if [ -f "$CATALOG" ]; then
        url=$(plutil -extract Assets.0.__BaseURL raw "$CATALOG")$(plutil -extract Assets.0.__RelativePath raw "$CATALOG")
        key=$(plutil -extract Assets.0.ArchiveDecryptionKey raw "$CATALOG")
    fi
    echo "downloading $url"
    curl -fL --progress-bar -o "$work/asset.aar" "$url"
    # The asset is an encrypted Apple Archive patch; applying it to an empty
    # source decrypts, decompresses and unpacks it in one step.
    echo "unpacking"
    aa patch -i "$work/asset.aar" -key-value "base64:$key" -src /var/empty -dst "$work/asset"
    rm "$work/asset.aar"
    dmg=$(ls "$work"/asset/AssetData/Restore/*.dmg | head -1)
    source_desc="downloaded from $url"
elif [ -z "$dmg" ]; then
    dmg=$(ls -t "$ASSET_DIR"/*.asset/AssetData/Restore/*.dmg 2>/dev/null | head -1 || true)
    if [ -z "$dmg" ]; then
        echo "no cached MetalToolchain asset in $ASSET_DIR; rerun with --download" >&2
        exit 1
    fi
    source_desc="cached MobileAsset $dmg"
else
    source_desc="DMG $dmg"
fi
[ -f "$dmg" ] || { echo "DMG not found: $dmg" >&2; exit 1; }
dmg_sha=$(shasum -a 256 "$dmg" | cut -d' ' -f1)

# root ends up holding Metal.xctoolchain/ either way.
if [ "$reader" = 7zz ]; then
    echo "extracting from $dmg with 7zz (no mount)"
    root=$work/dmg
    tc=Metal.xctoolchain
    7zz x -y -bso0 -bsp0 -o"$root" "$dmg" \
        "$tc/ToolchainInfo.plist" \
        "$tc/usr/metal/current" \
        "$tc/usr/metal/*/bin/metal" \
        "$tc/usr/metal/*/bin/air-lld" \
        "$tc/usr/metal/*/lib/clang/*/include/*" \
        "$tc/usr/metal/*/lib/clang/*/lib/darwin/libmetal_rt_osx.a" \
        RestoreVersion.plist
else
    echo "mounting $dmg (read-only)"
    root=$mnt
    mkdir "$mnt"
    hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$mnt" "$dmg"
fi

src=$root/Metal.xctoolchain/usr/metal
ver=$(readlink "$src/current")
clang_ver=$(ls "$src/$ver/lib/clang")
echo "toolchain $ver, clang resource dir $clang_ver"

stage=$work/toolchain
dst=$stage/metal/$ver
mkdir -p "$dst/bin" "$dst/lib/clang/$clang_ver/lib/darwin"

for tool in metal air-lld; do
    if [ "$universal" = 1 ]; then
        cp "$src/$ver/bin/$tool" "$dst/bin/$tool"
    else
        lipo "$src/$ver/bin/$tool" -thin "$(uname -m)" -output "$dst/bin/$tool"
    fi
done
ln -s air-lld "$dst/bin/metallib"
cp -R "$src/$ver/lib/clang/$clang_ver/include" "$dst/lib/clang/$clang_ver/"
cp "$src/$ver/lib/clang/$clang_ver/lib/darwin/libmetal_rt_osx.a" "$dst/lib/clang/$clang_ver/lib/darwin/"
cp "$root/Metal.xctoolchain/ToolchainInfo.plist" "$stage/"
[ -f "$root/RestoreVersion.plist" ] && cp "$root/RestoreVersion.plist" "$stage/"
ln -s "$ver" "$stage/metal/current"
ln -s metal/current/bin "$stage/bin"

for tool in metal air-lld; do
    codesign --verify --strict "$dst/bin/$tool"
done

cat > "$stage/PROVENANCE.txt" <<EOF
Extracted $(date -u +%Y-%m-%dT%H:%M:%SZ) by extract.sh (DMG read with $reader)
Source: $source_desc
Source DMG SHA-256: $dmg_sha
Toolchain: $ver (clang resource dir $clang_ver)
Compiler: $("$dst/bin/metal" --version | head -1)
Slices: $(lipo -archs "$dst/bin/metal")
Host: macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)
EOF

if [ "$reader" = hdiutil ]; then
    hdiutil detach -quiet "$mnt"
fi

rm -rf "$out"
mkdir -p "$(dirname "$out")"
mv "$stage" "$out"

echo
cat "$out/PROVENANCE.txt"
echo "size: $(du -sh "$out" | cut -f1)"
echo
echo "add to PATH:  export PATH=\"$out/bin:\$PATH\""
echo "if xcrun cached an older location for these tools, run: xcrun -kill-cache"
