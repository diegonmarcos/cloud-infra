# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : src/modules/network/wireguard.nix
# ║   Engine : b_infra/_shared/vm-pilot/build.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# WireGuard mesh configuration module for Home Manager
# Private keys owned by vault, deployed via sops secrets pipeline
{ vmName }:

{ config, lib, pkgs, ... }:

let
  # ── Mesh topology from _cloud-data-consolidated.json[.native.wireguard] ────
  # 2026-04-27 migrated: cloud-data-home-manager.json → _cloud-data-consolidated.json[.native.wireguard]
  # Hub-and-spoke: all spokes connect to hub, hub routes between them
  consolidated = builtins.fromJSON (builtins.readFile ../_cloud-data-consolidated.json);
  cloudData = {
    wireguard = consolidated.native.wireguard or {};
  };

  # Endpoint in consolidated is "host:port" — split if public_ip/wg_port not present
  splitEndpoint = ep:
    let
      epStr = if ep == null then "" else ep;
      parts = lib.splitString ":" epStr;
    in {
      host = if (builtins.length parts) >= 1 then builtins.elemAt parts 0 else "";
      port = if (builtins.length parts) >= 2 then lib.toInt (builtins.elemAt parts 1) else 51820;
    };

  toTopoEntry = p:
    let ep = splitEndpoint (p.endpoint or null);
    in {
      address   = p.wg_ip;
      endpoint  = p.public_ip or (if ep.host == "" then null else ep.host);
      port      = p.wg_port or ep.port;
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
  # Keep all peers (even with null keys) so every VM can find itself in the map.
  # Peers with null keys are excluded later when generating [Peer] blocks.
  allPeerEntries = builtins.listToAttrs (
    map (p: { name = p.name; value = toTopoEntry p; }) cloudData.wireguard.peers
  );
  clientEntries = lib.mapAttrs toClientEntry cloudData.wireguard.clients;
  topology = allPeerEntries // clientEntries;

  thisVm =
    if topology ? ${vmName} then topology.${vmName}
    else throw ''
      wireguard.nix: VM "${vmName}" not found in _cloud-data-consolidated.json wireguard.peers.
      Available peers: ${builtins.concatStringsSep ", " (builtins.attrNames topology)}
      Fix: ensure cloud-data submodule is up to date (git submodule update --remote)
    '';

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

  # Hub config: interface + ALL other peers (skip peers with null publicKey)
  mkHubConfig =
    let
      hub = topology.${hubName};
      peers = lib.filterAttrs (n: v: n != hubName && v.publicKey != null) topology;
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
  # Assert this VM's own public key is present (null means stale cloud-data)
  wgTemplate =
    if thisVm.publicKey == null then
      throw ''
        wireguard.nix: VM "${vmName}" has null wg_public_key in _cloud-data-consolidated.json.
        This usually means the cloud-data submodule is stale. Fix:
          1. Regenerate cloud-data (push to cloud-data repo, or run derive-cloud-data)
          2. Update submodule: git submodule update --remote
      ''
    else if thisVm.role == "hub" then mkHubConfig
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

    # STRICT: key MUST come from sops secrets. No fallback, no generation, no reading existing config.
    if [ ! -f "$SECRET_FILE" ]; then
      echo "$WG_LOG_PREFIX FATAL: WG private key not found at $SECRET_FILE"
      echo "$WG_LOG_PREFIX Fix: ensure sops secrets.yaml has WG_PRIVATE_KEY_$VM_NAME_UPPER and redeploy"
      exit 1
    fi
    PRIVKEY=$(cat "$SECRET_FILE" | tr -d '[:space:]')
    echo "$WG_LOG_PREFIX Read private key from secrets ($SECRET_FILE)"

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
