{ lib
, appimageTools
, fetchurl
, bash
, coreutils
, findutils
, wayland
}:

let
  pname = "donutbrowser";
  version = "0.30.0";

  # Updated automatically by scripts/update-version.sh
  assetName = "Donut_0.30.0_amd64.AppImage";

  src = fetchurl {
    url = "https://github.com/zhom/donutbrowser/releases/download/v${version}/${assetName}";
    hash = "sha256-Vcs7ZyWUOcny+ZjoxoP5U6laOTXbqMFAdr+DZABUeJM=";
  };

  appimageContents = appimageTools.extractType2 {
    inherit pname version src;

    postExtract = ''
      if [ -L "$out/Donut.desktop" ]; then
        rm "$out/Donut.desktop"
      fi
      if [ ! -e "$out/Donut.desktop" ]; then
        if [ -f "$out/usr/share/applications/Donut.desktop" ]; then
          ln -s usr/share/applications/Donut.desktop "$out/Donut.desktop"
        elif [ -f "$out/usr/share/applications/donutbrowser.desktop" ]; then
          ln -s usr/share/applications/donutbrowser.desktop "$out/Donut.desktop"
        fi
      fi

      if [ -L "$out/.DirIcon" ]; then
        rm "$out/.DirIcon"
      fi
      if [ ! -e "$out/.DirIcon" ]; then
        if [ -f "$out/Donut.png" ]; then
          ln -s Donut.png "$out/.DirIcon"
        elif [ -f "$out/usr/share/icons/hicolor/128x128/apps/donutbrowser.png" ]; then
          ln -s usr/share/icons/hicolor/128x128/apps/donutbrowser.png "$out/.DirIcon"
        fi
      fi

      # The extracted payload ships an older Wayland client ABI than the
      # wrapper runtime, which crashes Firefox on touchpad scroll under Hyprland
      # ("wl_pointer has no event 9"). Remove these stale copies so runtime
      # resolution falls through to the newer Wayland libs from the FHS env.
      rm -f \
        "$out/usr/lib/libwayland-client.so.0" \
        "$out/usr/lib/libwayland-cursor.so.0" \
        "$out/usr/lib/libwayland-egl.so.1"

      # Upstream AppImage hook forces GTK onto X11, which makes Donutbrowser and
      # spawned browsers run through XWayland.
      if [ -f "$out/apprun-hooks/linuxdeploy-plugin-gtk.sh" ]; then
        sed -i 's|^export GDK_BACKEND=x11.*|export GDK_BACKEND="''${GDK_BACKEND:-wayland,x11}"|' \
          "$out/apprun-hooks/linuxdeploy-plugin-gtk.sh"
      fi
    '';
  };
in
appimageTools.wrapAppImage {
  inherit pname version;
  src = appimageContents;

  passthru = {
    inherit src;
  };

  extraInstallCommands = ''
    if [ -f ${appimageContents}/donutbrowser.desktop ]; then
      install -Dm444 ${appimageContents}/donutbrowser.desktop $out/share/applications/donutbrowser.desktop
      sed -i 's#^Exec=.*#Exec=donutbrowser %u#' $out/share/applications/donutbrowser.desktop
      sed -i 's#^Icon=.*#Icon=donutbrowser#' $out/share/applications/donutbrowser.desktop
    elif [ -f ${appimageContents}/usr/share/applications/donutbrowser.desktop ]; then
      install -Dm444 ${appimageContents}/usr/share/applications/donutbrowser.desktop $out/share/applications/donutbrowser.desktop
      sed -i 's#^Exec=.*#Exec=donutbrowser %u#' $out/share/applications/donutbrowser.desktop
      sed -i 's#^Icon=.*#Icon=donutbrowser#' $out/share/applications/donutbrowser.desktop
    fi

    if [ -f ${appimageContents}/donutbrowser.png ]; then
      install -Dm444 ${appimageContents}/donutbrowser.png $out/share/icons/hicolor/512x512/apps/donutbrowser.png
    elif [ -f ${appimageContents}/usr/share/icons/hicolor/512x512/apps/donutbrowser.png ]; then
      install -Dm444 ${appimageContents}/usr/share/icons/hicolor/512x512/apps/donutbrowser.png $out/share/icons/hicolor/512x512/apps/donutbrowser.png
    fi

    # Prevent upstream cleanup bug from deleting downloaded browser binaries on startup.
    # Keep browser root dirs writable (for new downloads) but lock version dirs.
    mv $out/bin/donutbrowser $out/bin/.donutbrowser-wrapped
    cat > $out/bin/donutbrowser <<'EOF'
#!${bash}/bin/bash
set -euo pipefail

export MOZ_ENABLE_WAYLAND="''${MOZ_ENABLE_WAYLAND:-1}"
export GDK_BACKEND="''${GDK_BACKEND:-wayland,x11}"
export XDG_SESSION_TYPE="''${XDG_SESSION_TYPE:-wayland}"

if [ -z "''${WAYLAND_DISPLAY:-}" ] && [ -n "''${XDG_RUNTIME_DIR:-}" ]; then
  for sock in "$XDG_RUNTIME_DIR"/wayland-*; do
    if [ -S "$sock" ]; then
      export WAYLAND_DISPLAY="$(basename "$sock")"
      break
    fi
  done
fi

if [ "''${DONUTBROWSER_ALLOW_BINARY_CLEANUP:-0}" != "1" ]; then
  data_home="''${XDG_DATA_HOME:-$HOME/.local/share}"
  binaries_dir="$data_home/DonutBrowser/binaries"
  protect_secs="''${DONUTBROWSER_STARTUP_PROTECT_SECS:-8}"

  if [ -d "$binaries_dir" ]; then
    ${findutils}/bin/find "$binaries_dir" -mindepth 1 -maxdepth 1 -type d \
      -exec ${coreutils}/bin/chmod u+w '{}' + 2>/dev/null || true
    ${findutils}/bin/find "$binaries_dir" -mindepth 2 -maxdepth 2 -type d \
      -exec ${coreutils}/bin/chmod u-w '{}' + 2>/dev/null || true

    # Upstream bug runs cleanup immediately on startup.
    # Keep versions protected only for startup window, then restore writability
    # so normal downloads/extraction continue to work.
    (
      ${coreutils}/bin/sleep "$protect_secs"
      ${findutils}/bin/find "$binaries_dir" -mindepth 2 -maxdepth 2 -type d \
        -exec ${coreutils}/bin/chmod u+w '{}' + 2>/dev/null || true
    ) &
  fi
fi

script_dir="$(${coreutils}/bin/dirname "$0")"

# DonutBrowser's bundled AppImage ships an old libwayland-client (wl_seat v7),
# which crashes Firefox on Hyprland touchpad scroll with:
# "interface 'wl_pointer' has no event 9".
# Preload Nixpkgs Wayland libs so spawned browsers use a modern protocol stack.
if [ "''${DONUTBROWSER_DISABLE_WAYLAND_PRELOAD:-0}" != "1" ]; then
  export LD_PRELOAD="${wayland}/lib/libwayland-client.so.0:${wayland}/lib/libwayland-cursor.so.0''${LD_PRELOAD:+:$LD_PRELOAD}"
fi

exec "$script_dir/.donutbrowser-wrapped" "$@"
EOF
    ${coreutils}/bin/chmod 0755 $out/bin/donutbrowser
  '';

  meta = with lib; {
    description = "Powerful anti-detect browser that puts you in control of your browsing experience";
    homepage = "https://github.com/zhom/donutbrowser";
    license = licenses.agpl3Only;
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "donutbrowser";
  };
}
