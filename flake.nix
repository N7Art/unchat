{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      tools = with pkgs; [
        zig
        zls
      ];
    in
    {

      devShells.${system}.default = pkgs.mkShell {
        buildInputs = tools;
        shellHook = ''
        ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-cache
        '';
      };
    };
}
