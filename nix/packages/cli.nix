{
  lib,
  stdenv,
  nodejs_22,
  pnpm_10,
  pnpmConfigHook,
  fetchPnpmDeps,
  python3,
  makeWrapper,
  # node-pty needs libuv headers on Linux for its native build
  libuv,
  # Exposed so downstream flakes that follow a different nixpkgs revision
  # can override via `.override { pnpmDepsHash = "sha256-..."; }`. The
  # default is read from a sidecar file so CI can replace the hash with a
  # single file write instead of a sed against this source.
  pnpmDepsHash ? lib.fileContents ../pnpm-deps.hash,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "paseo";
  version = (builtins.fromJSON (builtins.readFile ../../package.json)).version;

  # Build context for the daemon: the four daemon workspaces in full
  # (highlight, relay, server, cli), plus the workspace metadata pnpm needs
  # to resolve `workspace:*` deps and run `pnpm install --offline`.
  # Non-daemon workspaces (app, desktop, website, expo-two-way-audio)
  # contribute only their package.json — pnpm reads them to populate the
  # workspace graph; we don't need their source, assets, or native build
  # artifacts in the daemon's src store path.
  src = lib.cleanSourceWith {
    src = ../..;
    filter =
      path: type:
      let
        baseName = builtins.baseNameOf path;
        relPath = lib.removePrefix (toString ../..) path;
        nonDaemonWorkspaces = [
          "app"
          "desktop"
          "website"
          "expo-two-way-audio"
        ];
        isUnderNonDaemonWorkspace = lib.any (
          ws: lib.hasPrefix "/packages/${ws}/" relPath
        ) nonDaemonWorkspaces;
        isWorkspacePackageJson =
          builtins.match "^/packages/[^/]+/package\\.json$" relPath != null;
      in
      # Non-daemon workspaces contribute only package.json.
      (!isUnderNonDaemonWorkspace || isWorkspacePackageJson)
      # Universal noise.
      && !(lib.hasSuffix ".test.ts" baseName)
      && !(lib.hasSuffix ".e2e.test.ts" baseName)
      && baseName != "node_modules"
      && baseName != ".git"
      && baseName != ".paseo"
      && baseName != ".DS_Store";
  };

  nativeBuildInputs = [
    nodejs_22
    pnpm_10
    pnpmConfigHook
    python3 # for node-gyp (node-pty compilation)
    makeWrapper
  ];

  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    libuv
  ];

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    fetcherVersion = 2;
    hash = pnpmDepsHash;
  };

  buildPhase = ''
    runHook preBuild

    # Compile native addons that the daemon needs at runtime. The pnpm
    # configHook installed with --ignore-scripts, so node-pty arrives
    # uncompiled — rebuild it here against the nixpkgs nodejs ABI.
    # Speech-related native modules (sherpa-onnx, onnxruntime-node) are
    # intentionally left unbuilt: they're lazily loaded and degrade
    # gracefully when unavailable, and their postinstalls fetch
    # binaries from external services (nuget, GitHub) that we can't
    # reach from the build sandbox.
    pnpm rebuild node-pty

    # Build daemon workspaces in topological order. This is a no-op for
    # workspaces with no `build` script (expo-two-way-audio, app, etc.)
    # because we only filter the four daemon ones.
    pnpm run build:daemon

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # pnpm deploy walks the workspace graph and materializes a filter
    # target into a self-contained directory: only that workspace's
    # transitive prod closure, with workspace deps copied in (not
    # symlinked). Deploying `@getpaseo/cli` pulls in @getpaseo/server,
    # @getpaseo/highlight, and @getpaseo/relay transitively — one tree
    # serves both the `paseo` CLI and `paseo-server` daemon entry.
    pnpm --filter=@getpaseo/cli deploy --prod --ignore-scripts $out/lib/paseo

    # CLI shebang script (`#!/usr/bin/env node ...`) lives outside dist
    install -Dm755 packages/cli/bin/paseo $out/lib/paseo/bin/paseo

    # Runtime config files the server expects at $0/../<file>
    for f in agent-prompt.md .env.example; do
      if [ -f packages/server/$f ]; then
        install -Dm644 packages/server/$f \
          $out/lib/paseo/node_modules/@getpaseo/server/$f
      fi
    done

    mkdir -p $out/bin

    # systemd-facing entry point. server's supervisor-entrypoint forks
    # the daemon-worker process and manages restarts.
    makeWrapper ${nodejs_22}/bin/node $out/bin/paseo-server \
      --add-flags "$out/lib/paseo/node_modules/@getpaseo/server/dist/scripts/supervisor-entrypoint.js" \
      --set NODE_ENV production

    # Interactive CLI entry point. NODE_PATH points at the deploy's
    # node_modules so workspace-local resolution works.
    makeWrapper ${nodejs_22}/bin/node $out/bin/paseo \
      --add-flags "$out/lib/paseo/dist/index.js" \
      --set NODE_PATH "$out/lib/paseo/node_modules"

    runHook postInstall
  '';

  meta = {
    description = "Self-hosted daemon for Claude Code, Codex, and OpenCode";
    homepage = "https://github.com/getpaseo/paseo";
    license = lib.licenses.agpl3Plus;
    mainProgram = "paseo";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
})
