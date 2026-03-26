name: "Ship → {{VM_NAME}}"

on:
  push:
    paths:
{{PATH_FILTERS}}    branches: [main]
  workflow_dispatch:

concurrency:
  group: ship-{{VM_NAME}}
  cancel-in-progress: false

jobs:
  ship:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: read
    steps:
      - name: Ship inside cloud-builder
        run: |
          echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u "${{ github.actor }}" --password-stdin
          docker pull ghcr.io/diegonmarcos/cloud-builder:latest
          docker run --rm \
            -e SSH_KEY='${{ secrets.{{SSH_KEY_SECRET}} }}' \
            -e SSH_HOST='{{SSH_HOST_VALUE}}' \
            -e SSH_USER='{{SSH_USER_VALUE}}' \
            -e SSH_ALIAS='{{VM_NAME}}' \
            -e SOPS_AGE_KEY='${{ secrets.SOPS_AGE_KEY }}' \
            -e GITHUB_ACTIONS=true \
            -e GITHUB_EVENT_NAME="${GITHUB_EVENT_NAME:-}" \
            -e GITHUB_REPOSITORY="${GITHUB_REPOSITORY}" \
            -e FORCE_DEPLOY=1 \
            ghcr.io/diegonmarcos/cloud-builder:latest \
            bash -c 'mkdir -p ~/.ssh && ssh-keyscan github.com >>~/.ssh/known_hosts 2>/dev/null && git clone --depth 2 --recurse-submodules https://github.com/$GITHUB_REPOSITORY.git /workspace && cd /workspace && git submodule update --remote && bash .github/workflows/scripts/cloud-builder.sh ship $SSH_ALIAS'
