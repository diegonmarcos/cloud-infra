{ config, pkgs, lib, ... }:
# Automated wildcard TLS cert for *.diegonmarcos.com via acme.sh + Cloudflare DNS-01.
# Writes cert to /opt/containers/maddy/tls/ (shared mount for maddy + stalwart).
# Monthly renewal via /etc/cron.monthly/tls-acme-renew.
# Reads CF_API_TOKEN from sops .secrets.d/ (HM secrets pipeline).
let
  tlsDir = "/opt/containers/maddy/tls";
  domain = "*.diegonmarcos.com";
  acmeEmail = "me@diegonmarcos.com";
  acmeBin = "${pkgs.acme-sh}/bin/acme.sh";
in {
  home.packages = [ pkgs.acme-sh ];

  # Renewal script installed to /etc/cron.monthly/ by activation.
  # Uses baked acme.sh store path so it works without Nix profile in cron env.
  home.file.".local/share/tls-acme/renew.sh" = {
    executable = true;
    text = ''
      #!/bin/sh
      HOME=/home/ubuntu
      SECRETS_D="$HOME/.config/home-manager/.secrets.d"
      CF_TOKEN_FILE="$SECRETS_D/CF_API_TOKEN"
      [ -f "$CF_TOKEN_FILE" ] || { echo "[tls-acme-renew] No CF_API_TOKEN — skipping"; exit 0; }
      export CF_Token="$(cat "$CF_TOKEN_FILE")"
      "${acmeBin}" --home "$HOME/.acme.sh" --renew-all --days 30 || true
      "${acmeBin}" --home "$HOME/.acme.sh" --install-cert -d "${domain}" \
        --fullchain-file "${tlsDir}/fullchain.pem" \
        --key-file "${tlsDir}/privkey.pem" || true
      docker ps -q --filter 'name=stalwart' | xargs -r docker restart
      docker ps -q --filter 'name=maddy'    | xargs -r docker restart
      echo "[tls-acme-renew] Done"
    '';
  };

  home.activation.tlsAcme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    (
    SECRETS_D="$HOME/.config/home-manager/.secrets.d"
    CF_TOKEN_FILE="$SECRETS_D/CF_API_TOKEN"
    if [ ! -f "$CF_TOKEN_FILE" ]; then
      echo "[tls-acme] CF_API_TOKEN not found in secrets — skipping cert issue" >&2
      exit 0
    fi

    _SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && _SUDO="$p" && break
    done
    [ -z "$_SUDO" ] && echo "[tls-acme] sudo not found — skipping" >&2 && exit 0

    # Ensure TLS dir is writable by ubuntu for cert deployment
    $_SUDO mkdir -p "${tlsDir}"
    $_SUDO chown "$(id -u):$(id -g)" "${tlsDir}"

    export CF_Token="$(cat "$CF_TOKEN_FILE")"
    ACME="${acmeBin}"

    # Issue/renew cert (idempotent — skips if not yet due, renews if due)
    "$ACME" --home "$HOME/.acme.sh" \
      --issue --dns dns_cf -d "${domain}" \
      --accountemail "${acmeEmail}" \
      --server letsencrypt \
      || echo "[tls-acme] WARN: acme.sh --issue returned non-zero (may already be issued)" >&2

    # Deploy cert to shared TLS dir
    "$ACME" --home "$HOME/.acme.sh" \
      --install-cert -d "${domain}" \
      --fullchain-file "${tlsDir}/fullchain.pem" \
      --key-file "${tlsDir}/privkey.pem" \
      || echo "[tls-acme] WARN: --install-cert failed (cert may not be issued yet)" >&2

    # Restart containers to pick up new cert
    docker ps -q --filter 'name=stalwart' | xargs -r docker restart
    docker ps -q --filter 'name=maddy'    | xargs -r docker restart

    # Install monthly renewal cron
    $_SUDO install -m 755 \
      "$HOME/.local/share/tls-acme/renew.sh" \
      /etc/cron.monthly/tls-acme-renew

    echo "[tls-acme] Done"
    )
  '';
}
