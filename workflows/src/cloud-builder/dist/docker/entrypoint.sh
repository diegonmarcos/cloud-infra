#!/bin/sh
# Cloud-builder entrypoint — routes commands
case "${1:-}" in
  docker-up)
    cat /opt/cloud-builder/docker-up.sh
    ;;
  ""|--help|-h)
    cat <<'USAGE'
echo "Cloud Builder X86 Nixos" \
&& OP="ship" \
&& VM="all" \
&& IMG="ghcr.io/diegonmarcos/cloud-builder-x86-nixos:latest" \
&& echo "---" \
  && docker pull $IMG \
  && docker run --rm $IMG docker-up | \
     sh -s $OP $VM \
&& echo "---"
USAGE
    ;;
  *)
    # GHA / direct usage: nix develop shell with command
    exec nix develop /opt/cloud-builder-flake# --command "$@"
    ;;
esac
