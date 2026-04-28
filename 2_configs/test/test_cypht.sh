#!/usr/bin/env bash
# Tester for the SnappyMail → Cypht migration (pure-kindling-pixel.md).
# Run after `cloud/2_configs/build.sh` regenerates dist/ and after
# `aa-sui_cypht/build.sh build` produces aa-sui_cypht/dist/.
#
# Asserts:
#  1. cypht/build.json structure (proxy, ports, two containers, db public:false)
#  2. dist/compose/docker-compose.yml has both cypht + cypht-postgres services
#  3. dist/configs/cypht.env has all required vars; no unsubstituted @VAR@
#  4. seed-accounts.json declares primary + 5 extras (Stalwart-IMAP, Stalwart-JMAP,
#     no-reply, Outlook, Gmail) with corresponding pass_env keys documented
#  5. Caddy ownership: build-caddy.json has exactly ONE webmail.diegonmarcos.com
#     route → 10.0.0.3:8889; SnappyMail's snappymail.app internal route is intact
#  6. Reconcile: cypht-postgres binds 127.0.0.1:5432 (loopback only)
set -uo pipefail
cd "$(dirname "$0")/.."

CLOUD_ROOT="$(cd ../ && pwd)"
CYPHT_DIR="${CLOUD_ROOT}/a_solutions/aa-sui_cypht"
SNAP_DIR="${CLOUD_ROOT}/a_solutions/aa-sui_snappymail"

PASS=0
FAIL=0

check() {
    label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        FAIL=$((FAIL + 1))
    fi
}

fail_with() {
    echo "[FAIL] $1"
    FAIL=$((FAIL + 1))
}

# ── 1. build.json structure ──────────────────────────────────────────────────
echo "==> 1. cypht/build.json schema"

[ -f "$CYPHT_DIR/build.json" ] || { fail_with "build.json missing"; exit 1; }

check "build.json: name == cypht" \
    bash -c "[ \"\$(jq -r .name '$CYPHT_DIR/build.json')\" = 'cypht' ]"

check "build.json: domain == webmail.diegonmarcos.com" \
    bash -c "[ \"\$(jq -r .domain '$CYPHT_DIR/build.json')\" = 'webmail.diegonmarcos.com' ]"

check "build.json: ports.app == 8889" \
    bash -c "[ \"\$(jq -r .ports.app '$CYPHT_DIR/build.json')\" = '8889' ]"

check "build.json: deploy.host == oci-mail" \
    bash -c "[ \"\$(jq -r .deploy.host '$CYPHT_DIR/build.json')\" = 'oci-mail' ]"

check "build.json: proxy.primary.domain == webmail.diegonmarcos.com" \
    bash -c "[ \"\$(jq -r .proxy.primary.domain '$CYPHT_DIR/build.json')\" = 'webmail.diegonmarcos.com' ]"

check "build.json: proxy.primary.auth == two_factor" \
    bash -c "[ \"\$(jq -r .proxy.primary.auth '$CYPHT_DIR/build.json')\" = 'two_factor' ]"

check "build.json: containers.app + containers.db both present" \
    bash -c "jq -e 'has(\"containers\") and (.containers | has(\"app\") and has(\"db\"))' '$CYPHT_DIR/build.json'"

check "build.json: containers.db.public == false (postgres NOT exposed)" \
    bash -c "[ \"\$(jq -r .containers.db.public '$CYPHT_DIR/build.json')\" = 'false' ]"

check "build.json: containers.db extra_ports binds 127.0.0.1 only" \
    bash -c "[ \"\$(jq -r '.containers.db.extra_ports[0].bind' '$CYPHT_DIR/build.json')\" = '127.0.0.1' ]"

# ── 2. dist/compose/docker-compose.yml ──────────────────────────────────────
echo ""
echo "==> 2. compose YAML (requires aa-sui_cypht/build.sh build to have run)"

CYPHT_COMPOSE="$CYPHT_DIR/dist/compose/docker-compose.yml"
if [ -f "$CYPHT_COMPOSE" ]; then
    check "compose: cypht service present" \
        grep -q '"cypht":' "$CYPHT_COMPOSE"
    check "compose: cypht-postgres service present" \
        grep -q '"cypht-postgres":' "$CYPHT_COMPOSE"
    check "compose: depends_on cypht-postgres healthy" \
        grep -q 'service_healthy' "$CYPHT_COMPOSE"
    check "compose: cypht-postgres bound 127.0.0.1:5432" \
        grep -q '127.0.0.1:5432:5432' "$CYPHT_COMPOSE"
else
    fail_with "compose YAML missing — run aa-sui_cypht/build.sh build first"
fi

# ── 3. dist/configs/cypht.env ────────────────────────────────────────────────
echo ""
echo "==> 3. cypht.env template substitution"

CYPHT_ENV="$CYPHT_DIR/dist/configs/cypht.env"
if [ -f "$CYPHT_ENV" ]; then
    check "cypht.env: no unsubstituted @VAR@ outside comments" \
        bash -c "! grep -vE '^[[:space:]]*#' '$CYPHT_ENV' | grep -qE '@[A-Z_]+@'"
    check "cypht.env: DB_DRIVER=pgsql" \
        grep -q '^DB_DRIVER=pgsql' "$CYPHT_ENV"
    check "cypht.env: DB_CONNECTION_TYPE=host (upstream-required)" \
        grep -q '^DB_CONNECTION_TYPE=host' "$CYPHT_ENV"
    check "cypht.env: DB_HOST=127.0.0.1" \
        grep -q '^DB_HOST=127.0.0.1' "$CYPHT_ENV"
    check "cypht.env: DB_PASS (NOT DB_PASSWORD — upstream var name)" \
        grep -qE '^DB_PASS=' "$CYPHT_ENV"
    check "cypht.env: no DB_PASSWORD (wrong var name)" \
        bash -c "! grep -qE '^DB_PASSWORD=' '$CYPHT_ENV'"
    check "cypht.env: CYPHT_MODULES contains jmap" \
        grep -q 'CYPHT_MODULES=.*jmap' "$CYPHT_ENV"
    check "cypht.env: CYPHT_MODULES contains feeds (RSS)" \
        grep -q 'CYPHT_MODULES=.*feeds' "$CYPHT_ENV"
    check "cypht.env: CYPHT_MODULES contains carddav_contacts" \
        grep -q 'CYPHT_MODULES=.*carddav_contacts' "$CYPHT_ENV"
    check "cypht.env: STALWART_DOMAIN substituted" \
        grep -q '^STALWART_HOST=mail-stalwart.diegonmarcos.com' "$CYPHT_ENV"
    check "cypht.env: LISTEN_PORT=8889" \
        grep -q '^LISTEN_PORT=8889' "$CYPHT_ENV"
else
    fail_with "cypht.env missing"
fi

# ── 3b. nginx.conf: WG-IP bind (defense in depth) ────────────────────────────
NGINX_CONF="$CYPHT_DIR/dist/configs/nginx.conf"
if [ -f "$NGINX_CONF" ]; then
    check "nginx.conf: listen 10.0.0.3:8889 (WG IP, NOT 0.0.0.0)" \
        grep -qE '^[[:space:]]+listen 10\.0\.0\.3:8889' "$NGINX_CONF"
    check "nginx.conf: no 0.0.0.0 bind" \
        bash -c "! grep -E '^[[:space:]]+listen[[:space:]]+0\.0\.0\.0' '$NGINX_CONF'"
    check "nginx.conf: no bare 'listen 80;' fallback" \
        bash -c "! grep -E '^[[:space:]]+listen 80;' '$NGINX_CONF'"
    check "nginx.conf: fastcgi_pass to unix socket (NOT TCP :9000 — collides with snappymail)" \
        grep -qE 'fastcgi_pass unix:/run/cypht-php-fpm\.sock' "$NGINX_CONF"
    check "nginx.conf: no fastcgi_pass to 127.0.0.1:9000 (snappymail conflict)" \
        bash -c "! grep -qE 'fastcgi_pass 127\.0\.0\.1:9000' '$NGINX_CONF'"
else
    fail_with "nginx.conf missing — run aa-sui_cypht/build.sh build first"
fi

# ── 3c. php-fpm-www.conf override (no TCP collision) ─────────────────────────
PHPFPM_CONF="$CYPHT_DIR/dist/configs/php-fpm-www.conf"
if [ -f "$PHPFPM_CONF" ]; then
    check "php-fpm-www.conf: listen on unix socket /run/cypht-php-fpm.sock" \
        grep -qE '^listen[[:space:]]*=[[:space:]]*/run/cypht-php-fpm\.sock' "$PHPFPM_CONF"
    check "php-fpm-www.conf: no TCP listen (would collide with snappymail)" \
        bash -c "! grep -qE '^listen[[:space:]]*=[[:space:]]*[0-9]' '$PHPFPM_CONF'"
    check "php-fpm-www.conf: comments use ; not # (php-fpm parser)" \
        bash -c "! grep -qE '^[[:space:]]*#' '$PHPFPM_CONF'"
else
    fail_with "php-fpm-www.conf missing — run aa-sui_cypht/build.sh build first"
fi

# Compose mounts the override
COMPOSE_YML="$CYPHT_DIR/dist/compose/docker-compose.yml"
if [ -f "$COMPOSE_YML" ]; then
    check "compose: mounts php-fpm-www.conf as zzz-cypht.conf (loads last, wins over zz-docker.conf)" \
        grep -q 'php-fpm-www.conf:/usr/local/etc/php-fpm.d/zzz-cypht.conf' "$COMPOSE_YML"
fi

# ── 4. seed-accounts inventory ───────────────────────────────────────────────
echo ""
echo "==> 4. seed-accounts.json inventory"

# PHP seeder — encrypts + persists IMAP/SMTP/JMAP backends server-side
SEED_PHP="$CYPHT_DIR/src/seed-accounts.php"
check "seed-accounts.php: present (declarative backend seeder)" \
    test -f "$SEED_PHP"
check "seed-accounts.php: uses Hm_User_Config_DB (cypht's own crypto)" \
    grep -q "Hm_User_Config_DB" "$SEED_PHP"
check "seed-accounts.php: writes imap_servers + smtp_servers" \
    bash -c "grep -q 'imap_servers' '$SEED_PHP' && grep -q 'smtp_servers' '$SEED_PHP'"
check "seed-accounts.php: rejects TODO_ placeholder secrets" \
    grep -q "TODO_" "$SEED_PHP"

# Invocation chain: seed-accounts.sh must call seed-accounts.php
SEED_SH="$CYPHT_DIR/src/seed-accounts.sh"
check "seed-accounts.sh: invokes seed-accounts.php" \
    grep -q "seed-accounts.php" "$SEED_SH"
check "seed-accounts.sh: uses pg_isready for postgres probe (apt-installed via runtime_packages)" \
    grep -qE '^[[:space:]]*pg_isready' "$SEED_SH"
check "build.json: docker.runtime_packages.apt includes jq + postgresql-client" \
    bash -c "jq -e '.docker.runtime_packages.apt | contains(\"jq\") and contains(\"postgresql-client\")' '$CYPHT_DIR/build.json' >/dev/null"
check "dist/Dockerfile: apt-get install jq + postgresql-client (auto-injected by engine)" \
    bash -c "grep -qE 'apt-get install.*jq.*postgresql-client|apt-get install.*postgresql-client.*jq' '$CYPHT_DIR/dist/code/amd64/Dockerfile'"

# flake registers all three assets
FLAKE="$CYPHT_DIR/src/flake.nix"
check "flake.nix: extraAssets includes seed-accounts.php" \
    grep -q "seed-accounts.php" "$FLAKE"

# compose mounts the PHP seeder
COMPOSE_NIX="$CYPHT_DIR/src/compose.nix"
check "compose.nix: mounts seed-accounts.php" \
    grep -q "assets/seed-accounts.php:/tmp/cypht-config/seed-accounts.php" "$COMPOSE_NIX"
check "compose.nix: mount target is /tmp/cypht-config (PHP open_basedir allows /tmp)" \
    bash -c "! grep -q '/opt/cypht-config' '$COMPOSE_NIX'"

SEED_JSON="$CYPHT_DIR/src/seed-accounts.json"
check "seed: primary email = me@diegonmarcos.com" \
    bash -c "[ \"\$(jq -r .primary.email '$SEED_JSON')\" = 'me@diegonmarcos.com' ]"

check "seed: extras count == 5" \
    bash -c "[ \"\$(jq -r '.extras | length' '$SEED_JSON')\" = '5' ]"

check "seed: includes Stalwart IMAP (port 2993)" \
    bash -c "jq -e '.extras[] | select(.imap.port == 2993)' '$SEED_JSON'"

check "seed: includes Stalwart JMAP (port 2443)" \
    bash -c "jq -e '.extras[] | select(.jmap.port == 2443)' '$SEED_JSON'"

check "seed: includes no-reply Maddy account" \
    bash -c "jq -e '.extras[] | select(.email == \"no-reply@diegonmarcos.com\")' '$SEED_JSON'"

check "seed: includes Outlook account" \
    bash -c "jq -e '.extras[] | select(.imap.host == \"outlook.office365.com\")' '$SEED_JSON'"

check "seed: includes Gmail account" \
    bash -c "jq -e '.extras[] | select(.imap.host == \"imap.gmail.com\")' '$SEED_JSON'"

# Each pass_env documented in secrets.schema.md
SCHEMA="$CYPHT_DIR/src/secrets.schema.md"
for env_var in $(jq -r '.primary.pass_env, .extras[].pass_env' "$SEED_JSON" | sort -u); do
    check "schema: $env_var documented" grep -q "$env_var" "$SCHEMA"
done

# ── 5. Caddy ownership ──────────────────────────────────────────────────────
echo ""
echo "==> 5. Caddy ownership of webmail.diegonmarcos.com"

CADDY_JSON="dist/build-caddy.json"
if [ -f "$CADDY_JSON" ]; then
    webmail_count=$(jq '[.routes[]? | select(.domain == "webmail.diegonmarcos.com")] | length' "$CADDY_JSON")
    if [ "$webmail_count" = "1" ]; then
        check "caddy: exactly ONE route for webmail.diegonmarcos.com" true
        upstream=$(jq -r '.routes[]? | select(.domain == "webmail.diegonmarcos.com") | .upstream' "$CADDY_JSON")
        if [ "$upstream" = "10.0.0.3:8889" ]; then
            check "caddy: webmail.diegonmarcos.com → 10.0.0.3:8889 (cypht)" true
        else
            fail_with "caddy: webmail upstream is '$upstream' (expected 10.0.0.3:8889)"
        fi
    else
        fail_with "caddy: $webmail_count routes for webmail.diegonmarcos.com (expected 1, got conflict)"
    fi

    snappy_internal=$(jq '[.private_A0_app_short[]? | select(.host == "snappymail.app")] | length' "$CADDY_JSON")
    [ "$snappy_internal" -ge 1 ] && check "caddy: snappymail.app internal route still present" true \
        || fail_with "caddy: snappymail.app internal route missing — snappymail demoted too far"
else
    fail_with "build-caddy.json not found — run cloud/2_configs/build.sh first"
fi

# ── 6. Reconcile loopback bind ──────────────────────────────────────────────
echo ""
echo "==> 6. cypht-postgres loopback enforcement"

check "build.json: postgres extra_ports[0].bind == 127.0.0.1" \
    bash -c "[ \"\$(jq -r '.containers.db.extra_ports[0].bind' '$CYPHT_DIR/build.json')\" = '127.0.0.1' ]"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -gt 0 ] && exit 1
exit 0
