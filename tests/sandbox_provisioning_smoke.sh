#!/bin/bash
# Optional Docker smoke: verify selected-tool discovery/provisioning paths inside
# the Ralph sandbox image without calling a real AI provider or mutating this repo.
set -euo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not installed"
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker daemon unavailable"
  exit 0
fi

( cd "$R" && source lib/utils.sh && source lib/tools.sh && load_config >/dev/null && PROJECT_DIR="$R" setup_sandbox )

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/bin/opencode" <<'SH'
#!/bin/bash
if [[ "${1:-}" == "models" ]]; then
  echo "stub/local"
  exit 0
fi
echo "stub opencode $*"
SH
cat > "$tmp/bin/bd" <<'SH'
#!/bin/bash
case "${1:-}" in
  --help|help|where|status|version) exit 0 ;;
  *) exit 0 ;;
esac
SH
for name in bun sqlite3 bc; do
  cat > "$tmp/bin/$name" <<'SH'
#!/bin/bash
exit 0
SH
done
chmod +x "$tmp/bin"/*

docker run --rm \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,mode=1777,size=1g \
  --tmpfs /home/ralph/.config:rw,noexec,nosuid,mode=1777,size=256m \
  --tmpfs /home/ralph/.cache:rw,noexec,nosuid,mode=1777,size=1g \
  --tmpfs /home/ralph/.npm:rw,noexec,nosuid,mode=1777,size=500m \
  --tmpfs /home/ralph/.bun:rw,nosuid,mode=1777,size=1g \
  --tmpfs /home/ralph/.local:rw,nosuid,mode=1777,size=1g \
  --tmpfs /home/ralph/.npm-global:rw,nosuid,mode=1777,size=1g \
  --tmpfs /home/ralph/go:rw,nosuid,mode=1777,size=1g \
  -v "$R:/app:ro" \
  -v "$tmp/bin:/sandbox-bin:ro" \
  -w /app \
  --network bridge \
  --user ralph \
  --cap-drop=ALL \
  -e RALPH_IN_SANDBOX=true \
  -e HOME=/home/ralph \
  -e XDG_CONFIG_HOME=/home/ralph/.config \
  -e XDG_CACHE_HOME=/home/ralph/.cache \
  -e XDG_DATA_HOME=/home/ralph/.local/share \
  -e BUN_INSTALL=/home/ralph/.bun \
  -e npm_config_prefix=/home/ralph/.npm-global \
  -e PATH=/sandbox-bin:/home/ralph/.bun/bin:/home/ralph/.local/bin:/home/ralph/.npm-global/bin:/home/ralph/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  --memory=2g \
  --cpus=2 \
  --pids-limit=100 \
  ralph-sandbox:latest \
  bash -c 'set -euo pipefail; source lib/utils.sh; TOOL=opencode check_dependencies; test "$(opencode models)" = stub/local; mkdir -p "$XDG_CONFIG_HOME/opencode" "$XDG_CACHE_HOME/opencode"; touch "$XDG_CONFIG_HOME/opencode/write-ok" "$XDG_CACHE_HOME/opencode/write-ok"; boundary_dir=$(mktemp -d); python3 lib/process_supervisor.py --state-file "$boundary_dir/state" --log-file "$boundary_dir/log" --stdout-file "$boundary_dir/out" -- bash -c "printf supervised"; test "$(cat "$boundary_dir/out")" = supervised; echo "sandbox provisioning and process supervision smoke passed"; trap - EXIT || true; exit 0'
