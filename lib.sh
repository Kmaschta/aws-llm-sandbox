# Shared helpers - sourced by up.sh / down.sh / status.sh / models.sh
# shellcheck shell=bash

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$HERE/config.env" ]]; then
  printf '\033[1;31merror:\033[0m %s\n' "config.env not found. Create it first:  cp config.example.env config.env  (then edit it)" >&2
  exit 1
fi
# shellcheck source=config.example.env
source "$HERE/config.env"
export AWS_PAGER=""

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Required settings; AWS_REGION falls back to the CLI's configured region
for v in TAG_NAME KEY_NAME SSH_KEY SSH_HOST_ALIAS ELASTIC_IP ROOT_GB ROOT_DEVICE AMI_SSM_PARAMETER \
         INSTANCE_FAMILIES PRICE_HEADROOM SSH_USER MODELS OLLAMA_PORT; do
  [[ -n "${!v:-}" ]] || die "config.env: $v is not set (see config.example.env)"
done
[[ "${#OLLAMA_ENV[@]}" -gt 0 ]] || die "config.env: OLLAMA_ENV is empty"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
[[ -n "$AWS_REGION" ]] || die "config.env: AWS_REGION is not set and the aws cli has no default region"
export AWS_REGION

# Print the calling script's header comment block (its usage) and exit.
# Call as: handle_help "$@"  - reacts to -h / --help / help anywhere in the arguments.
handle_help() {
  local a
  for a in "$@"; do
    case "$a" in
      -h|--help|help)
        # lines 2..N of the leading comment block, minus the "# " prefix
        awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
        exit 0 ;;
    esac
  done
}

confirm() {  # confirm "question" -> 0 if yes  (prompt on stderr, so it never leaks into $(...) captures)
  local answer
  printf '%s [y/N] ' "$1" >&2
  read -r answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

preflight() {
  command -v aws >/dev/null || die "aws cli not found (https://aws.amazon.com/cli/)"
  command -v jq  >/dev/null || die "jq not found (brew install jq / apt install jq)"
  command -v curl >/dev/null || die "curl not found"
  aws sts get-caller-identity >/dev/null 2>&1 \
    || die "no working AWS credentials for region $AWS_REGION - run 'aws login', 'aws sso login', 'aws configure', or export AWS_PROFILE"
}

# ---------------------------------------------------------------- key pair
# Make sure KEY_NAME exists in EC2 and SSH_KEY exists locally, creating/importing on first run.
ensure_key_pair() {
  local in_aws=0
  aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1 && in_aws=1
  if [[ $in_aws -eq 1 && -f "$SSH_KEY" ]]; then
    return 0
  elif [[ $in_aws -eq 1 ]]; then
    die "EC2 key pair '$KEY_NAME' exists in $AWS_REGION but the private key is not at $SSH_KEY.
       AWS never re-issues private keys. Either copy the .pem there, point SSH_KEY at it, or pick a new
       KEY_NAME in config.env and the script will create it."
  elif [[ -f "$SSH_KEY" ]]; then
    warn "no EC2 key pair named '$KEY_NAME' in $AWS_REGION, but $SSH_KEY exists locally"
    confirm "Import its public key into EC2 as '$KEY_NAME'?" || die "aborted - change KEY_NAME or SSH_KEY in config.env"
    local pub; pub="$(ssh-keygen -y -f "$SSH_KEY")" || die "cannot read $SSH_KEY as an ssh private key"
    aws ec2 import-key-pair --key-name "$KEY_NAME" --public-key-material "$(base64 <<<"$pub" | tr -d '\n')" \
      --tag-specifications "ResourceType=key-pair,Tags=[{Key=Name,Value=$TAG_NAME}]" >/dev/null
    log "imported key pair $KEY_NAME"
  else
    echo
    echo "  No EC2 key pair '$KEY_NAME' in $AWS_REGION and no private key at $SSH_KEY."
    confirm "Create an ed25519 key pair '$KEY_NAME' and save the private key to $SSH_KEY?" \
      || die "aborted - set KEY_NAME/SSH_KEY in config.env to an existing pair"
    mkdir -p "$(dirname "$SSH_KEY")"
    aws ec2 create-key-pair --key-name "$KEY_NAME" --key-type ed25519 --key-format pem \
      --tag-specifications "ResourceType=key-pair,Tags=[{Key=Name,Value=$TAG_NAME}]" \
      --query KeyMaterial --output text > "$SSH_KEY"
    chmod 600 "$SSH_KEY"
    log "created key pair $KEY_NAME, private key saved to $SSH_KEY (keep it: AWS cannot re-issue it)"
  fi
}

# ---------------------------------------------------------------- elastic IP
# Resolve ELASTIC_IP ("auto" | "none" | eipalloc-...) to an allocation id; prints "" when not using one.
# "auto": reuse the EIP tagged Name=TAG_NAME, or offer to allocate one on first launch.
resolve_eip() {
  case "$ELASTIC_IP" in
    none) echo ""; return 0 ;;
    eipalloc-*)
      aws ec2 describe-addresses --allocation-ids "$ELASTIC_IP" >/dev/null 2>&1 \
        || die "ELASTIC_IP=$ELASTIC_IP not found in $AWS_REGION"
      echo "$ELASTIC_IP"; return 0 ;;
    auto) ;;
    *) die "config.env: ELASTIC_IP must be auto, none or an eipalloc-... id" ;;
  esac
  local id
  id="$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=$TAG_NAME" \
    --query 'Addresses[0].AllocationId' --output text 2>/dev/null || true)"
  if [[ -n "$id" && "$id" != "None" ]]; then echo "$id"; return 0; fi
  echo >&2
  echo "  No elastic IP tagged $TAG_NAME yet. With one, the instance keeps the same public IP across" >&2
  echo "  stop/start (stable ssh config and Ollama URL); it costs ~\$3.6/month, even while stopped." >&2
  echo "  Without it, each start gets a new public IP and the scripts rewrite ~/.ssh/config for you." >&2
  if confirm "Allocate an elastic IP now?"; then
    id="$(aws ec2 allocate-address --domain vpc \
      --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$TAG_NAME}]" \
      --query AllocationId --output text)"
    log "allocated elastic IP $id (tagged $TAG_NAME; release with: aws ec2 release-address --allocation-id $id)"
    echo "$id"
  else
    log "continuing without an elastic IP (set ELASTIC_IP=none in config.env to stop asking)"
    echo ""
  fi
}

# Public IP of an allocation id
eip_public_ip() {  # allocation-id
  aws ec2 describe-addresses --allocation-ids "$1" --query 'Addresses[0].PublicIp' --output text
}

# Allocation id of the EIP tagged TAG_NAME or set explicitly, without prompting; "" if none
current_eip() {
  case "$ELASTIC_IP" in
    none) echo "" ;;
    eipalloc-*) echo "$ELASTIC_IP" ;;
    *) aws ec2 describe-addresses --filters "Name=tag:Name,Values=$TAG_NAME" \
         --query 'Addresses[0].AllocationId' --output text 2>/dev/null | grep -v '^None$' || true ;;
  esac
}

# The instance managed by these scripts: newest non-terminated instance tagged Name=TAG_NAME.
# Prints "<id> <state> <type> <az> <public-ip> <spot-request-id>" or nothing.
find_instance() {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$TAG_NAME" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[] | sort_by(@, &LaunchTime) | [-1].[InstanceId,State.Name,InstanceType,Placement.AvailabilityZone,PublicIpAddress,SpotInstanceRequestId]' \
    --output text 2>/dev/null | grep -v '^None$' || true
}

# Current spot price for a type in an AZ
spot_price_now() {  # type az
  aws ec2 describe-spot-price-history \
    --instance-types "$1" --availability-zone "$2" \
    --product-descriptions "Linux/UNIX" \
    --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --query 'SpotPriceHistory[0].SpotPrice' --output text
}

# On-demand Linux price for a type in AWS_REGION (pricing API lives in us-east-1); empty if unknown
ondemand_price() {  # type
  # marketoption=OnDemand: types sold as Capacity Blocks (p5...) also have a $0 "Used" entry, which PriceList[0] could pick
  aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
    --filters "Type=TERM_MATCH,Field=instanceType,Value=$1" "Type=TERM_MATCH,Field=regionCode,Value=$AWS_REGION" \
              Type=TERM_MATCH,Field=operatingSystem,Value=Linux Type=TERM_MATCH,Field=tenancy,Value=Shared \
              Type=TERM_MATCH,Field=preInstalledSw,Value=NA Type=TERM_MATCH,Field=capacitystatus,Value=Used \
              Type=TERM_MATCH,Field=marketoption,Value=OnDemand \
    --query 'PriceList[0]' --output text 2>/dev/null \
    | jq -r '.terms.OnDemand[]?.priceDimensions[]?.pricePerUnit.USD' 2>/dev/null | head -1 \
    | { read -r p; [[ -n "$p" ]] && printf '%.4f' "$p"; } || true
}

# "spot" or "on-demand" for an instance's spot-request-id field
market_of() {  # spot-request-id
  [[ -n "${1:-}" && "$1" != "None" ]] && echo spot || echo on-demand
}

# One-line price description for a running/stopped instance
price_summary() {  # type az spot-request-id
  if [[ "$(market_of "$3")" == "spot" ]]; then
    echo "spot ~\$$(spot_price_now "$1" "$2")/h now, cap \$$(spot_request_max_price "$3")/h"
  else
    echo "on-demand \$$(ondemand_price "$1")/h fixed"
  fi
}

# Max price recorded on the spot request (the cap chosen at launch)
spot_request_max_price() {  # spot-request-id
  [[ -z "${1:-}" || "$1" == "None" ]] && { echo "n/a"; return; }
  aws ec2 describe-spot-instance-requests --spot-instance-request-ids "$1" \
    --query 'SpotInstanceRequests[0].SpotPrice' --output text 2>/dev/null || echo "n/a"
}

# Given an /api/tags JSON body, print the configured models it does not list (space-separated)
missing_models() {  # tags-json
  local m have=""
  [[ -n "${1:-}" ]] && have="$(jq -r '[.models[]?.name] | join(" ")' <<<"$1" 2>/dev/null || true)"
  for m in $MODELS; do
    case " $have " in *" $m "*) ;; *) printf '%s ' "$m" ;; esac
  done
}

# Size in GiB of a model on the Ollama registry (sum of its manifest layers), or "" if unknown / not found.
# Works for "name:tag", "name" (=> latest) and "user/name:tag".
model_size_gib() {  # model
  local ref="$1" name tag path
  name="${ref%%:*}"; tag="${ref##*:}"; [[ "$name" == "$ref" ]] && tag="latest"
  case "$name" in */*) path="$name" ;; *) path="library/$name" ;; esac
  curl -fsS --max-time 15 "https://registry.ollama.ai/v2/$path/manifests/$tag" \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' 2>/dev/null \
    | jq -r '[.config.size, (.layers[].size)] | add / 1073741824 | . * 10 | round / 10' 2>/dev/null || true
}

# Print a per-model size table for $MODELS plus the total; sets MODELS_TOTAL_GIB and MODELS_UNKNOWN.
# Dies if a model does not exist on the registry (cheaper to learn now than after paying for a launch).
report_model_sizes() {
  local m s total=0
  MODELS_UNKNOWN=""
  for m in $MODELS; do
    s="$(model_size_gib "$m")"
    if [[ -z "$s" ]]; then
      printf '    %-30s %s\n' "$m" "NOT FOUND on registry.ollama.ai"
      MODELS_UNKNOWN="$MODELS_UNKNOWN $m"
    else
      printf '    %-30s %6.1f GiB\n' "$m" "$s"
      total="$(awk -v a="$total" -v b="$s" 'BEGIN{print a+b}')"
    fi
  done
  MODELS_TOTAL_GIB="$total"
  printf '    %-30s %6.1f GiB\n' "total" "$total"
}

# ssh to the instance. Callers set REMOTE_IP first.
remote() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 -o LogLevel=ERROR "$SSH_USER@$REMOTE_IP" "$@"
}

# ---------------------------------------------------------------- VRAM / context fitting
# Ollama's KV cache grows linearly with the context, so ONE load at a known context gives the exact
# bytes-per-token for that model/quant/KV type; from there the largest context that stays fully on
# the GPU is a formula. No architecture math, everything is measured on the box.

# Load a model (empty generate = load only) and print "weights total in_vram ctx vram_bytes model_max"
# (bytes). Empty on failure.
measure_load() {  # model
  local m="$1" raw ps tags show vram_mib
  remote "curl -fsS localhost:$OLLAMA_PORT/api/generate -d '{\"model\":\"$m\",\"keep_alive\":\"$KEEP_ALIVE\"}'" >/dev/null 2>&1 || return 0
  raw="$(remote "curl -s localhost:$OLLAMA_PORT/api/ps; echo; curl -s localhost:$OLLAMA_PORT/api/tags; echo; \
    curl -s localhost:$OLLAMA_PORT/api/show -d '{\"model\":\"$m\"}'; echo; \
    nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1" 2>/dev/null)" || return 0
  ps="$(sed -n 1p <<<"$raw")"; tags="$(sed -n 2p <<<"$raw")"; show="$(sed -n 3p <<<"$raw")"
  vram_mib="$(sed -n 4p <<<"$raw" | tr -dc '0-9')"
  [[ -n "$vram_mib" ]] || return 0
  jq -r -n --argjson ps "$ps" --argjson tags "$tags" --argjson show "$show" --arg m "$m" --argjson vram "$vram_mib" '
    def is_m: (.name==$m or .model==$m or .name==($m+":latest"));
    ($ps.models[] | select(is_m)) as $p
    | ($tags.models[] | select(is_m) | .size) as $w
    | ($show.model_info["general.architecture"]) as $arch
    | ($show.model_info[$arch + ".context_length"] // 0) as $mmax
    | [$w, $p.size, $p.size_vram, $p.context_length, $vram * 1048576, $mmax] | @tsv' 2>/dev/null || true
}

# Current OLLAMA_CONTEXT_LENGTH of the service on the box (from the systemd override)
service_context() {
  remote "grep -o 'OLLAMA_CONTEXT_LENGTH=[0-9]*' /etc/systemd/system/ollama.service.d/override.conf 2>/dev/null | head -1 | cut -d= -f2"
}

# Write OLLAMA_CONTEXT_LENGTH=<n> into the systemd override and restart ollama (drops loaded models).
set_service_context() {  # n
  remote "sudo sed -i 's/^Environment=\"OLLAMA_CONTEXT_LENGTH=[0-9]*\"/Environment=\"OLLAMA_CONTEXT_LENGTH=$1\"/' /etc/systemd/system/ollama.service.d/override.conf \
    && grep -q 'OLLAMA_CONTEXT_LENGTH=$1\"' /etc/systemd/system/ollama.service.d/override.conf \
    && sudo systemctl daemon-reload && sudo systemctl restart ollama" \
    || die "could not set OLLAMA_CONTEXT_LENGTH=$1 on the box"
  local _
  for _ in $(seq 1 30); do remote "curl -fs localhost:$OLLAMA_PORT/api/tags" >/dev/null 2>&1 && return 0; sleep 2; done
  die "ollama did not come back after restart"
}

# One-line report of a measurement
report_fit() {  # model "w total invram ctx vram mmax"
  awk -F'\t' -v m="$1" '{
    w=$1; total=$2; invram=$3; ctx=$4; vram=$5; G=1073741824; spill=total-invram
    printf "  Context : %s at %d tokens = %.1f GiB weights + %.1f GiB KV/buffers = %.1f GiB, GPU %.1f GiB - ", m, ctx, w/G, (total-w)/G, total/G, vram/G
    if (spill > 64*1048576) printf "%.1f GiB on the CPU (slower)\n", spill/G; else printf "fully in VRAM\n"
  }' <<<"$2"
}

# Fit the service context to the GPU for this model and leave it loaded:
#   1. load at the current service context, measure bytes/token
#   2. compute the largest fully-on-GPU context (8% VRAM headroom, multiple of 4096, <= model max)
#   3. if it differs from the service value: write it to the override, restart ollama, load again
# Prints the final measurement. Silently returns if the box cannot be measured.
fit_context() {  # model
  local m="$1" meas cur target
  KEEP_ALIVE="${KEEP_ALIVE:-30m}"
  log "loading $m to measure its VRAM footprint..."
  meas="$(measure_load "$m")"
  [[ -n "$meas" ]] || { warn "could not measure $m (ollama not answering?)"; return 0; }
  cur="$(cut -f4 <<<"$meas")"
  target="$(awk -F'\t' '{
    w=$1; total=$2; ctx=$4; vram=$5; mmax=$6
    pt = (ctx > 0) ? (total - w) / ctx : 0
    budget = vram * 0.92 - w
    max = (pt > 0) ? budget / pt : 0
    rec = int(max / 4096) * 4096
    if (mmax > 0 && rec > mmax) rec = int(mmax / 4096) * 4096
    print rec }' <<<"$meas")"
  if [[ "$target" -lt 4096 ]]; then
    report_fit "$m" "$meas"
    warn "the weights alone nearly fill this GPU: no context fits. Pick a bigger GPU or a smaller quantization."
    return 0
  fi
  if [[ "$target" -eq "$cur" ]]; then
    report_fit "$m" "$meas"
    log "OLLAMA_CONTEXT_LENGTH=$cur already fits this GPU"
    return 0
  fi
  report_fit "$m" "$meas"
  log "setting OLLAMA_CONTEXT_LENGTH=$target (was $cur), restarting ollama, reloading $m..."
  set_service_context "$target"
  meas="$(measure_load "$m")"
  [[ -n "$meas" ]] || { warn "reload after restart failed"; return 0; }
  report_fit "$m" "$meas"
  log "$m loaded with a $target-token context. Persisted on the box; put it in config.env OLLAMA_ENV to keep it across --fresh."
}

# Force a context length (the user may want to spill into CPU RAM for a bigger window): write it,
# restart, load the model and report what happened.
force_context() {  # model n
  local m="$1" n="$2" meas
  KEEP_ALIVE="${KEEP_ALIVE:-30m}"
  [[ "$n" =~ ^[0-9]+$ && "$n" -ge 512 ]] || die "context must be a number >= 512"
  log "setting OLLAMA_CONTEXT_LENGTH=$n, restarting ollama, loading $m..."
  set_service_context "$n"
  meas="$(measure_load "$m")"
  [[ -n "$meas" ]] || die "load failed - is $m pulled? (./models.sh list)"
  report_fit "$m" "$meas"
  log "OLLAMA_CONTEXT_LENGTH=$n persisted on the box; put it in config.env OLLAMA_ENV to keep it across --fresh."
}

# Rewrite the HostName of the ~/.ssh/config alias
update_ssh_config() {  # ip
  local cfg="$HOME/.ssh/config"
  if [[ ! -f "$cfg" ]]; then mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"; touch "$cfg"; chmod 600 "$cfg"; fi
  if grep -q "^Host $SSH_HOST_ALIAS\$" "$cfg"; then
    # replace the HostName line that follows the Host block header
    awk -v host="$SSH_HOST_ALIAS" -v ip="$1" '
      $1=="Host" { inblock = ($2==host) }
      inblock && $1=="HostName" { sub($2, ip) }
      { print }' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
    log "~/.ssh/config: Host $SSH_HOST_ALIAS -> $1"
  else
    printf '\nHost %s\n    HostName %s\n    User %s\n    IdentityFile %s\n' \
      "$SSH_HOST_ALIAS" "$1" "$SSH_USER" "$SSH_KEY" >> "$cfg"
    log "~/.ssh/config: added Host $SSH_HOST_ALIAS ($1)"
  fi
}
