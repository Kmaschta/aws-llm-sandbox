#!/bin/bash
# status.sh - where is my llm-sandbox and what does it cost right now?
#
#   ./status.sh       instance state, IP, spot price now vs cap (or on-demand price), models
#   ./status.sh -h    this help

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
handle_help "$@"
[[ -z "${1:-}" ]] || die "unknown argument: $1 (see ./status.sh -h)"
preflight

read -r inst_id inst_state inst_type inst_az inst_ip inst_sir <<<"$(find_instance)"
if [[ -z "${inst_id:-}" ]]; then
  eip="$(current_eip)"
  if [[ -n "$eip" ]]; then
    echo "  No $TAG_NAME instance. Elastic IP $(eip_public_ip "$eip") is allocated (./up.sh to launch)."
  else
    echo "  No $TAG_NAME instance (./up.sh to launch)."
  fi
  exit 0
fi

echo "  instance : $inst_id  $inst_type in $inst_az ($(market_of "$inst_sir"))"
echo "  state    : $inst_state"
echo "  ip       : ${inst_ip:-none}"
echo "  price    : $(price_summary "$inst_type" "$inst_az" "$inst_sir")"

if [[ "$inst_state" == "running" && -n "${inst_ip:-}" && "$inst_ip" != "None" ]]; then
  tags="$(curl -fs --max-time 5 "http://$inst_ip:$OLLAMA_PORT/api/tags" 2>/dev/null || true)"
  if [[ -n "$tags" ]]; then
    echo "  ollama   : up - models: $(jq -r '[.models[].name] | join(", ")' <<<"$tags")"
    loaded="$(curl -fs --max-time 5 "http://$inst_ip:$OLLAMA_PORT/api/ps" 2>/dev/null | jq -r '[.models[].name] | join(", ")')"
    echo "  loaded   : ${loaded:-none}"
  else
    echo "  ollama   : not reachable from this IP (still booting, or your IP changed - rerun ./up.sh to refresh the SG)"
  fi
fi
