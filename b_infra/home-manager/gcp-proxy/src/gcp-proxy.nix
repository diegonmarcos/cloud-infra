{ config, pkgs, lib, ... }:

{
  imports = [
    (import ./wireguard.nix { vmName = "gcp-proxy"; })
    (import ./modules/firewall.nix {
      vmName = "gcp-proxy";
      publicPorts = [
        { port = 80;   proto = "tcp"; desc = "HTTP (Caddy)"; }
        { port = 443;  proto = "tcp"; desc = "HTTPS (Caddy)"; }
        { port = 443;  proto = "udp"; desc = "QUIC (Caddy)"; }
        { port = 993;  proto = "tcp"; desc = "IMAPS (Caddy L4 → oci-mail)"; }
        { port = 465;  proto = "tcp"; desc = "SMTPS (Caddy L4 → oci-mail)"; }
        { port = 587;  proto = "tcp"; desc = "SMTP Submission (Caddy L4 → oci-mail)"; }
        { port = 2200; proto = "tcp"; desc = "Rescue SSH (Dropbear — untouchable)"; }
      ];
    })
    ./modules/shared-all.nix
    (import ./modules/system-protection.nix { inherit config pkgs lib; ramMB = 1024; })
    (import ./modules/container-init.nix {
      inherit config pkgs lib;
      staleContainers = [ "syslog-central" "siem-api" "alerts-api" "dozzle" "fluent-bit" ];
    })
  ];
  home.username = "diego";
  home.homeDirectory = "/home/diego";
  home.stateVersion = "24.11";

  programs.home-manager.enable = true;

  # Git configuration
  programs.git = {
    enable = true;
    userName = "Diego Marcos";
    userEmail = "diegonmarcos@gmail.com";
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
