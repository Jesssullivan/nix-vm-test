{ pkgs, package, system }:
let
  lib = package;
  graphicalRuntimeSetup = ''
    vm.succeed(
      "dnf install -y "
      "dbus-x11 "
      "mesa-dri-drivers "
      "mutter "
      "xorg-x11-server-Xwayland "
      "xorg-x11-xauth "
      "xprop "
      "xwayland-run"
    )
    vm.succeed("command -v dbus-run-session")
    vm.succeed("command -v mutter")
    vm.succeed("command -v xprop")
    vm.succeed("command -v xwfb-run")
    vm.succeed("install -d -m 700 /tmp/graphical-runtime")
  '';
  budgieGraphicalHarness = pkgs.runCommandNoCC "budgie-graphical-harness" {} ''
    mkdir -p "$out"

    cat > "$out/manifest.json" <<'EOF'
    {
      "target": "rocky-10_1-budgie-graphical-harness-test",
      "kind": "budgie-graphical-harness",
      "session_entry": "budgie-session",
      "persistence_service": "budgie-desktop-services",
      "compositor": "labwc",
      "full_session_target": "rocky-10_1-budgie-graphical-test",
      "current_boundary": "generic-rocky-graphical-bootstrap-with-budgie-package-probe"
    }
    EOF

    cat > "$out/run-harness.sh" <<'EOF'
    #!/usr/bin/env bash
    set -euo pipefail

    manifest_path="''${1:?manifest path required}"
    summary_path="''${2:?summary path required}"

    xprop -root > /tmp/budgie-graphical-harness-root-window.txt

    python3 - "$manifest_path" "$summary_path" <<'PY'
    import json
    import subprocess
    import sys

    manifest_path, summary_path = sys.argv[1], sys.argv[2]

    with open(manifest_path, "r", encoding="utf-8") as handle:
        manifest = json.load(handle)

    package_names = [
        manifest["session_entry"],
        manifest["persistence_service"],
        manifest["compositor"],
        "labwc-session",
    ]

    def probe_package(name: str) -> dict:
        result = subprocess.run(
            ["dnf", "repoquery", "--available", "--qf", "%{name}", name],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        return {
            "name": name,
            "available": name in lines,
            "matches": lines,
        }

    summary = {
        "kind": manifest["kind"],
        "target": manifest["target"],
        "full_session_target": manifest["full_session_target"],
        "current_boundary": manifest["current_boundary"],
        "generic_graphical_bootstrap": True,
        "package_probes": [probe_package(name) for name in package_names],
    }

    with open(summary_path, "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2)
        handle.write("\n")
    PY
    EOF

    chmod +x "$out/run-harness.sh"
  '';
  multiUserTest = runner: (runner {
    sharedDirs = {};
    testScript = ''
      vm.wait_for_unit("multi-user.target")
    '';
  }).sandboxed;
  graphicalBootstrapTest = runner: (runner {
    sharedDirs = {};
    testScript = ''
      vm.wait_for_unit("multi-user.target")
    '' + graphicalRuntimeSetup + ''
      vm.succeed("""
        timeout 180 bash -lc '
          set -euo pipefail
          export NO_AT_BRIDGE=1
          export XDG_RUNTIME_DIR=/tmp/graphical-runtime
          export GSETTINGS_BACKEND=memory
          dbus-run-session -- \
            xwfb-run -c mutter -- \
            bash -lc "xprop -root > /tmp/graphical-bootstrap-root-window.txt"
        '
      """)
      vm.succeed("test -s /tmp/graphical-bootstrap-root-window.txt")
    '';
  }).sandboxed;
  budgieGraphicalHarnessTest = runner: (runner {
    sharedDirs = {
      budgieGraphicalHarness = {
        source = budgieGraphicalHarness;
        target = "/tmp/budgie-graphical-harness";
      };
    };
    testScript = ''
      vm.wait_for_unit("multi-user.target")
    '' + graphicalRuntimeSetup + ''
      vm.succeed("command -v python3")
      vm.succeed("dnf repoquery --help >/dev/null")
      vm.succeed("test -f /tmp/budgie-graphical-harness/manifest.json")
      vm.succeed("test -x /tmp/budgie-graphical-harness/run-harness.sh")
      vm.succeed("grep -q 'budgie-session' /tmp/budgie-graphical-harness/manifest.json")
      vm.succeed("""
        timeout 180 bash -lc '
          set -euo pipefail
          export NO_AT_BRIDGE=1
          export XDG_RUNTIME_DIR=/tmp/graphical-runtime
          export GSETTINGS_BACKEND=memory
          dbus-run-session -- \
            xwfb-run -c mutter -- \
            /tmp/budgie-graphical-harness/run-harness.sh \
              /tmp/budgie-graphical-harness/manifest.json \
              /tmp/budgie-graphical-harness-summary.json
        '
      """)
      vm.succeed("test -s /tmp/budgie-graphical-harness-root-window.txt")
      vm.succeed("test -s /tmp/budgie-graphical-harness-summary.json")
      vm.succeed("grep -q 'budgie-session' /tmp/budgie-graphical-harness-summary.json")
      vm.succeed("grep -q 'budgie-desktop-services' /tmp/budgie-graphical-harness-summary.json")
      vm.succeed("grep -q 'labwc' /tmp/budgie-graphical-harness-summary.json")
    '';
  }).sandboxed;
  runTestOnEveryImage = test:
    pkgs.lib.mapAttrs'
    (n: v: pkgs.lib.nameValuePair "${n}-multi-user-test" (test lib.rocky.${n}))
    lib.rocky.images;
in
runTestOnEveryImage multiUserTest //
{
  "10_1-graphical-bootstrap-test" = graphicalBootstrapTest lib.rocky."10_1";
  "10_1-budgie-graphical-harness-test" = budgieGraphicalHarnessTest lib.rocky."10_1";
} //
package.rocky.images
