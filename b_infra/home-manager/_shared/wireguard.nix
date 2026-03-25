# WireGuard mesh configuration module for Home Manager
# Canonical topology — keys generated on-VM (private key never leaves machine)
{ vmName }:

{ config, lib, pkgs, ... }:

let
  # ── Mesh topology from cloud-data ─────────────────────────────────────
  # Hub-and-spoke: all spokes connect to hub, hub routes between them
  cloudData = builtins.fromJSON (builtins.readFile ./modules/cloud-data-home-manager.json);

  mkPeer = p: {
    address   = p.wg_ip;
    endpoint  = p.public_ip;
    port      = p.wg_port;
    publicKey = p.wg_public_key;
    role      = p.role;
  };
  mkClient = name: c: {
    address   = c.wg_ip;
    endpoint  = null;
    port      = null;
    publicKey = c.wg_public_key;
    role      = c.role;
  };

  # Build topology from JSON peers (VMs) + clients (surface, termux)
  peerEntries = builtins.listToAttrs (
    builtins.filter (e: e.value.publicKey != null) (
      map (p: { name = p.name; value = mkPeer p; }) cloudData.wireguard.peers
    )
  );
  clientEntries = lib.mapAttrs mkClient cloudData.wireguard.clients;
  topology = peerEntries // clientEntries;

  thisVm = topology.${vmName};

  # ── Config generators ────────────────────────────────────────────────

  # Hub [Interface] with iptables forwarding + masquerade
  mkHubInterface = vm: ''
    [Interface]
    Address = ${vm.address}/24
    ListenPort = ${toString vm.port}
    PrivateKey = __PRIVKEY__
    MTU = 1380
    PostUp = iptables -I FORWARD -i wg0 -j ACCEPT; iptables -I FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o wg0 -j MASQUERADE
    PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.0.0.0/24 -o wg0 -j MASQUERADE
  '';

  # Spoke [Interface] — allow WireGuard traffic to reach Docker port mappings
  mkSpokeInterface = vm: ''
    [Interface]
    Address = ${vm.address}/24
    ListenPort = ${toString vm.port}
    PrivateKey = __PRIVKEY__
    MTU = 1380
    PostUp = iptables -I FORWARD -i wg0 -j ACCEPT; iptables -I FORWARD -o wg0 -j ACCEPT
    PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT
  '';

  # [Peer] block for a given peer VM
  mkPeer = name: peer: ''

    [Peer]
    # ${name}
    PublicKey = ${peer.publicKey}
  '' + (if peer.endpoint != null then
    "Endpoint = ${peer.endpoint}:${toString peer.port}\n"
  else "") +
  (if peer.role == "client" then
    "AllowedIPs = ${peer.address}/32\n"
  else if peer.role == "hub" then
    "AllowedIPs = 10.0.0.0/24\n"
  else
    "AllowedIPs = ${peer.address}/32\n"
  ) + "PersistentKeepalive = 25\n";

  # Derive hub name from topology (the peer with role == "hub")
  hubName = (lib.findFirst (p: p.role == "hub") { name = "gcp-proxy"; } cloudData.wireguard.peers).name;

  # Hub config: interface + ALL other peers
  mkHubConfig =
    let
      hub = topology.${hubName};
      peers = lib.filterAttrs (n: _: n != hubName) topology;
    in mkHubInterface hub
       + lib.concatStrings (lib.mapAttrsToList mkPeer peers);

  # Spoke config: interface + hub peer only
  mkSpokeConfig = name:
    let
      spoke = topology.${name};
      hub = topology.${hubName};
    in mkSpokeInterface spoke
       + mkPeer hubName hub;

  # Select the right config for this VM
  wgTemplate =
    if thisVm.role == "hub" then mkHubConfig
    else mkSpokeConfig vmName;

in {
  home.sessionVariables.WIREGUARD_IP = thisVm.address;

  programs.bash.bashrcExtra = ''
    # WireGuard mesh IP (also in home.sessionVariables for login shells)
    export WIREGUARD_IP="${thisVm.address}"
  '';

  home.activation.wireguard = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    (
    trap 'echo "[wireguard] FAILED at line $LINENO (''${FUNCNAME[0]:-main}): $BASH_COMMAND" >&2' ERR
    WG_CONF="/etc/wireguard/wg0.conf"
    WG_LOG_PREFIX="[wireguard]"

    # Find sudo (not in PATH during home-manager activation)
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "$WG_LOG_PREFIX ERROR: sudo not found — cannot manage WireGuard"
      exit 1
    fi

    # 1. Read existing private key (use sudo — /etc/wireguard is 700 root:root)
    PRIVKEY=""
    if $SUDO test -f "$WG_CONF"; then
      PRIVKEY=$($SUDO grep -oP '(?<=PrivateKey = ).+' "$WG_CONF" 2>/dev/null || true)
    fi

    if [ -z "$PRIVKEY" ]; then
      echo "$WG_LOG_PREFIX No existing PrivateKey in $WG_CONF — generating new keypair"
      WG_BIN="${pkgs.wireguard-tools}/bin/wg"
      if [ ! -x "$WG_BIN" ]; then
        echo "$WG_LOG_PREFIX ERROR: $WG_BIN not found — cannot generate keypair"
        exit 1
      fi
      PRIVKEY=$($WG_BIN genkey)
      PUBKEY=$(echo "$PRIVKEY" | $WG_BIN pubkey)
      echo "$WG_LOG_PREFIX Generated new keypair for ${vmName}"
      echo "$WG_LOG_PREFIX PUBLIC KEY: $PUBKEY"
      echo "$WG_LOG_PREFIX *** Update wireguard.nix topology publicKey for ${vmName}, then redeploy all VMs ***"
      $SUDO mkdir -p /etc/wireguard
    fi

    # 2. Generate new config from template with injected key
    TEMPLATE=$(cat <<'WGTEMPLATE'
    ${wgTemplate}
    WGTEMPLATE
    )
    # Strip leading whitespace from heredoc
    TEMPLATE=$(echo "$TEMPLATE" | sed 's/^    //')
    NEW_CONF=$(echo "$TEMPLATE" | sed "s|__PRIVKEY__|$PRIVKEY|")

    # 3. Compare with current live config (use sudo — /etc/wireguard is 700 root:root)
    CURRENT=""
    if $SUDO test -f "$WG_CONF"; then
      CURRENT=$($SUDO cat "$WG_CONF" 2>/dev/null || true)
    fi

    if [ "$NEW_CONF" = "$CURRENT" ]; then
      echo "$WG_LOG_PREFIX wg0.conf unchanged — skipping"
    else
      echo "$WG_LOG_PREFIX wg0.conf changed — deploying"
      echo "$NEW_CONF" | $SUDO tee "$WG_CONF" > /dev/null
      $SUDO chmod 600 "$WG_CONF"
      $SUDO chown root:root "$WG_CONF"
      if $SUDO systemctl is-active wg-quick@wg0 >/dev/null 2>&1; then
        $SUDO systemctl restart wg-quick@wg0
        echo "$WG_LOG_PREFIX wg-quick@wg0 restarted"
      else
        echo "$WG_LOG_PREFIX wg-quick@wg0 not active — config written, start manually"
      fi
    fi
    ) || echo "[wireguard] FAILED — see errors above, activation continues"
  '';
}
