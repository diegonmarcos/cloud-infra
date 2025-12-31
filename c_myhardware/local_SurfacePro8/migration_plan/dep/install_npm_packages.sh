#!/bin/bash
# Node.js NPM Global Packages Installation Script

set -e

echo "Installing 2 global npm packages..."

npm install -g @anthropic-ai/claude-code
npm install -g @google/gemini-cli

echo "NPM packages installation complete!"
