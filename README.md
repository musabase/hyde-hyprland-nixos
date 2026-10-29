# HyDE Hyprland dotfiles on NixOS

Install [HyDE](https://github.com/HyDE-Project/HyDE) on NixOS with two files. Nix installs the packages and services, then HyDE copies its own dotfiles into your home folder with its own deployer (deez-dots), as normal writable files. Theme and wallpaper changes survive reboots and rebuilds.

Full guide: musabase.com

## Install

Start from a fresh NixOS install ("No desktop", hostname `nixos`, your user created in the installer).

```bash
cd /etc/nixos
sudo curl -fLO https://raw.githubusercontent.com/musabase/hyde-hyprland-nixos/main/flake.nix
sudo curl -fLO https://raw.githubusercontent.com/musabase/hyde-hyprland-nixos/main/hyde.nix
sudo sed -i "s/CHANGEME/$(whoami)/" flake.nix
sudo NIX_CONFIG="experimental-features = nix-command flakes" \
  nix-shell -p git --run "nixos-rebuild switch --flake /etc/nixos#nixos"
reboot
```

Log in through SDDM. On the first login HyDE imports its themes from GitHub (a few minutes), then shows "Setup finished".

## Update HyDE

Change the commit on the `hyde` line in `flake.nix` (or remove it to follow master), then:

```bash
sudo nix flake update hyde --flake /etc/nixos
sudo nixos-rebuild switch --flake /etc/nixos#nixos
```

Log out and back in. HyDE's files are refreshed; your theme, wallpaper, `config.toml` and `hyprland.lua` are kept.

## Files

- `flake.nix`: pins nixpkgs and the HyDE, deez-dots and hyprquery sources. You only change the username.
- `hyde.nix`: packages, services, fonts, a few `/usr` and `/bin` links HyDE expects, and the two user services that deploy HyDE.
