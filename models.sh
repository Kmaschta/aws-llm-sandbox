#!/bin/bash
# models.sh - manage Ollama models on the running llm-sandbox (no relaunch needed)
#
#   ./models.sh list            pulled models + what is loaded in VRAM + disk usage (default)
#   ./models.sh sync            pull every model in config.env MODELS that is missing
#   ./models.sh pull <name>     pull a model (also add it to MODELS in config.env to keep it across --fresh)
#   ./models.sh rm <name>       delete a model from the instance
#   ./models.sh load <name>     fit OLLAMA_CONTEXT_LENGTH to the GPU for this model (measure, write the
#                               systemd override, restart ollama) and load it into VRAM
#   ./models.sh context <name> <tokens>
#                               force OLLAMA_CONTEXT_LENGTH (restart + load); larger than the fit spills to CPU RAM
#   ./models.sh unload [name]   evict a model from VRAM (default: every loaded model)
#   ./models.sh -h              this help

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
handle_help "$@"
case "${1:-list}" in
  list|sync|pull|rm|load|context|unload) ;;
  *) die "unknown command: $1 (see ./models.sh -h)" ;;
esac
preflight

read -r inst_id inst_state _ _ inst_ip _ <<<"$(find_instance)"
[[ -n "${inst_id:-}" ]] || die "no $TAG_NAME instance found"
[[ "$inst_state" == "running" ]] || die "instance $inst_id is $inst_state - ./up.sh first"
[[ -n "${inst_ip:-}" && "$inst_ip" != "None" ]] || die "instance has no public IP"

REMOTE_IP="$inst_ip"

# Refuse to pull a model that does not exist or does not fit in the instance's free disk (+15% headroom)
check_fits() {  # model
  local size free need
  size="$(model_size_gib "$1")"
  [[ -n "$size" ]] || die "model '$1' not found on registry.ollama.ai"
  free="$(remote "df -BG --output=avail / | tail -1" | tr -dc '0-9')"
  need="$(awk -v s="$size" 'BEGIN{printf "%d", s * 1.15 + 0.5}')"
  log "$1 is ${size} GiB; ${free} GB free on the instance"
  [[ "$need" -le "$free" ]] || die "not enough disk for $1 (needs ~${need} GB incl. headroom, ${free} GB free) - ./models.sh rm something, or relaunch with a bigger ROOT_GB"
}

case "${1:-list}" in
  list)
    echo "  pulled:"; remote "ollama ls" | sed 's/^/    /'
    echo "  loaded:"; remote "ollama ps" | sed 's/^/    /'
    echo "  disk:";   remote "df -h / | tail -1" | awk '{print "    " $3 " used / " $2 " (" $5 "), " $4 " free"}'
    ;;
  sync)
    missing="$(missing_models "$(remote "curl -fs localhost:$OLLAMA_PORT/api/tags")")"
    [[ -n "$missing" ]] || { log "all configured models present: $MODELS"; exit 0; }
    for m in $missing; do check_fits "$m"; done
    for m in $missing; do log "pulling $m"; remote "ollama pull $m"; done
    ;;
  pull)
    [[ -n "${2:-}" ]] || die "usage: ./models.sh pull <name>"
    check_fits "$2"
    remote "ollama pull $2"
    case " $MODELS " in *" $2 "*) ;; *) warn "add '$2' to MODELS in config.env to keep it across a --fresh launch" ;; esac
    ;;
  rm)
    [[ -n "${2:-}" ]] || die "usage: ./models.sh rm <name>"
    confirm "Delete $2 from the instance?" || die "aborted"
    remote "ollama rm $2"
    ;;
  load)
    [[ -n "${2:-}" ]] || die "usage: ./models.sh load <name>"
    fit_context "$2"
    echo "  loaded:"; remote "ollama ps" | sed 's/^/    /'
    ;;
  context)
    [[ -n "${2:-}" && -n "${3:-}" ]] || die "usage: ./models.sh context <name> <tokens>"
    force_context "$2" "$3"
    echo "  loaded:"; remote "ollama ps" | sed 's/^/    /'
    ;;
  unload)
    if [[ -n "${2:-}" ]]; then targets="$2"
    else targets="$(remote "curl -fs localhost:$OLLAMA_PORT/api/ps" | jq -r '.models[].name')"; fi
    [[ -n "$targets" ]] || { log "nothing loaded"; exit 0; }
    for m in $targets; do
      log "unloading $m"
      remote "curl -fsS localhost:$OLLAMA_PORT/api/generate -d '{\"model\":\"$m\",\"keep_alive\":0}'" >/dev/null
    done
    echo "  loaded:"; remote "ollama ps" | sed 's/^/    /'
    ;;
  *) die "usage: ./models.sh [list|sync|pull <name>|rm <name>|load <name>|context <name> <tokens>|unload [name]]" ;;
esac
