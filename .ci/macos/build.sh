#!/usr/bin/env bash

set -ue

# unused
#TAG=$(git tag -l --points-at HEAD)

# Add Qt binaries to path
QT_BASEPATH=(${HOME}/Qt/6.*/macos/)
PATH="${QT_BASEPATH}/bin/:${PATH}"
pipx ensurepath
. ~/.zshrc
export PATH

CMAKE_PREFIX_PATH="${QT_BASEPATH}/lib/cmake"
export CMAKE_PREFIX_PATH

export CMAKE_BUILD_PARALLEL_LEVEL="$(sysctl -n hw.ncpu)"

export CMAKE_POLICY_VERSION_MINIMUM="3.5"

# GStreamer / VoIP
VOIP_FLAG="-DVOIP=OFF"
GST_PREFIX=""

# Only if gstreamer is available
if brew list gstreamer &>/dev/null 2>&1; then
    GST_PREFIX="$(brew --prefix gstreamer)"
    GST_VERSION="$(brew list --versions gstreamer | awk '{print $2}')"

    # Extract the Qt version
    QT_VER="$(basename "$(dirname "${QT_BASEPATH}")")"

    echo "Building GStreamer qml6glsink plugin (GStreamer ${GST_VERSION}, Qt ${QT_VER})…"

    if [[ -f "${GST_PREFIX}/lib/gstreamer-1.0/libgstqml6.dylib" ]]; then
        echo "GStreamer qml6glsink plugin already installed; skipping build."
    else
        echo "GStreamer qml6glsink plugin not found; building from source."
        # check if the repository is already cloned
        if [[ ! -d "/tmp/gstreamer-src" ]]; then
            git clone --depth 1 --filter=blob:none --sparse \
                --branch "${GST_VERSION}" \
                https://gitlab.freedesktop.org/gstreamer/gstreamer.git \
                /tmp/gstreamer-src
        else
            echo "GStreamer source already cloned; Making sure it's up to date"
            (
                cd /tmp/gstreamer-src
                git fetch --depth 1 origin "${GST_VERSION}"
                git checkout FETCH_HEAD
                git sparse-checkout set subprojects/gst-plugins-good
            )
        fi
        (
            cd /tmp/gstreamer-src
            git sparse-checkout set subprojects/gst-plugins-good
            cd subprojects/gst-plugins-good

            # Disable cmake-based Qt6 discovery: cmake searches system paths (homebrew)
            # causing a conflict (probably doesn't apply in CI)
            MESON_NATIVE_FILE="/tmp/nheko-qml6-native.ini"
            printf '[binaries]\nmoc = '"'"'%s/bin/moc'"'"'\nrcc = '"'"'%s/bin/rcc'"'"'\nuic = '"'"'%s/bin/uic'"'"'\nqmake = '"'"'%s/bin/qmake6'"'"'\n[cmake]\nCMAKE_DISABLE_FIND_PACKAGE_Qt6 = '"'"'true'"'"'\n' \
                "${QT_BASEPATH}" "${QT_BASEPATH}" "${QT_BASEPATH}" "${QT_BASEPATH}" \
                > "${MESON_NATIVE_FILE}"

            PKG_CONFIG_PATH="${GST_PREFIX}/lib/pkgconfig" \
            CXXFLAGS="-I${QT_BASEPATH}/lib/QtGui.framework/Headers -I${QT_BASEPATH}/lib/QtGui.framework/Headers/${QT_VER}/QtGui -F${QT_BASEPATH}/lib" \
            PATH="${QT_BASEPATH}/bin:${PATH}" \
            meson setup build \
                --native-file "${MESON_NATIVE_FILE}" \
                --prefix="${GST_PREFIX}" \
                -Dauto_features=disabled \
                -Dqt6=enabled

            ninja -C build ext/qt6/libgstqml6.dylib
            ninja -C build install
        )
    fi

    # Patch GStreamer .pc files into a temp dir to strip frameworks removed from
    # newer macOS (AGL since macOS 14, OpenGL deprecated/removed in macOS 26+).
    # Modifying a tmpdir copy avoids touching homebrew's installed files.
    GST_PC_PATCHED="/tmp/nheko-gst-pc-patched"
    rm -rf "${GST_PC_PATCHED}"
    mkdir -p "${GST_PC_PATCHED}"
    cp "${GST_PREFIX}/lib/pkgconfig/"*.pc "${GST_PC_PATCHED}/"
    MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
    if [[ "${MACOS_MAJOR}" -ge 26 ]]; then
        # macOS 26+ removed both AGL and OpenGL frameworks
        sed -i '' 's/ -framework AGL\b//g; s/ -framework OpenGL\b//g' "${GST_PC_PATCHED}"/*.pc
    elif [[ "${MACOS_MAJOR}" -ge 14 ]]; then
        # macOS 14-25: only AGL removed
        sed -i '' 's/ -framework AGL\b//g' "${GST_PC_PATCHED}"/*.pc
    fi
    export PKG_CONFIG_PATH="${GST_PC_PATCHED}:$(brew --prefix)/lib/pkgconfig"
    VOIP_FLAG="-DVOIP=ON"
    echo "GStreamer qml6glsink installed; VoIP support enabled."
else
    echo "GStreamer not found; VoIP support disabled."
fi

# Build nheko
cmake -GNinja -S. -Bbuild \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DCMAKE_INSTALL_PREFIX="nheko.temp" \
      -DHUNTER_ROOT="../.hunter" \
      -DHUNTER_ENABLED=ON -DBUILD_SHARED_LIBS=OFF \
      -DKDSingleApplication_STATIC=ON -DKDSingleApplication_EXAMPLES=OFF \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo -DHUNTER_CONFIGURATION_TYPES=RelWithDebInfo \
      -DQt6_DIR="${QT_BASEPATH}/lib/cmake/Qt6" \
      ${GST_PREFIX:+-DCMAKE_PREFIX_PATH="${GST_PREFIX};${QT_BASEPATH}/lib/cmake"} \
      "${VOIP_FLAG}" \
      -DCI_BUILD=ON
cmake --build build
cmake --install build
( cd build
  git clone https://github.com/Nheko-Reborn/qt-jdenticon.git
  ( cd qt-jdenticon
    qmake
    make -j "$CMAKE_BUILD_PARALLEL_LEVEL"
    cp libqtjdenticon.dylib ../../nheko.temp/nheko.app/Contents/MacOS
  )
  # Without this, end users will need to install Qt6 via homebrew
  # "$(brew --prefix qt6)/bin/macdeployqt" nheko.app -always-overwrite -qmldir=../resources/qml/
  # # workaround for https://bugreports.qt.io/browse/QTBUG-100686
  # cp "$(brew --prefix brotli)/lib/libbrotlicommon.1.dylib" nheko.app/Contents/Frameworks/libbrotlicommon.1.dylib
)

# If VoIP is inabled, bundle the required GStreamer plugins.
if [[ "${VOIP_FLAG}" == "-DVOIP=ON" ]]; then
    echo "Bundling GStreamer plugins into nheko.app…"
    "$(dirname "$0")/bundle-gstreamer.sh" nheko.temp/nheko.app
fi

mv nheko.temp/nheko.app nheko.app
