[![mini-metal-toolchain: shiny metallic apples shrinking in size](img/minimetal-small.png)](img/minimetal.png)

# mini-metal-toolchain

A 112 MB extract of Apple's Metal shader compiler that compiles `.metal`
source into `.metallib` files on a Mac with only the Xcode Command Line
Tools installed. You don't need Xcode.app.

```sh
./extract.sh          # build ./toolchain from the copy macOS already cached
./verify.sh           # compile a test shader and load it on the GPU
export PATH="$PWD/toolchain/bin:$PATH"
```

After that, `metal`, `metallib`, and `xcrun -sdk macosx metal` all work.

## Requirements

- macOS (tested on 26.7, Apple silicon)
- The Xcode Command Line Tools (`xcode-select --install`). Xcode.app is not
  needed.
- Optional: `7zz` (7-Zip, e.g. `brew install sevenzip`). If it is on `PATH`,
  `extract.sh` reads the DMG with it instead of mounting it.

Every tool the scripts use, and where it comes from:

| Tool | Comes with | Used by |
|---|---|---|
| `bash`, `curl`, `plutil`, `aa`, `hdiutil`, `codesign`, `shasum`, `xcode-select`, and basic file tools | macOS | `extract.sh` |
| `lipo`, `xcrun` | Command Line Tools | `extract.sh` (thinning, the up-front check) |
| `clang` | Command Line Tools | `verify.sh` (builds the GPU loader) |
| `7zz` | optional, not Apple | `extract.sh` (reads the DMG without mounting) |

`extract.sh` checks for the Command Line Tools first and stops with a clear message.

## Why this exists

Starting with Xcode 26, the Metal compiler is no longer bundled with Xcode
or the Command Line Tools. It is a separate download, and the documented way
to get it is `xcodebuild -downloadComponent MetalToolchain`, which requires
Xcode.app, a multi-gigabyte install. Projects
that compile shaders at build time with `xcrun metal` / `xcrun metallib`
therefore seem to need Xcode.app.

You don't need it. The download that `xcodebuild` triggers is an ordinary
macOS MobileAsset. Anyone can fetch it from Apple's CDN and unpack it with
tools built into macOS. It holds a 2.1 GB `Metal.xctoolchain`,
but a build that compiles and links shaders uses only two of its programs
and a few support files.

This project is for builds (Makefiles, `build.zig`, CMake, scripts) that run
`xcrun -sdk macosx metal` and `xcrun -sdk macosx metallib`, so they can run
without installing Xcode.

## What's in `toolchain/`

| Path | Size | What it is |
|---|---|---|
| `metal/32023/bin/metal` | 89 MB | The Metal compiler driver and front end (clang-based). Compiles `.metal` to `.air` bitcode. |
| `metal/32023/bin/air-lld` | 18 MB | The AIR linker. |
| `metal/32023/bin/metallib` | symlink | Points to `air-lld`. Apple ships `metallib` the same way. |
| `metal/32023/lib/clang/32023.830/include/` | 4.5 MB | `metal_stdlib` and the other Metal headers. |
| `metal/32023/lib/clang/32023.830/lib/darwin/libmetal_rt_osx.a` | 128 KB | Metal runtime library. `metallib` fails to link without it. |
| `metal/current` | symlink | Points to `32023`, mirroring Apple's layout. |
| `bin` | symlink | Points to `metal/current/bin`. Put this on `PATH`. |
| `ToolchainInfo.plist`, `RestoreVersion.plist` | | Apple's version metadata, copied from the DMG. |
| `PROVENANCE.txt` | | Written by `extract.sh`: source, DMG SHA-256, compiler version, slices, date. |

The binaries are thinned to the host architecture (arm64 here). Use
`./extract.sh --universal` to keep both arm64 and x86_64 slices; that gives
230 MB in total. Both binaries depend only on system libraries (`libSystem`,
`libc++`, `libbz2`, `libarchive`, CoreFoundation). Their code signatures stay
valid after thinning, and `extract.sh` checks them with `codesign --verify`.

The rest of the toolchain was dropped because compiling and linking shaders
never touches it:

- GPU back ends that compile AIR to device machine code: `libapplegpu*-nt.dylib`,
  `libigc.dylib` (Intel), and the AMD bundles. That's about 1.2 GB. Shipped
  metallibs contain AIR, and the OS driver compiles AIR to machine code at
  run time.
- `lib/metalfe` (181 MB).
- Tools a build doesn't call: `metal-objdump`, `metal-nm`, `metal-opt`,
  `metal-dsymutil`, `air-pack`, and others.
- Runtime libraries for iOS, tvOS, watchOS and visionOS, plus OpenCL, ray
  tracing, and shader logging runtimes.

To check the result, I compiled the same source with this extract and with
the full toolchain, using the same arguments. The outputs were byte-identical.

## Where the files come from

Everything comes from Apple, and you can follow each step:

1. **Asset type:** `com.apple.MobileAsset.MetalToolchain`. The build used
   here is **17B54**: metal `32023.830` (`metalfe-32023.830.2`), posted
   10/28/2025.
2. **Catalog:** macOS keeps the asset catalog at
   `/System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/com_apple_MobileAsset_MetalToolchain.xml`.
   It records the download URL (`__BaseURL` + `__RelativePath`) and the
   archive key (`ArchiveDecryptionKey`). Apple's live catalog server
   (`gdmf.apple.com`) isn't publicly browsable, and the `mesu.apple.com`
   paths return 403. So `extract.sh` reads the local catalog when there is
   one, and otherwise falls back to the 17B54 URL and key written into the
   script.
3. **Download:**
   `https://updates.cdn-apple.com/2025/mobileassets/022-20354/192ADD28-31EE-43C8-972D-E5BED5FB1845/com_apple_MobileAsset_MetalToolchain/637B0E26-E00A-488B-BA3B-CB50A8ECFD74.aar`
   (704,643,072 bytes).
   Its SHA-256 is
   `84f1cec3984878294777349e794f7bff0407e501a728bd600dc8605fa36abf6f`.
4. **Decrypt and unpack:** the `.aar` is an AEA1-encrypted Apple Archive in
   patch form. Inside the encryption is a `pbzx` stream (4 MiB xz chunks, the
   format of macOS OTA updates). macOS's built-in `aa` handles all of it in
   one step by applying the patch to an empty directory:
   `aa patch -i asset.aar -key-value base64:<ArchiveDecryptionKey> -src /var/empty -dst out`.
   That produces `AssetData/Restore/022-20369-066.dmg` (716 MB) plus the
   asset's metadata, the same layout macOS keeps under `AssetsV2/` once it
   has downloaded the asset itself.
5. **Read the DMG:** it is a cryptex disk image (UDZO: zlib-compressed,
   read-only) holding one APFS volume, which contains `Metal.xctoolchain/`.
   `extract.sh` copies the files listed above out of it in one of two ways:
   - `hdiutil attach -readonly -nobrowse` mounts it. This needs no root, but
     it does create a system-wide mount until the script detaches it.
   - `7zz x` reads the disk image and APFS volume as a file and extracts only
     the needed paths. Nothing is mounted. This is the default when `7zz` is
     on `PATH`.

   Both produce identical output.

Source DMG SHA-256 for build 17B54:
`9849e91f9525f2860a355f44774b155c4a6574a074ce3865538cea45cc36b843`.
The DMG cached by macOS and the DMG from the download path (steps 3–4)
produced this same hash.

### Getting the source DMG

- **Already cached (default):** if Xcode was ever installed, or something
  else triggered the download, the DMG is already at
  `/System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/*.asset/AssetData/Restore/*.dmg`.
  The asset is marked `NeverCollected`, so it stays after Xcode is
  uninstalled. `./extract.sh` uses it, and nothing is downloaded.
- **`--download`:** steps 3–4 above, using `curl` and `aa`. Expect about
  700 MB of download and about 1.5 GB of temporary disk space, which is
  removed afterwards. This works on a Mac that never had Xcode.
- **`--dmg PATH`:** any toolchain DMG you already have.

## Do you need `xcrun`?

No. `xcrun` is the launcher in `/usr/bin` that the Command Line Tools
install. When you run `xcrun -sdk macosx metal …` it:

1. Finds `metal` by looking in the active developer directory
   (`xcode-select -p`) and its toolchains, then falling back to `PATH`. That
   fallback is why putting `toolchain/bin` on `PATH` makes `xcrun metal`
   work.
2. Caches the location it found. If the toolchain later moves, `xcrun` keeps
   using the old, now-missing path and fails with `couldn't stat toolchain`.
   Run `xcrun -kill-cache` to fix that.
3. Runs the tool with `SDKROOT` set to the selected SDK
   (`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`).

The only thing `xcrun` changes in the output comes from step 3. With
`SDKROOT` set, the compiler passes `-isysroot` and
`-target-sdk-version=<SDK version>`, and records the SDK version in the
bitcode. In one test, that made a 53 KB metallib 352 bytes larger. The deployment target
(`air64_v28-apple-macosx26.0.0`) is the same either way, and both files load
and run identically. To get byte-identical output without `xcrun`:

```sh
SDKROOT=$(xcrun --show-sdk-path) toolchain/bin/metal -c shader.metal -o shader.air
toolchain/bin/metallib shader.air -o default.metallib
```

The tools also run fine directly with an empty environment, without
`SDKROOT`.

## Using it with an existing build

Put `toolchain/bin` on `PATH` and run the build as usual:

```sh
export PATH="$HOME/src/mini-metal-toolchain/toolchain/bin:$PATH"
xcrun -kill-cache        # only needed if xcrun cached an old location
make                     # or zig build, cmake --build, ...
```

Builds that call `xcrun -sdk macosx metal` / `metallib`, or `metal` /
`metallib` directly, need no changes. I tested this on macOS 26.7 (25G229)
with an Apple M4 Pro, using a Zig 0.16 project whose `build.zig` compiles its
shaders with `xcrun`. The build and its tests passed, and the resulting
metallib loaded with all 11 shader functions and its render pipelines built.

## Files

| File | Purpose |
|---|---|
| `extract.sh` | Builds `toolchain/` from the cached asset, `--dmg PATH`, or `--download`. `--reader hdiutil\|7zz` picks how the DMG is read. Writes into a temporary directory and replaces `toolchain/` only after every step succeeds. |
| `verify.sh [DIR]` | Compiles `test/shader.metal` (vertex, fragment and compute functions), links it, and runs `test/load.m`, which loads the metallib on the GPU and builds render and compute pipelines. |
| `test/` | Test shader and loader. |

## Related work

[ZML](https://github.com/zml/zml) ships the same toolchain asset for its
Metal backend. Its `MODULE.bazel` downloads the identical 17B54 `.aar` (same
URL, key and SHA-256), and its `bazel/http_aea_archive.bzl` is where the
`aa patch -src /var/empty` and `7zz` techniques used here came from. ZML
keeps a slightly larger subset (`metal`, `air-as`, `air-opt`, `metallib` and
`lib/clang/32023.830`) and bundles it with its application. On Linux hosts
it decrypts the asset with [`ipsw ota extract`](https://github.com/blacktop/ipsw)
instead of `aa`.

[hermetic-llvm](https://github.com/hermeticbuild/hermetic-llvm) (the C/C++
toolchain ZML builds with) does the same thing for the macOS SDK: it
downloads only `CLTools_macOSNMOS_SDK.pkg` from `swcdn.apple.com`, found
through Apple's public software-update catalog, and unpacks a trimmed SDK
from it. That approach, combined with the toolchain asset, can build Metal
apps on a Mac with neither Xcode nor the Command Line Tools installed. This
repository doesn't go that far: it assumes the Command Line Tools are present.

## Caveats

- **License:** these are Apple's binaries, signed by Apple and distributed
  through Apple's update CDN for use with Apple's developer tools. Building
  them locally for your own use is the same thing `xcodebuild
  -downloadComponent` does. Don't commit `toolchain/` to a repository or
  redistribute it; `.gitignore` excludes it.
- **Pinned version:** without a local catalog, `--download` gets build
  17B54. When Apple posts a newer toolchain, a machine that downloads it
  through Xcode or the OS gets a new catalog, and `extract.sh` picks that up
  automatically. The fallback URL and key in the script have to be updated
  by hand.
- **Other versions not tested:** the script reads the toolchain and clang
  version directory names from the DMG instead of hard-coding them, but only
  build 17B54 has been tested. A future toolchain could need more files; if
  so, `verify.sh` will fail.
- **Intel Macs not tested:** `--universal` keeps the x86_64 slices. They ran
  under Rosetta on Apple silicon, but nothing was tested on a real Intel Mac.
- **No device-specific compilation:** you can't use this to build
  GPU-specific binary archives (`metal-tt`, offline `MTLBinaryArchive`
  generation), because those back ends were removed. Ordinary metallibs
  don't need them.
