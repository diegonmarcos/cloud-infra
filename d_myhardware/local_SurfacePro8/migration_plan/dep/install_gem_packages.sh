#!/bin/bash
# RubyGems Installation Script
# Dependencies will be automatically installed

set -e

echo "Installing 9 Ruby gems..."

gem install bundler
gem install classifier-reborn
gem install jekyll
gem install jekyll-feed
gem install jekyll-seo-tag
gem install minima
gem install pygments.rb
gem install rdiscount
gem install redcarpet

echo "RubyGems installation complete!"
