#!/usr/bin/env bash
# Install a pre-push git hook that blocks push when tests or metadata validation fail.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_PATH="$REPO_ROOT/.git/hooks/pre-push"

if [ ! -d "$REPO_ROOT/.git/hooks" ]; then
  echo "❌ Not a git repository with a hooks directory: $REPO_ROOT"
  exit 1
fi

cat > "$HOOK_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ "${TOPKIT_SKIP_PRE_PUSH_TESTS:-0}" = "1" ]; then
  echo "⚠️ Skipping pre-push test gates (TOPKIT_SKIP_PRE_PUSH_TESTS=1)."
  exit 0
fi

echo "🔒 pre-push: running required Topkit test gates..."
"$REPO_ROOT/scripts/run-test-gates.sh"
EOF

chmod +x "$HOOK_PATH"

echo "✅ Installed pre-push hook at $HOOK_PATH"
echo "ℹ️ To bypass once (not recommended): TOPKIT_SKIP_PRE_PUSH_TESTS=1 git push"

