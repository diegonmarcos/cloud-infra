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
    check "cypht.env: SESSION_TYPE=DB (UPPERCASE — Cypht switches on 'DB' literal)" \
        grep -q '^SESSION_TYPE=DB$' "$CYPHT_ENV"
    check "cypht.env: USER_CONFIG_TYPE=DB (UPPERCASE — file fallback otherwise)" \
        grep -q '^USER_CONFIG_TYPE=DB$' "$CYPHT_ENV"
    check "cypht.env: NO 'database' (lowercase) on TYPE keys" \
        bash -c "! grep -qE '^(SESSION_TYPE|USER_CONFIG_TYPE)=database' '$CYPHT_ENV'"
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

# PHP seeder logic now lives under cypht-api/ — see Section 7 below.
# Cross-cutting checks shared with cypht-api still belong here.
check "build.json: docker.runtime_packages.apt includes jq + postgresql-client" \
    bash -c "jq -e '.docker.runtime_packages.apt | contains(\"jq\") and contains(\"postgresql-client\")' '$CYPHT_DIR/build.json' >/dev/null"
check "dist/Dockerfile: apt-get install jq + postgresql-client (auto-injected by engine)" \
    bash -c "grep -qE 'apt-get install.*jq.*postgresql-client|apt-get install.*postgresql-client.*jq' '$CYPHT_DIR/dist/code/amd64/Dockerfile'"
COMPOSE_NIX="$CYPHT_DIR/src/compose.nix"
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

# ── 7. cypht-api sidecar (declarative accounts + CardDAV + feeds + settings) ─
echo ""
echo "==> 7. cypht-api/ sidecar layout + configs.json + ntfy-topics canonical-equality + uniqid shape"

API_DIR="$CYPHT_DIR/src/cypht-api"
CFG_JSON="$API_DIR/configs.json"
NTFY_TOPICS="$CYPHT_DIR/src/ntfy-topics.json"
NTFY_CANONICAL="$CLOUD_ROOT/I_cloud-data/ntfy-api/src/topics.json"

# ── 7a. cypht-api/ directory layout ──
check "cypht-api/ directory present" test -d "$API_DIR"
check "cypht-api/configs.json present" test -f "$CFG_JSON"
check "cypht-api/sidecar.sh present + executable" \
    bash -c "[ -x '$API_DIR/sidecar.sh' ]"
check "cypht-api/apply.php present" test -f "$API_DIR/apply.php"
check "cypht-api/verify.php present" test -f "$API_DIR/verify.php"
check "cypht-api/README.md present" test -f "$API_DIR/README.md"
for mod in bootstrap accounts carddav feeds settings; do
    check "cypht-api/lib/$mod.php present" test -f "$API_DIR/lib/$mod.php"
done

# ── 7b. configs.json schema ──
check "configs.json: primary_user.email = me@diegonmarcos.com" \
    bash -c "[ \"\$(jq -r '.primary_user.email' '$CFG_JSON')\" = 'me@diegonmarcos.com' ]"
check "configs.json: primary_user.pass_env = ME_PASSWORD" \
    bash -c "[ \"\$(jq -r '.primary_user.pass_env' '$CFG_JSON')\" = 'ME_PASSWORD' ]"
check "configs.json: accounts.source points to ../seed-accounts.json" \
    bash -c "[ \"\$(jq -r '.accounts.source' '$CFG_JSON')\" = '../seed-accounts.json' ]"
check "configs.json: carddav.radicale.server_template defined" \
    bash -c "jq -e '.carddav.radicale.server_template' '$CFG_JSON' >/dev/null"
check "configs.json: carddav.radicale.pass_env = ME_PASSWORD" \
    bash -c "[ \"\$(jq -r '.carddav.radicale.pass_env' '$CFG_JSON')\" = 'ME_PASSWORD' ]"
check "configs.json: feeds.source = ../ntfy-topics.json" \
    bash -c "[ \"\$(jq -r '.feeds.source' '$CFG_JSON')\" = '../ntfy-topics.json' ]"
check "configs.json: feeds.url_template references rss.diegonmarcos.com" \
    bash -c "jq -r '.feeds.url_template' '$CFG_JSON' | grep -q 'rss.diegonmarcos.com'"
check "configs.json: settings.theme_setting = darkly" \
    bash -c "[ \"\$(jq -r '.settings.theme_setting' '$CFG_JSON')\" = 'darkly' ]"
check "configs.json: all settings keys (excl. _doc) end in _setting" \
    bash -c "jq -e '.settings | to_entries | map(select(.key | startswith(\"_\") | not)) | all(.key | endswith(\"_setting\"))' '$CFG_JSON' >/dev/null"

# ── 7c. ntfy-topics.json — canonical-equality ──
check "ntfy-topics.json: present (regular file, not broken symlink)" \
    bash -c "[ -f '$NTFY_TOPICS' ] && [ ! -L '$NTFY_TOPICS' ]"
check "ntfy-topics.json: content matches I_cloud-data canonical" \
    bash -c "diff -q '$NTFY_TOPICS' '$NTFY_CANONICAL' >/dev/null"
check "ntfy-topics.json: declares 'topics' array" \
    bash -c "jq -e '.topics | type == \"array\"' '$NTFY_TOPICS' >/dev/null"

# ── 7d. accounts.php — uniqid-keyed shape (the bug fix) ──
ACC_PHP="$API_DIR/lib/accounts.php"
check "accounts.php: uses repoEntity() helper from bootstrap.php" \
    grep -q 'repoEntity(' "$ACC_PHP"
BOOT_PHP="$API_DIR/lib/bootstrap.php"
check "bootstrap.php::repoEntity() generates uniqid()" \
    grep -q 'uniqid()' "$BOOT_PHP"
check "bootstrap.php::repoEntity() sets entity['id']" \
    grep -qF "\$entity['id']" "$BOOT_PHP"
check "bootstrap.php::repoEntity() sets object=>false + connected=>false" \
    bash -c "grep -qF \"'object'\" '$BOOT_PHP' && grep -qF \"'connected'\" '$BOOT_PHP'"
check "accounts.php: NO flat-list append" \
    bash -c "! grep -qE '\\\$(imap|smtp|jmap)Servers\\[\\]\\s*=' '$ACC_PHP'"

# ── 7e. apply.php dispatch ──
APPLY_PHP="$API_DIR/apply.php"
for module in AccountsApi CardDavApi FeedsApi SettingsApi; do
    check "apply.php: dispatches to $module" \
        grep -qE "${module}\\s*::\\s*apply" "$APPLY_PHP"
done
check "apply.php: single \$userConfig->save() call" \
    bash -c "[ \"\$(grep -c '\\\$userConfig->save(' '$APPLY_PHP')\" = '1' ]"

# ── 7f. flake.nix registration ──
FLAKE_NIX="$CYPHT_DIR/src/flake.nix"
check "flake.nix: extraAssets includes seed-accounts.json" \
    grep -q "./seed-accounts.json" "$FLAKE_NIX"
check "flake.nix: extraAssets includes ntfy-topics.json" \
    grep -q "./ntfy-topics.json" "$FLAKE_NIX"
check "flake.nix: extraAssets includes ./cypht-api directory" \
    grep -q "./cypht-api" "$FLAKE_NIX"

# ── 7g. compose.nix mount + entrypoint ──
COMPOSE_NIX="$CYPHT_DIR/src/compose.nix"
check "compose.nix: mounts cypht-api at /tmp/cypht-config/cypht-api" \
    grep -q 'cypht-api:/tmp/cypht-config/cypht-api' "$COMPOSE_NIX"
check "compose.nix: entrypoint invokes /tmp/cypht-config/cypht-api/sidecar.sh" \
    grep -q '/tmp/cypht-config/cypht-api/sidecar.sh' "$COMPOSE_NIX"

# ── 7h. dist/ output ──
check "dist/assets/cypht-api/configs.json: present" \
    test -f "$CYPHT_DIR/dist/assets/cypht-api/configs.json"
check "dist/assets/cypht-api/sidecar.sh: present" \
    test -f "$CYPHT_DIR/dist/assets/cypht-api/sidecar.sh"
check "dist/assets/cypht-api/apply.php: present" \
    test -f "$CYPHT_DIR/dist/assets/cypht-api/apply.php"
check "dist/assets/cypht-api/lib/bootstrap.php: present" \
    test -f "$CYPHT_DIR/dist/assets/cypht-api/lib/bootstrap.php"
check "dist/compose: mounts cypht-api directory" \
    grep -q 'cypht-api' "$CYPHT_DIR/dist/compose/docker-compose.yml"

# Old monolithic files MUST NOT exist (regression guard)
check "old seed-accounts.sh removed" \
    bash -c "[ ! -f '$CYPHT_DIR/src/seed-accounts.sh' ]"
check "old seed-accounts.php removed" \
    bash -c "[ ! -f '$CYPHT_DIR/src/seed-accounts.php' ]"
check "old seed-config.json removed (replaced by cypht-api/configs.json)" \
    bash -c "[ ! -f '$CYPHT_DIR/src/seed-config.json' ]"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -gt 0 ] && exit 1
exit 0
