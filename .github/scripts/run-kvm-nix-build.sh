#!/usr/bin/env bash
set -uo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <nix-attr> [nix-build-args...]" >&2
  exit 64
fi

attr="$1"
shift

cgroup_base() {
  local path
  path="$(cut -d: -f3 /proc/self/cgroup 2>/dev/null | head -n1 || true)"
  if [ -n "$path" ] && [ -d "/sys/fs/cgroup${path}" ]; then
    printf '/sys/fs/cgroup%s\n' "$path"
  else
    printf '/sys/fs/cgroup\n'
  fi
}

print_file_if_present() {
  local label="$1"
  local path="$2"

  if [ -e "$path" ]; then
    echo "--- ${label}"
    cat "$path" || true
  fi
}

print_runner_diagnostics() {
  local phase="$1"
  local base
  base="$(cgroup_base)"

  echo "::group::runner diagnostics (${phase})"
  echo "cgroup: ${base}"
  print_file_if_present "memory.current" "${base}/memory.current"
  print_file_if_present "memory.peak" "${base}/memory.peak"
  print_file_if_present "memory.max" "${base}/memory.max"
  print_file_if_present "memory.events" "${base}/memory.events"
  print_file_if_present "memory.swap.current" "${base}/memory.swap.current"
  print_file_if_present "memory.swap.max" "${base}/memory.swap.max"
  print_file_if_present "pids.current" "${base}/pids.current"
  print_file_if_present "pids.max" "${base}/pids.max"
  echo "--- /proc/meminfo"
  sed -n '1,20p' /proc/meminfo || true
  echo "--- filesystems"
  df -h / /nix "${GITHUB_WORKSPACE:-.}" 2>/dev/null || df -h || true
  echo "--- largest processes"
  ps -eo pid,ppid,stat,pcpu,pmem,rss,args --sort=-rss 2>/dev/null | head -30 || true
  echo "::endgroup::"
}

print_runner_diagnostics "before nix build"

nix build -L --max-jobs 1 --cores 1 "$attr" "$@"
status=$?
if [ "$status" -ne 0 ]; then
  print_runner_diagnostics "after failed nix build"
  exit "$status"
fi

if ! test -e result; then
  print_runner_diagnostics "missing result link"
  echo "ERROR: nix build completed but ./result is missing" >&2
  exit 1
fi

readlink result
