#!/bin/sh
# Test: the user my-watchdog is retired even when activation runs under
# `sudo -u` (XDG_RUNTIME_DIR stripped), and nothing is called when there is no
# user manager. Runs the SHIPPED snippet out of my-stack.nix against a stub
# systemctl and a real UNIX socket — not a grep for the fix's spelling.
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)/my-stack.nix"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
ok()   { printf "  [ok] %s\n"   "$1"; }
nope() { printf "  [FAIL] %s\n" "$1"; fail=1; }

# The snippet, nix-unescaped (''${ -> ${), with /run/user rooted in $T so the
# default-path branch is exercisable without root.
sed -n '/^ *_ubus="/,/^ *fi$/p' "$SRC" | sed "s/''\\\${/\${/; s|/run/user/|$T/run/user/|" > "$T/snip.sh"
[ -s "$T/snip.sh" ] || { echo "[test] FAILED: retirement snippet not found in my-stack.nix"; exit 1; }

mkdir -p "$T/bin"
cat > "$T/bin/systemctl" <<EOF
#!/bin/sh
echo "XDG=\$XDG_RUNTIME_DIR \$*" >> "$T/calls"
EOF
chmod +x "$T/bin/systemctl"
run() { rm -f "$T/calls"; env -u XDG_RUNTIME_DIR PATH="$T/bin:$PATH" "$@" sh "$T/snip.sh"; }

uid=$(id -u)
mkdir -p "$T/run/user/$uid"

# 1. No user manager (no bus socket) -> systemctl never called.
run
[ ! -e "$T/calls" ] && ok "no bus socket: nothing called" || nope "called systemctl with no user manager"

# 2. sudo-stripped env, user manager alive -> retires via the default bus path.
python3 -c "import socket,sys;socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "$T/run/user/$uid/bus"
run
grep -qx "XDG=$T/run/user/$uid --user disable --now my-watchdog.service" "$T/calls" 2>/dev/null \
  && ok "XDG_RUNTIME_DIR stripped: user copy retired via /run/user/<uid>" \
  || nope "user copy not retired when XDG_RUNTIME_DIR is stripped: $(cat "$T/calls" 2>/dev/null)"

# 3. An inherited XDG_RUNTIME_DIR wins over the default.
mkdir -p "$T/own"; python3 -c "import socket,sys;socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "$T/own/bus"
run XDG_RUNTIME_DIR="$T/own"
grep -q "^XDG=$T/own --user disable --now" "$T/calls" 2>/dev/null \
  && ok "inherited XDG_RUNTIME_DIR respected" || nope "inherited XDG_RUNTIME_DIR ignored"

[ $fail -eq 0 ] && { echo "[test] ALL CHECKS PASSED"; exit 0; }
echo "[test] FAILED"; exit 1
