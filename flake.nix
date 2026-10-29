# flake.nix : HyDE on NixOS (musabase method)
# The only line you edit is hydeUser (the install step does it with sed).
{
  description = "HyDE Hyprland dotfiles on NixOS, deployed by HyDE's own deez-dots manifests";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Pinned upstream sources. flake.lock records their hashes automatically.
    hyde      = { url = "github:HyDE-Project/HyDE/fa2fd57afc7203b1b5653d3271f3a57ea3873f97";      flake = false; };
    deez      = { url = "github:HyDE-Project/deez-dots/f797e860bdccd7fbe188deac7e4dbabd9035786e"; flake = false; };
    hyprquery = { url = "github:HyDE-Project/hyprquery/002af783eeb8c487a4bf90d75e5a804340557967"; flake = false; };
  };

  outputs = { nixpkgs, ... }@inputs:
    let
      hydeUser = "CHANGEME";
    in
    {
      nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs hydeUser; };
        modules = [ ./configuration.nix ./hyde.nix ];
      };
    };
}
