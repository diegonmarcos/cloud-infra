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
      - name: Ship inside cloud-ci container
        shell: bash {0}
        run: |
          CI_IMAGE="ghcr.io/diegonmarcos/cloud-ci:latest"
          echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u "${{ github.actor }}" --password-stdin
          docker pull "$CI_IMAGE"
          docker run --rm \
            -e SSH_KEY='${{ secrets.{{SSH_KEY_SECRET}} }}' \
            -e SSH_HOST='{{SSH_HOST_VALUE}}' \
            -e SSH_USER='{{SSH_USER_VALUE}}' \
            -e SSH_ALIAS='{{VM_NAME}}' \
            -e SOPS_AGE_KEY='${{ secrets.SOPS_AGE_KEY }}' \
            -e GITHUB_ACTIONS=true \
            -e GITHUB_EVENT_NAME="${GITHUB_EVENT_NAME:-}" \
            -e GITHUB_REPOSITORY="${GITHUB_REPOSITORY}" \
            -e GITHUB_SHA="${GITHUB_SHA}" \
            -e FORCE_DEPLOY=1 \
            "$CI_IMAGE" \
            bash -c '
              set -e

              # Clone repo
              mkdir -p ~/.ssh
              ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
              git clone --depth 2 --recurse-submodules \
                "https://github.com/$GITHUB_REPOSITORY.git" /workspace
              cd /workspace
              git submodule update --remote

              # Setup SSH to target VM
              echo "$SSH_KEY" > ~/.ssh/id_deploy && chmod 600 ~/.ssh/id_deploy
              cat > ~/.ssh/config <<SSHEOF
              Host $SSH_ALIAS
                HostName $SSH_HOST
                User $SSH_USER
                IdentityFile ~/.ssh/id_deploy
                StrictHostKeyChecking no
                ServerAliveInterval 30
                ServerAliveCountMax 10
              SSHEOF
              chmod 600 ~/.ssh/config

              # Setup SOPS
              mkdir -p ~/.config/sops/age
              echo "$SOPS_AGE_KEY" > ~/.config/sops/age/keys.txt
              export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

              # Ship all services for this VM
              bash .github/workflows/scripts/ship-vm.sh $SSH_ALIAS
            '
