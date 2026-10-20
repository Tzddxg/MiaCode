#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-build-linux-ubuntu}"
QT_ROOT="${QT_ROOT:-}"
MIACODE_BUILD_DEV_TOOLS="${MIACODE_BUILD_DEV_TOOLS:-OFF}"
RELEASE_CHANNEL="${MIACODE_RELEASE_CHANNEL:-nightly}"
PACKAGE_CHANNEL="${MIACODE_PACKAGE_CHANNEL-$RELEASE_CHANNEL}"
if [[ "$PACKAGE_CHANNEL" == "release" ]]; then
  PACKAGE_CHANNEL=""
fi
PACKAGE_JOBS="${MIACODE_PACKAGE_JOBS:-$(nproc 2>/dev/null || echo 4)}"

if [[ -z "$QT_ROOT" && -n "${QT_ROOT_DIR:-}" ]]; then
  QT_ROOT="$QT_ROOT_DIR"
fi

export APPIMAGE_EXTRACT_AND_RUN=1
export DEBIAN_FRONTEND=noninteractive

install_sys_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    # GitHub runners and non-root shells need sudo for apt operations.
    local sudo=""
    if [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
      sudo="sudo"
    fi
    $sudo apt-get update -y
    $sudo apt-get install -y \
      build-essential \
      cmake \
      ninja-build \
      pkg-config \
      git \
      git-lfs \
      curl \
      wget \
      patchelf \
      file \
      python3 \
      python3-venv \
      libgl1-mesa-dev \
      libegl1-mesa-dev \
      libxkbcommon-dev \
      libxkbcommon-x11-0 \
      libxkbcommon-x11-dev \
      libxcb-cursor0 \
      libxcb-cursor-dev \
      libxcb-xkb-dev \
      libxcb-xinerama0 \
      libxcb-randr0 \
      libxcb-keysyms1 \
      libxcb-image0 \
      libxcb-shm0 \
      libxcb-icccm4 \
      libxcb-sync1 \
      libxcb-xfixes0 \
      libxcb-shape0 \
      libxcb-render-util0 \
      libxcb-util1 \
      libxcb1-dev \
      libpulse-dev \
      libasound2-dev \
      libva-dev \
      libva-drm2 \
      libdrm-dev \
      libavcodec-dev \
      libavformat-dev \
      libavutil-dev \
      libswscale-dev \
      libswresample-dev \
      libavfilter-dev \
      libfuse2 || true \
      fuse || true \
      xz-utils \
      zlib1g-dev
  else
    echo "apt-get not found, skipping system deps" >&2
  fi
}

ensure_aqt() {
  local venv="$HOME/.local/aqt-venv"
  if [[ ! -x "$venv/bin/aqt" ]]; then
    mkdir -p "$HOME/.local"
    python3 -m venv "$venv"
    "$venv/bin/pip" install -q "aqtinstall==3.3.*" "py7zr==1.0.*"
  fi
  echo "$venv/bin/aqt"
}

export_qt_env() {
  # linuxdeploy-plugin-qt locates Qt through qmake, and the build tools
  # (qmake, moc, rcc, uic) must resolve to this Qt, not a system Qt5.
  local qt_prefix="$1"
  export QT_ROOT_DIR="$qt_prefix"
  export QT_ROOT="$qt_prefix"
  export CMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH:-$qt_prefix}"
  if [[ -x "$qt_prefix/bin/qmake6" ]]; then
    export QMAKE="$qt_prefix/bin/qmake6"
  elif [[ -x "$qt_prefix/bin/qmake" ]]; then
    export QMAKE="$qt_prefix/bin/qmake"
  fi
  export PATH="$qt_prefix/bin:$PATH"
}

ensure_qt() {
  if [[ -n "$QT_ROOT" && -d "$QT_ROOT" && (-x "$QT_ROOT/bin/qmake6" || -x "$QT_ROOT/bin/qmake") ]]; then
    echo "Using existing Qt at $QT_ROOT"
    export_qt_env "$QT_ROOT"
    return
  fi
  local aqt_bin
  aqt_bin="$(ensure_aqt)"
  QT_ROOT="$ROOT_DIR/.qt/6.11.1/gcc_64"
  if [[ -x "$QT_ROOT/bin/qmake6" || -x "$QT_ROOT/bin/qmake" ]]; then
    echo "Qt already present at $QT_ROOT"
  else
    "$aqt_bin" install-qt linux desktop 6.11.1 linux_gcc_64 --outputdir "$ROOT_DIR/.qt" --modules qtmultimedia qtshadertools
  fi
  export_qt_env "$QT_ROOT"
}

ensure_ffmpeg() {
  local ffmpeg_dir="$ROOT_DIR/third_party/ffmpeg/linux"
  mkdir -p "$ffmpeg_dir"
  if [[ -x "$ffmpeg_dir/ffmpeg" && -s "$ffmpeg_dir/ffmpeg" ]]; then
    echo "FFmpeg exists at $ffmpeg_dir/ffmpeg"
    return
  fi
  if bash "$ROOT_DIR/scripts/ffmpeg/ensure-linux-ffmpeg.sh" 2>/dev/null; then
    return
  fi
  echo "ensure-linux-ffmpeg.sh failed, falling back to system ffmpeg"
  if command -v ffmpeg >/dev/null 2>&1; then
    cp "$(command -v ffmpeg)" "$ffmpeg_dir/ffmpeg"
    chmod +x "$ffmpeg_dir/ffmpeg"
  else
    echo "No ffmpeg available" >&2
    exit 1
  fi
}

ensure_linuxdeploy() {
  mkdir -p "$HOME/.local/bin"
  if [[ -x "$HOME/.local/bin/linuxdeploy" ]]; then
    chmod +x "$HOME/.local/bin/linuxdeploy"
    echo "$HOME/.local/bin/linuxdeploy"
    return
  fi
  curl -L --retry 3 -o "$HOME/.local/bin/linuxdeploy" "https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-x86_64.AppImage"
  chmod +x "$HOME/.local/bin/linuxdeploy"
  echo "$HOME/.local/bin/linuxdeploy"
}

ensure_linuxdeploy_plugin_qt() {
  mkdir -p "$HOME/.local/bin"
  if [[ -x "$HOME/.local/bin/linuxdeploy-plugin-qt" ]]; then
    chmod +x "$HOME/.local/bin/linuxdeploy-plugin-qt"
    echo "$HOME/.local/bin/linuxdeploy-plugin-qt"
    return
  fi
  curl -L --retry 3 -o "$HOME/.local/bin/linuxdeploy-plugin-qt" "https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/1-alpha-20250213-1/linuxdeploy-plugin-qt-x86_64.AppImage"
  chmod +x "$HOME/.local/bin/linuxdeploy-plugin-qt"
  echo "$HOME/.local/bin/linuxdeploy-plugin-qt"
}

ensure_appimagetool() {
  mkdir -p "$HOME/.local/bin"
  if [[ -x "$HOME/.local/bin/appimagetool" ]]; then
    chmod +x "$HOME/.local/bin/appimagetool"
    echo "$HOME/.local/bin/appimagetool"
    return
  fi
  curl -L --retry 3 -o "$HOME/.local/bin/appimagetool" "https://github.com/AppImage/AppImageKit/releases/download/13/appimagetool-x86_64.AppImage"
  chmod +x "$HOME/.local/bin/appimagetool"
  echo "$HOME/.local/bin/appimagetool"
}

export PATH="$HOME/.local/bin:$PATH"
export APPIMAGE_EXTRACT_AND_RUN=1

install_sys_deps
ensure_qt
ensure_ffmpeg
ensure_linuxdeploy
ensure_linuxdeploy_plugin_qt
ensure_appimagetool

parse_version() {
  local cmake_file="$1"
  major="$(grep -Eo 'set\(MIACODE_VERSION_MAJOR\s+"[^"]+"' "$cmake_file" | sed -E 's/.*"([^"]+)"/\1/')"
  minor="$(grep -Eo 'set\(MIACODE_VERSION_MINOR\s+"[^"]+"' "$cmake_file" | sed -E 's/.*"([^"]+)"/\1/')"
  patch="$(grep -Eo 'set\(MIACODE_VERSION_PATCH\s+"[^"]+"' "$cmake_file" | sed -E 's/.*"([^"]+)"/\1/')"
  prerelease="$(grep -Eo 'set\(MIACODE_VERSION_PRERELEASE\s+"[^"]*"' "$cmake_file" | sed -E 's/.*"([^"]*)"/\1/' || true)"
  version="${major}.${minor}.${patch}"
  [[ -n "$prerelease" ]] && version="${version}-${prerelease}"
  echo "$version"
}

package_step() {
  printf '\n==> [package] %s\n' "$*"
}

VERSION="$(parse_version "$ROOT_DIR/CMakeLists.txt")"
PACKAGE_NAME="MiaCode_${VERSION}"
if [[ -n "$PACKAGE_CHANNEL" ]]; then
  PACKAGE_NAME+="_${PACKAGE_CHANNEL}"
fi
PACKAGE_NAME+="_linux_x86_64"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist/$PACKAGE_NAME}"
APPDIR="${DIST_DIR}/AppDir"

package_step "Configuring Release build in $BUILD_DIR"
cmake_args=(
  -S "$ROOT_DIR"
  -B "$BUILD_DIR"
  -DCMAKE_BUILD_TYPE=Release
  "-DMIACODE_RELEASE_CHANNEL=$RELEASE_CHANNEL"
  "-DMIACODE_BUILD_DEV_TOOLS=$MIACODE_BUILD_DEV_TOOLS"
)
if [[ -n "$QT_ROOT" ]]; then
  cmake_args+=("-DCMAKE_PREFIX_PATH=$QT_ROOT")
fi
cmake "${cmake_args[@]}"

package_step "Building MiaCode"
build_args=(--build "$BUILD_DIR" --config Release --parallel "$PACKAGE_JOBS" --target MiaCode)
cmake "${build_args[@]}"

APP_BINARY=""
for candidate in "$BUILD_DIR/bin/MiaCode" "$BUILD_DIR/MiaCode"; do
  if [[ -f "$candidate" && -x "$candidate" ]]; then
    APP_BINARY="$candidate"
    break
  fi
done
if [[ -z "$APP_BINARY" ]]; then
  echo "MiaCode binary not found in $BUILD_DIR" >&2
  exit 1
fi

package_step "Preparing AppDir"
rm -rf "$DIST_DIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/share/icons/hicolor/512x512/apps" "$APPDIR/usr/share/applications"

cp "$APP_BINARY" "$APPDIR/usr/bin/MiaCode"
chmod +x "$APPDIR/usr/bin/MiaCode"

if [[ -d "$BUILD_DIR/bin/assets" ]]; then
  cp -R "$BUILD_DIR/bin/assets" "$APPDIR/usr/bin/"
elif [[ -d "$BUILD_DIR/assets" ]]; then
  cp -R "$BUILD_DIR/assets" "$APPDIR/usr/bin/"
elif [[ -d "$ROOT_DIR/assets" ]]; then
  mkdir -p "$APPDIR/usr/share"
  cp -R "$ROOT_DIR/assets" "$APPDIR/usr/share/"
fi

for lib in "$BUILD_DIR/bin"/*.so*; do
  [[ -e "$lib" ]] || continue
  cp -L "$lib" "$APPDIR/usr/lib/" 2>/dev/null || true
done

for f in LICENSE THIRD_PARTY_NOTICES.md; do
  [[ -f "$ROOT_DIR/$f" ]] && cp "$ROOT_DIR/$f" "$DIST_DIR/"
done
[[ -d "$ROOT_DIR/licenses" ]] && cp -R "$ROOT_DIR/licenses" "$DIST_DIR/licenses"

ICON_SOURCE="$ROOT_DIR/resources/icons/app.png"
if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$APPDIR/usr/share/icons/hicolor/512x512/apps/miacode.png"
fi

cat > "$APPDIR/usr/share/applications/miacode.desktop" <<'EOF'
[Desktop Entry]
Name=MiaCode
Exec=MiaCode
Type=Application
Icon=miacode
Categories=Graphics;AudioVideo;
Terminal=false
EOF

FFMPEG_SRC="$ROOT_DIR/third_party/ffmpeg/linux/ffmpeg"
if [[ -f "$FFMPEG_SRC" && -x "$FFMPEG_SRC" ]]; then
  mkdir -p "$APPDIR/usr/bin/ffmpeg"
  cp "$FFMPEG_SRC" "$APPDIR/usr/bin/ffmpeg/ffmpeg"
  chmod +x "$APPDIR/usr/bin/ffmpeg/ffmpeg"
fi

package_step "Deploying with linuxdeploy"
LINUXDEPLOY_BIN="$(command -v linuxdeploy || echo "$HOME/.local/bin/linuxdeploy")"
APPIMAGETOOL_BIN="$(command -v appimagetool || echo "$HOME/.local/bin/appimagetool")"

export APPIMAGE_EXTRACT_AND_RUN=1
if [[ -n "${QMAKE:-}" ]]; then
  export QMAKE
fi

"$LINUXDEPLOY_BIN" \
  --appdir="$APPDIR" \
  --executable="$APPDIR/usr/bin/MiaCode" \
  --desktop-file="$APPDIR/usr/share/applications/miacode.desktop" \
  --icon-file="$APPDIR/usr/share/icons/hicolor/512x512/apps/miacode.png" \
  --plugin qt \
  --output appimage

APPIMAGE_OUTPUT=""
for candidate in "$ROOT_DIR"/MiaCode-*.AppImage "$(pwd)"/MiaCode-*.AppImage "$DIST_DIR"/../MiaCode-*.AppImage; do
  if [[ -f "$candidate" ]]; then
    APPIMAGE_OUTPUT="$candidate"
    break
  fi
done
if [[ -z "$APPIMAGE_OUTPUT" ]]; then
  APPIMAGE_OUTPUT="$(find "$ROOT_DIR" "$PWD" -name "MiaCode-*.AppImage" 2>/dev/null | head -n 1 || true)"
fi

TARGET_APPIMAGE="${DIST_DIR}/${PACKAGE_NAME}.AppImage"
mkdir -p "$(dirname "$TARGET_APPIMAGE")"
if [[ -n "$APPIMAGE_OUTPUT" && -f "$APPIMAGE_OUTPUT" ]]; then
  mv "$APPIMAGE_OUTPUT" "$TARGET_APPIMAGE"
else
  "$APPIMAGETOOL_BIN" "$APPDIR" "$TARGET_APPIMAGE"
fi
chmod +x "$TARGET_APPIMAGE"

package_step "Packaging complete"
echo "AppImage created: $TARGET_APPIMAGE"
echo "Package dir: $DIST_DIR"
