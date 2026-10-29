# hyde.nix : HyDE on NixOS (musabase method)
#
# Nix provides packages, services and a few FHS links.
# HyDE then copies its own dotfiles into $HOME with its own deployer (deez-dots),
# once per pinned HyDE commit, as normal writable files. Theme changes survive
# reboots and rebuilds because nothing in $HOME is touched until the pin changes.
{ config, pkgs, lib, inputs, hydeUser, ... }:

let
  # Keep only the attribute names that exist in this nixpkgs (avoids eval errors on renames).
  pick = set: names: map (n: set.${n}) (builtins.filter (n: set ? ${n}) names);

  # ---------------------------------------------------------------------------
  # 1. HyDE source at the pinned commit, with the one NixOS fix.
  #    theme.switch.sh switches GTK theme lookups to the read-only system profile
  #    when it detects NixOS; HyDE's writable themes live in ~/.local/share/themes.
  #    --replace-fail stops the build if upstream ever changes this line.
  # ---------------------------------------------------------------------------
  hydeSrc = pkgs.runCommand "hyde-src" { } ''
    cp -r ${inputs.hyde} $out
    chmod -R u+w $out
    substituteInPlace $out/Configs/.local/lib/hyde/theme.switch.sh \
      --replace-fail "[ -d /run/current-system/sw/share/themes ]" "[ -d /run/hyde-nixos-disabled ]"
  '';

  # 2. deez-dots, HyDE's deployer (standard library only).
  deez = pkgs.python3Packages.buildPythonPackage {
    pname = "deez-dots";
    version = "0.2.0";
    pyproject = true;
    src = inputs.deez;
    build-system = with pkgs.python3Packages; [ setuptools wheel ];
    pythonImportsCheck = [ "deez_dots" ];
  };

  # 3. hyprquery (hyq), used by theme switching. Built with system deps, no downloads.
  hyprquery = pkgs.stdenv.mkDerivation {
    pname = "hyprquery";
    version = "0-unstable-2026-06-13";
    src = inputs.hyprquery;
    nativeBuildInputs = with pkgs; [ cmake pkg-config ];
    buildInputs = with pkgs; [ hyprlang hyprutils libxkbcommon cli11 nlohmann_json ];
    cmakeFlags = [ "-DHYPRQUERY_DISTRO_BUILD=ON" ];
    postInstall = ''ln -s hyq $out/bin/hyprquery'';
  };

  # 4. Python for HyDE's scripts, replacing the uv venv HyDE builds on Arch.
  hydePython = pkgs.python3.withPackages (ps: [ deez ] ++ pick ps [
    "loguru" "pulsectl" "requests" "inotify-simple" "websockets" "xdg-base-dirs"
    "pywayland" "pygobject3" "pyqt6" "pysensors"
  ]);
  hydeVenv = pkgs.runCommand "hyde-python-env" { } ''
    mkdir -p $out/bin
    for f in ${hydePython}/bin/*; do ln -s "$f" "$out/bin/$(basename "$f")"; done
    cat > $out/bin/activate <<'EOF'
    VIRTUAL_ENV=/etc/hyde/python_env
    export VIRTUAL_ENV
    case ":$PATH:" in *":$VIRTUAL_ENV/bin:"*) ;; *) PATH="$VIRTUAL_ENV/bin:$PATH" ;; esac
    export PATH
    deactivate () { :; }
    EOF
  '';

  # 5. Lua for HyDE's Lua scripts (config watcher, battery notify), replacing luarocks.
  #    HyDE's shell/activate refuses to start unless a luarocks binary is on PATH,
  #    so luarocks is installed too (HyDE only checks for it; the rocks come from Nix).
  luaBase = pkgs.lua5_5 or pkgs.lua5_4;
  hydeLua = luaBase.withPackages (ps: pick ps [
    "luasec" "luasocket" "argparse" "dkjson" "luafilesystem" "lgi"
  ]);
  hydeLuarocks = luaBase.pkgs.luarocks or pkgs.luarocks;

  # Oh My Zsh with the three plugins HyDE's zsh config asks for.
  # nixpkgs' oh-my-zsh is read-only, so the plugins are added in a merged copy.
  zsh256color = pkgs.writeTextDir "zsh-256color/zsh-256color.plugin.zsh" ''
    # Stand-in for chrissicool/zsh-256color: upgrade plain terminals to their 256-colour names.
    case "$TERM" in xterm|screen|tmux) export TERM="$TERM-256color" ;; esac
  '';
  hydeOmz = pkgs.runCommand "hyde-oh-my-zsh" { } ''
    mkdir -p $out
    cp -rs ${pkgs.oh-my-zsh}/share/oh-my-zsh/. $out/
    chmod -R u+w $out
    p=$out/custom/plugins
    mkdir -p $p/zsh-autosuggestions $p/zsh-syntax-highlighting
    cp -r ${zsh256color}/zsh-256color $p/
    echo "source ${pkgs.zsh-autosuggestions}/share/zsh-autosuggestions/zsh-autosuggestions.zsh" \
      > $p/zsh-autosuggestions/zsh-autosuggestions.plugin.zsh
    echo "source ${pkgs.zsh-syntax-highlighting}/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" \
      > $p/zsh-syntax-highlighting/zsh-syntax-highlighting.plugin.zsh
  '';

  # 6. killall that also matches Nix wrapper names (.waybar-wrapped, .dunst-wrapped).
  #    HyDE restarts waybar, dunst and kitty with plain "killall NAME".
  killallShim = pkgs.writeShellScriptBin "killall" ''
    ${pkgs.psmisc}/bin/killall "$@" 2>/dev/null && exit 0
    name="''${!#}"
    set -- "''${@:1:$#-1}"
    exec ${pkgs.psmisc}/bin/killall "$@" -r "^\.?''${name}(-wrapped)?$"
  '';

  # 7. Seeding, step 1 (before Hyprland starts): deploy HyDE when the pin changed.
  hydeDeploy = pkgs.writeShellScriptBin "hyde-deploy" ''
    set -u
    export PATH="/run/wrappers/bin:/run/current-system/sw/bin:$HOME/.local/bin:$PATH"
    state="''${XDG_STATE_HOME:-$HOME/.local/state}/hyde"
    stage="''${XDG_CACHE_HOME:-$HOME/.cache}/hyde-nixos/src"
    mkdir -p "$state"

    # HyDE looks for its Python and Lua environments here: point them at the Nix ones.
    for env in python_env lua_env; do
      if [ -e "$state/$env" ] && [ ! -L "$state/$env" ]; then
        mv "$state/$env" "$state/$env.before-nixos.$(date +%s)"
      fi
      ln -sfn "/etc/hyde/$env" "$state/$env"
    done

    # Same pin as last time: touch nothing, so your theme and edits are kept.
    if [ "$(cat "$state/nixos-deployed" 2>/dev/null)" = "${hydeSrc}" ]; then
      echo "HyDE already deployed for this pin, nothing to do"
      exit 0
    fi

    # deez copies file modes, and store files are read-only, so deploy from a writable copy.
    echo "Deploying HyDE from ${hydeSrc}"
    rm -rf "$stage"
    mkdir -p "$(dirname "$stage")"
    cp -r "${hydeSrc}" "$stage"
    chmod -R u+w "$stage"

    deploy() {
      group="$1"; shift
      ${hydePython}/bin/deez --source "$stage" --config "$stage/Scripts/dots-groups/$group.toml" \
        dots --skip-git --no-deps-checks --deploy "$@" </dev/null
    }

    # Same dots as Scripts/install.sh, minus the ones Nix replaces
    # (package installs, fonts and cursors that go to /usr/local).
    deploy core hyde grimblast xdg-terminal-exec app2unit hyprland wallbash-gtk \
      waybar rofi dunst wlogout icon-wallbash \
      || { echo "core deploy failed, will retry next login" >&2; exit 1; }
    deploy extra electron-flags baloofilerc dolphin kitty hyprlock hypridle hyprsunset \
      fastfetch swaync_config || echo "warning: some extra dots failed" >&2
    deploy shell zsh || echo "warning: zsh dots failed" >&2

    echo "${hydeSrc}" > "$state/nixos-deployed"
    touch "$state/nixos-pending"
  '';

  # 8. Seeding, step 2 (inside Hyprland): import themes once, then apply the current theme.
  hydeFirstrun = pkgs.writeShellScriptBin "hyde-firstrun" ''
    export PATH="$HOME/.local/lib/hyde:$HOME/.local/bin:/run/wrappers/bin:/run/current-system/sw/bin:$PATH"
    export LIB_DIR="$HOME/.local/lib" SHARE_DIR="$HOME/.local/share" HYDE_SHELL_INIT=1
    state="''${XDG_STATE_HOME:-$HOME/.local/state}/hyde"
    stage="''${XDG_CACHE_HOME:-$HOME/.cache}/hyde-nixos/src"

    # Wait for Hyprland's socket (up to 60s).
    for _ in $(seq 60); do
      sig="$(ls -t "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | head -n1)"
      [ -n "$sig" ] && break
      sleep 1
    done
    export HYPRLAND_INSTANCE_SIGNATURE="''${HYPRLAND_INSTANCE_SIGNATURE:-$sig}"

    if [ -z "$(ls -A "$HOME/.config/hyde/themes" 2>/dev/null)" ]; then
      notify-send -a HyDE "HyDE" "First login: importing themes from GitHub, this takes a few minutes"
      "$stage/Scripts/restore_thm.sh" \
        || notify-send -u critical -a HyDE "HyDE" "Theme import failed: journalctl --user -u hyde-firstrun"
    fi

    # Same tail as Scripts/install.sh. theme.switch.sh -q re-applies the theme you last picked.
    source "$LIB_DIR/hyde/globalcontrol.sh"
    "$LIB_DIR/hyde/wallpaper/cache.sh" commence -t ""
    "$LIB_DIR/hyde/theme.switch.sh" -q
    "$LIB_DIR/hyde/waybar.py" --update
    rm -f "$state/nixos-pending"
    notify-send -a HyDE "HyDE" "Setup finished"
  '';
in
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # ---- Session: Hyprland under UWSM (HyDE starts its services as UWSM units) ----
  programs.hyprland = { enable = true; withUWSM = true; xwayland.enable = true; };
  programs.hyprlock.enable = true;
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
    theme = "catppuccin-sddm-corners";
    extraPackages = with pkgs.kdePackages; [ qt5compat qtsvg ];  # the theme imports Qt5Compat.GraphicalEffects
  };
  services.displayManager.defaultSession = "hyprland-uwsm";

  # ---- User and shell ----
  programs.zsh = {
    enable = true;
    enableGlobalCompInit = false;
    # Oh My Zsh lives in the read-only store, so its cache goes to your home folder.
    shellInit = ''export ZSH_CACHE_DIR="$HOME/.cache/oh-my-zsh"'';
  };
  users.users.${hydeUser} = {
    shell = pkgs.zsh;
    extraGroups = [ "networkmanager" "video" "input" ];
  };

  # ---- Services HyDE enables on Arch ----
  networking.networkmanager.enable = true;
  hardware.bluetooth = { enable = true; powerOnBoot = true; };
  services.blueman.enable = true;
  services.pipewire = { enable = true; alsa.enable = true; pulse.enable = true; jack.enable = true; wireplumber.enable = true; };
  security.rtkit.enable = true;
  security.polkit.enable = true;
  services.udisks2.enable = true;
  services.gvfs.enable = true;
  services.upower.enable = true;

  # ---- Runs HyDE's prebuilt hydectl and hyde-ipc binaries ----
  programs.nix-ld.enable = true;

  # ---- Fonts and cursor HyDE downloads on Arch ----
  fonts.packages = with pkgs; [
    nerd-fonts.caskaydia-cove nerd-fonts.jetbrains-mono nerd-fonts.mononoki
    maple-mono.truetype-autohint cantarell-fonts noto-fonts-cjk-sans
    noto-fonts-color-emoji material-design-icons
  ];

  # ---- Packages (HyDE starts bar, notifications, idle etc. itself: no NixOS services for them) ----
  environment.systemPackages = with pkgs; [
    # system
    pavucontrol pamixer networkmanagerapplet bluez brightnessctl playerctl udiskie
    # window manager
    dunst rofi waybar wlogout grim slurp satty hyprpicker cliphist
    wl-clipboard wl-clip-persist hyprsunset hypridle hyprpolkitagent
    (if pkgs ? awww then awww else swww)
    # dependencies
    parallel jq imagemagick libnotify xdg-user-dirs xdg-utils unzip fzf git curl psmisc
    kdePackages.ffmpegthumbs kdePackages.kde-cli-tools kdePackages.kimageformats
    qt5.qtimageformats kdePackages.qtimageformats gobject-introspection
    # theming
    nwg-look libsForQt5.qt5ct qt6Packages.qt6ct
    libsForQt5.qtstyleplugin-kvantum kdePackages.qtstyleplugin-kvantum
    qt5.qtwayland kdePackages.qtwayland bibata-cursors
    (tela-circle-icon-theme.override { colorVariants = [ "dracula" ]; })
    catppuccin-sddm-corners
    # applications
    firefox kitty kdePackages.dolphin kdePackages.ark vim nwg-displays fastfetch starship
    # HyDE runtimes and custom builds
    hydePython hydeLua hydeLuarocks hyprquery hydeDeploy hydeFirstrun
    # Note: do not install binutils system-wide. If readelf is on PATH, HyDE inspects the
    # Hyprland binary for Lua support, and on NixOS that path is a wrapper script.
    (lib.hiPrio killallShim)
  ];

  # ---- Stable paths for HyDE's Python and Lua envs (/etc survives garbage collection) ----
  environment.etc."hyde/python_env".source = hydeVenv;
  environment.etc."hyde/lua_env".source = hydeLua;
  environment.pathsToLink = [ "/lib/girepository-1.0" ];
  environment.sessionVariables.GI_TYPELIB_PATH = "/run/current-system/sw/lib/girepository-1.0";

  # ---- The FHS paths HyDE hardcodes, as links instead of patches ----
  systemd.tmpfiles.rules = [
    "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash"
    "L+ /bin/env - - - - ${pkgs.coreutils}/bin/env"
    "L+ /usr/bin/python3 - - - - ${hydePython}/bin/python3"
    "L+ /usr/bin/rofi - - - - ${pkgs.rofi}/bin/rofi"
    "L+ /usr/bin/xdg-open - - - - ${pkgs.xdg-utils}/bin/xdg-open"
    "L+ /usr/bin/kitten - - - - ${pkgs.kitty}/bin/kitten"
    "d /usr/libexec 0755 root root -"
    "L+ /usr/libexec/hyprpolkitagent - - - - ${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent"
    "d /usr/share 0755 root root -"
    "L+ /usr/share/wlogout - - - - ${pkgs.wlogout}/share/wlogout"
    "L+ /usr/share/oh-my-zsh - - - - ${hydeOmz}"
    "L+ /usr/share/zsh-theme-powerlevel10k - - - - ${pkgs.zsh-powerlevel10k}/share/zsh-powerlevel10k"
  ];

  # ---- The two user units that put HyDE in $HOME ----
  systemd.user.services.hyde-deploy = {
    description = "HyDE: deploy dotfiles into $HOME when the pinned commit changes";
    wantedBy = [ "default.target" "graphical-session-pre.target" ];
    before = [ "graphical-session-pre.target" ];
    unitConfig.ConditionUser = hydeUser;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${hydeDeploy}/bin/hyde-deploy";
      TimeoutStartSec = "10min";
    };
  };

  systemd.user.services.hyde-firstrun = {
    description = "HyDE: import themes and apply the current theme after a deploy";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" "hyde-deploy.service" ];
    partOf = [ "graphical-session.target" ];
    unitConfig = {
      ConditionUser = hydeUser;
      ConditionPathExists = "%h/.local/state/hyde/nixos-pending";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${hydeFirstrun}/bin/hyde-firstrun";
      TimeoutStartSec = "30min";
    };
  };
}
