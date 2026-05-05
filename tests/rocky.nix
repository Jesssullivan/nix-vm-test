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
  budgieLoginManagerPackages = budgieGraphicalPackages ++ [
    "sddm"
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
  budgieGraphicalSessionScript = ''
    #!/usr/bin/env bash
    set -euo pipefail

    session_log_path="''${1:?session log path required}"
    session_manager_path="''${2:?session manager path required}"
    labwc_process_path="''${3:-/tmp/budgie-graphical-labwc-processes.txt}"
    budgie_session_process_path="''${4:-/tmp/budgie-graphical-session-processes.txt}"

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
      if pgrep -x labwc >/dev/null && pgrep -af budgie-session >"$budgie_session_process_path"; then
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

    pgrep -a labwc >"$labwc_process_path" || true
    pgrep -af budgie-session >"$budgie_session_process_path" || true

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

    session_script_path="/tmp/budgie-graphical/run-session.sh"
    test -x "$session_script_path"
    dbus-run-session -- "$session_script_path" "$session_log_path" "$session_manager_path"

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
    session_script_path = harness_dir / "run-session.sh"
    session_script_path.write_text(
        ${builtins.toJSON budgieGraphicalSessionScript},
        encoding="utf-8",
    )
    session_script_path.chmod(0o755)
  '';
  budgieGraphicalWriteCommand =
    builtins.toJSON "python3 -c ${budgieGraphicalWriter}";
  budgieDisplayPersistenceManifest = builtins.toJSON {
    target = "rocky-10_1-budgie-display-persistence-test";
    kind = "budgie-display-persistence";
    predecessor_target = "rocky-10_1-budgie-graphical-test";
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
    persistence_cycles = [
      {
        name = "initial-launch";
        session_log_path = "/tmp/budgie-display-persistence/initial-launch-session.log";
        session_manager_path =
          "/tmp/budgie-display-persistence/initial-launch-session-manager.txt";
        labwc_process_path =
          "/tmp/budgie-display-persistence/initial-launch-labwc-processes.txt";
        budgie_session_process_path =
          "/tmp/budgie-display-persistence/initial-launch-session-processes.txt";
      }
      {
        name = "relaunch";
        session_log_path = "/tmp/budgie-display-persistence/relaunch-session.log";
        session_manager_path =
          "/tmp/budgie-display-persistence/relaunch-session-manager.txt";
        labwc_process_path =
          "/tmp/budgie-display-persistence/relaunch-labwc-processes.txt";
        budgie_session_process_path =
          "/tmp/budgie-display-persistence/relaunch-session-processes.txt";
      }
    ];
    current_boundary =
      "first-rocky-budgie-display-persistence-via-double-session-relaunch";
  };
  budgieDisplayPersistenceAssertionWriter = pkgs.lib.escapeShellArg ''
    import json

    with open("/tmp/budgie-display-persistence-summary.json", "r", encoding="utf-8") as handle:
        summary = json.load(handle)

    repo_surface = summary["repo_surface"]
    package_install = summary["package_install"]
    persistence_probe = summary["persistence_probe"]
    cycles = summary["persistence_cycles"]

    if repo_surface["fedora_release"] != "44":
        raise SystemExit(f"unexpected Fedora consumer release: {repo_surface['fedora_release']}")

    if not repo_surface["consumer_repo_path_exists"]:
        raise SystemExit("Fedora consumer repo file was not created in the guest")

    if not package_install["transaction_succeeded"]:
        raise SystemExit("Budgie display-persistence package installation did not succeed")

    if persistence_probe["completed_cycle_count"] != 2:
        raise SystemExit(
            f"expected 2 persistence cycles, saw {persistence_probe['completed_cycle_count']}"
        )

    if not persistence_probe["second_cycle_registered"]:
        raise SystemExit("second Budgie session cycle did not register org.gnome.SessionManager")

    for cycle in cycles:
        if not cycle["labwc_running"]:
            raise SystemExit(f"labwc did not stay up during cycle {cycle['name']}")
        if not cycle["budgie_session_running"]:
            raise SystemExit(
                f"budgie-session did not stay up during cycle {cycle['name']}"
            )
        if not cycle["session_manager_registered"]:
            raise SystemExit(
                f"org.gnome.SessionManager did not register during cycle {cycle['name']}"
            )
  '';
  budgieDisplayPersistenceAssertionCommand =
    builtins.toJSON "python3 -c ${budgieDisplayPersistenceAssertionWriter}";
  budgieDisplayPersistenceScript = ''
    #!/usr/bin/env bash
    set -euo pipefail

    manifest_path="''${1:?manifest path required}"
    summary_path="''${2:?summary path required}"
    install_log_path="''${3:?install log path required}"

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

    session_script_path="/tmp/budgie-display-persistence/run-session.sh"
    test -x "$session_script_path"

    for cycle_name in initial-launch relaunch; do
      log_path="/tmp/budgie-display-persistence/''${cycle_name}-session.log"
      manager_path="/tmp/budgie-display-persistence/''${cycle_name}-session-manager.txt"
      labwc_path="/tmp/budgie-display-persistence/''${cycle_name}-labwc-processes.txt"
      budgie_path="/tmp/budgie-display-persistence/''${cycle_name}-session-processes.txt"

      dbus-run-session -- \
        "$session_script_path" \
        "$log_path" \
        "$manager_path" \
        "$labwc_path" \
        "$budgie_path"

      test -s "$manager_path"
      sleep 2
    done

    python3 - "$manifest_path" "$summary_path" "$install_log_path" <<'PY'
    import json
    from pathlib import Path
    import subprocess
    import sys

    manifest_path, summary_path, install_log_path = sys.argv[1:4]

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

    installed_package_versions = [
        probe_installed_package(name) for name in manifest["package_set"]
    ]

    cycles = []
    for cycle in manifest["persistence_cycles"]:
        labwc_processes = read_lines(cycle["labwc_process_path"])
        budgie_session_processes = read_lines(cycle["budgie_session_process_path"])
        session_manager_excerpt = read_lines(cycle["session_manager_path"])
        cycles.append(
            {
                "name": cycle["name"],
                "session_log_path": cycle["session_log_path"],
                "session_manager_path": cycle["session_manager_path"],
                "labwc_process_path": cycle["labwc_process_path"],
                "budgie_session_process_path": cycle["budgie_session_process_path"],
                "labwc_processes": labwc_processes,
                "budgie_session_processes": budgie_session_processes,
                "labwc_running": bool(labwc_processes),
                "budgie_session_running": any(
                    "budgie-session-binary" in line or "budgie-session --builtin" in line
                    for line in budgie_session_processes
                ),
                "session_manager_registered": bool(session_manager_excerpt),
                "session_manager_excerpt": session_manager_excerpt,
                "session_log_excerpt": read_lines(cycle["session_log_path"]),
            }
        )

    summary = {
        "kind": manifest["kind"],
        "target": manifest["target"],
        "predecessor_target": manifest["predecessor_target"],
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
        "persistence_cycles": cycles,
        "persistence_probe": {
            "cycle_names": [cycle["name"] for cycle in cycles],
            "completed_cycle_count": len(cycles),
            "second_cycle_registered": (
                len(cycles) > 1 and cycles[1]["session_manager_registered"]
            ),
            "second_cycle_labwc_running": (
                len(cycles) > 1 and cycles[1]["labwc_running"]
            ),
            "second_cycle_budgie_session_running": (
                len(cycles) > 1 and cycles[1]["budgie_session_running"]
            ),
        },
    }

    with open(summary_path, "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2)
        handle.write("\n")
    PY
  '';
  budgieDisplayPersistenceWriter = pkgs.lib.escapeShellArg ''
    from pathlib import Path

    harness_dir = Path("/tmp/budgie-display-persistence")
    harness_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    (harness_dir / "manifest.json").write_text(
        ${builtins.toJSON budgieDisplayPersistenceManifest} + "\n",
        encoding="utf-8",
    )
    script_path = harness_dir / "run-display-persistence-test.sh"
    script_path.write_text(
        ${builtins.toJSON budgieDisplayPersistenceScript},
        encoding="utf-8",
    )
    script_path.chmod(0o755)
    session_script_path = harness_dir / "run-session.sh"
    session_script_path.write_text(
        ${builtins.toJSON budgieGraphicalSessionScript},
        encoding="utf-8",
    )
    session_script_path.chmod(0o755)
  '';
  budgieDisplayPersistenceWriteCommand =
    builtins.toJSON "python3 -c ${budgieDisplayPersistenceWriter}";
  budgieRebootPersistenceManifest = builtins.toJSON {
    target = "rocky-10_1-budgie-reboot-persistence-test";
    kind = "budgie-reboot-persistence";
    predecessor_target = "rocky-10_1-budgie-display-persistence-test";
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
    reboot_cycles = [
      {
        name = "pre-reboot";
        session_log_path = "/var/lib/budgie-reboot-persistence/pre-reboot-session.log";
        session_manager_path =
          "/var/lib/budgie-reboot-persistence/pre-reboot-session-manager.txt";
        labwc_process_path =
          "/var/lib/budgie-reboot-persistence/pre-reboot-labwc-processes.txt";
        budgie_session_process_path =
          "/var/lib/budgie-reboot-persistence/pre-reboot-session-processes.txt";
      }
      {
        name = "post-reboot";
        session_log_path = "/var/lib/budgie-reboot-persistence/post-reboot-session.log";
        session_manager_path =
          "/var/lib/budgie-reboot-persistence/post-reboot-session-manager.txt";
        labwc_process_path =
          "/var/lib/budgie-reboot-persistence/post-reboot-labwc-processes.txt";
        budgie_session_process_path =
          "/var/lib/budgie-reboot-persistence/post-reboot-session-processes.txt";
      }
    ];
    current_boundary =
      "first-rocky-budgie-reboot-persistence-via-post-reboot-session-rerun";
  };
  budgieRebootPersistenceAssertionWriter = pkgs.lib.escapeShellArg ''
    import json

    with open("/var/lib/budgie-reboot-persistence-summary.json", "r", encoding="utf-8") as handle:
        summary = json.load(handle)

    repo_surface = summary["repo_surface"]
    package_install = summary["package_install"]
    reboot_probe = summary["reboot_probe"]
    cycles = summary["reboot_cycles"]

    if repo_surface["fedora_release"] != "44":
        raise SystemExit(f"unexpected Fedora consumer release: {repo_surface['fedora_release']}")

    if not repo_surface["consumer_repo_path_exists"]:
        raise SystemExit("Fedora consumer repo file was not present after reboot")

    if not package_install["transaction_succeeded"]:
        raise SystemExit("Budgie reboot-persistence packages were not present after reboot")

    if reboot_probe["completed_cycle_count"] != 2:
        raise SystemExit(
            f"expected 2 reboot-persistence cycles, saw {reboot_probe['completed_cycle_count']}"
        )

    if not reboot_probe["post_reboot_registered"]:
        raise SystemExit("post-reboot Budgie session did not register org.gnome.SessionManager")

    for cycle in cycles:
        if not cycle["completed"]:
            raise SystemExit(f"reboot-persistence cycle {cycle['name']} did not complete")
        if not cycle["labwc_running"]:
            raise SystemExit(f"labwc did not stay up during cycle {cycle['name']}")
        if not cycle["budgie_session_running"]:
            raise SystemExit(
                f"budgie-session did not stay up during cycle {cycle['name']}"
            )
        if not cycle["session_manager_registered"]:
            raise SystemExit(
                f"org.gnome.SessionManager did not register during cycle {cycle['name']}"
            )
  '';
  budgieRebootPersistenceAssertionCommand =
    builtins.toJSON "python3 -c ${budgieRebootPersistenceAssertionWriter}";
  budgieRebootPersistenceScript = ''
    #!/usr/bin/env bash
    set -euo pipefail

    manifest_path="''${1:?manifest path required}"
    phase="''${2:?phase required}"
    summary_path="''${3:?summary path required}"
    install_log_path="''${4:?install log path required}"

    harness_dir="$(dirname "$manifest_path")"
    session_script_path="$harness_dir/run-session.sh"

    case "$phase" in
      pre-reboot)
        dnf install -y ${builtins.toJSON "https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm"} >/dev/null
        dnf install -y dnf-plugins-core >/dev/null
        dnf config-manager --set-enabled crb >/dev/null

        ${fedora44ConsumerRepoWriteCommand}

        dnf install -y --setopt=install_weak_deps=False \
          ${builtins.concatStringsSep " \\\n          " budgieGraphicalPackages} \
          >"$install_log_path"
        ;;
      post-reboot)
        test -s "$install_log_path"
        test -f /etc/yum.repos.d/fedora44.repo
        ;;
      *)
        printf 'unknown reboot-persistence phase: %s\n' "$phase" >&2
        exit 1
        ;;
    esac

    command -v dbus-run-session >/dev/null
    command -v gdbus >/dev/null
    command -v pgrep >/dev/null
    command -v startbudgielabwc >/dev/null
    command -v budgie-session >/dev/null

    desktop_file="/usr/share/wayland-sessions/budgie-desktop.desktop"
    test -f "$desktop_file"
    grep -q '^Exec=.*/startbudgielabwc$' "$desktop_file"

    install -d -m 700 /tmp/budgie-graphical-runtime
    test -x "$session_script_path"

    log_path="$harness_dir/''${phase}-session.log"
    manager_path="$harness_dir/''${phase}-session-manager.txt"
    labwc_path="$harness_dir/''${phase}-labwc-processes.txt"
    budgie_path="$harness_dir/''${phase}-session-processes.txt"

    dbus-run-session -- \
      "$session_script_path" \
      "$log_path" \
      "$manager_path" \
      "$labwc_path" \
      "$budgie_path"

    test -s "$manager_path"
    sleep 2

    python3 - "$manifest_path" "$phase" "$summary_path" "$install_log_path" <<'PY'
    import json
    from pathlib import Path
    import subprocess
    import sys

    manifest_path, phase, summary_path, install_log_path = sys.argv[1:5]

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

    installed_package_versions = [
        probe_installed_package(name) for name in manifest["package_set"]
    ]

    cycles = []
    completed_cycle_count = 0
    for cycle in manifest["reboot_cycles"]:
        labwc_processes = read_lines(cycle["labwc_process_path"])
        budgie_session_processes = read_lines(cycle["budgie_session_process_path"])
        session_manager_excerpt = read_lines(cycle["session_manager_path"])
        session_log_excerpt = read_lines(cycle["session_log_path"])
        completed = bool(
            labwc_processes
            or budgie_session_processes
            or session_manager_excerpt
            or session_log_excerpt
        )
        if completed:
            completed_cycle_count += 1
        cycles.append(
            {
                "name": cycle["name"],
                "completed": completed,
                "session_log_path": cycle["session_log_path"],
                "session_manager_path": cycle["session_manager_path"],
                "labwc_process_path": cycle["labwc_process_path"],
                "budgie_session_process_path": cycle["budgie_session_process_path"],
                "labwc_processes": labwc_processes,
                "budgie_session_processes": budgie_session_processes,
                "labwc_running": bool(labwc_processes),
                "budgie_session_running": any(
                    "budgie-session-binary" in line or "budgie-session --builtin" in line
                    for line in budgie_session_processes
                ),
                "session_manager_registered": bool(session_manager_excerpt),
                "session_manager_excerpt": session_manager_excerpt,
                "session_log_excerpt": session_log_excerpt,
            }
        )

    post_reboot_cycle = next(
        (cycle for cycle in cycles if cycle["name"] == "post-reboot"),
        None,
    )

    summary = {
        "kind": manifest["kind"],
        "target": manifest["target"],
        "predecessor_target": manifest["predecessor_target"],
        "current_boundary": manifest["current_boundary"],
        "executed_phase": phase,
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
        "reboot_cycles": cycles,
        "reboot_probe": {
            "cycle_names": [cycle["name"] for cycle in cycles if cycle["completed"]],
            "completed_cycle_count": completed_cycle_count,
            "post_reboot_registered": bool(
                post_reboot_cycle and post_reboot_cycle["session_manager_registered"]
            ),
            "post_reboot_labwc_running": bool(
                post_reboot_cycle and post_reboot_cycle["labwc_running"]
            ),
            "post_reboot_budgie_session_running": bool(
                post_reboot_cycle and post_reboot_cycle["budgie_session_running"]
            ),
        },
    }

    with open(summary_path, "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2)
        handle.write("\n")
    PY
  '';
  budgieRebootPersistenceWriter = pkgs.lib.escapeShellArg ''
    from pathlib import Path

    harness_dir = Path("/var/lib/budgie-reboot-persistence")
    harness_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    (harness_dir / "manifest.json").write_text(
        ${builtins.toJSON budgieRebootPersistenceManifest} + "\n",
        encoding="utf-8",
    )
    script_path = harness_dir / "run-reboot-persistence-test.sh"
    script_path.write_text(
        ${builtins.toJSON budgieRebootPersistenceScript},
        encoding="utf-8",
    )
    script_path.chmod(0o755)
    session_script_path = harness_dir / "run-session.sh"
    session_script_path.write_text(
        ${builtins.toJSON budgieGraphicalSessionScript},
        encoding="utf-8",
    )
    session_script_path.chmod(0o755)
  '';
  budgieRebootPersistenceWriteCommand =
    builtins.toJSON "python3 -c ${budgieRebootPersistenceWriter}";
  budgieGraphicalLoginManagerPersistenceManifest = builtins.toJSON {
    target = "rocky-10_1-budgie-graphical-login-manager-persistence-test";
    kind = "budgie-graphical-login-manager-persistence";
    predecessor_target = "rocky-10_1-budgie-reboot-persistence-test";
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
    login_manager_package = "sddm";
    login_manager_service = "sddm.service";
    display_manager_service = "display-manager.service";
    display_manager_alias_path = "/etc/systemd/system/display-manager.service";
    graphical_target = "graphical.target";
    package_set = budgieLoginManagerPackages;
    epel_release_rpm =
      "https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm";
    fedora_release = "44";
    fedora_repo_path = "/etc/yum.repos.d/fedora44.repo";
    session_descriptor_path = "/usr/share/wayland-sessions/budgie-desktop.desktop";
    session_launcher = "startbudgielabwc";
    login_manager_cycles = [
      {
        name = "pre-reboot";
        probe_json_path =
          "/var/lib/budgie-graphical-login-manager-persistence/pre-reboot-probe.json";
        login_manager_status_path =
          "/var/lib/budgie-graphical-login-manager-persistence/pre-reboot-sddm-status.txt";
        display_manager_status_path =
          "/var/lib/budgie-graphical-login-manager-persistence/pre-reboot-display-manager-status.txt";
        loginctl_sessions_path =
          "/var/lib/budgie-graphical-login-manager-persistence/pre-reboot-logind-sessions.txt";
        alias_state_path =
          "/var/lib/budgie-graphical-login-manager-persistence/pre-reboot-display-manager-alias.txt";
        journal_path =
          "/var/lib/budgie-graphical-login-manager-persistence/pre-reboot-sddm-journal.txt";
      }
      {
        name = "post-reboot";
        probe_json_path =
          "/var/lib/budgie-graphical-login-manager-persistence/post-reboot-probe.json";
        login_manager_status_path =
          "/var/lib/budgie-graphical-login-manager-persistence/post-reboot-sddm-status.txt";
        display_manager_status_path =
          "/var/lib/budgie-graphical-login-manager-persistence/post-reboot-display-manager-status.txt";
        loginctl_sessions_path =
          "/var/lib/budgie-graphical-login-manager-persistence/post-reboot-logind-sessions.txt";
        alias_state_path =
          "/var/lib/budgie-graphical-login-manager-persistence/post-reboot-display-manager-alias.txt";
        journal_path =
          "/var/lib/budgie-graphical-login-manager-persistence/post-reboot-sddm-journal.txt";
      }
    ];
    current_boundary =
      "first-rocky-budgie-graphical-login-manager-persistence-via-sddm-restart-after-reboot";
  };
  budgieGraphicalLoginManagerPersistenceAssertionWriter = pkgs.lib.escapeShellArg ''
    import json

    with open(
        "/var/lib/budgie-graphical-login-manager-persistence-summary.json",
        "r",
        encoding="utf-8",
    ) as handle:
        summary = json.load(handle)

    repo_surface = summary["repo_surface"]
    package_install = summary["package_install"]
    desktop_file = summary["desktop_file"]
    login_manager_probe = summary["login_manager_probe"]
    cycles = summary["login_manager_cycles"]

    if repo_surface["fedora_release"] != "44":
        raise SystemExit(f"unexpected Fedora consumer release: {repo_surface['fedora_release']}")

    if not repo_surface["consumer_repo_path_exists"]:
        raise SystemExit("Fedora consumer repo file was not present after reboot")

    if not package_install["transaction_succeeded"]:
        raise SystemExit("Budgie graphical login-manager packages were not present after reboot")

    if "startbudgielabwc" not in desktop_file["exec_line"]:
        raise SystemExit(f"unexpected desktop file Exec line: {desktop_file['exec_line']!r}")

    if login_manager_probe["completed_cycle_count"] != 2:
        raise SystemExit(
            "expected 2 login-manager persistence cycles, "
            f"saw {login_manager_probe['completed_cycle_count']}"
        )

    if not login_manager_probe["post_reboot_default_target_graphical"]:
        raise SystemExit("post-reboot default target was not graphical.target")

    if not login_manager_probe["post_reboot_login_manager_active"]:
        raise SystemExit("post-reboot sddm.service was not active")

    if not login_manager_probe["post_reboot_display_manager_active"]:
        raise SystemExit("post-reboot display-manager.service was not active")

    if not login_manager_probe["post_reboot_alias_exists"]:
        raise SystemExit("post-reboot display-manager.service alias was missing")

    if not login_manager_probe["post_reboot_alias_targets_sddm"]:
        raise SystemExit("post-reboot display-manager.service alias did not point at sddm.service")

    for cycle in cycles:
        if not cycle["completed"]:
            raise SystemExit(f"login-manager persistence cycle {cycle['name']} did not complete")
        if not cycle["login_manager_enabled"]:
            raise SystemExit(f"sddm.service was not enabled during cycle {cycle['name']}")
        if not cycle["login_manager_active"]:
            raise SystemExit(f"sddm.service was not active during cycle {cycle['name']}")
        if not cycle["display_manager_active"]:
            raise SystemExit(
                f"display-manager.service was not active during cycle {cycle['name']}"
            )
        if cycle["default_target"] != "graphical.target":
            raise SystemExit(
                f"default target during cycle {cycle['name']} was {cycle['default_target']!r}"
            )
        if not cycle["display_manager_alias_exists"]:
            raise SystemExit(
                f"display-manager.service alias was missing during cycle {cycle['name']}"
            )
        if not cycle["display_manager_alias_targets_sddm"]:
            raise SystemExit(
                f"display-manager.service alias did not point at sddm.service during cycle {cycle['name']}"
            )
  '';
  budgieGraphicalLoginManagerPersistenceAssertionCommand =
    builtins.toJSON
    "python3 -c ${budgieGraphicalLoginManagerPersistenceAssertionWriter}";
  budgieGraphicalLoginManagerPersistenceScript = ''
    #!/usr/bin/env bash
    set -euo pipefail

    manifest_path="''${1:?manifest path required}"
    phase="''${2:?phase required}"
    summary_path="''${3:?summary path required}"
    install_log_path="''${4:?install log path required}"

    harness_dir="$(dirname "$manifest_path")"

    case "$phase" in
      pre-reboot)
        dnf install -y ${builtins.toJSON "https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm"} >/dev/null
        dnf install -y dnf-plugins-core >/dev/null
        dnf config-manager --set-enabled crb >/dev/null

        ${fedora44ConsumerRepoWriteCommand}

        dnf install -y --setopt=install_weak_deps=False \
          --exclude=compat-gpgme124 \
          ${builtins.concatStringsSep " \\\n          " budgieLoginManagerPackages} \
          >"$install_log_path"

        systemctl set-default graphical.target >/dev/null
        systemctl enable sddm.service >/dev/null
        systemctl start sddm.service
        ;;
      post-reboot)
        test -s "$install_log_path"
        test -f /etc/yum.repos.d/fedora44.repo
        ;;
      *)
        printf 'unknown login-manager persistence phase: %s\n' "$phase" >&2
        exit 1
        ;;
    esac

    command -v loginctl >/dev/null
    command -v readlink >/dev/null
    command -v systemctl >/dev/null

    desktop_file="/usr/share/wayland-sessions/budgie-desktop.desktop"
    test -f "$desktop_file"
    grep -q '^Exec=.*/startbudgielabwc$' "$desktop_file"

    login_manager_status_path="$harness_dir/''${phase}-sddm-status.txt"
    display_manager_status_path="$harness_dir/''${phase}-display-manager-status.txt"
    loginctl_sessions_path="$harness_dir/''${phase}-logind-sessions.txt"
    alias_state_path="$harness_dir/''${phase}-display-manager-alias.txt"
    journal_path="$harness_dir/''${phase}-sddm-journal.txt"

    systemctl status --no-pager sddm.service >"$login_manager_status_path" || true
    systemctl status --no-pager display-manager.service >"$display_manager_status_path" || true
    loginctl list-sessions --no-legend >"$loginctl_sessions_path" || true
    ls -l /etc/systemd/system/display-manager.service >"$alias_state_path" || true
    journalctl -b -u sddm.service --no-pager -n 120 >"$journal_path" || true

    systemctl is-enabled sddm.service >/dev/null
    systemctl is-active sddm.service >/dev/null
    systemctl is-active display-manager.service >/dev/null
    test "$(systemctl get-default)" = "graphical.target"
    test -L /etc/systemd/system/display-manager.service

    python3 - "$manifest_path" "$phase" "$summary_path" "$install_log_path" <<'PY'
    import json
    from pathlib import Path
    import subprocess
    import sys

    manifest_path, phase, summary_path, install_log_path = sys.argv[1:5]

    with open(manifest_path, "r", encoding="utf-8") as handle:
        manifest = json.load(handle)

    def read_lines(path: str, limit: int = 120) -> list[str]:
        file_path = Path(path)
        if not file_path.exists():
            return []
        with file_path.open("r", encoding="utf-8", errors="replace") as handle:
            return [line.rstrip("\n") for _, line in zip(range(limit), handle)]

    def run_command(command: list[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )

    def probe_installed_package(name: str) -> dict:
        result = run_command(
            ["rpm", "-q", "--qf", "%{name}-%{version}-%{release}.%{arch}\n", name]
        )
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        return {
            "name": name,
            "installed": result.returncode == 0,
            "matches": lines,
        }

    desktop_file_path = Path(manifest["session_descriptor_path"])
    exec_line = ""
    if desktop_file_path.exists():
        for line in desktop_file_path.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("Exec="):
                exec_line = line

    installed_package_versions = [
        probe_installed_package(name) for name in manifest["package_set"]
    ]

    current_cycle = next(
        cycle for cycle in manifest["login_manager_cycles"] if cycle["name"] == phase
    )
    default_target_result = run_command(["systemctl", "get-default"])
    login_manager_enabled_result = run_command(
        ["systemctl", "is-enabled", manifest["login_manager_service"]]
    )
    login_manager_active_result = run_command(
        ["systemctl", "is-active", manifest["login_manager_service"]]
    )
    display_manager_active_result = run_command(
        ["systemctl", "is-active", manifest["display_manager_service"]]
    )

    alias_path = Path(manifest["display_manager_alias_path"])
    alias_target = alias_path.readlink().as_posix() if alias_path.is_symlink() else ""

    current_probe = {
        "default_target": default_target_result.stdout.strip(),
        "login_manager_enabled": login_manager_enabled_result.returncode == 0,
        "login_manager_active": login_manager_active_result.returncode == 0,
        "display_manager_active": display_manager_active_result.returncode == 0,
        "display_manager_alias_exists": alias_path.exists(),
        "display_manager_alias_is_symlink": alias_path.is_symlink(),
        "display_manager_alias_target": alias_target,
        "display_manager_alias_targets_sddm": alias_target.endswith("sddm.service"),
    }
    Path(current_cycle["probe_json_path"]).write_text(
        json.dumps(current_probe, indent=2) + "\n",
        encoding="utf-8",
    )

    cycles = []
    completed_cycle_count = 0
    for cycle in manifest["login_manager_cycles"]:
        login_manager_status_excerpt = read_lines(cycle["login_manager_status_path"])
        display_manager_status_excerpt = read_lines(cycle["display_manager_status_path"])
        loginctl_sessions_excerpt = read_lines(cycle["loginctl_sessions_path"])
        alias_state_excerpt = read_lines(cycle["alias_state_path"])
        journal_excerpt = read_lines(cycle["journal_path"])
        completed = bool(
            login_manager_status_excerpt
            or display_manager_status_excerpt
            or loginctl_sessions_excerpt
            or alias_state_excerpt
            or journal_excerpt
        )
        if completed:
            completed_cycle_count += 1
        probe_path = Path(cycle["probe_json_path"])
        if probe_path.exists():
            phase_probe = json.loads(probe_path.read_text(encoding="utf-8"))
        else:
            phase_probe = {
                "default_target": "",
                "login_manager_enabled": False,
                "login_manager_active": False,
                "display_manager_active": False,
                "display_manager_alias_exists": False,
                "display_manager_alias_is_symlink": False,
                "display_manager_alias_target": "",
                "display_manager_alias_targets_sddm": False,
            }

        cycles.append(
            {
                "name": cycle["name"],
                "completed": completed,
                "default_target": phase_probe["default_target"],
                "login_manager_enabled": phase_probe["login_manager_enabled"],
                "login_manager_active": phase_probe["login_manager_active"],
                "display_manager_active": phase_probe["display_manager_active"],
                "display_manager_alias_exists": phase_probe["display_manager_alias_exists"],
                "display_manager_alias_is_symlink": phase_probe["display_manager_alias_is_symlink"],
                "display_manager_alias_target": phase_probe["display_manager_alias_target"],
                "display_manager_alias_targets_sddm": phase_probe[
                    "display_manager_alias_targets_sddm"
                ],
                "probe_json_path": cycle["probe_json_path"],
                "login_manager_status_path": cycle["login_manager_status_path"],
                "display_manager_status_path": cycle["display_manager_status_path"],
                "loginctl_sessions_path": cycle["loginctl_sessions_path"],
                "alias_state_path": cycle["alias_state_path"],
                "journal_path": cycle["journal_path"],
                "login_manager_status_excerpt": login_manager_status_excerpt,
                "display_manager_status_excerpt": display_manager_status_excerpt,
                "loginctl_sessions_excerpt": loginctl_sessions_excerpt,
                "alias_state_excerpt": alias_state_excerpt,
                "journal_excerpt": journal_excerpt,
            }
        )

    post_reboot_cycle = next(
        (cycle for cycle in cycles if cycle["name"] == "post-reboot"),
        None,
    )

    summary = {
        "kind": manifest["kind"],
        "target": manifest["target"],
        "predecessor_target": manifest["predecessor_target"],
        "current_boundary": manifest["current_boundary"],
        "executed_phase": phase,
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
        },
        "package_install": {
            "packages": manifest["package_set"],
            "transaction_succeeded": all(
                probe["installed"] for probe in installed_package_versions
            ),
            "installed_package_versions": installed_package_versions,
            "log_excerpt": read_lines(install_log_path),
        },
        "login_manager_cycles": cycles,
        "login_manager_probe": {
            "cycle_names": [cycle["name"] for cycle in cycles if cycle["completed"]],
            "completed_cycle_count": completed_cycle_count,
            "post_reboot_default_target_graphical": bool(
                post_reboot_cycle
                and post_reboot_cycle["default_target"] == manifest["graphical_target"]
            ),
            "post_reboot_login_manager_active": bool(
                post_reboot_cycle and post_reboot_cycle["login_manager_active"]
            ),
            "post_reboot_display_manager_active": bool(
                post_reboot_cycle and post_reboot_cycle["display_manager_active"]
            ),
            "post_reboot_alias_exists": bool(
                post_reboot_cycle and post_reboot_cycle["display_manager_alias_exists"]
            ),
            "post_reboot_alias_targets_sddm": bool(
                post_reboot_cycle
                and post_reboot_cycle["display_manager_alias_targets_sddm"]
            ),
        },
    }

    with open(summary_path, "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2)
        handle.write("\n")
    PY
  '';
  budgieGraphicalLoginManagerPersistenceWriter = pkgs.lib.escapeShellArg ''
    from pathlib import Path

    harness_dir = Path("/var/lib/budgie-graphical-login-manager-persistence")
    harness_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    (harness_dir / "manifest.json").write_text(
        ${builtins.toJSON budgieGraphicalLoginManagerPersistenceManifest} + "\n",
        encoding="utf-8",
    )
    script_path = harness_dir / "run-graphical-login-manager-persistence-test.sh"
    script_path.write_text(
        ${builtins.toJSON budgieGraphicalLoginManagerPersistenceScript},
        encoding="utf-8",
    )
    script_path.chmod(0o755)
  '';
  budgieGraphicalLoginManagerPersistenceWriteCommand =
    builtins.toJSON
    "python3 -c ${budgieGraphicalLoginManagerPersistenceWriter}";
  budgieDisplayManagerSessionManifest = builtins.toJSON {
    target = "rocky-10_1-budgie-display-manager-session-test";
    kind = "budgie-display-manager-session";
    predecessor_target =
      "rocky-10_1-budgie-graphical-login-manager-persistence-test";
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
    login_manager_package = "sddm";
    login_manager_service = "sddm.service";
    display_manager_service = "display-manager.service";
    display_manager_alias_path = "/etc/systemd/system/display-manager.service";
    graphical_target = "graphical.target";
    package_set = budgieLoginManagerPackages;
    epel_release_rpm =
      "https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm";
    fedora_release = "44";
    fedora_repo_path = "/etc/yum.repos.d/fedora44.repo";
    session_descriptor_path = "/usr/share/wayland-sessions/budgie-desktop.desktop";
    session_launcher = "startbudgielabwc";
    session_binary = "budgie-session-binary";
    proof_user = "budgieproof";
    autologin_session = "budgie-desktop.desktop";
    autologin_config_path =
      "/etc/sddm.conf.d/10-budgie-display-manager-session.conf";
    session_probe_path =
      "/var/lib/budgie-display-manager-session/post-reboot-session-probe.json";
    loginctl_sessions_path =
      "/var/lib/budgie-display-manager-session/post-reboot-logind-sessions.txt";
    loginctl_session_details_path =
      "/var/lib/budgie-display-manager-session/post-reboot-logind-session-details.txt";
    process_path =
      "/var/lib/budgie-display-manager-session/post-reboot-budgie-processes.txt";
    labwc_process_path =
      "/var/lib/budgie-display-manager-session/post-reboot-labwc-processes.txt";
    budgie_session_process_path =
      "/var/lib/budgie-display-manager-session/post-reboot-budgie-session-processes.txt";
    login_manager_status_path =
      "/var/lib/budgie-display-manager-session/post-reboot-sddm-status.txt";
    display_manager_status_path =
      "/var/lib/budgie-display-manager-session/post-reboot-display-manager-status.txt";
    journal_path =
      "/var/lib/budgie-display-manager-session/post-reboot-sddm-journal.txt";
    current_boundary =
      "first-rocky-budgie-display-manager-driven-session-via-controlled-sddm-autologin";
  };
  budgieDisplayManagerSessionAssertionWriter = pkgs.lib.escapeShellArg ''
    import json

    with open(
        "/var/lib/budgie-display-manager-session-summary.json",
        "r",
        encoding="utf-8",
    ) as handle:
        summary = json.load(handle)

    repo_surface = summary["repo_surface"]
    package_install = summary["package_install"]
    desktop_file = summary["desktop_file"]
    login_manager_probe = summary["login_manager_probe"]
    autologin_probe = summary["autologin_probe"]
    session_probe = summary["session_probe"]

    if repo_surface["fedora_release"] != "44":
        raise SystemExit(f"unexpected Fedora consumer release: {repo_surface['fedora_release']}")

    if not repo_surface["consumer_repo_path_exists"]:
        raise SystemExit("Fedora consumer repo file was not present after reboot")

    if not package_install["transaction_succeeded"]:
        raise SystemExit("Budgie display-manager session packages were not present after reboot")

    if "startbudgielabwc" not in desktop_file["exec_line"]:
        raise SystemExit(f"unexpected desktop file Exec line: {desktop_file['exec_line']!r}")

    if not login_manager_probe["post_reboot_default_target_graphical"]:
        raise SystemExit("post-reboot default target was not graphical.target")

    if not login_manager_probe["post_reboot_login_manager_active"]:
        raise SystemExit("post-reboot sddm.service was not active")

    if not login_manager_probe["post_reboot_display_manager_active"]:
        raise SystemExit("post-reboot display-manager.service was not active")

    if not login_manager_probe["post_reboot_alias_targets_sddm"]:
        raise SystemExit("post-reboot display-manager.service alias did not point at sddm.service")

    if not autologin_probe["proof_user_exists"]:
        raise SystemExit("Budgie display-manager proof user was missing")

    if not autologin_probe["autologin_config_exists"]:
        raise SystemExit("SDDM autologin config was missing")

    if not autologin_probe["autologin_config_targets_budgie"]:
        raise SystemExit("SDDM autologin config did not target the Budgie session")

    if session_probe["proof_user_session_count"] < 1:
        raise SystemExit("SDDM did not create a logind session for the proof user")

    if not session_probe["budgie_session_running"]:
        raise SystemExit("Budgie session process was not running under the proof user")

    if not session_probe["labwc_running"]:
        raise SystemExit("labwc process was not running under the proof user")

    if not session_probe["display_manager_started_session"]:
        raise SystemExit("display-manager-driven Budgie session proof did not complete")
  '';
  budgieDisplayManagerSessionAssertionCommand =
    builtins.toJSON "python3 -c ${budgieDisplayManagerSessionAssertionWriter}";
  budgieDisplayManagerSessionScript = ''
    #!/usr/bin/env bash
    set -euo pipefail

    manifest_path="''${1:?manifest path required}"
    phase="''${2:?phase required}"
    summary_path="''${3:?summary path required}"
    install_log_path="''${4:?install log path required}"

    harness_dir="$(dirname "$manifest_path")"

    manifest_value() {
      python3 - "$manifest_path" "$1" <<'PY'
    import json
    import sys

    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        manifest = json.load(handle)

    print(manifest[sys.argv[2]])
    PY
    }

    proof_user="$(manifest_value proof_user)"
    autologin_session="$(manifest_value autologin_session)"
    autologin_config_path="$(manifest_value autologin_config_path)"

    case "$phase" in
      pre-reboot)
        dnf install -y ${builtins.toJSON "https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm"} >/dev/null
        dnf install -y dnf-plugins-core >/dev/null
        dnf config-manager --set-enabled crb >/dev/null

        ${fedora44ConsumerRepoWriteCommand}

        dnf install -y --setopt=install_weak_deps=False \
          --exclude=compat-gpgme124 \
          ${builtins.concatStringsSep " \\\n          " budgieLoginManagerPackages} \
          >"$install_log_path"

        if ! id -u "$proof_user" >/dev/null 2>&1; then
          useradd -m "$proof_user"
        fi
        for group in video input; do
          if getent group "$group" >/dev/null; then
            usermod -a -G "$group" "$proof_user"
          fi
        done
        passwd -d "$proof_user" >/dev/null 2>&1 || true

        install -d -m 755 "$(dirname "$autologin_config_path")"
        python3 - "$autologin_config_path" "$proof_user" "$autologin_session" <<'PY'
    from pathlib import Path
    import sys

    config_path, proof_user, autologin_session = sys.argv[1:4]
    Path(config_path).write_text(
        "\n".join(
            [
                "[Autologin]",
                f"User={proof_user}",
                f"Session={autologin_session}",
                "Relogin=false",
                "",
                "[Users]",
                "MinimumUid=1000",
                "MaximumUid=60000",
                "",
            ]
        ),
        encoding="utf-8",
    )
    PY

        systemctl set-default graphical.target >/dev/null
        systemctl enable sddm.service >/dev/null
        ;;
      post-reboot)
        test -s "$install_log_path"
        test -f /etc/yum.repos.d/fedora44.repo
        test -f "$autologin_config_path"
        id -u "$proof_user" >/dev/null
        ;;
      *)
        printf 'unknown display-manager session phase: %s\n' "$phase" >&2
        exit 1
        ;;
    esac

    command -v loginctl >/dev/null
    command -v pgrep >/dev/null
    command -v readlink >/dev/null
    command -v systemctl >/dev/null

    desktop_file="/usr/share/wayland-sessions/budgie-desktop.desktop"
    test -f "$desktop_file"
    grep -q '^Exec=.*/startbudgielabwc$' "$desktop_file"

    if [ "$phase" = "post-reboot" ]; then
      loginctl_sessions_path="$harness_dir/post-reboot-logind-sessions.txt"
      loginctl_session_details_path="$harness_dir/post-reboot-logind-session-details.txt"
      process_path="$harness_dir/post-reboot-budgie-processes.txt"
      labwc_process_path="$harness_dir/post-reboot-labwc-processes.txt"
      budgie_session_process_path="$harness_dir/post-reboot-budgie-session-processes.txt"
      login_manager_status_path="$harness_dir/post-reboot-sddm-status.txt"
      display_manager_status_path="$harness_dir/post-reboot-display-manager-status.txt"
      journal_path="$harness_dir/post-reboot-sddm-journal.txt"

      ready=0
      for _ in $(seq 1 90); do
        loginctl list-sessions --no-legend >"$loginctl_sessions_path" || true
        pgrep -u "$proof_user" -af 'startbudgielabwc|budgie-session|labwc' >"$process_path" || true
        pgrep -u "$proof_user" -x labwc >"$labwc_process_path" || true
        pgrep -u "$proof_user" -af 'budgie-session-binary|budgie-session --builtin|budgie-session' >"$budgie_session_process_path" || true
        if awk -v user="$proof_user" '$3 == user { found=1 } END { exit found ? 0 : 1 }' "$loginctl_sessions_path" \
          && test -s "$labwc_process_path" \
          && test -s "$budgie_session_process_path"
        then
          ready=1
          break
        fi
        sleep 2
      done

      : >"$loginctl_session_details_path"
      awk -v user="$proof_user" '$3 == user { print $1 }' "$loginctl_sessions_path" | while read -r session_id; do
        if [ -n "$session_id" ]; then
          {
            printf -- '--- session %s ---\n' "$session_id"
            loginctl show-session "$session_id" || true
          } >>"$loginctl_session_details_path"
        fi
      done

      systemctl status --no-pager sddm.service >"$login_manager_status_path" || true
      systemctl status --no-pager display-manager.service >"$display_manager_status_path" || true
      journalctl -b -u sddm.service --no-pager -n 160 >"$journal_path" || true

      systemctl is-active sddm.service >/dev/null
      systemctl is-active display-manager.service >/dev/null
      test "$(systemctl get-default)" = "graphical.target"
      test -L /etc/systemd/system/display-manager.service

      if [ "$ready" -ne 1 ]; then
        sed -n "1,160p" "$login_manager_status_path" >&2 || true
        sed -n "1,160p" "$journal_path" >&2 || true
        sed -n "1,120p" "$loginctl_sessions_path" >&2 || true
        sed -n "1,120p" "$process_path" >&2 || true
        exit 1
      fi
    fi

    python3 - "$manifest_path" "$phase" "$summary_path" "$install_log_path" <<'PY'
    import json
    from pathlib import Path
    import subprocess
    import sys

    manifest_path, phase, summary_path, install_log_path = sys.argv[1:5]

    with open(manifest_path, "r", encoding="utf-8") as handle:
        manifest = json.load(handle)

    def read_lines(path: str, limit: int = 120) -> list[str]:
        file_path = Path(path)
        if not file_path.exists():
            return []
        with file_path.open("r", encoding="utf-8", errors="replace") as handle:
            return [line.rstrip("\n") for _, line in zip(range(limit), handle)]

    def run_command(command: list[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )

    def probe_installed_package(name: str) -> dict:
        result = run_command(
            ["rpm", "-q", "--qf", "%{name}-%{version}-%{release}.%{arch}\n", name]
        )
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        return {
            "name": name,
            "installed": result.returncode == 0,
            "matches": lines,
        }

    desktop_file_path = Path(manifest["session_descriptor_path"])
    exec_line = ""
    if desktop_file_path.exists():
        for line in desktop_file_path.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("Exec="):
                exec_line = line

    installed_package_versions = [
        probe_installed_package(name) for name in manifest["package_set"]
    ]

    default_target_result = run_command(["systemctl", "get-default"])
    login_manager_active_result = run_command(
        ["systemctl", "is-active", manifest["login_manager_service"]]
    )
    display_manager_active_result = run_command(
        ["systemctl", "is-active", manifest["display_manager_service"]]
    )
    alias_path = Path(manifest["display_manager_alias_path"])
    alias_target = alias_path.readlink().as_posix() if alias_path.is_symlink() else ""

    proof_user = manifest["proof_user"]
    proof_user_exists = run_command(["id", "-u", proof_user]).returncode == 0
    autologin_config_path = Path(manifest["autologin_config_path"])
    autologin_config = (
        autologin_config_path.read_text(encoding="utf-8", errors="replace")
        if autologin_config_path.exists()
        else ""
    )

    loginctl_sessions = read_lines(manifest["loginctl_sessions_path"])
    loginctl_details = read_lines(manifest["loginctl_session_details_path"])
    process_lines = read_lines(manifest["process_path"])
    labwc_processes = read_lines(manifest["labwc_process_path"])
    budgie_session_processes = read_lines(manifest["budgie_session_process_path"])

    proof_user_sessions = []
    for line in loginctl_sessions:
        fields = line.split()
        if len(fields) >= 3 and fields[2] == proof_user:
            proof_user_sessions.append(fields[0])

    summary = {
        "kind": manifest["kind"],
        "target": manifest["target"],
        "predecessor_target": manifest["predecessor_target"],
        "current_boundary": manifest["current_boundary"],
        "executed_phase": phase,
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
        },
        "package_install": {
            "packages": manifest["package_set"],
            "transaction_succeeded": all(
                probe["installed"] for probe in installed_package_versions
            ),
            "installed_package_versions": installed_package_versions,
            "log_excerpt": read_lines(install_log_path),
        },
        "login_manager_probe": {
            "post_reboot_default_target_graphical": (
                default_target_result.stdout.strip() == manifest["graphical_target"]
            ),
            "post_reboot_login_manager_active": login_manager_active_result.returncode == 0,
            "post_reboot_display_manager_active": display_manager_active_result.returncode == 0,
            "post_reboot_alias_exists": alias_path.exists(),
            "post_reboot_alias_is_symlink": alias_path.is_symlink(),
            "post_reboot_alias_target": alias_target,
            "post_reboot_alias_targets_sddm": alias_target.endswith("sddm.service"),
            "login_manager_status_excerpt": read_lines(manifest["login_manager_status_path"]),
            "display_manager_status_excerpt": read_lines(
                manifest["display_manager_status_path"]
            ),
            "journal_excerpt": read_lines(manifest["journal_path"]),
        },
        "autologin_probe": {
            "proof_user": proof_user,
            "proof_user_exists": proof_user_exists,
            "autologin_config_path": manifest["autologin_config_path"],
            "autologin_config_exists": autologin_config_path.exists(),
            "autologin_session": manifest["autologin_session"],
            "autologin_config_targets_budgie": (
                f"User={proof_user}" in autologin_config
                and f"Session={manifest['autologin_session']}" in autologin_config
            ),
            "autologin_config_excerpt": autologin_config.splitlines()[:80],
        },
        "session_probe": {
            "proof_user_sessions": proof_user_sessions,
            "proof_user_session_count": len(proof_user_sessions),
            "loginctl_sessions_excerpt": loginctl_sessions,
            "loginctl_session_details_excerpt": loginctl_details,
            "process_excerpt": process_lines,
            "labwc_processes": labwc_processes,
            "budgie_session_processes": budgie_session_processes,
            "labwc_running": bool(labwc_processes),
            "budgie_session_running": any(
                "budgie-session-binary" in line or "budgie-session" in line
                for line in budgie_session_processes
            ),
            "display_manager_started_session": bool(
                proof_user_sessions and labwc_processes and budgie_session_processes
            ),
        },
    }

    Path(manifest["session_probe_path"]).write_text(
        json.dumps(summary["session_probe"], indent=2) + "\n",
        encoding="utf-8",
    )

    with open(summary_path, "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2)
        handle.write("\n")
    PY
  '';
  budgieDisplayManagerSessionWriter = pkgs.lib.escapeShellArg ''
    from pathlib import Path

    harness_dir = Path("/var/lib/budgie-display-manager-session")
    harness_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    (harness_dir / "manifest.json").write_text(
        ${builtins.toJSON budgieDisplayManagerSessionManifest} + "\n",
        encoding="utf-8",
    )
    script_path = harness_dir / "run-display-manager-session-test.sh"
    script_path.write_text(
        ${builtins.toJSON budgieDisplayManagerSessionScript},
        encoding="utf-8",
    )
    script_path.chmod(0o755)
  '';
  budgieDisplayManagerSessionWriteCommand =
    builtins.toJSON "python3 -c ${budgieDisplayManagerSessionWriter}";
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
  budgieDisplayPersistenceTest = runner: (runner {
    sharedDirs = {};
    testScript = ''
      vm.wait_for_unit("multi-user.target")
      vm.succeed("command -v python3")
      vm.succeed(${budgieDisplayPersistenceWriteCommand})
      vm.succeed("test -f /tmp/budgie-display-persistence/manifest.json")
      vm.succeed("test -x /tmp/budgie-display-persistence/run-display-persistence-test.sh")
      vm.succeed("grep -q 'predecessor_target' /tmp/budgie-display-persistence/manifest.json")
      vm.succeed("""
        timeout 1200 bash -lc '
          set -euo pipefail
          /tmp/budgie-display-persistence/run-display-persistence-test.sh \
            /tmp/budgie-display-persistence/manifest.json \
            /tmp/budgie-display-persistence-summary.json \
            /tmp/budgie-display-persistence-install.log || {
              status=$?
              sed -n "1,200p" /tmp/budgie-display-persistence-install.log || true
              sed -n "1,120p" /tmp/budgie-display-persistence/initial-launch-session.log || true
              sed -n "1,120p" /tmp/budgie-display-persistence/relaunch-session.log || true
              exit "$status"
            }
        '
      """)
      vm.succeed("test -s /tmp/budgie-display-persistence-summary.json")
      vm.succeed("test -s /tmp/budgie-display-persistence-install.log")
      vm.succeed("test -s /tmp/budgie-display-persistence/initial-launch-session-manager.txt")
      vm.succeed("test -s /tmp/budgie-display-persistence/relaunch-session-manager.txt")
      vm.succeed("grep -q 'rocky-10_1-budgie-graphical-test' /tmp/budgie-display-persistence-summary.json")
      vm.succeed("grep -q 'org.gnome.SessionManager' /tmp/budgie-display-persistence-summary.json")
      vm.succeed("grep -q 'relaunch' /tmp/budgie-display-persistence-summary.json")
      vm.succeed(${budgieDisplayPersistenceAssertionCommand})
      vm.succeed("cat /tmp/budgie-display-persistence-summary.json")
      vm.succeed("sed -n '1,120p' /tmp/budgie-display-persistence/initial-launch-session.log || true")
      vm.succeed("sed -n '1,120p' /tmp/budgie-display-persistence/relaunch-session.log || true")
    '';
  }).sandboxed;
  budgieRebootPersistenceTest = runner: (runner {
    sharedDirs = {};
    testScript = ''
      vm.start(allow_reboot = True)
      vm.wait_for_unit("multi-user.target")
      vm.succeed("command -v python3")
      vm.succeed(${budgieRebootPersistenceWriteCommand})
      vm.succeed("test -f /var/lib/budgie-reboot-persistence/manifest.json")
      vm.succeed("test -x /var/lib/budgie-reboot-persistence/run-reboot-persistence-test.sh")
      vm.succeed("grep -q 'rocky-10_1-budgie-display-persistence-test' /var/lib/budgie-reboot-persistence/manifest.json")
      vm.succeed("""
        timeout 1200 bash -lc '
          set -euo pipefail
          /var/lib/budgie-reboot-persistence/run-reboot-persistence-test.sh \
            /var/lib/budgie-reboot-persistence/manifest.json \
            pre-reboot \
            /var/lib/budgie-reboot-persistence-summary.json \
            /var/lib/budgie-reboot-persistence-install.log || {
              status=$?
              sed -n "1,200p" /var/lib/budgie-reboot-persistence-install.log || true
              sed -n "1,120p" /var/lib/budgie-reboot-persistence/pre-reboot-session.log || true
              exit "$status"
            }
        '
      """)
      vm.reboot()
      vm.wait_for_unit("multi-user.target")
      vm.succeed("test -f /var/lib/budgie-reboot-persistence/manifest.json")
      vm.succeed("test -x /var/lib/budgie-reboot-persistence/run-reboot-persistence-test.sh")
      vm.succeed("""
        timeout 900 bash -lc '
          set -euo pipefail
          /var/lib/budgie-reboot-persistence/run-reboot-persistence-test.sh \
            /var/lib/budgie-reboot-persistence/manifest.json \
            post-reboot \
            /var/lib/budgie-reboot-persistence-summary.json \
            /var/lib/budgie-reboot-persistence-install.log || {
              status=$?
              sed -n "1,200p" /var/lib/budgie-reboot-persistence-install.log || true
              sed -n "1,120p" /var/lib/budgie-reboot-persistence/pre-reboot-session.log || true
              sed -n "1,120p" /var/lib/budgie-reboot-persistence/post-reboot-session.log || true
              exit "$status"
            }
        '
      """)
      vm.succeed("test -s /var/lib/budgie-reboot-persistence-summary.json")
      vm.succeed("test -s /var/lib/budgie-reboot-persistence-install.log")
      vm.succeed("test -s /var/lib/budgie-reboot-persistence/pre-reboot-session-manager.txt")
      vm.succeed("test -s /var/lib/budgie-reboot-persistence/post-reboot-session-manager.txt")
      vm.succeed("grep -q 'rocky-10_1-budgie-display-persistence-test' /var/lib/budgie-reboot-persistence-summary.json")
      vm.succeed("grep -q 'org.gnome.SessionManager' /var/lib/budgie-reboot-persistence-summary.json")
      vm.succeed("grep -q 'post-reboot' /var/lib/budgie-reboot-persistence-summary.json")
      vm.succeed(${budgieRebootPersistenceAssertionCommand})
      vm.succeed("cat /var/lib/budgie-reboot-persistence-summary.json")
      vm.succeed("sed -n '1,120p' /var/lib/budgie-reboot-persistence/pre-reboot-session.log || true")
      vm.succeed("sed -n '1,120p' /var/lib/budgie-reboot-persistence/post-reboot-session.log || true")
    '';
  }).sandboxed;
  budgieGraphicalLoginManagerPersistenceTest = runner: (runner {
    sharedDirs = {};
    testScript = ''
      vm.start(allow_reboot = True)
      vm.wait_for_unit("multi-user.target")
      vm.succeed("command -v python3")
      vm.succeed(${budgieGraphicalLoginManagerPersistenceWriteCommand})
      vm.succeed("test -f /var/lib/budgie-graphical-login-manager-persistence/manifest.json")
      vm.succeed("test -x /var/lib/budgie-graphical-login-manager-persistence/run-graphical-login-manager-persistence-test.sh")
      vm.succeed("grep -q 'rocky-10_1-budgie-reboot-persistence-test' /var/lib/budgie-graphical-login-manager-persistence/manifest.json")
      vm.succeed("""
        timeout 1200 bash -lc '
          set -euo pipefail
          /var/lib/budgie-graphical-login-manager-persistence/run-graphical-login-manager-persistence-test.sh \
            /var/lib/budgie-graphical-login-manager-persistence/manifest.json \
            pre-reboot \
            /var/lib/budgie-graphical-login-manager-persistence-summary.json \
            /var/lib/budgie-graphical-login-manager-persistence-install.log || {
              status=$?
              sed -n "1,200p" /var/lib/budgie-graphical-login-manager-persistence-install.log || true
              sed -n "1,120p" /var/lib/budgie-graphical-login-manager-persistence/pre-reboot-sddm-status.txt || true
              sed -n "1,120p" /var/lib/budgie-graphical-login-manager-persistence/pre-reboot-display-manager-status.txt || true
              sed -n "1,120p" /var/lib/budgie-graphical-login-manager-persistence/pre-reboot-sddm-journal.txt || true
              exit "$status"
            }
        '
      """)
      vm.reboot()
      vm.wait_for_unit("graphical.target")
      vm.wait_for_unit("sddm.service")
      vm.succeed("test -f /var/lib/budgie-graphical-login-manager-persistence/manifest.json")
      vm.succeed("test -x /var/lib/budgie-graphical-login-manager-persistence/run-graphical-login-manager-persistence-test.sh")
      vm.succeed("""
        timeout 900 bash -lc '
          set -euo pipefail
          /var/lib/budgie-graphical-login-manager-persistence/run-graphical-login-manager-persistence-test.sh \
            /var/lib/budgie-graphical-login-manager-persistence/manifest.json \
            post-reboot \
            /var/lib/budgie-graphical-login-manager-persistence-summary.json \
            /var/lib/budgie-graphical-login-manager-persistence-install.log || {
              status=$?
              sed -n "1,200p" /var/lib/budgie-graphical-login-manager-persistence-install.log || true
              sed -n "1,120p" /var/lib/budgie-graphical-login-manager-persistence/post-reboot-sddm-status.txt || true
              sed -n "1,120p" /var/lib/budgie-graphical-login-manager-persistence/post-reboot-display-manager-status.txt || true
              sed -n "1,120p" /var/lib/budgie-graphical-login-manager-persistence/post-reboot-sddm-journal.txt || true
              exit "$status"
            }
        '
      """)
      vm.succeed("test -s /var/lib/budgie-graphical-login-manager-persistence-summary.json")
      vm.succeed("test -s /var/lib/budgie-graphical-login-manager-persistence-install.log")
      vm.succeed("test -s /var/lib/budgie-graphical-login-manager-persistence/pre-reboot-sddm-status.txt")
      vm.succeed("test -s /var/lib/budgie-graphical-login-manager-persistence/post-reboot-sddm-status.txt")
      vm.succeed("grep -q 'rocky-10_1-budgie-reboot-persistence-test' /var/lib/budgie-graphical-login-manager-persistence-summary.json")
      vm.succeed("grep -q 'graphical.target' /var/lib/budgie-graphical-login-manager-persistence-summary.json")
      vm.succeed("grep -q 'sddm.service' /var/lib/budgie-graphical-login-manager-persistence-summary.json")
      vm.succeed(${budgieGraphicalLoginManagerPersistenceAssertionCommand})
      vm.succeed("cat /var/lib/budgie-graphical-login-manager-persistence-summary.json")
      vm.succeed("sed -n '1,120p' /var/lib/budgie-graphical-login-manager-persistence/pre-reboot-sddm-status.txt || true")
      vm.succeed("sed -n '1,120p' /var/lib/budgie-graphical-login-manager-persistence/post-reboot-sddm-status.txt || true")
    '';
  }).sandboxed;
  budgieDisplayManagerSessionTest = runner: (runner {
    sharedDirs = {};
    testScript = ''
      vm.start(allow_reboot = True)
      vm.wait_for_unit("multi-user.target")
      vm.succeed("command -v python3")
      vm.succeed(${budgieDisplayManagerSessionWriteCommand})
      vm.succeed("test -f /var/lib/budgie-display-manager-session/manifest.json")
      vm.succeed("test -x /var/lib/budgie-display-manager-session/run-display-manager-session-test.sh")
      vm.succeed("grep -q 'rocky-10_1-budgie-graphical-login-manager-persistence-test' /var/lib/budgie-display-manager-session/manifest.json")
      vm.succeed("""
        timeout 1200 bash -lc '
          set -euo pipefail
          /var/lib/budgie-display-manager-session/run-display-manager-session-test.sh \
            /var/lib/budgie-display-manager-session/manifest.json \
            pre-reboot \
            /var/lib/budgie-display-manager-session-summary.json \
            /var/lib/budgie-display-manager-session-install.log || {
              status=$?
              sed -n "1,200p" /var/lib/budgie-display-manager-session-install.log || true
              exit "$status"
            }
        '
      """)
      vm.reboot()
      vm.wait_for_unit("graphical.target")
      vm.wait_for_unit("sddm.service")
      vm.succeed("test -f /var/lib/budgie-display-manager-session/manifest.json")
      vm.succeed("test -x /var/lib/budgie-display-manager-session/run-display-manager-session-test.sh")
      vm.succeed("""
        timeout 900 bash -lc '
          set -euo pipefail
          /var/lib/budgie-display-manager-session/run-display-manager-session-test.sh \
            /var/lib/budgie-display-manager-session/manifest.json \
            post-reboot \
            /var/lib/budgie-display-manager-session-summary.json \
            /var/lib/budgie-display-manager-session-install.log || {
              status=$?
              sed -n "1,200p" /var/lib/budgie-display-manager-session-install.log || true
              sed -n "1,160p" /var/lib/budgie-display-manager-session/post-reboot-sddm-status.txt || true
              sed -n "1,160p" /var/lib/budgie-display-manager-session/post-reboot-sddm-journal.txt || true
              sed -n "1,120p" /var/lib/budgie-display-manager-session/post-reboot-logind-sessions.txt || true
              sed -n "1,120p" /var/lib/budgie-display-manager-session/post-reboot-budgie-processes.txt || true
              exit "$status"
            }
        '
      """)
      vm.succeed("test -s /var/lib/budgie-display-manager-session-summary.json")
      vm.succeed("test -s /var/lib/budgie-display-manager-session-install.log")
      vm.succeed("test -s /var/lib/budgie-display-manager-session/post-reboot-logind-sessions.txt")
      vm.succeed("test -s /var/lib/budgie-display-manager-session/post-reboot-budgie-processes.txt")
      vm.succeed("grep -q 'rocky-10_1-budgie-graphical-login-manager-persistence-test' /var/lib/budgie-display-manager-session-summary.json")
      vm.succeed("grep -q 'budgieproof' /var/lib/budgie-display-manager-session-summary.json")
      vm.succeed("grep -q 'sddm.service' /var/lib/budgie-display-manager-session-summary.json")
      vm.succeed("grep -q 'budgie-session' /var/lib/budgie-display-manager-session-summary.json")
      vm.succeed(${budgieDisplayManagerSessionAssertionCommand})
      vm.succeed("cat /var/lib/budgie-display-manager-session-summary.json")
      vm.succeed("sed -n '1,120p' /var/lib/budgie-display-manager-session/post-reboot-logind-session-details.txt || true")
      vm.succeed("sed -n '1,120p' /var/lib/budgie-display-manager-session/post-reboot-sddm-status.txt || true")
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
  "10_1-budgie-display-persistence-test" = budgieDisplayPersistenceTest lib.rocky."10_1";
  "10_1-budgie-reboot-persistence-test" = budgieRebootPersistenceTest lib.rocky."10_1";
  "10_1-budgie-graphical-login-manager-persistence-test" =
    budgieGraphicalLoginManagerPersistenceTest lib.rocky."10_1";
  "10_1-budgie-display-manager-session-test" =
    budgieDisplayManagerSessionTest lib.rocky."10_1";
  "10_1-budgie-graphical-harness-test" = budgieGraphicalHarnessTest lib.rocky."10_1";
  "10_1-budgie-session-gate-test" = budgieSessionGateTest lib.rocky."10_1";
} //
package.rocky.images
