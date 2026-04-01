# WireGuard mesh configuration module for Home Manager
# Private keys owned by vault, deployed via sops secrets pipeline
{ vmName }:

{ config, lib, pkgs, ... }:

let
  # ── Mesh topology from cloud-data ─────────────────────────────────────
  # Hub-and-spoke: all spokes connect to hub, hub routes between them
  cloudData = builtins.fromJSON (builtins.readFile ./modules/cloud-data-home-manager.json);

  toTopoEntry = p: {
    address   = p.wg_ip;
    endpoint  = p.public_ip;
    port      = p.wg_port;
    publicKey = p.wg_public_key;
    role      = p.role;
  };
  toClientEntry = name: c: {
    address   = c.wg_ip;
    endpoint  = null;
    port      = null;
    publicKey = c.wg_public_key;
    role      = c.role;
  };

  # Build topology from JSON peers (VMs) + clients (surface, termux)
  peerEntries = builtins.listToAttrs (
    builtins.filter (e: e.value.publicKey != null) (
      map (p: { name = p.name; value = toTopoEntry p; }) cloudData.wireguard.peers
    )
  );
  clientEntries = lib.mapAttrs toClientEntry cloudData.wireguard.clients;
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
    PostUp = iptables -I FORWARD -i wg0 -j ACCEPT; iptables -I FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -s ${cloudData.wireguard.subnet} -o wg0 -j MASQUERADE
    PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -s ${cloudData.wireguard.subnet} -o wg0 -j MASQUERADE
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
    "AllowedIPs = ${cloudData.wireguard.subnet}\n"
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

    # 1. Read private key from sops secrets (deployed by build.sh secrets)
    VM_NAME_UPPER=$(echo "${vmName}" | tr '[:lower:]-' '[:upper:]_')
    SECRETS_DIR="$HOME/.config/home-manager/.secrets.d"
    SECRET_FILE="$SECRETS_DIR/WG_PRIVATE_KEY_$VM_NAME_UPPER"

    PRIVKEY=""
    if [ -f "$SECRET_FILE" ]; then
      PRIVKEY=$(cat "$SECRET_FILE" | tr -d '[:space:]')
      echo "$WG_LOG_PREFIX Read private key from secrets ($SECRET_FILE)"
    fi

    # Fallback: read from existing wg0.conf (migration period only)
    if [ -z "$PRIVKEY" ] && $SUDO test -f "$WG_CONF"; then
      PRIVKEY=$($SUDO grep -oP '(?<=PrivateKey = ).+' "$WG_CONF" 2>/dev/null || true)
      if [ -n "$PRIVKEY" ]; then
        echo "$WG_LOG_PREFIX WARNING: Using existing key from $WG_CONF (secret not found at $SECRET_FILE)"
        echo "$WG_LOG_PREFIX Ensure sops secrets.yaml has WG_PRIVATE_KEY_$VM_NAME_UPPER and redeploy"
      fi
    fi

    if [ -z "$PRIVKEY" ]; then
      echo "$WG_LOG_PREFIX ERROR: No WG private key found!"
      echo "$WG_LOG_PREFIX Expected: $SECRET_FILE (from sops secrets.yaml)"
      echo "$WG_LOG_PREFIX NEVER auto-generating keys — add key to sops secrets.yaml and redeploy"
      exit 1
    fi

    $SUDO mkdir -p /etc/wireguard

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
