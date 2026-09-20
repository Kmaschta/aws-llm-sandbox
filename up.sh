#!/bin/bash
# up.sh - start the existing llm-sandbox instance, or launch a fresh one.
#
#   ./up.sh            start if a stopped instance exists, otherwise launch (interactive)
#   ./up.sh --fresh    terminate the existing instance (root disk lost) and launch a new one
#   ./up.sh -h         this help
#
# Every step is interactive where money is involved: you choose the GPU, the type/AZ
# (spot or on-demand), and the spot price cap. The security group is refreshed to your
# current public IP on every run.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
handle_help "$@"

FRESH=0
case "${1:-}" in
  "") ;;
  --fresh) FRESH=1 ;;
  *) die "unknown argument: $1 (see ./up.sh -h)" ;;
esac

preflight
ensure_key_pair
eip_id="$(resolve_eip)"   # may prompt on first run; empty = no elastic IP

# ---------------------------------------------------------------- security group
my_ip="$(curl -fs --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')"
[[ "$my_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "could not determine my public IP"
log "my public IP: $my_ip"

vpc_id="$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)"
[[ "$vpc_id" != "None" ]] || die "no default VPC in $AWS_REGION"

sg_id="$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$TAG_NAME" "Name=vpc-id,Values=$vpc_id" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
  log "creating security group $TAG_NAME"
  sg_id="$(aws ec2 create-security-group --group-name "$TAG_NAME" \
    --description "llm-sandbox: ssh + ollama from my IP only" --vpc-id "$vpc_id" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$TAG_NAME}]" \
    --query GroupId --output text)"
fi

# Replace whatever inbound rules exist with 22 + OLLAMA_PORT from my current IP only
existing_rules="$(aws ec2 describe-security-groups --group-ids "$sg_id" \
  --query 'SecurityGroups[0].IpPermissions' --output json)"
if [[ "$existing_rules" != "[]" ]]; then
  aws ec2 revoke-security-group-ingress --group-id "$sg_id" --ip-permissions "$existing_rules" >/dev/null
fi
aws ec2 authorize-security-group-ingress --group-id "$sg_id" --ip-permissions \
  "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"IpRanges\":[{\"CidrIp\":\"$my_ip/32\",\"Description\":\"ssh\"}]},
    {\"IpProtocol\":\"tcp\",\"FromPort\":$OLLAMA_PORT,\"ToPort\":$OLLAMA_PORT,\"IpRanges\":[{\"CidrIp\":\"$my_ip/32\",\"Description\":\"ollama\"}]}]" >/dev/null
log "security group $sg_id: 22 + $OLLAMA_PORT open to $my_ip/32 only"

# ---------------------------------------------------------------- existing instance?
read -r inst_id inst_state inst_type inst_az _ inst_sir <<<"$(find_instance)"
instance_id=""

if [[ -n "${inst_id:-}" && $FRESH -eq 1 ]]; then
  warn "existing instance $inst_id ($inst_type, $inst_state) will be TERMINATED - root disk and pulled models are lost"
  confirm "Terminate $inst_id and launch fresh?" || die "aborted"
  aws ec2 terminate-instances --instance-ids "$inst_id" >/dev/null
  [[ -n "${inst_sir:-}" && "$inst_sir" != "None" ]] && aws ec2 cancel-spot-instance-requests --spot-instance-request-ids "$inst_sir" >/dev/null
  log "waiting for termination..."
  aws ec2 wait instance-terminated --instance-ids "$inst_id"
  inst_id=""
fi

if [[ -n "${inst_id:-}" ]]; then
  if [[ "$inst_state" == "stopping" ]]; then
    log "instance $inst_id is stopping - waiting..."
    aws ec2 wait instance-stopped --instance-ids "$inst_id"
    inst_state=stopped
  fi
  case "$inst_state" in
    running|pending)
      log "instance $inst_id ($inst_type in $inst_az) is already $inst_state"
      instance_id="$inst_id"
      ;;
    stopped)
      echo
      if [[ -n "${inst_sir:-}" && "$inst_sir" != "None" ]]; then
        price_now="$(spot_price_now "$inst_type" "$inst_az")"
        cap="$(spot_request_max_price "$inst_sir")"
        echo "  Existing instance : $inst_id  ($inst_type in $inst_az, spot, stopped)"
        echo "  Spot price now    : \$$price_now/h"
        echo "  Your price cap    : \$$cap/h"
        if [[ "$cap" != "n/a" ]] && awk -v p="$price_now" -v c="$cap" 'BEGIN{exit !(p>c)}'; then
          warn "market price is above your cap - AWS will not start it until the price drops. Use --fresh to relaunch with a new cap."
        fi
      else
        echo "  Existing instance : $inst_id  ($inst_type in $inst_az, on-demand, stopped)"
        echo "  Price             : \$$(ondemand_price "$inst_type")/h fixed"
      fi
      echo
      confirm "Start it?" || die "aborted"
      aws ec2 start-instances --instance-ids "$inst_id" >/dev/null \
        || die "start refused (spot capacity or price). Retry later or ./up.sh --fresh"
      instance_id="$inst_id"
      ;;
  esac
fi

# ---------------------------------------------------------------- launch path
if [[ -z "$instance_id" ]]; then
  log "no existing instance - launching a new one"

  # single-GPU types of the configured families, with their VRAM
  # shellcheck disable=SC2086
  types_json="$(aws ec2 describe-instance-types \
    --filters "Name=instance-type,Values=$(for f in $INSTANCE_FAMILIES; do printf '%s.*,' "$f"; done | sed 's/,$//')" \
    --query 'InstanceTypes[?GpuInfo.Gpus[0].Count==`1`].{type:InstanceType,vcpu:VCpuInfo.DefaultVCpus,ram_gb:MemoryInfo.SizeInMiB,gpu:GpuInfo.Gpus[0].Name,vram_gb:GpuInfo.Gpus[0].MemoryInfo.SizeInMiB}' \
    --output json | jq '[.[] | .ram_gb = (.ram_gb/1024|floor) | .vram_gb = (((.vram_gb/1024)/8|ceil)*8)] | sort_by(.vcpu)')"
  # vram_gb: AWS reports usable MiB (22888 for a 24 GB card); round up to the marketed size (multiple of 8 GB)

  # -- 1. GPU / VRAM choice
  echo
  echo "Available GPUs (single-GPU instances). Pick by VRAM: the model + its KV cache must fit in it."
  gpu_opts=()
  while IFS= read -r line; do gpu_opts+=("$line"); done < <(jq -r 'group_by(.gpu) | sort_by(.[0].vram_gb) | .[] | "\(.[0].vram_gb)\t\(.[0].gpu)\t\(map(.type)|join(", "))"' <<<"$types_json")
  gpu_w="$(jq -r '[.[].gpu | length] | max' <<<"$types_json")"   # widest GPU name, e.g. "RTX PRO Server 6000"
  for i in "${!gpu_opts[@]}"; do
    IFS=$'\t' read -r vram gpu types <<<"${gpu_opts[$i]}"
    notes_var="GPU_NOTES_${gpu//[^A-Za-z0-9]/_}"
    printf '  %d) %2s GB VRAM  NVIDIA %-*s %s\n' "$((i+1))" "$vram" "$gpu_w" "$gpu" "${!notes_var:-}"
    printf '     %-13s %s\n' "" "types: $types"
  done
  read -r -p "GPU? [1-${#gpu_opts[@]}] " gpu_choice
  [[ "$gpu_choice" =~ ^[0-9]+$ && $gpu_choice -ge 1 && $gpu_choice -le ${#gpu_opts[@]} ]] || die "invalid choice"
  gpu_name="$(cut -f2 <<<"${gpu_opts[$((gpu_choice-1))]}")"
  candidate_types="$(jq -r --arg g "$gpu_name" '[.[] | select(.gpu==$g) | .type] | join(" ")' <<<"$types_json")"

  # -- 2. one list: a spot row per type x AZ, plus an on-demand row per type, sorted by price
  log "fetching spot prices for: $candidate_types"
  # shellcheck disable=SC2086
  spot_json="$(aws ec2 describe-spot-price-history \
    --instance-types $candidate_types --product-descriptions "Linux/UNIX" \
    --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --query 'SpotPriceHistory[].{type:InstanceType,az:AvailabilityZone,price:SpotPrice}' --output json)"

  # Capacity: there is no "is there capacity" API for on-demand - the only test is to launch.
  # For spot, get-spot-placement-scores gives a 1-10 likelihood per AZ (1 = unlikely, 10 = likely);
  # it is a hint, not a promise. Scores are keyed by zone id, so map ids to names.
  log "fetching spot placement scores"
  az_map="$(aws ec2 describe-availability-zones --query 'AvailabilityZones[].{id:ZoneId,name:ZoneName}' --output json)"
  scores_json="[]"
  for t in $candidate_types; do
    s="$(aws ec2 get-spot-placement-scores --instance-types "$t" --target-capacity 1 \
      --single-availability-zone --region-names "$AWS_REGION" \
      --query 'SpotPlacementScores[].{id:AvailabilityZoneId,score:Score}' --output json 2>/dev/null || echo '[]')"
    scores_json="$(jq --arg t "$t" --argjson s "$s" --argjson m "$az_map" \
      '. + ($s | map({type:$t, az:(.id as $i | $m[] | select(.id==$i) | .name), score:.score}))' <<<"$scores_json")"
  done

  # on-demand is the same price in every AZ and cannot be probed, so the row is not pinned to
  # an AZ: AWS places it wherever there is capacity ("any")
  ondemand_json="[]"
  for t in $candidate_types; do
    od="$(ondemand_price "$t")"
    [[ -n "$od" ]] || continue
    ondemand_json="$(jq --arg t "$t" --arg p "$od" '. + [{type:$t, price:$p}]' <<<"$ondemand_json")"
  done

  # row: market  type  az  price  score
  rows=()
  while IFS= read -r line; do rows+=("$line"); done < <(jq -r --argjson od "$ondemand_json" --argjson sc "$scores_json" '
    (map(. as $r | . + {market:"spot",
        score: (($sc[] | select(.type==$r.type and .az==$r.az) | .score) // "?")})) as $spot
    | ($od | map(. + {market:"on-demand", az:"any", score:"-"})) as $odrows
    | ($spot + $odrows) | sort_by(.price|tonumber) | .[]
    | [.market, .type, .az, .price, (.score|tostring)] | @tsv' <<<"$spot_json")
  [[ ${#rows[@]} -gt 0 ]] || die "no prices returned"

  echo
  printf '     %-10s %-14s %-15s %10s  %-5s  %-6s %-8s\n' MARKET TYPE AZ '$/h' SCORE vCPU RAM
  for i in "${!rows[@]}"; do
    IFS=$'\t' read -r mk t az p sc <<<"${rows[$i]}"
    specs="$(jq -r --arg t "$t" '.[] | select(.type==$t) | "\(.vcpu)\t\(.ram_gb) GB"' <<<"$types_json")"
    IFS=$'\t' read -r vcpu ram <<<"$specs"
    printf '  %2d) %-10s %-14s %-15s %10.4f  %-5s  %-6s %-8s\n' "$((i+1))" "$mk" "$t" "$az" "$p" "$sc" "$vcpu" "$ram"
  done
  echo
  echo "  SCORE: spot placement score 1-10 (10 = capacity very likely, 1 = unlikely)."
  echo "  spot: market price, varies; AWS stops the instance if it rises above your cap."
  echo "  on-demand: fixed price, never interrupted, no quota issue; AZ chosen by AWS where capacity exists."
  read -r -p "Which one? [1-${#rows[@]}] " row_choice
  [[ "$row_choice" =~ ^[0-9]+$ && $row_choice -ge 1 && $row_choice -le ${#rows[@]} ]] || die "invalid choice"
  IFS=$'\t' read -r market instance_type az price _ <<<"${rows[$((row_choice-1))]}"
  price="$(printf '%.4f' "$price")"

  # -- 3. price cap (spot only)
  market_options=()
  spot_tag_spec=()   # tagging a spot request is rejected on an on-demand launch
  if [[ "$market" == "spot" ]]; then
    ondemand="$(jq -r --arg t "$instance_type" '.[] | select(.type==$t) | .price' <<<"$ondemand_json")"
    default_cap="$(awk -v p="$price" -v h="$PRICE_HEADROOM" 'BEGIN{printf "%.4f", p*(1+h)}')"
    echo
    echo "  You pay the market price (now \$$price/h). The cap is the maximum you accept:"
    echo "  above it AWS stops the instance until the price drops back."
    read -r -p "Max price cap [\$$default_cap/h]: " cap
    cap="${cap:-$default_cap}"
    [[ "$cap" =~ ^[0-9]*\.?[0-9]+$ ]] || die "invalid price"
    market_options=(--instance-market-options
      "{\"MarketType\":\"spot\",\"SpotOptions\":{\"MaxPrice\":\"$cap\",\"SpotInstanceType\":\"persistent\",\"InstanceInterruptionBehavior\":\"stop\"}}")
    spot_tag_spec=("ResourceType=spot-instances-request,Tags=[{Key=Name,Value=$TAG_NAME}]")
    launch_line="$instance_type in $az (spot, persistent, stop on interruption)"
    price_line="~\$$price/h now, cap \$$cap/h  (on-demand: \$${ondemand:-?}/h)"
  else
    spot_min="$(jq -r --arg t "$instance_type" '[.[] | select(.type==$t) | .price | tonumber] | min' <<<"$spot_json")"
    launch_line="$instance_type, AZ chosen by AWS (on-demand)"
    price_line="\$$price/h fixed  (spot from: ~\$$(printf '%.4f' "$spot_min")/h)"
  fi

  # AZ order to try: the chosen one first (if any), then the others - all with a subnet in the default VPC
  az_candidates=()
  [[ "$az" != "any" ]] && az_candidates+=("$az")
  while IFS= read -r z; do
    [[ -n "$z" && "$z" != "$az" ]] && az_candidates+=("$z")
  done < <(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" \
    --query 'Subnets[].AvailabilityZone' --output text | tr '\t' '\n' | sort -u)
  [[ ${#az_candidates[@]} -gt 0 ]] || die "no subnets in the default VPC"

  ami_id="$(aws ssm get-parameter --name "$AMI_SSM_PARAMETER" --query Parameter.Value --output text)"
  ami_name="$(aws ec2 describe-images --image-ids "$ami_id" --query 'Images[0].Name' --output text)"

  echo
  echo "  Launch  : $launch_line"
  echo "  Price   : $price_line"
  echo "  AMI     : $ami_name"
  echo "  Disk    : ${ROOT_GB} GB gp3 (kept while stopped, ~\$$(awk -v g="$ROOT_GB" 'BEGIN{printf "%.1f", g*0.0952}')/month)"
  echo "  Models  : (sizes from registry.ollama.ai)"
  report_model_sizes
  [[ -z "$MODELS_UNKNOWN" ]] || die "unknown model(s):$MODELS_UNKNOWN - fix MODELS in config.env"
  # AMI + OS ~10 GB, and pulls need transient room for the download; keep 15% free
  disk_needed="$(awk -v t="$MODELS_TOTAL_GIB" 'BEGIN{printf "%d", (t + 10) * 1.15 + 0.5}')"
  if [[ "$disk_needed" -gt "$ROOT_GB" ]]; then
    warn "models need ~${disk_needed} GB (incl. OS + headroom) but ROOT_GB=${ROOT_GB} - raise ROOT_GB in config.env"
    confirm "Launch anyway?" || die "aborted"
  else
    echo "  Fit     : ~${disk_needed} GB needed incl. OS + headroom, $((ROOT_GB - disk_needed)) GB left for more models"
  fi
  echo
  confirm "Launch?" || die "aborted"

  # user-data with substitutions (macOS awk refuses newlines in -v, so join with | and split)
  env_lines="$(printf 'Environment="%s"|' "${OLLAMA_ENV[@]}")"
  user_data="$(awk -v models="$MODELS" -v envs="${env_lines%|}" '
    /__OLLAMA_ENV__/ { n = split(envs, a, "|"); for (i = 1; i <= n; i++) print a[i]; next }
    { gsub(/__MODELS__/, models); print }' "$HERE/user-data.sh")"
  grep -q '__' <<<"$user_data" && die "user-data placeholders not substituted"

  # Try each AZ in turn; only InsufficientInstanceCapacity moves on to the next one
  instance_id=""
  for try_az in "${az_candidates[@]}"; do
    subnet_id="$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" "Name=availability-zone,Values=$try_az" \
      --query 'Subnets[0].SubnetId' --output text)"
    log "launching $instance_type in $try_az"
    set +e
    out="$(aws ec2 run-instances \
      --image-id "$ami_id" --instance-type "$instance_type" --subnet-id "$subnet_id" \
      --key-name "$KEY_NAME" --security-group-ids "$sg_id" \
      "${market_options[@]+"${market_options[@]}"}" \
      --block-device-mappings "[{\"DeviceName\":\"$ROOT_DEVICE\",\"Ebs\":{\"VolumeSize\":$ROOT_GB,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
      --user-data "$user_data" \
      --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_NAME}]" \
        "ResourceType=volume,Tags=[{Key=Name,Value=$TAG_NAME}]" \
        "${spot_tag_spec[@]+"${spot_tag_spec[@]}"}" \
      --query 'Instances[0].InstanceId' --output text 2>&1)"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      instance_id="$out"
      az="$try_az"
      break
    elif grep -q 'InsufficientInstanceCapacity' <<<"$out"; then
      warn "no $instance_type capacity in $try_az right now"
      continue
    else
      die "$out"
    fi
  done
  [[ -n "$instance_id" ]] || die "no $instance_type capacity in any AZ of $AWS_REGION right now - try another type, or again later"
  log "launched $instance_id in $az"
fi

# ---------------------------------------------------------------- wait + public IP
log "waiting for $instance_id to be running..."
aws ec2 wait instance-running --instance-ids "$instance_id"

if [[ -n "$eip_id" ]]; then
  aws ec2 associate-address --allocation-id "$eip_id" --instance-id "$instance_id" --allow-reassociation >/dev/null
  public_ip="$(eip_public_ip "$eip_id")"
  log "elastic IP $public_ip associated"
else
  public_ip="$(aws ec2 describe-instances --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
  [[ -n "$public_ip" && "$public_ip" != "None" ]] || die "instance has no public IP (is the subnet set to auto-assign public IPs?)"
  log "public IP $public_ip (no elastic IP: it changes on every start)"
fi
update_ssh_config "$public_ip"

REMOTE_IP="$public_ip"

log "waiting for ssh..."
until remote true 2>/dev/null; do sleep 5; done

log "waiting for first-boot setup (fresh launch: several minutes, mostly the model download)..."
# user-data publishes its current step in /var/lib/llm-sandbox.status and the streamed
# /api/pull progress in /var/lib/llm-sandbox.pull; print each step once, pulls with a % bar.
last_shown=""
for _ in $(seq 1 360); do   # up to 30 min
  st="$(remote 'cat /var/lib/llm-sandbox.status 2>/dev/null; echo; tail -c 400 /var/lib/llm-sandbox.pull 2>/dev/null' 2>/dev/null || true)"
  step="$(sed -n 1p <<<"$st")"
  pull="$(sed -n 2p <<<"$st")"
  if [[ -z "$step" ]]; then
    step="cloud-init starting"   # status file not there yet (or a restarted instance that has no user-data run)
    # a started (not fresh) instance never rewrites the status file: fall back to the model check
    missing="$(missing_models "$(remote "curl -fs localhost:$OLLAMA_PORT/api/tags" 2>/dev/null)")"
    [[ -z "$missing" ]] && { step="ready"; }
  fi
  case "$step" in
    ready) break ;;
    failed:*) die "first-boot setup $step - ssh $SSH_HOST_ALIAS sudo tail -50 /var/log/llm-sandbox.log" ;;
    pulling*)
      pct="$(jq -r 'if (.total // 0) > 0 then ((.completed // 0) * 100 / .total | floor | tostring) + "%  " + ((.completed // 0) / 1073741824 * 10 | round / 10 | tostring) + "/" + (.total / 1073741824 * 10 | round / 10 | tostring) + " GiB" else .status // "" end' <<<"$pull" 2>/dev/null || true)"
      printf '\r\033[K    %s  %s' "$step" "$pct" >&2
      last_shown="$step"
      ;;
    *)
      if [[ "$step" != "$last_shown" ]]; then
        [[ "$last_shown" == pulling* ]] && printf '\n' >&2
        log "  $step"
        last_shown="$step"
      fi
      ;;
  esac
  sleep 5
done
[[ "$last_shown" == pulling* ]] && printf '\n' >&2
[[ "${step:-}" == "ready" ]] || die "first-boot setup not finished after 30 min (last step: ${step:-unknown}) - ssh $SSH_HOST_ALIAS sudo tail -f /var/log/llm-sandbox.log"
missing="$(missing_models "$(remote "curl -fs localhost:$OLLAMA_PORT/api/tags" 2>/dev/null)")"
[[ -z "$missing" ]] || die "setup says ready but models are missing: $missing"

first_model="${MODELS%% *}"
fit_context "$first_model"

read -r _ _ inst_type inst_az _ inst_sir <<<"$(find_instance)"
echo
echo "  Ready."
echo "  ssh      : ssh $SSH_HOST_ALIAS"
echo "  ollama   : http://$public_ip:$OLLAMA_PORT"
echo "  models   : $MODELS  (loaded: $first_model, context: $(service_context))"
echo "  instance : $instance_id  $inst_type in $inst_az ($(market_of "$inst_sir"))"
echo "  price    : $(price_summary "$inst_type" "$inst_az" "$inst_sir")"
echo "  stop     : ./down.sh"
