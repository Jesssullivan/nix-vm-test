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
  fedora44ConsumerRepoContents = builtins.concatStringsSep "\n" [
    "[fedora44]"
    "name=Fedora 44 - x86_64"
    "metalink=https://mirrors.fedoraproject.org/metalink?repo=fedora-44&arch=x86_64"
    "enabled=1"
    "gpgcheck=0"
    "repo_gpgcheck=0"
    "skip_if_unavailable=False"
    ""
    "[fedora44-updates]"
    "name=Fedora 44 Updates - x86_64"
    "metalink=https://mirrors.fedoraproject.org/metalink?repo=updates-released-f44&arch=x86_64"
    "enabled=1"
    "gpgcheck=0"
    "repo_gpgcheck=0"
    "skip_if_unavailable=False"
  ];
  budgieGraphicalPackages = [
    "budgie-desktop"
    "budgie-session"
    "budgie-desktop-services"
    "labwc"
    "labwc-session"
    "xdg-desktop-portal-wlr"
    "grim"
    "slurp"
    "swaybg"
    "swayidle"
    "wlopm"
    "dbus-daemon"
    "dbus-x11"
    "glib2"
    "mesa-dri-drivers"
    "procps-ng"
    "xorg-x11-server-Xwayland"
    "xorg-x11-xauth"
  ];
  budgieGraphicalManifest = builtins.toJSON {
    target = "rocky-10_1-budgie-graphical-test";
    kind = "budgie-graphical";
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
    package_set = budgieGraphicalPackages;
    epel_release_rpm =
      "https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm";
    fedora_release = "44";
    fedora_repo_path = "/etc/yum.repos.d/fedora44.repo";
    session_descriptor_path = "/usr/share/wayland-sessions/budgie-desktop.desktop";
    session_launcher = "startbudgielabwc";
    session_manager_bus_name = "org.gnome.SessionManager";
    session_manager_object_path = "/org/gnome/SessionManager";
    session_manager_interface = "org.gnome.SessionManager";
    session_binary = "budgie-session-binary";
    current_boundary =
      "first-rocky-budgie-graphical-session-execution-via-fedora44-consumer-repos";
  };
  fedora44ConsumerRepoWriteCommand = "python3 -c ${
    pkgs.lib.escapeShellArg ''
      from pathlib import Path

      Path("/etc/yum.repos.d/fedora44.repo").write_text(
          ${builtins.toJSON (fedora44ConsumerRepoContents + "\n")},
          encoding="utf-8",
      )
    ''
  }";
  budgieGraphicalSessionLaunchCommand = builtins.toJSON ''
    set -euo pipefail

    session_log_path="$BUDGIE_GRAPHICAL_SESSION_LOG_PATH"
    session_manager_path="$BUDGIE_GRAPHICAL_SESSION_MANAGER_PATH"

    export XDG_RUNTIME_DIR=/tmp/budgie-graphical-runtime
    export WLR_BACKENDS=headless
    export WLR_LIBINPUT_NO_DEVICES=1
    export WLR_RENDERER=pixman
    export NO_AT_BRIDGE=1
    export GSETTINGS_BACKEND=memory
    export XDG_CURRENT_DESKTOP=Budgie
    export XDG_SESSION_DESKTOP=Budgie
    export XDG_SESSION_TYPE=wayland
    export QT_QPA_PLATFORM=wayland
    export SDL_VIDEODRIVER=wayland
    export CLUTTER_BACKEND=wayland
    export _JAVA_AWT_WM_NONREPARENTING=1

    rm -f "$session_manager_path"

    startbudgielabwc >"$session_log_path" 2>&1 &
    launcher="$!"
    ready=0

    for _ in $(seq 1 60); do
      if pgrep -x labwc >/dev/null && pgrep -af budgie-session >/tmp/budgie-graphical-session-processes.txt; then
        if gdbus introspect \
          --session \
          --dest org.gnome.SessionManager \
          --object-path /org/gnome/SessionManager \
          >"$session_manager_path"
        then
          ready=1
          break
        fi
      fi
      sleep 1
    done

    pgrep -a labwc >/tmp/budgie-graphical-labwc-processes.txt || true
    pgrep -af budgie-session >/tmp/budgie-graphical-session-processes.txt || true

    if [ "$ready" -ne 1 ]; then
      sed -n "1,200p" "$session_log_path" >&2 || true
      exit 1
    fi

    kill "$launcher" >/dev/null 2>&1 || true
    pkill -TERM -x labwc >/dev/null 2>&1 || true
    pkill -TERM -f budgie-session >/dev/null 2>&1 || true
    wait "$launcher" || true
  '';
  budgieGraphicalAssertionWriter = pkgs.lib.escapeShellArg ''
    import json

    with open("/tmp/budgie-graphical-summary.json", "r", encoding="utf-8") as handle:
        summary = json.load(handle)

    repo_surface = summary["repo_surface"]
    desktop_file = summary["desktop_file"]
    package_install = summary["package_install"]
    session_execution = summary["session_execution"]

    if repo_surface["fedora_release"] != "44":
        raise SystemExit(f"unexpected Fedora consumer release: {repo_surface['fedora_release']}")

    if not repo_surface["consumer_repo_path_exists"]:
        raise SystemExit("Fedora consumer repo file was not created in the guest")

    if not package_install["transaction_succeeded"]:
        raise SystemExit("Budgie graphical package installation did not succeed")

    if "startbudgielabwc" not in desktop_file["exec_line"]:
        raise SystemExit(f"unexpected desktop file Exec line: {desktop_file['exec_line']!r}")

    if not session_execution["labwc_running"]:
        raise SystemExit("labwc did not stay up during the Budgie graphical probe")

    if not session_execution["budgie_session_running"]:
        raise SystemExit("budgie-session did not stay up during the Budgie graphical probe")

    if not session_execution["session_manager_registered"]:
        raise SystemExit("org.gnome.SessionManager did not register on the session bus")
  '';
  budgieGraphicalAssertionCommand =
    builtins.toJSON "python3 -c ${budgieGraphicalAssertionWriter}";
  budgieGraphicalScript = ''
    #!/usr/bin/env bash
    set -euo pipefail

    manifest_path="''${1:?manifest path required}"
    summary_path="''${2:?summary path required}"
    install_log_path="''${3:?install log path required}"
    session_log_path="''${4:?session log path required}"
    session_manager_path="''${5:?session manager path required}"

    dnf install -y ${builtins.toJSON "https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm"} >/dev/null
    dnf install -y dnf-plugins-core >/dev/null
    dnf config-manager --set-enabled crb >/dev/null

    ${fedora44ConsumerRepoWriteCommand}

    dnf install -y --setopt=install_weak_deps=False \
      ${builtins.concatStringsSep " \\\n      " budgieGraphicalPackages} \
      >"$install_log_path"

    command -v dbus-run-session >/dev/null
    command -v gdbus >/dev/null
    command -v pgrep >/dev/null
    command -v startbudgielabwc >/dev/null
    command -v budgie-session >/dev/null

    desktop_file="/usr/share/wayland-sessions/budgie-desktop.desktop"
    test -f "$desktop_file"
    grep -q '^Exec=.*/startbudgielabwc$' "$desktop_file"

    install -d -m 700 /tmp/budgie-graphical-runtime

    export BUDGIE_GRAPHICAL_SESSION_LOG_PATH="$session_log_path"
    export BUDGIE_GRAPHICAL_SESSION_MANAGER_PATH="$session_manager_path"
    dbus-run-session -- bash -lc ${budgieGraphicalSessionLaunchCommand}

    python3 - "$manifest_path" "$summary_path" "$install_log_path" "$session_log_path" "$session_manager_path" <<'PY'
    import json
    from pathlib import Path
    import subprocess
    import sys

    manifest_path, summary_path, install_log_path, session_log_path, session_manager_path = sys.argv[1:6]

    with open(manifest_path, "r", encoding="utf-8") as handle:
        manifest = json.load(handle)

    def read_lines(path: str, limit: int = 80) -> list[str]:
        file_path = Path(path)
        if not file_path.exists():
            return []
        with file_path.open("r", encoding="utf-8", errors="replace") as handle:
            return [line.rstrip("\n") for _, line in zip(range(limit), handle)]

    def probe_installed_package(name: str) -> dict:
        result = subprocess.run(
            ["rpm", "-q", "--qf", "%{name}-%{version}-%{release}.%{arch}\n", name],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        return {
            "name": name,
            "installed": result.returncode == 0,
            "matches": lines,
        }

    desktop_file_path = Path(manifest["session_descriptor_path"])
    exec_line = ""
    desktop_names_line = ""
    if desktop_file_path.exists():
        for line in desktop_file_path.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("Exec="):
                exec_line = line
            if line.startswith("DesktopNames="):
                desktop_names_line = line

    labwc_processes = read_lines("/tmp/budgie-graphical-labwc-processes.txt")
    budgie_session_processes = read_lines("/tmp/budgie-graphical-session-processes.txt")
    session_manager_excerpt = read_lines(session_manager_path)

    installed_package_versions = [
        probe_installed_package(name) for name in manifest["package_set"]
    ]

    summary = {
        "kind": manifest["kind"],
        "target": manifest["target"],
        "current_boundary": manifest["current_boundary"],
        "repo_surface": {
            "epel_release_rpm": manifest["epel_release_rpm"],
            "crb_enabled": True,
            "fedora_release": manifest["fedora_release"],
            "consumer_repo_path": manifest["fedora_repo_path"],
            "consumer_repo_path_exists": Path(manifest["fedora_repo_path"]).exists(),
        },
        "desktop_file": {
            "path": manifest["session_descriptor_path"],
            "exists": desktop_file_path.exists(),
            "exec_line": exec_line,
            "desktop_names_line": desktop_names_line,
        },
        "package_install": {
            "packages": manifest["package_set"],
            "transaction_succeeded": all(
                probe["installed"] for probe in installed_package_versions
            ),
            "installed_package_versions": installed_package_versions,
            "log_excerpt": read_lines(install_log_path),
        },
        "session_execution": {
            "launcher": manifest["session_launcher"],
            "session_binary": manifest["session_binary"],
            "session_manager_bus_name": manifest["session_manager_bus_name"],
            "session_manager_object_path": manifest["session_manager_object_path"],
            "session_manager_interface": manifest["session_manager_interface"],
            "labwc_processes": labwc_processes,
            "budgie_session_processes": budgie_session_processes,
            "labwc_running": bool(labwc_processes),
            "budgie_session_running": any(
                "budgie-session-binary" in line or "budgie-session --builtin" in line
                for line in budgie_session_processes
            ),
            "session_manager_registered": bool(session_manager_excerpt),
            "session_manager_excerpt": session_manager_excerpt,
            "session_log_excerpt": read_lines(session_log_path),
        },
    }

    with open(summary_path, "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2)
        handle.write("\n")
    PY
  '';
  budgieGraphicalWriter = pkgs.lib.escapeShellArg ''
    from pathlib import Path

    harness_dir = Path("/tmp/budgie-graphical")
    harness_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    (harness_dir / "manifest.json").write_text(
        ${builtins.toJSON budgieGraphicalManifest} + "\n",
        encoding="utf-8",
    )
    script_path = harness_dir / "run-graphical-test.sh"
    script_path.write_text(
        ${builtins.toJSON budgieGraphicalScript},
        encoding="utf-8",
    )
    script_path.chmod(0o755)
  '';
  budgieGraphicalWriteCommand =
    builtins.toJSON "python3 -c ${budgieGraphicalWriter}";
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
  budgieSessionGateAssertionWriter = pkgs.lib.escapeShellArg ''
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
  '';
  budgieSessionGateAssertionCommand =
    builtins.toJSON "python3 -c ${budgieSessionGateAssertionWriter}";
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
  budgieGraphicalTest = runner: (runner {
    sharedDirs = {};
    testScript = ''
      vm.wait_for_unit("multi-user.target")
      vm.succeed("command -v python3")
      vm.succeed(${budgieGraphicalWriteCommand})
      vm.succeed("test -f /tmp/budgie-graphical/manifest.json")
      vm.succeed("test -x /tmp/budgie-graphical/run-graphical-test.sh")
      vm.succeed("grep -q 'startbudgielabwc' /tmp/budgie-graphical/manifest.json")
      vm.succeed("""
        timeout 900 bash -lc '
          set -euo pipefail
          /tmp/budgie-graphical/run-graphical-test.sh \
            /tmp/budgie-graphical/manifest.json \
            /tmp/budgie-graphical-summary.json \
            /tmp/budgie-graphical-install.log \
            /tmp/budgie-graphical-session.log \
            /tmp/budgie-graphical-session-manager.txt || {
              status=$?
              sed -n "1,200p" /tmp/budgie-graphical-install.log || true
              sed -n "1,200p" /tmp/budgie-graphical-session.log || true
              sed -n "1,120p" /tmp/budgie-graphical-session-manager.txt || true
              exit "$status"
            }
        '
      """)
      vm.succeed("test -s /tmp/budgie-graphical-summary.json")
      vm.succeed("test -s /tmp/budgie-graphical-install.log")
      vm.succeed("test -e /tmp/budgie-graphical-session.log")
      vm.succeed("test -s /tmp/budgie-graphical-session-manager.txt")
      vm.succeed("grep -q 'startbudgielabwc' /tmp/budgie-graphical-summary.json")
      vm.succeed("grep -q 'budgie-session-binary' /tmp/budgie-graphical-summary.json")
      vm.succeed("grep -q 'org.gnome.SessionManager' /tmp/budgie-graphical-summary.json")
      vm.succeed(${budgieGraphicalAssertionCommand})
      vm.succeed("cat /tmp/budgie-graphical-summary.json")
      vm.succeed("sed -n '1,120p' /tmp/budgie-graphical-session.log || true")
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
      vm.succeed(${budgieSessionGateAssertionCommand})
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
  "10_1-budgie-graphical-test" = budgieGraphicalTest lib.rocky."10_1";
  "10_1-budgie-graphical-harness-test" = budgieGraphicalHarnessTest lib.rocky."10_1";
  "10_1-budgie-session-gate-test" = budgieSessionGateTest lib.rocky."10_1";
} //
package.rocky.images
