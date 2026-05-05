# Log shipper — Fluent Bit streaming agent
# Inputs : systemd journald + /var/lib/docker/containers/*/*-json.log
# Output : OpenObserve via WG IP 10.0.0.6:5080 (host_journald + container_logs streams)
#
# Bearer token wiring: ZO_INGEST_TOKEN is read from $HOME/.config/home-manager/.secrets
# (decrypted by build.sh secrets from _shared/secrets.yaml at deploy time) and
# substituted into /opt/fluent-bit/log-shipper.conf at activation time. {HOSTNAME}
# is substituted from `hostname -s` so each VM tags its records with its alias.
#
# Resource caps mirror journal-ntfy.service: MemoryMax=64M CPUQuota=10%. Fits the
# 1 GB E2 Micro VMs (gcp-proxy, oci-mail, oci-analytics).
#
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [ fluent-bit ];

  home.file.".local/share/vm-pilot/log-shipper.conf.tpl" = {
    source = ../scripts/log-shipper.conf.tpl;
  };

  home.file.".local/share/vm-pilot/log-shipper.service".text = ''
    [Unit]
    Description=Fluent Bit — stream journald + docker container logs to OpenObserve
    After=network-online.target docker.service
    Wants=network-online.target

    [Service]
    Type=simple
    ExecStart=${pkgs.fluent-bit}/bin/fluent-bit --config=/opt/fluent-bit/log-shipper.conf
    Restart=always
    RestartSec=15
    MemoryMax=64M
    CPUQuota=10%
    User=root
    # Fluent Bit needs read access to /var/log/journal + /var/lib/docker
    ProtectSystem=strict
    ReadWritePaths=/var/lib/fluent-bit
    ReadOnlyPaths=/var/lib/docker /var/log/journal /run/log/journal /opt/fluent-bit

    [Install]
    WantedBy=multi-user.target
  '';

  home.activation.installLogShipper = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    # HM activate sets a strict PATH that has bash/coreutils/diffutils/jq/etc
    # but NOT awk or hostname. Use full nix-store paths for everything we
    # invoke directly (cf. etc-hosts-clean.nix which already does this).
    AWK=${pkgs.gawk}/bin/awk
    HOSTNAME_BIN=${pkgs.hostname}/bin/hostname
    MKTEMP=${pkgs.coreutils}/bin/mktemp
    INSTALL=${pkgs.coreutils}/bin/install
    MKDIR=${pkgs.coreutils}/bin/mkdir
    CHMOD=${pkgs.coreutils}/bin/chmod
    CHOWN=${pkgs.coreutils}/bin/chown
    CP=${pkgs.coreutils}/bin/cp
    MV=${pkgs.coreutils}/bin/mv
    TEE=${pkgs.coreutils}/bin/tee

    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && exit 0

    SRC="$HOME/.local/share/vm-pilot"
    SECRETS="$HOME/.config/home-manager/.secrets"

    # Read bearer token from the sops-decrypted .secrets dotenv file. If missing,
    # log loudly and skip — the agent unit will fail-fast on next activation
    # rather than silently shipping with an empty token.
    if [ ! -r "$SECRETS" ]; then
      echo "[log-shipper] FATAL: .secrets not readable at $SECRETS — skipping"
      exit 0
    fi
    ZO_TOKEN="$($AWK -F= '/^ZO_INGEST_TOKEN=/ {sub(/^ZO_INGEST_TOKEN=/,""); gsub(/^"|"$/,""); print; exit}' "$SECRETS")"
    if [ -z "$ZO_TOKEN" ]; then
      echo "[log-shipper] FATAL: ZO_INGEST_TOKEN missing/empty in $SECRETS — skipping"
      exit 0
    fi
    HOSTNAME_SHORT="$($HOSTNAME_BIN -s 2>/dev/null || echo unknown)"
    PARSERS_FILE=${pkgs.fluent-bit}/etc/fluent-bit/parsers.conf

    # Render the conf — literal substitution via awk index() (no regex, no shell-glob).
    # Same substitution pattern used by secrets-subst.nix.
    CONF_TPL="$SRC/log-shipper.conf.tpl"
    CONF_OUT_TMP="$($SUDO $MKTEMP /tmp/log-shipper.conf.XXXXXX)"
    "$AWK" -v tok="$ZO_TOKEN" -v hst="$HOSTNAME_SHORT" -v pf="$PARSERS_FILE" '
      {
        line = $0
        while ((i = index(line, "{ZO_INGEST_TOKEN}")) > 0)
          line = substr(line,1,i-1) tok substr(line,i+length("{ZO_INGEST_TOKEN}"))
        while ((i = index(line, "{HOSTNAME}")) > 0)
          line = substr(line,1,i-1) hst substr(line,i+length("{HOSTNAME}"))
        while ((i = index(line, "{PARSERS_FILE}")) > 0)
          line = substr(line,1,i-1) pf substr(line,i+length("{PARSERS_FILE}"))
        print line
      }
    ' "$CONF_TPL" | $SUDO $TEE "$CONF_OUT_TMP" >/dev/null

    $SUDO $MKDIR -p /opt/fluent-bit /var/lib/fluent-bit
    $SUDO $MV "$CONF_OUT_TMP" /opt/fluent-bit/log-shipper.conf
    $SUDO $CHMOD 0600 /opt/fluent-bit/log-shipper.conf
    $SUDO $CHOWN root:root /opt/fluent-bit/log-shipper.conf

    $SUDO $CP -f "$SRC/log-shipper.service" /etc/systemd/system/log-shipper.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable log-shipper.service 2>/dev/null || true
    $SUDO systemctl restart log-shipper.service 2>/dev/null || true
    echo "[log-shipper] deployed (host=$HOSTNAME_SHORT, target=10.0.0.6:5080)"
    ) || echo "[log-shipper] FAILED — activation continues"
  '';
}
