{ pkgs, package, system }:
let
  lib = package;
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
  runTestOnEveryImage = test:
    pkgs.lib.mapAttrs'
    (n: v: pkgs.lib.nameValuePair "${n}-multi-user-test" (test lib.rocky.${n}))
    lib.rocky.images;
in
runTestOnEveryImage multiUserTest //
{
  "10_1-graphical-bootstrap-test" = graphicalBootstrapTest lib.rocky."10_1";
} //
package.rocky.images
