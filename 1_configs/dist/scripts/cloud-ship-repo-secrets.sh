#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/gha/scripts/cloud-ship-repo-secrets.sh
# ║   Engine : 1_configs/src/gha/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

set -e
CLOUD_ROOT="${CLOUD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
. "$CLOUD_ROOT/1_configs/src/gha/scripts/cloud-ship-lib.sh"

# Secrets management
cmd_secrets() {
    service="$1"; action="$2"

    if [ -z "$service" ]; then
        echo ""
        echo "=== Secrets Status ==="
        printf "  %-25s %-12s %s\n" "SERVICE" "STATUS" "FILE"
        printf "  %s\n" "------------------------------------------------------------"
        for folder in "$SOLUTIONS_DIR"/*/src/secrets.yaml; do
            [ -f "$folder" ] || continue
            svc_name=$(basename "$(dirname "$(dirname "$folder")")")
            if grep -q "sops:" "$folder" 2>/dev/null; then
                status="encrypted"
            else
                status="PLAINTEXT"
            fi
            printf "  %-25s %-12s %s\n" "$svc_name" "$status" "src/secrets.yaml"
        done
        echo ""
        return
    fi

    folder=$(get_service_folder "$service")
    secrets_file="$SOLUTIONS_DIR/$folder/src/secrets.yaml"
    [ ! -f "$secrets_file" ] && { log_error "No secrets.yaml for $service"; exit 1; }

    case "$action" in
        encrypt) sops -e -i "$secrets_file"; log "Encrypted $secrets_file" ;;
        decrypt) sh "$SOLUTIONS_DIR/$folder/build.sh" secrets; log "Decrypted to dist/.secrets" ;;
        edit)    sops "$secrets_file" ;;
        show)    sops -d "$secrets_file" ;;
        *)       sops -d "$secrets_file" 2>/dev/null | grep -v "^#" | grep -v "^$" | cut -d: -f1 | sed 's/^/  /' ;;
    esac
}

cmd_secrets "$@"
