{ config, pkgs, lib, ... }:

let
  cloudData = builtins.fromJSON (builtins.readFile ./modules/cloud-data-home-manager.json);
  vmData = cloudData.vms."gcp-proxy";
  publicPorts = map (p: { port = p.port; proto = p.proto; desc = p.desc; }) vmData.public_ports
    ++ [{ port = vmData.rescue_port; proto = "tcp"; desc = "Rescue SSH (Dropbear — untouchable)"; }];
in {
  imports = [
    (import ./wireguard.nix { vmName = "gcp-proxy"; })
    (import ./modules/network-firewall.nix { vmName = "gcp-proxy"; inherit publicPorts; })
    ./modules/shared-all.nix
    (import ./modules/system-protection.nix { inherit config pkgs lib; vmName = "gcp-proxy"; })
    (import ./modules/system-protection-systemd-control.nix {})
  ];
  home.username = vmData.user;
  home.homeDirectory = vmData.home;
  home.stateVersion = cloudData.home_manager.state_version;

  programs.home-manager.enable = true;

  programs.git = {
    enable = true;
    userName = cloudData.owner.name;
    userEmail = cloudData.owner.email;
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = false;
    };
  };

  # Bash configuration
  programs.bash = {
    enable = true;
    shellAliases = {
      ll = "ls -lah";
      ".." = "cd ..";
      "..." = "cd ../..";
      dps = "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'";
      dlogs = "docker logs -f";
      dstop = "docker stop";
      drestart = "docker restart";

      # Block imperative package managers
      apt = "_nix_block apt";
      apt-get = "_nix_block apt-get";
      dpkg = "_nix_block dpkg";
      npm = "_nix_block npm";
      yarn = "_nix_block yarn";
      pnpm = "_nix_block pnpm";
      pip = "_nix_block pip";
      pip3 = "_nix_block pip3";
      pipx = "_nix_block pipx";
      snap = "_nix_block snap";
      brew = "_nix_block brew";
      nix-env = "_nix_block nix-env";
    };
    bashrcExtra = ''
      # Block imperative package managers — use declarative Nix Home Manager
      _nix_block() {
        echo -e "\033[1;31m[BLOCKED]\033[0m \"$1\" is disabled on this VM."
        echo '  This environment is managed declaratively with Nix Home Manager.'
        echo '  Flake: git/cloud/a_solutions/home-manager/'
        echo '  To add packages: edit the .nix file, then deploy with:'
        echo '    ./build.sh switch'
        echo '  Do NOT install packages imperatively.'
        return 1
      }

      # Custom prompt
      PS1='\[\033[01;32m\]\u@gcp-proxy\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

      # History settings
      export HISTSIZE=10000
      export HISTFILESIZE=20000
      export HISTCONTROL=ignoredups:erasedups

      # Age key for sops (if exists)
      [ -f "$HOME/.config/sops/age/keys.txt" ] && export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
    '';
  };

  # GCP guest agent — enables startup scripts + rescue-mode metadata
  home.packages = [ pkgs.google-guest-agent ];

  # Deploy google-guest-agent systemd service
  home.file.".local/share/gcp-agent/google-guest-agent.service".text = ''
    [Unit]
    Description=Google Guest Agent (nix)
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=simple
    ExecStart=${pkgs.google-guest-agent}/bin/google_guest_agent
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
  '';


  home.activation.installGcpAgent = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && exit 0

    SRC="$HOME/.local/share/gcp-agent"
    $SUDO cp -f "$SRC/google-guest-agent.service" /etc/systemd/system/google-guest-agent.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable google-guest-agent.service 2>/dev/null || true
    $SUDO systemctl restart google-guest-agent.service 2>/dev/null || true
    echo "[gcp-agent] Google Guest Agent deployed — startup scripts + rescue mode enabled"
    ) || echo "[gcp-agent] FAILED — see errors above"
  '';

  # Environment variables
  home.sessionVariables = {
    EDITOR = "vim";
    VISUAL = "vim";
  };

  # XDG directories
  xdg.enable = true;
}
