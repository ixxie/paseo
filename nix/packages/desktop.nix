{
  lib,
  stdenv,
  nodejs_22,
  pnpm_10,
  pnpmConfigHook,
  python3,
  makeWrapper,
  copyDesktopItems,
  makeDesktopItem,
  electron,
  libuv,
  # Share the daemon's pnpmDeps FOD. Same lockfile, same content;
  # passing `paseo` through means downstream `paseo.override
  # { pnpmDepsHash = "..."; }` flows transitively to the desktop drv,
  # and we don't run prefetch twice.
  paseo,
}:

stdenv.mkDerivation {
  pname = "paseo-desktop";
  version = (builtins.fromJSON (builtins.readFile ../../package.json)).version;

  src = lib.cleanSourceWith {
    src = ../..;
    filter =
      path: type:
      let
        baseName = builtins.baseNameOf path;
        relPath = lib.removePrefix (toString ../..) path;
      in
      # Exclude mobile-only platform code (we only need the web/electron build)
      !(lib.hasPrefix "/packages/app/android" relPath)
      && !(lib.hasPrefix "/packages/app/ios" relPath)
      # Website is unrelated to the desktop app
      && !(lib.hasPrefix "/packages/website" relPath)
      # Test fixtures and build artifacts
      && !(lib.hasSuffix ".test.ts" baseName)
      && !(lib.hasSuffix ".e2e.test.ts" baseName)
      && baseName != "node_modules"
      && baseName != ".git"
      && baseName != ".paseo"
      && baseName != ".DS_Store"
      && baseName != "release";
  };

  nativeBuildInputs = [
    nodejs_22
    pnpm_10
    pnpmConfigHook
    python3 # for node-gyp (node-pty compilation)
    makeWrapper
    copyDesktopItems
  ];

  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ libuv ];

  inherit (paseo) pnpmDeps;

  env = {
    EXPO_NO_TELEMETRY = "1";
    # Expo's web build pulls in some pre-bundled assets; ensure it
    # doesn't try to phone home during the build.
    CI = "1";
  };

  buildPhase = ''
    runHook preBuild

    # Native terminal addon (libuv-linked on Linux). The pnpm
    # configHook installed with --ignore-scripts so this is uncompiled.
    pnpm rebuild node-pty

    # Daemon workspaces (highlight + relay + server + cli)
    pnpm run build:daemon

    # App's workspace-only deps not covered by build:daemon (the
    # expo-two-way-audio native module wrapper)
    pnpm --filter @getpaseo/expo-two-way-audio build

    # Expo web export for the Electron renderer
    ( cd packages/app && PASEO_WEB_PLATFORM=electron pnpm exec expo export --platform web )

    # Desktop main process (tsc only — NOT electron-builder; we wrap
    # nixpkgs' electron via makeWrapper instead)
    pnpm --filter @getpaseo/desktop build:main

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # Self-contained deploy of the desktop workspace and its transitive
    # closure (which pulls in @getpaseo/cli and @getpaseo/server). The
    # output is a flat directory with its own node_modules — no shared
    # root, no Expo/RN/Metro/Website hoisted bloat.
    pnpm --filter=@getpaseo/desktop deploy --prod --ignore-scripts $out/share/paseo-desktop/desktop

    # main.ts resolves the Expo renderer assets via
    # `__dirname/../../app/dist` when running unpackaged (app.isPackaged
    # is false when invoked as `electron path/to/main.js`). With main.js
    # at $out/share/paseo-desktop/desktop/dist/main.js, the lookup lands
    # at $out/share/paseo-desktop/app/dist — put the export there.
    mkdir -p $out/share/paseo-desktop/app
    cp -a packages/app/dist $out/share/paseo-desktop/app/dist

    # Hicolor icon for desktop environments
    install -Dm644 packages/desktop/assets/icon.png \
      $out/share/icons/hicolor/512x512/apps/paseo-desktop.png

    mkdir -p $out/bin

    # Launcher wraps nixpkgs electron.
    # --no-sandbox: Chromium's setuid sandbox can't live in /nix/store
    # (immutable, no setuid). Acceptable for v1; a follow-up can wire
    # `security.wrappers` via a NixOS module for users who want the
    # sandbox.
    #
    # EXPO_DEV_URL: We run unpackaged via `electron path/to/main.js`, so
    # `app.isPackaged` is false. In that mode main.ts loads
    # `DEV_SERVER_URL` (defaults to http://localhost:8081 — the Expo dev
    # server, which doesn't exist here). Point it at the `paseo://`
    # protocol handler instead, which serves from
    # `__dirname/../../app/dist`.
    makeWrapper ${electron}/bin/electron $out/bin/paseo-desktop \
      --add-flags "$out/share/paseo-desktop/desktop/dist/main.js" \
      --add-flags "--no-sandbox" \
      --set EXPO_DEV_URL "paseo://app/"

    copyDesktopItems

    runHook postInstall
  '';

  desktopItems = [
    (makeDesktopItem {
      name = "paseo-desktop";
      desktopName = "Paseo";
      genericName = "AI Coding Agents";
      comment = "Self-hosted daemon for AI coding agents";
      exec = "paseo-desktop";
      icon = "paseo-desktop";
      categories = [ "Development" ];
      startupWMClass = "Paseo";
    })
  ];

  meta = {
    description = "Paseo desktop app (Electron wrapper)";
    homepage = "https://github.com/getpaseo/paseo";
    license = lib.licenses.agpl3Plus;
    mainProgram = "paseo-desktop";
    platforms = lib.platforms.linux;
  };
}
