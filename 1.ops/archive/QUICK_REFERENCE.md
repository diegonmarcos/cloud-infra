# Build System Quick Reference

## 🚀 Most Common Commands

### Build Everything
```bash
./1.ops/build_main.sh build
```

### Start All Dev Servers
```bash
./1.ops/build_main.sh dev
```

### Clean All Builds
```bash
./1.ops/build_main.sh clean
```

### Build Individual Project
```bash
./1.ops/build_main.sh build-<project>
# Example: ./1.ops/build_main.sh build-myprofile
```

## 📋 Project-Specific Commands

### Linktree (Static Site)
```bash
cd linktree/1.ops
./build.sh build          # Validate files
./build.sh dev            # Start server on :8000
./build.sh watch          # Watch for changes
```

### CV Web (Sass)
```bash
cd cv_web/1.ops
./build.sh build          # Compile Sass → CSS
./build.sh dev            # Watch Sass files
./build.sh clean          # Remove CSS output
```

### MyFeed (Vue + Vite)
```bash
cd myfeed/1.ops
./build.sh build          # Build for production
./build.sh dev            # Vite dev server
./build.sh preview        # Preview production build
./build.sh clean          # Clean dist/
```

### MyProfile (SvelteKit)
```bash
cd myprofile/1.1.ops
./build.sh build          # Build for production
./build.sh dev            # SvelteKit dev server
./build.sh preview        # Preview production build
./build.sh check          # Type checking
./build.sh clean          # Clean build/
```

## 🛠️ Development Workflow

### Option 1: All Projects (Requires tmux)
```bash
./1.ops/build_main.sh dev
# Starts all servers in separate tmux sessions
# tmux attach -t build-myprofile  # Attach to specific session
```

### Option 2: Individual Projects
```bash
# Terminal 1: MyProfile
./1.ops/build_main.sh dev-myprofile

# Terminal 2: MyFeed
./1.ops/build_main.sh dev-myfeed

# Terminal 3: Linktree
./1.ops/build_main.sh dev-linktree
```

## 🧹 Cleaning

### Clean Build Artifacts Only
```bash
./1.ops/build_main.sh clean
```

### Deep Clean (Including node_modules)
```bash
./1.ops/build_main.sh clean-all
```

## 🧪 Testing

### Test All Projects
```bash
./1.ops/build_main.sh test
```

### Test Individual Project
```bash
cd <project>/1.ops
./build.sh test
```

## 🎯 Common Scenarios

### Scenario 1: Fresh Start After Pulling Changes
```bash
./1.ops/build_main.sh clean-all  # Clean everything
./1.ops/build_main.sh build      # Build all from scratch
```

### Scenario 2: Working on Linktree Only
```bash
cd linktree/1.ops
./build.sh dev                    # Start dev server
# Make changes, browser auto-refreshes
```

### Scenario 3: Deploy Preparation
```bash
./1.ops/build_main.sh build       # Build all
./1.ops/build_main.sh test        # Test all
git add .
git commit -m "Update"
git push                          # GitHub Actions will deploy
```

### Scenario 4: MyProfile Changes
```bash
cd myprofile/1.1.ops
./build.sh dev                    # Start dev server
# Make changes in 1.3.svelte/src/
./build.sh build                  # Build for production
./build.sh preview                # Preview build
```

## 📍 Port Reference

| Project | Dev Port | Preview Port |
|---------|----------|--------------|
| Linktree | 8000 | - |
| MyFeed | 5173 | 4173 |
| MyProfile | 5174 | 4174 |

## 🐛 Quick Troubleshooting

### "Command not found"
```bash
chmod +x 1.ops/build_main.sh
```

### "npm not found"
```bash
cd <project> && npm install
```

### "Port already in use"
```bash
lsof -ti:<port> | xargs kill -9
```

### Build fails after pull
```bash
./1.ops/build_main.sh clean-all
./1.ops/build_main.sh build
```

## 📖 More Help

```bash
./1.ops/build_main.sh help              # Main orchestrator help
cd <project>/1.ops && ./build.sh help   # Project-specific help
cat 1.ops/BUILD_SYSTEM_README.md       # Full documentation
```

---

**Tip:** Add this alias to your `~/.bashrc`:
```bash
alias build='./1.ops/build_main.sh'
```

Then you can just run:
```bash
build build-myprofile
build dev
build clean
```
