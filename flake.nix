{
  description = "Nix-VM-Test, re-use the NixOS VM integration test infrastructure on Ubuntu, Debian and Fedora";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systemsWithLib = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllLibSystems = f: lib.genAttrs systemsWithLib f;
      mkPkgs = system: import nixpkgs {
        overlays = [
          (final: prev: {
            libguestfs = prev.libguestfs.overrideAttrs (old: {
              configureFlags = (old.configureFlags or [ ]) ++ [
                "--disable-perl"
              ];
            });
          })
          self.overlays.default
        ];
        localSystem = system;
      };
      system = "x86_64-linux";
      pkgs = mkPkgs system;
    in
    {
      lib = forAllLibSystems (system: (mkPkgs system).testers.nonNixOSDistros);

      checks.${system} = import ./tests {
        package = pkgs.testers.nonNixOSDistros;
        inherit pkgs system;
      };

      overlays.default = import ./overlay.nix;
    };
}
