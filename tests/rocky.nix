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
  budgieGraphicalHarnessManifest = builtins.toJSON {
    target = "rocky-10_1-budgie-graphical-harness-test";
    kind = "budgie-graphical-harness";
    session_entry = "budgie-session";
    persistence_service = "budgie-desktop-services";
    compositor = "labwc";
    full_session_target = "rocky-10_1-budgie-graphical-test";
    current_boundary = "generic-rocky-graphical-bootstrap-with-budgie-package-probe";
  };
  budgieGraphicalHarnessScript = ''
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
  '';
  budgieGraphicalHarnessWriter = pkgs.lib.escapeShellArg ''
    from pathlib import Path

    harness_dir = Path("/tmp/budgie-graphical-harness")
    harness_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    (harness_dir / "manifest.json").write_text(
        ${builtins.toJSON budgieGraphicalHarnessManifest} + "\n",
        encoding="utf-8",
    )
    script_path = harness_dir / "run-harness.sh"
    script_path.write_text(
        ${builtins.toJSON budgieGraphicalHarnessScript},
        encoding="utf-8",
    )
    script_path.chmod(0o755)
  '';
  budgieGraphicalHarnessWriteCommand =
    builtins.toJSON "python3 -c ${budgieGraphicalHarnessWriter}";
  budgieSessionGateManifest = builtins.toJSON {
    target = "rocky-10_1-budgie-session-gate-test";
    kind = "budgie-session-gate";
    desktop_package = "budgie-desktop";
    session_entry = "budgie-session";
    persistence_service = "budgie-desktop-services";
    compositor = "labwc";
    companion_session_package = "labwc-session";
    portal_backend = "xdg-desktop-portal-wlr";
    runtime_helpers = [
      "grim"
      "slurp"
      "swaybg"
      "swayidle"
      "wlopm"
    ];
    session_descriptor_paths = [
      "/usr/share/wayland-sessions/budgie-desktop.desktop"
      "/usr/share/xsessions/budgie-desktop.desktop"
    ];
    full_session_target = "rocky-10_1-budgie-graphical-test";
    current_boundary = "generic-rocky-graphical-bootstrap-with-budgie-session-transaction-probe";
  };
  budgieSessionGateCorePackages = [
    "budgie-desktop"
    "budgie-session"
    "budgie-desktop-services"
  ];
  budgieSessionGateScript = ''
    #!/usr/bin/env bash
    set -euo pipefail

    manifest_path="''${1:?manifest path required}"
    summary_path="''${2:?summary path required}"
    transaction_log_path="''${3:?transaction log path required}"

    xprop -root > /tmp/budgie-session-gate-root-window.txt

    python3 - "$manifest_path" "$summary_path" "$transaction_log_path" <<'PY'
    import json
    import subprocess
    import sys

    manifest_path, summary_path, transaction_log_path = sys.argv[1:4]

    with open(manifest_path, "r", encoding="utf-8") as handle:
        manifest = json.load(handle)

    package_names = [
        manifest["desktop_package"],
        manifest["session_entry"],
        manifest["persistence_service"],
        manifest["compositor"],
        manifest["companion_session_package"],
        manifest["portal_backend"],
        *manifest["runtime_helpers"],
    ]

    session_descriptor_paths = manifest["session_descriptor_paths"]

    def run_command(command: list[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )

    def probe_package(name: str) -> dict:
        result = run_command(
            ["dnf", "repoquery", "--available", "--qf", "%{name}", name]
        )
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        return {
            "name": name,
            "available": name in lines,
            "matches": lines,
        }

    def list_package_files(name: str) -> list[str]:
        result = run_command(["dnf", "repoquery", "--available", "--list", name])
        if result.returncode != 0:
            return []
        return [line.strip() for line in result.stdout.splitlines() if line.strip()]

    package_probes = [probe_package(name) for name in package_names]
    descriptor_providers = []
    for probe in package_probes:
        if not probe["available"]:
            continue
        files = list_package_files(probe["name"])
        matched_paths = [
            descriptor_path
            for descriptor_path in session_descriptor_paths
            if descriptor_path in files
        ]
        if matched_paths:
            descriptor_providers.append(
                {
                    "name": probe["name"],
                    "paths": matched_paths,
                }
            )

    transaction_probe = run_command(["dnf", "install", "--assumeno", *package_names])
    transaction_output = transaction_probe.stdout
    no_match_markers = [
        "No match for argument:",
        "No package matches",
        "Unable to find a match",
    ]
    missing_packages = [
        probe["name"] for probe in package_probes if not probe["available"]
    ]
    full_session_transaction_ready = (
        not missing_packages
        and not any(marker in transaction_output for marker in no_match_markers)
    )

    transaction_summary = {
        "packages": package_names,
        "returncode": transaction_probe.returncode,
        "missing_packages": missing_packages,
        "full_session_transaction_ready": full_session_transaction_ready,
        "missing_match_error": any(
            marker in transaction_output for marker in no_match_markers
        ),
        "output_excerpt": transaction_output.splitlines()[:80],
    }

    summary = {
        "kind": manifest["kind"],
        "target": manifest["target"],
        "full_session_target": manifest["full_session_target"],
        "current_boundary": manifest["current_boundary"],
        "generic_graphical_bootstrap": True,
        "session_descriptor_paths": session_descriptor_paths,
        "package_probes": package_probes,
        "descriptor_providers": descriptor_providers,
        "transaction_probe": transaction_summary,
    }

    with open(summary_path, "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2)
        handle.write("\n")

    with open(transaction_log_path, "w", encoding="utf-8") as handle:
        handle.write(transaction_output)
    PY
  '';
  budgieSessionGateWriter = pkgs.lib.escapeShellArg ''
    from pathlib import Path

    gate_dir = Path("/tmp/budgie-session-gate")
    gate_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    (gate_dir / "manifest.json").write_text(
        ${builtins.toJSON budgieSessionGateManifest} + "\n",
        encoding="utf-8",
    )
    script_path = gate_dir / "run-session-gate.sh"
    script_path.write_text(
        ${builtins.toJSON budgieSessionGateScript},
        encoding="utf-8",
    )
    script_path.chmod(0o755)
  '';
  budgieSessionGateWriteCommand =
    builtins.toJSON "python3 -c ${budgieSessionGateWriter}";
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
    sharedDirs = {};
    testScript = ''
      vm.wait_for_unit("multi-user.target")
    '' + graphicalRuntimeSetup + ''
      vm.succeed("command -v python3")
      vm.succeed("dnf repoquery --help >/dev/null")
      vm.succeed(${budgieGraphicalHarnessWriteCommand})
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
  budgieSessionGateTest = runner: (runner {
    sharedDirs = {};
    testScript = ''
      vm.wait_for_unit("multi-user.target")
    '' + graphicalRuntimeSetup + ''
      vm.succeed("command -v python3")
      vm.succeed("dnf repoquery --help >/dev/null")
      vm.succeed(${budgieSessionGateWriteCommand})
      vm.succeed("test -f /tmp/budgie-session-gate/manifest.json")
      vm.succeed("test -x /tmp/budgie-session-gate/run-session-gate.sh")
      vm.succeed("grep -q 'budgie-desktop' /tmp/budgie-session-gate/manifest.json")
      vm.succeed("grep -q 'budgie-session' /tmp/budgie-session-gate/manifest.json")
      vm.succeed("""
        timeout 240 bash -lc '
          set -euo pipefail
          export NO_AT_BRIDGE=1
          export XDG_RUNTIME_DIR=/tmp/graphical-runtime
          export GSETTINGS_BACKEND=memory
          dbus-run-session -- \
            xwfb-run -c mutter -- \
            /tmp/budgie-session-gate/run-session-gate.sh \
              /tmp/budgie-session-gate/manifest.json \
              /tmp/budgie-session-gate-summary.json \
              /tmp/budgie-session-gate-transaction.log
        '
      """)
      vm.succeed("test -s /tmp/budgie-session-gate-root-window.txt")
      vm.succeed("test -s /tmp/budgie-session-gate-summary.json")
      vm.succeed("test -e /tmp/budgie-session-gate-transaction.log")
      vm.succeed("grep -q 'budgie-desktop' /tmp/budgie-session-gate-summary.json")
      vm.succeed("grep -q 'budgie-session' /tmp/budgie-session-gate-summary.json")
      vm.succeed("grep -q 'budgie-desktop-services' /tmp/budgie-session-gate-summary.json")
      vm.succeed("grep -q 'labwc' /tmp/budgie-session-gate-summary.json")
      vm.succeed("grep -q 'xdg-desktop-portal-wlr' /tmp/budgie-session-gate-summary.json")
      vm.succeed("""
        python3 - <<'PY'
        import json

        with open("/tmp/budgie-session-gate-summary.json", "r", encoding="utf-8") as handle:
            summary = json.load(handle)

        expected_missing = set(${builtins.toJSON budgieSessionGateCorePackages})
        observed_missing = set(summary["transaction_probe"]["missing_packages"])

        if summary["transaction_probe"]["full_session_transaction_ready"]:
            raise SystemExit("Budgie full-session transaction unexpectedly became ready")

        if summary["descriptor_providers"]:
            raise SystemExit(
                f"unexpected Budgie session descriptor providers: {summary['descriptor_providers']}"
            )

        missing_core = expected_missing - observed_missing
        if missing_core:
            raise SystemExit(
                f"expected core Budgie session packages to remain unresolved, missing check for: {sorted(missing_core)}"
            )
        PY
      """)
      vm.succeed("cat /tmp/budgie-session-gate-summary.json")
      vm.succeed("sed -n '1,120p' /tmp/budgie-session-gate-transaction.log || true")
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
  "10_1-budgie-session-gate-test" = budgieSessionGateTest lib.rocky."10_1";
} //
package.rocky.images
