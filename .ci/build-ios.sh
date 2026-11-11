#!/usr/bin/env bash
# Vita3KiOS: builds an unsigned IPA with a plain Xcode project.
set -euo pipefail

output_dir="${1:-artifacts}"
config="${BUILD_CONFIG:-Release}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${repo_root}/build/ios"

export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-16.5}"
export CMAKE_OSX_DEPLOYMENT_TARGET="${CMAKE_OSX_DEPLOYMENT_TARGET:-16.5}"

: "${VCPKG_ROOT:?VCPKG_ROOT must point at a bootstrapped vcpkg checkout}"

seed="${CMAKE_CHECKS_SEED:-}"
seed_args=()
if [[ -n "$seed" && -s "$seed" && ! -f "$build_dir/CMakeCache.txt" ]]; then
    echo "Reusing $(grep -c '^set(' "$seed") CMake check results"
    seed_args=(-C "$seed")
fi

cmake ${seed_args[@]+"${seed_args[@]}"} -S "$repo_root" -B "$build_dir" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=16.5 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    -DCMAKE_TOOLCHAIN_FILE="${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake" \
    -DVCPKG_TARGET_TRIPLET=arm64-ios \
    -DUSE_LTO=NEVER \
    -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

if [[ -n "$seed" ]]; then
    mkdir -p "$(dirname "$seed")"
    python3 - "$build_dir/CMakeCache.txt" "$seed" <<'PY'
import re, sys
entries = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    m = re.match(r"^([A-Za-z][A-Za-z0-9_]*):INTERNAL=(.*)$", line.rstrip("\n"))
    if not m:
        continue
    name, value = m.groups()
    if name.startswith(("CMAKE_", "Z_VCPKG", "VCPKG", "FETCHCONTENT")) or "/" in value or "$" in value:
        continue
    value = value.replace("\\", "\\\\").replace('"', '\\"')
    entries.append(f'set({name} "{value}" CACHE INTERNAL "")')
open(sys.argv[2], "w").write("\n".join(entries) + "\n")
print(f"Saved {len(entries)} CMake check results")
PY
fi

ccache_args=()
if command -v ccache > /dev/null; then
    ccache_args=(
        C_COMPILER_LAUNCHER="$(command -v ccache)"
        CLANG_USE_RESPONSE_FILE=NO
        COMPILER_INDEX_STORE_ENABLE=NO
    )
fi

xcodebuild \
    -project "$build_dir/Vita3K.xcodeproj" \
    -target vita3k \
    -configuration "$config" \
    -sdk iphoneos \
    IPHONEOS_DEPLOYMENT_TARGET=16.5 \
    SWIFT_DEPLOYMENT_TARGET=16.5 \
    SWIFT_ENABLE_EXPLICIT_MODULE_BUILD=NO \
    OTHER_SWIFT_FLAGS="-Xfrontend -disable-availability-checking" \
    -parallelizeTargets \
    -jobs "$(sysctl -n hw.ncpu)" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    ${ccache_args[@]+"${ccache_args[@]}"} \
    build

app_path="$(find "$build_dir" -name 'Vita3K.app' -type d -path "*${config}-iphoneos*" | head -n 1)"
if [[ -z "$app_path" ]]; then
    echo "Vita3K.app not found under $build_dir" >&2
    exit 1
fi
echo "Built: $app_path"

# ---- RAM helper extension (V3KRamHelper.appex) ----
if [[ ! -d "$app_path/PlugIns/V3KRamHelper.appex" ]]; then
    appex_path="$(find "$build_dir" -name 'V3KRamHelper.appex' -type d -path "*${config}-iphoneos*" -not -path "*/PlugIns/*" | head -n 1)"
    if [[ -n "$appex_path" ]]; then
        mkdir -p "$app_path/PlugIns"
        cp -R "$appex_path" "$app_path/PlugIns/"
        echo "Embedded $appex_path"
    else
        echo "V3KRamHelper.appex was not built" >&2
        exit 1
    fi
fi

# ---- App icon ----
icon_work="$(mktemp -d)"
plist="$app_path/Info.plist"
pb=/usr/libexec/PlistBuddy

if xcrun actool "$repo_root/dist/image/Vita3K.icon" \
        --compile "$app_path" \
        --platform iphoneos \
        --minimum-deployment-target 16.5 \
        --target-device iphone --target-device ipad \
        --app-icon Vita3K \
        --output-partial-info-plist "$icon_work/partial.plist" > "$icon_work/actool.log" 2>&1; then
    "$pb" -c "Merge $icon_work/partial.plist" "$plist" || true
    echo "Compiled Vita3K.icon"
else
    echo "actool could not compile Vita3K.icon, using PNG icons only:"
    cat "$icon_work/actool.log"
fi

python3 - "$repo_root/vita3k/org.vita3k.vita3k.svg" "$icon_work/icon.svg" <<'PY'
import sys
svg = open(sys.argv[1]).read()
start = svg.index('>', svg.index('<svg')) + 1
background = ('<defs><linearGradient id="v3kbg" x1="0" y1="0" x2="0" y2="0.7">'
              '<stop offset="0" stop-color="#F8CA00"/><stop offset="1" stop-color="#E97F02"/>'
              '</linearGradient></defs><rect x="0" y="0" width="270.93" height="270.93" fill="url(#v3kbg)"/>')
open(sys.argv[2], 'w').write(svg[:start] + background + svg[start:])
PY
if sips -s format png -z 1024 1024 "$icon_work/icon.svg" --out "$icon_work/icon-1024.png" > /dev/null; then
    for spec in "120:AppIcon60x60@2x.png" "180:AppIcon60x60@3x.png" "152:AppIcon76x76@2x~ipad.png" "167:AppIcon83.5x83.5@2x~ipad.png"; do
        sips -z "${spec%%:*}" "${spec%%:*}" "$icon_work/icon-1024.png" --out "$app_path/${spec#*:}" > /dev/null
    done
    "$pb" -c "Add :CFBundleIcons dict" "$plist" 2> /dev/null || true
    "$pb" -c "Add :CFBundleIcons:CFBundlePrimaryIcon dict" "$plist" 2> /dev/null || true
    "$pb" -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles array" "$plist" 2> /dev/null || true
    "$pb" -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:0 string AppIcon60x60" "$plist"
    "$pb" -c "Add :CFBundleIcons~ipad dict" "$plist" 2> /dev/null || true
    "$pb" -c "Add :CFBundleIcons~ipad:CFBundlePrimaryIcon dict" "$plist" 2> /dev/null || true
    "$pb" -c "Add :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconFiles array" "$plist" 2> /dev/null || true
    "$pb" -c "Add :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconFiles:0 string AppIcon76x76" "$plist"
    "$pb" -c "Add :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconFiles:0 string AppIcon83.5x83.5" "$plist"
    echo "Added PNG icons"
else
    echo "Could not render the PNG icons"
fi
rm -rf "$icon_work"

# ---- Version ----
version="${VITA3KIOS_VERSION:-}"
if [[ -z "$version" && "${GITHUB_REF_TYPE:-}" == tag && "${GITHUB_REF_NAME:-}" == v* ]]; then
    version="${GITHUB_REF_NAME#v}"
fi
if [[ -n "$version" ]]; then
    "$pb" -c "Set :CFBundleShortVersionString $version" "$plist"
fi
version="$("$pb" -c "Print :CFBundleShortVersionString" "$plist")"
build_number="${GITHUB_RUN_NUMBER:-$(git -C "$repo_root" rev-list --count HEAD)}"
"$pb" -c "Set :CFBundleVersion $build_number" "$plist"
for appex_plist in "$app_path"/PlugIns/*.appex/Info.plist; do
    [[ -f "$appex_plist" ]] || continue
    "$pb" -c "Set :CFBundleVersion $build_number" "$appex_plist"
    "$pb" -c "Set :CFBundleShortVersionString $version" "$appex_plist"
done
commit="$(git -C "$repo_root" rev-parse --short HEAD)"
"$pb" -c "Delete :V3KCommit" "$plist" 2> /dev/null || true
"$pb" -c "Add :V3KCommit string $commit" "$plist"
echo "Version $version ($build_number), commit $commit"

mkdir -p "$output_dir"
staging="$(mktemp -d)"
mkdir -p "$staging/Payload"
cp -R "$app_path" "$staging/Payload/"
if [[ "${VITA3KIOS_RELEASE:-0}" == 1 ]]; then
    ipa_name="Vita3KiOS-${version}.ipa"
else
    ipa_name="Vita3KiOS-${version}-${commit}.ipa"
fi
(cd "$staging" && zip -qry "$ipa_name" Payload)
mv "$staging/$ipa_name" "$output_dir/"
rm -rf "$staging"

echo "IPA: $output_dir/$ipa_name"
if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "IPA_PATH=$output_dir/$ipa_name" >> "$GITHUB_ENV"
    echo "IPA_NAME=${ipa_name%.ipa}" >> "$GITHUB_ENV"
    echo "IPA_VERSION=$version" >> "$GITHUB_ENV"
    echo "IPA_BUILD=$build_number" >> "$GITHUB_ENV"
fi
