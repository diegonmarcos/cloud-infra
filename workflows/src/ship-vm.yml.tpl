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
      packages: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2
          submodules: true

      - name: Update submodules to latest
        run: git submodule update --remote

      - uses: ./.github/actions/setup-deps
        with:
{{SSH_CONFIG}}          sops_age_key: ${{ secrets.SOPS_AGE_KEY }}
{{DOCKER_STEPS}}
      - name: Ship services
        shell: bash {0}
        run: |
          docker run --rm \
            -v "$GITHUB_WORKSPACE:/workspace" \
            -v "$HOME/.ssh:/root/.ssh:ro" \
            -v "$HOME/.config/sops/age:/root/.config/sops/age:ro" \
            -e SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt \
            -e FORCE_DEPLOY=1 \
            -e GITHUB_ACTIONS=true \
            -e GITHUB_EVENT_NAME="${GITHUB_EVENT_NAME:-}" \
            -e GITHUB_WORKSPACE=/workspace \
            -w /workspace \
            "$CLOUD_CI_IMAGE" \
            bash .github/workflows/scripts/ship-vm.sh {{VM_NAME}}
