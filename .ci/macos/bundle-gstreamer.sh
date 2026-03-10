#!/usr/bin/env bash
# Bundle GStreamer plugins into nheko.app.
# Usage: bundle-gstreamer.sh <path/to/nheko.app>
#
# Plugins land in: Contents/PlugIns/gstreamer-1.0/
# Shared libs land in: Contents/Frameworks/
# Plugin  deps use: @loader_path/../../Frameworks/<lib>
# Library deps use: @rpath/<lib>   (resolved via nheko binary rpath)

set -euo pipefail

APP="${1:?Usage: $0 <path/to/nheko.app>}"
PLUGINS_DEST="${APP}/Contents/PlugIns/gstreamer-1.0"
FRAMEWORKS_DEST="${APP}/Contents/Frameworks"
NHEKO_BIN="${APP}/Contents/MacOS/nheko"

GST_PREFIX="$(brew --prefix gstreamer)"
BREW_PREFIX="$(brew --prefix)"

mkdir -p "${PLUGINS_DEST}" "${FRAMEWORKS_DEST}"

# VoIP / Video / Screenshare gstreamer plugins required on MacOS
GST_PLUGINS=(
    libgstcoreelements          # queue, tee, capsfilter, filesrc
    libgstaudioconvert
    libgstaudioresample
    libgstautodetect            # autoaudiosink, autoaudiosrc
    libgstplayback              # decodebin
    libgstopus                  # opusenc, opusdec
    libgstvolume                # volume
    libgstopengl                # glsinkbin, glupload, gldownload, glcolorconvert
    libgstcompositor            # compositor
    libgstvideorate             # videorate
    libgstvideoscale            # videoscale
    libgstvideoconvert          # videoconvert
    libgstvpx                   # vp8enc, vp8dec
    libgstrtp                   # rtpopuspay, rtpvp8pay, rtpopusdepay
    libgstwebrtc                # webrtcbin
    libgstdtls                  # DTLS (WebRTC dep)
    libgstsrtp                  # SRTP (WebRTC dep)
    libgstrtpmanager            # rtpbin (WebRTC dep)
    libgstosxaudio              # osxaudiosrc, osxaudiosink
    libgstapplemedia            # avfvideosrc (screenshare)
    libgsttypefindfunctions     # media type detection
    libgstnice                  # nicesrc, nicesink (ICE/STUN/TURN)
    libgstqml6                  # qml6glsink (built from source)
)

# Get non-system dynamic library dependencies
get_brew_deps() {
    otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}' | \
        grep -v '^@' | grep -v '^/System' | grep -v '^/usr/lib' | grep -v '^$' || true
}

# Copy a dylib into the Frameworks/ directory, and recursively bundle its dependencies.
bundle_lib() {
    local src="$1"
    local name
    name="$(basename "$src")"
    local dest="${FRAMEWORKS_DEST}/${name}"
    [[ -f "$dest" ]] && return      # already there
    [[ -f "$src"  ]] || { echo "WARN: dep not found: $src" >&2; return; }

    cp "$src" "$dest"

    # Recurse before patching so all transitive deps are present
    while IFS= read -r dep; do
        bundle_lib "$dep"
    done < <(get_brew_deps "$dest")
}

# Copy plugins
echo "Copying GStreamer plugins…"
for plugin in "${GST_PLUGINS[@]}"; do
    src="${GST_PREFIX}/lib/gstreamer-1.0/${plugin}.dylib"
    if [[ -f "$src" ]]; then
        cp "$src" "${PLUGINS_DEST}/${plugin}.dylib"
    else
        echo "  WARN: ${plugin}.dylib not found" >&2
    fi
done

# Bundle deps
echo "Bundling shared library dependencies…"
for p in "${PLUGINS_DEST}"/*.dylib; do
    while IFS= read -r dep; do
        bundle_lib "$dep"
    done < <(get_brew_deps "$p")
done

# fix load paths
echo "Fixing plugin install names…"
for p in "${PLUGINS_DEST}"/*.dylib; do
    while IFS= read -r dep; do
        name="$(basename "$dep")"
        install_name_tool -change "$dep" "@loader_path/../../Frameworks/${name}" "$p"
    done < <(get_brew_deps "$p")
done

# fix framework install names and their deps to use @rpath, so they resolve via the nheko binary rpath
echo "Fixing framework install names…"
for f in "${FRAMEWORKS_DEST}"/*.dylib; do
    name="$(basename "$f")"
    # Canonicalise own install name so dyld can match it
    install_name_tool -id "@rpath/${name}" "$f"
    # Point all homebrew deps to @rpath so they resolve via the process rpath
    while IFS= read -r dep; do
        depname="$(basename "$dep")"
        install_name_tool -change "$dep" "@rpath/${depname}" "$f"
    done < <(get_brew_deps "$f")
done

# verify rpath
if [[ -f "${NHEKO_BIN}" ]]; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "${NHEKO_BIN}" 2>/dev/null || true
fi

echo "GStreamer bundling complete."
echo "  Plugins   : $(find "${PLUGINS_DEST}"    -name '*.dylib' | wc -l | tr -d ' ')"
echo "  Frameworks: $(find "${FRAMEWORKS_DEST}" -name '*.dylib' | wc -l | tr -d ' ')"
