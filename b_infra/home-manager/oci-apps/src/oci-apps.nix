{ config, pkgs, lib, ... }:

{
  imports = [
    (import ./wireguard.nix { vmName = "oci-apps"; })
    (import ./modules/firewall.nix {
      vmName = "oci-apps";
      publicPorts = [
        { port = 3010; proto = "tcp"; desc = "AFFiNE"; }
        { port = 8081; proto = "tcp"; desc = "C3 API"; }
        { port = 3000; proto = "tcp"; desc = "Crawlee/Gitea/Backup"; }
        { port = 3001; proto = "tcp"; desc = "Crawlee API"; }
        { port = 2222; proto = "tcp"; desc = "Gitea SSH"; }
        { port = 2223; proto = "tcp"; desc = "Backup BUP SSH"; }
        { port = 2224; proto = "tcp"; desc = "Backup Borg SSH"; }
        { port = 8099; proto = "tcp"; desc = "cloud-spec httpd"; }
        { port = 2200; proto = "tcp"; desc = "Rescue SSH (Dropbear — untouchable)"; }
      ];
    })
    (import ./httpd.nix {
      sites = {
        cloud-spec = { root = "/opt/containers/cloud-spec"; port = 8099; };
      };
    })
    ./modules/shared-all.nix
    (import ./modules/system-protection.nix { inherit config pkgs lib; ramMB = 24576; })
    (import ./modules/rescue-ssh.nix { inherit config pkgs lib; port = 2200; })
    (import ./modules/docker-network.nix {
      vmName  = "oci-apps";
      subnet  = "172.21.0.0/24";
      gateway = "172.21.0.1";
    })
    (import ./modules/dnsmasq.nix {
      vmName   = "oci-apps";
      dnsIp    = "172.21.0.2";
      subnet   = "172.21.0.0/24";
      containers = {
        "c3-api"           = "172.21.0.10";
        "rig-agentic"      = "172.21.0.11";
        nocodb             = "172.21.0.12";
        "nocodb-db"        = "172.21.0.13";
        "lgtm-grafana"     = "172.21.0.40";
        "lgtm-loki"        = "172.21.0.41";
        "lgtm-mimir"       = "172.21.0.42";
        "lgtm-tempo"       = "172.21.0.43";
        "photoprism-app"   = "172.21.0.50";
        "photoprism-db"    = "172.21.0.51";
        "photoprism-rclone" = "172.21.0.52";
        "code-server"      = "172.21.0.61";
        orchestrator       = "172.21.0.63";
        "hedgedoc-affine"  = "172.21.0.70";
        "hedgedoc-affine-db" = "172.21.0.71";
        "grist-app"        = "172.21.0.72";
        "filebrowser-app"  = "172.21.0.73";
        "etherpad-app"     = "172.21.0.74";
        "etherpad-db"      = "172.21.0.75";
        radicale           = "172.21.0.76";
        "revealmd-app"     = "172.21.0.77";
        "hedgedoc-app"     = "172.21.0.78";
        "hedgedoc-db"      = "172.21.0.79";
        "c3-services-mcp-api" = "172.21.0.80";
        "google-workspace-mcp" = "172.21.0.81";
        "mailu-mcp"        = "172.21.0.82";
        "mattermost-mcp"   = "172.21.0.83";
      };
      meshPeers = {
        "gcp-proxy"     = "10.0.0.1";
        "oci-mail"      = "10.0.0.3";
        "oci-analytics" = "10.0.0.4";
        "oci-apps-2"    = "10.0.0.7";
      };
    })
  ];
  home.username = "ubuntu";
  home.homeDirectory = "/home/ubuntu";
  home.stateVersion = "24.11";

  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    # Cloud SDKs (C3 API runs on this VM)
    google-cloud-sdk
  ];

  programs.git = {
    enable = true;
    userName = "Diego Marcos";
    userEmail = "diegonmarcos@gmail.com";
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = false;
    };
  };

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
      dexec = "docker exec -it";

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

      # Custom prompt with color
      PS1='\[\033[01;32m\]\u@oci-apps\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

      # History settings
      export HISTSIZE=10000
      export HISTFILESIZE=20000
      export HISTCONTROL=ignoredups:erasedups

      # Age key for sops
      [ -f "$HOME/.config/sops/age/keys.txt" ] && export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
    '';
  };

  home.sessionVariables = {
    EDITOR = "vim";
    VISUAL = "vim";
  };

  xdg.enable = true;
}
