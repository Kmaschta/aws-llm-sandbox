#!/bin/bash
# down.sh - stop the llm-sandbox instance (root disk + models kept, restart with ./up.sh)
#
#   ./down.sh               stop
#   ./down.sh --terminate   terminate + cancel the spot request (disk lost; EIP and SG kept)
#   ./down.sh -h            this help

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
handle_help "$@"
case "${1:-}" in
  ""|--terminate) ;;
  *) die "unknown argument: $1 (see ./down.sh -h)" ;;
esac
preflight

read -r inst_id inst_state inst_type inst_az _ inst_sir <<<"$(find_instance)"
[[ -n "${inst_id:-}" ]] || die "no $TAG_NAME instance found"

log "instance $inst_id ($inst_type in $inst_az, $(market_of "$inst_sir")) is $inst_state"

if [[ "${1:-}" == "--terminate" ]]; then
  warn "TERMINATE: the root disk and pulled models are lost; the elastic IP stays allocated"
  confirm "Terminate $inst_id?" || die "aborted"
  aws ec2 terminate-instances --instance-ids "$inst_id" >/dev/null
  if [[ -n "${inst_sir:-}" && "$inst_sir" != "None" ]]; then
    aws ec2 cancel-spot-instance-requests --spot-instance-request-ids "$inst_sir" >/dev/null
  fi
  log "waiting for termination..."
  aws ec2 wait instance-terminated --instance-ids "$inst_id"
  eip="$(current_eip)"
  if [[ -n "$eip" ]]; then
    echo "  Terminated. Still billed: elastic IP $(eip_public_ip "$eip") (~\$3.6/month) - release with:"
    echo "    aws ec2 release-address --allocation-id $eip"
  else
    echo "  Terminated. Nothing left running or billed (security group and key pair are free)."
  fi
  exit 0
fi

case "$inst_state" in
  stopped)  log "already stopped"; exit 0 ;;
  stopping) log "already stopping - waiting..." ;;
  *)        aws ec2 stop-instances --instance-ids "$inst_id" >/dev/null; log "stopping..." ;;
esac
aws ec2 wait instance-stopped --instance-ids "$inst_id"

vol_gb="$(aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$inst_id" \
  --query 'sum(Volumes[].Size)' --output text 2>/dev/null || echo "$ROOT_GB")"
echo
echo "  Stopped. Restart with ./up.sh (models stay on disk)."
eip_note=""; [[ -n "$(current_eip)" ]] && eip_note=" + elastic IP (~\$3.6/month)"
echo "  Still billed while stopped: ${vol_gb} GB gp3 (~\$$(awk -v g="$vol_gb" 'BEGIN{printf "%.1f", g*0.0952}')/month)${eip_note}."
echo "  Free everything: ./down.sh --terminate"
