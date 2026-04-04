#!/bin/bash
# VS Code Extensions Installation Script

set -e

echo "Installing 48 VS Code extensions..."

code --install-extension anthropic.claude-code
code --install-extension bierner.markdown-mermaid
code --install-extension cs128.cs128-clang-tidy
code --install-extension cschlosser.doxdocgen
code --install-extension docker.docker
code --install-extension dokca.42-ft-count-line
code --install-extension donjayamanne.githistory
code --install-extension eamodio.gitlens
code --install-extension evilcat.norminette-42
code --install-extension geddski.macros
code --install-extension github.copilot
code --install-extension github.copilot-chat
code --install-extension golang.go
code --install-extension google.gemini-cli-vscode-ide-companion
code --install-extension google.geminicodeassist
code --install-extension hars.cppsnippets
code --install-extension hediet.debug-visualizer
code --install-extension hediet.realtime-debugging
code --install-extension jakub-beranek.memviz
code --install-extension jurajstefanic.md-commands
code --install-extension kube.42header
code --install-extension llvm-vs-code-extensions.lldb-dap
code --install-extension mariusvanwijk-joppekoers.codam-norminette-3
code --install-extension ms-azuretools.vscode-containers
code --install-extension ms-azuretools.vscode-docker
code --install-extension ms-python.debugpy
code --install-extension ms-python.python
code --install-extension ms-python.vscode-pylance
code --install-extension ms-python.vscode-python-envs
code --install-extension ms-toolsai.jupyter
code --install-extension ms-toolsai.jupyter-keymap
code --install-extension ms-toolsai.jupyter-renderers
code --install-extension ms-toolsai.vscode-jupyter-cell-tags
code --install-extension ms-toolsai.vscode-jupyter-slideshow
code --install-extension ms-vscode-remote.remote-containers
code --install-extension ms-vscode.cmake-tools
code --install-extension ms-vscode.cpptools
code --install-extension ms-vscode.cpptools-extension-pack
code --install-extension ms-vscode.cpptools-themes
code --install-extension ms-vscode.live-server
code --install-extension ms-vscode.makefile-tools
code --install-extension psioniq.psi-header
code --install-extension ritwickdey.liveserver
code --install-extension technosophos.vscode-make
code --install-extension tomoki1207.pdf
code --install-extension twxs.cmake
code --install-extension vadimcn.vscode-lldb
code --install-extension wakatime.vscode-wakatime

echo "VS Code extensions installation complete!"
