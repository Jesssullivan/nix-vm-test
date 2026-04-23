# Rocky 10 Notes For Downstream Consumers

These notes are for downstream package-test and VM-harness consumers of this
fork, especially `Jesssullivan/cmux` and `tinyland-inc/rockies`.

## Release Shape

- Rocky Linux 10.0 GA date: 2025-06-11
- general support through 2030-05-31
- security support through 2035-05-31
- `x86_64` now means `x86-64-v3` baseline, not older `x86-64-v2` hardware
- fresh installs only for major-version adoption; no supported in-place major
  upgrade path from Rocky 9

## Installer And Base System Facts

- the installer disables the root account by default and expects an
  administrative user with sudo privileges
- third-party repositories are not added in the graphical installer anymore;
  use `inst.addrepo` or Kickstart if install-time repo changes matter
- Wayland is the default graphical stack, with Xwayland for legacy X11 clients

## Repository Surface

Rocky 10 ships a larger RHEL-like repository surface than the narrow cloud image
footprint suggests. Current public trees include:

- `BaseOS`
- `AppStream`
- `CRB`
- `extras`
- `plus`
- `devel`
- `HighAvailability`
- `NFV`
- `RT`
- `SAP`
- `SAPHANA`

For package tests this matters because a fresh cloud image only proves the base
image state until we explicitly enable more repositories.

## Package Management Changes

- Rocky 10 uses the DNF5 generation and deprecates module workflows
- `dnf module` should not be a planning assumption for EL10 package tests
- prefer `dnf repoquery` and ordinary `dnf install` flows with explicit package
  names
- RPM is 4.19, which is relevant for spec/build tooling behavior

## EPEL / CRB Implications

- `CRB` exists on Rocky 10 but is disabled by default
- many EPEL packages depend on `CRB`, so enabling EPEL without enabling `CRB`
  first is a bad default assumption
- EPEL 10 is versioned by EL10 minor-release streams, so package availability
  can differ between `10.0`, `10.1`, and the leading Stream-backed branch

## Testing Implications For Downstream Consumers

- separate "RPM install works" from "desktop/browser stack works"
- treat Rocky 10 as terminal-first until direct runtime proof says otherwise
- prefer explicit repo setup in tests:
  - enable `CRB` only when the test actually needs it
  - add `epel-release` only when the package/runtime dependency chain needs it
  - keep the base-image path minimal when validating first-party RPM install
- keep Fedora 42 and Rocky 10 as distinct lanes rather than assuming one can
  stand in for the other
- for `rockies`, keep the VM-preflight lane honest about what the published
  harness surface exposes today instead of assuming local branch state has
  already been promoted

## Current Fork Proof Surface

- the fork runs a bounded Rocky 10.1 VM smoke on the `nix-vm-test-kvm`
  lane through `.github/workflows/kvm-soak.yml`
- that proof remains the base terminal-first contract: the published
  `rocky-10_1-multi-user-test` harness boots and reaches `multi-user.target`
  under KVM
- the fork now also exposes a bounded `rocky-10_1-graphical-bootstrap-test`
  target intended for a separate KVM soak lane
- that graphical bootstrap target is still deliberately narrow:
  - it installs first-party Rocky 10 Xwayland/Wayland userspace at runtime
  - it proves a headless X11 client can connect through `xwfb-run -c mutter`
  - it does not prove a graphical login manager, Budgie session,
    display persistence, GPU acceleration, or broader `rockies` workload
    maturity
- the fork now also exposes a bounded
  `rocky-10_1-budgie-graphical-harness-test` target intended to complement
  downstream Budgie graphical harness work
- that Budgie harness target is still deliberately narrow:
  - it reuses the same generic Rocky graphical bootstrap path
  - it mounts a guest-side Budgie harness bundle and emits a Budgie package
    probe summary inside the guest
  - it does not prove a Budgie session, display manager, display persistence,
    GPU acceleration, or broader `rockies` workload maturity
- the fork now also exposes a bounded
  `rocky-10_1-budgie-session-gate-test` target intended to complement
  downstream Budgie session-gate work
- that Budgie session-gate target is still deliberately bounded:
  - it reuses the same generic Rocky graphical bootstrap path
  - it mounts a guest-side Budgie session-gate bundle and records a Budgie
    session transaction probe against the live Rocky 10.1 repo surface
  - it currently keeps the core Budgie session packages unresolved on the
    native Rocky 10.1 plus EL10 repo surface instead of pretending a full
    session is already installable there
  - it records session-descriptor expectations for the eventual Budgie session
    target without claiming those descriptors are present today
  - it does not prove a Budgie session, display manager, display persistence,
    GPU acceleration, or broader `rockies` workload maturity
- the fork now also exposes a first real
  `rocky-10_1-budgie-graphical-test` target intended to publish the initial
  Rocky 10.1 Budgie session-execution proof surface
- that Budgie graphical target is still deliberately bounded:
  - it consumes a Rocky 10.1 guest, enables `CRB`, installs `epel-release`,
    and adds explicit Fedora 44 consumer repos at runtime
  - it installs the Budgie desktop/session stack through that consumer-repo
    path instead of claiming native Rocky publication exists today
  - it launches `startbudgielabwc` under a headless wlroots environment and
    proves `labwc`, `budgie-session-binary`, and
    `org.gnome.SessionManager` appear on the session bus
  - it does not prove display persistence, a graphical login manager,
    bare-metal display readiness, GPU acceleration, or broader `rockies`
    workload maturity
- the fork now also exposes a bounded
  `rocky-10_1-budgie-display-persistence-test` target intended to publish the
  first stronger follow-on after Budgie graphical session execution
- that Budgie display-persistence target is still deliberately bounded:
  - it reuses the same Rocky 10.1 plus Fedora 44 consumer-repo install path as
    the first Budgie graphical target
  - it launches the headless `startbudgielabwc` session twice in the same guest
    and proves `labwc`, `budgie-session-binary`, and
    `org.gnome.SessionManager` come back on the relaunch cycle
  - it does not prove reboot persistence, a graphical login manager,
    bare-metal display readiness, GPU acceleration, hotplug, mixed-DPI policy,
    or broader `rockies` workload maturity
- the fork now also exposes a bounded
  `rocky-10_1-budgie-reboot-persistence-test` target intended to publish the
  first stronger reboot-persistence follow-on after relaunch persistence
- that Budgie reboot-persistence target is still deliberately bounded:
  - it reuses the same Rocky 10.1 plus Fedora 44 consumer-repo install path as
    the first Budgie graphical and relaunch-persistence targets
  - it launches the headless `startbudgielabwc` session once, reboots the
    guest, and launches the session again after the reboot
  - it proves `labwc`, `budgie-session-binary`, and
    `org.gnome.SessionManager` come back after the guest restart
  - it does not prove graphical login-manager persistence, bare-metal display
    readiness, GPU acceleration, hotplug, mixed-DPI policy, or broader
    `rockies` workload maturity

## Source Pointers

- https://docs.rockylinux.org/ja/release_notes/10_0/
- https://wiki.rockylinux.org/rocky/repo/
- https://communityblog.fedoraproject.org/epel-10-is-now-available/
