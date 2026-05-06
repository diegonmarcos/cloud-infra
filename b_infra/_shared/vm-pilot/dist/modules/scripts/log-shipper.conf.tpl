# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : src/modules/scripts/log-shipper.conf.tpl
# ║   Engine : b_infra/home-manager/vm-pilot/build.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# log-shipper.conf — Fluent Bit config (template)
#
# Placeholders are substituted by vm-pilot/agents/log-shipper.nix at activation:
#   {HOSTNAME}        → output of `hostname -s`
#   {ZO_INGEST_TOKEN} → value from $HOME/.config/home-manager/.secrets
#                       (decrypted from _shared/secrets.yaml by build.sh secrets)
#
# Output target is the central OpenObserve at WG IP 10.0.0.6:5080 — no public
# DNS / Caddy dependency. Two streams keep host journals separate from
# container stdout/stderr.

[SERVICE]
    flush         5
    daemon        off
    log_level     info
    parsers_file  {PARSERS_FILE}
    storage.path  /var/lib/fluent-bit/storage
    storage.sync  normal
    storage.backlog.mem_limit 4M

[INPUT]
    Name             systemd
    Tag              host.{HOSTNAME}
    DB               /var/lib/fluent-bit/journald.db
    Read_From_Tail   On
    Strip_Underscores On

[INPUT]
    Name             tail
    Tag              docker.{HOSTNAME}.*
    Path             /var/lib/docker/containers/*/*-json.log
    DB               /var/lib/fluent-bit/docker.db
    Path_Key         _docker_log_path
    Buffer_Max_Size  64KB
    Mem_Buf_Limit    8MB
    Skip_Long_Lines  On
    Refresh_Interval 5
    Rotate_Wait      30
    Parser           docker

[FILTER]
    Name   parser
    Match  docker.*
    Key_Name log
    Parser   json
    Reserve_Data On
    Preserve_Key On

[OUTPUT]
    Name             http
    Match            host.*
    Host             10.0.0.6
    Port             5080
    URI              /api/default/host_journald/_json
    Format           json
    Json_Date_Key    _timestamp
    Json_Date_Format iso8601
    http_User        {ZO_USER}
    http_Passwd      {ZO_PASS}
    Retry_Limit      3
    net.keepalive    on

[OUTPUT]
    Name             http
    Match            docker.*
    Host             10.0.0.6
    Port             5080
    URI              /api/default/container_logs/_json
    Format           json
    Json_Date_Key    _timestamp
    Json_Date_Format iso8601
    http_User        {ZO_USER}
    http_Passwd      {ZO_PASS}
    Retry_Limit      3
    net.keepalive    on

# Built-in parsers `docker` and `json` are loaded from Fluent Bit's
# bundled parsers.conf — referenced via parsers_file in [SERVICE]
# below. Custom [PARSER] sections are not valid in the main config.
