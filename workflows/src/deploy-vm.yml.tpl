name: "Deploy → {{VM_NAME}}"

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

      - name: Detect changed services
        id: changed
        run: |
          if [ "${{ github.event_name }}" = "workflow_dispatch" ]; then
            echo "dirs=ALL" >> "$GITHUB_OUTPUT"
          else
            dirs=$(git diff --name-only HEAD~1 HEAD -- 'a_solutions/*/src/' | awk -F/ '{print $2}' | sort -u | tr '\n' ' ')
            echo "dirs=$dirs" >> "$GITHUB_OUTPUT"
          fi

      - uses: ./.github/actions/setup-deps
        with:
{{SSH_CONFIG}}          sops_age_key: ${{ secrets.SOPS_AGE_KEY }}
{{DOCKER_STEPS}}
{{SHIP_STEPS}}
