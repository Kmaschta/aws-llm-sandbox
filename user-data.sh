#!/bin/bash
# First-boot configuration, run by cloud-init as root on the DLAMI (Amazon Linux 2023,
# NVIDIA driver already installed and matched to the kernel).
# The MODELS and OLLAMA_ENV placeholders (double-underscore markers) are substituted by up.sh before launch.
# Progress is published in /var/lib/llm-sandbox.status (one line, read by up.sh), and the
# streamed pull progress in /var/lib/llm-sandbox.pull (last JSON line from /api/pull).
set -euxo pipefail
exec > >(tee -a /var/log/llm-sandbox.log) 2>&1

STATUS=/var/lib/llm-sandbox.status
PULL=/var/lib/llm-sandbox.pull
status() { echo "$*" > "$STATUS"; echo "=== $* ($(date -u +%H:%M:%S))"; }
trap 'status "failed: see /var/log/llm-sandbox.log"' ERR

status "booting: checking the GPU"
nvidia-smi || echo "WARNING: nvidia-smi failed"

status "installing packages"
dnf install -y htop

status "installing ollama"
# Ollama (creates the ollama user + /etc/systemd/system/ollama.service)
curl -fsSL https://ollama.com/install.sh | sh

mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf <<'EOF'
[Service]
__OLLAMA_ENV__
EOF

status "starting ollama"
systemctl daemon-reload
systemctl enable ollama
systemctl restart ollama

# wait for the API
for _ in $(seq 1 60); do
  curl -fs localhost:11434/api/tags >/dev/null && break
  sleep 2
done

MODELS="__MODELS__"
# Pull through the service's API, not the CLI: under cloud-init $HOME is unset and the
# `ollama` binary panics on it, and the API stores models where the service reads them.
# Streamed so the last line of $PULL always carries {status, total, completed} for up.sh.
n=0; count=$(wc -w <<<"$MODELS")
for m in $MODELS; do
  n=$((n+1))
  status "pulling $m ($n/$count)"
  : > "$PULL"
  curl -fsS -N localhost:11434/api/pull -d "{\"model\":\"$m\",\"stream\":true}" \
    | while IFS= read -r line; do echo "$line" > "$PULL"; done
  grep -q '"status":"success"' "$PULL" || { echo "pull of $m failed: $(cat "$PULL")"; false; }
done

first="${MODELS%% *}"
status "loading $first into VRAM"
curl -fs localhost:11434/api/generate -d "{\"model\":\"$first\",\"keep_alive\":\"30m\"}" >/dev/null || true

status "ready"
touch /var/lib/llm-sandbox.ready
echo "=== llm-sandbox user-data done $(date -u)"
