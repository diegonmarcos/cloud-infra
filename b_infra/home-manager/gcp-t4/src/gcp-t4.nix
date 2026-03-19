{ config, pkgs, lib, ... }:

{
  imports = [
    (import ./wireguard.nix { vmName = "gcp-t4"; })
    (import ./modules/firewall.nix {
      vmName = "gcp-t4";
      publicPorts = [
        # No public ports — ollama binds to 10.0.0.8 (WireGuard only)
        { port = 2200; proto = "tcp"; desc = "Rescue SSH (Dropbear — untouchable)"; }
      ];
    })
    (import ./modules/idle-shutdown.nix { inherit config pkgs lib; vmName = "gcp-t4"; idleTimeoutHours = 1; })
    ./modules/shared-all.nix
    (import ./modules/system-protection.nix { inherit config pkgs lib; ramMB = 15360; })
    (import ./modules/rescue-ssh.nix { inherit config pkgs lib; port = 2200; })
  ];
  home.username = "diego";
  home.homeDirectory = "/home/diego";
  home.stateVersion = "24.11";

  programs.home-manager.enable = true;

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

      # GPU monitoring
      gsmi = "docker exec ollama nvidia-smi";
      ollama-models = "docker exec ollama ollama list";
      ollama-pull = "docker exec ollama ollama pull";

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
      PS1='\[\033[01;32m\]\u@gcp-t4\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

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
