#!/bin/bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/scripts/cloud-ship-container-sync-dnat.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Re-point the DNAT rules that publish a compose project's ports at the
# containers' CURRENT addresses. Run ON the deploy host, as root, via
# `ssh HOST 'sudo bash -s' < this-file`, with the compose flags in $1.
#
# WHY THIS EXISTS
#
# On hosts whose daemon.json sets "iptables": false (oci-mail does, alongside
# "userland-proxy": false) docker publishes NOTHING itself: the rules in the
# nat DOCKER chain ARE the port mapping, and docker never creates, updates or
# removes them. Every `compose up` that recreates a container hands it a fresh
# bridge address while those rules keep pointing at the old one, so a deploy
# reliably breaks its own port mapping and then fails its own activate step
# waiting for a service it just unplugged. That cost six deploys on
# 2026-08-30 before this was written.
#
# Note firewall.sh's "zero DNAT / kills any zombie Docker DNAT rules" comment
# is misleading: Caddy's jmap.diegonmarcos.com -> 10.0.0.3:2443 and the
# IMAPS/SMTPS SNI routes depend on exactly these rules. They are not zombies.
#
# ponytail: host-port DNAT only, and only on iptables:false hosts. Where
# docker manages its own chain this is a deliberate no-op -- racing the daemon
# over its own rules is how the orphans got there in the first place.
set -u

CF="${1:-}"
[ -z "$CF" ] && { echo "SKIP no compose flags"; exit 0; }

# netfilter needs root. This matters more than it looks: `iptables -S` on
# permission denied prints NOTHING and exits non-zero, which reads exactly
# like "no rules exist" -- and would make this script add a duplicate of every
# rule already present. Bail instead of guessing.
IPT="iptables"
[ "$(id -u)" = "0" ] || IPT="sudo -n iptables"
$IPT -t nat -S DOCKER >/dev/null 2>&1 || { echo "SKIP no iptables privilege"; exit 0; }

# Gate: if docker manages iptables, it owns these rules. Leave them alone.
if ! grep -qs '"iptables"[[:space:]]*:[[:space:]]*false' /etc/docker/daemon.json; then
    echo "SKIP docker manages iptables"
    exit 0
fi

# shellcheck disable=SC2086  # CF is intentionally word-split compose flags
for c in $(docker compose $CF ps --format '{{.Name}}' 2>/dev/null); do
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c" 2>/dev/null)
    [ -z "$ip" ] && continue
    net=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$v.NetworkID}}{{end}}' "$c" 2>/dev/null | cut -c1-12)
    br="br-$net"

    docker port "$c" 2>/dev/null | while read -r line; do
        cp=${line%%/*}
        hp=${line##*-> }
        [ "$hp" = "$line" ] && continue
        hport=${hp##*:}
        hip=${hp%:*}
        # Only the explicit mesh binds are ours to manage.
        case "$hip" in 0.0.0.0|::|"[::]"|"") continue ;; esac
        want="$ip:$cp"

        # Drop any rule for this host:port aimed anywhere other than $want.
        # Deleting by the exact -S text is what makes this safe to re-run.
        $IPT -t nat -S DOCKER 2>/dev/null \
            | grep -- "-d $hip/32 .*--dport $hport -j DNAT" \
            | grep -v -- "--to-destination $want" \
            | while IFS= read -r rule; do
                  # shellcheck disable=SC2086
                  $IPT -t nat ${rule/#-A /-D } 2>/dev/null \
                      && echo "removed stale $hip:$hport"
              done

        if $IPT -t nat -S DOCKER 2>/dev/null \
             | grep -q -- "-d $hip/32 .*--dport $hport .*--to-destination $want"; then
            echo "ok $hip:$hport -> $want"
        else
            $IPT -t nat -A DOCKER -d "$hip/32" ! -i "$br" -p tcp -m tcp \
                --dport "$hport" -j DNAT --to-destination "$want" \
                && echo "added $hip:$hport -> $want"
        fi
    done
done
