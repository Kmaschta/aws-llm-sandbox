# llm-sandbox

> [!CAUTION]
> This repo is a playground for running
> GPU instances on AWS. GPU instances cost real money by the hour (from $0.5 per hour to more than $10
> per hour), and a forgotten one keeps billing until you stop it. Make sure you understand what each
> script does before running it, watch the price recap before answering `y`, and run
> `./down.sh` (or check `./status.sh`) when you are done. You are responsible for your AWS bill.

Scripts to run [Ollama](https://ollama.com) on an AWS GPU instance that you start when you need
it and stop when you don't, without paying for an idle GPU or redoing the setup each time.

- `./up.sh` finds a GPU instance (spot or on-demand, you pick the row and the price), launches it
  from AWS's Deep Learning AMI (NVIDIA driver preinstalled), installs Ollama as a systemd service,
  pulls your models, opens ports 22 and 11434 **to your current IP only**, and loads the first
  model with a context length fitted to the GPU's VRAM.
- `./down.sh` stops it. The root disk (and the pulled models) survive; the next `./up.sh` starts
  the same instance in about a minute.
- `./status.sh` and `./models.sh` tell you what is running and manage models on the live box.

Bash + aws cli + jq; runs on macOS's stock bash 3.2 and on Linux.

## Requirements

- An AWS account with a **default VPC** in the region (every account has one unless it was deleted).
- [aws cli](https://aws.amazon.com/cli/) v2 with working credentials (`aws login`, `aws sso login`,
  `aws configure`, or an `AWS_PROFILE`). The scripts refuse to run otherwise.
- `jq`, `curl`, `ssh`.
- **For spot instances**: the "All G and VT Spot Instance Requests" quota (`L-3819A6DF`) is 0 on
  new accounts. Request an increase (e.g. 64 vCPUs) in Service Quotas or with
  `aws service-quotas request-service-quota-increase --service-code ec2 --quota-code L-3819A6DF --desired-value 64`.
  The H100 row (`p5.4xlarge`) is under a separate "All P Spot Instance Requests" quota (`L-7212CCBC`).
  On-demand needs no quota change.
- **IAM permissions**: the scripts only use the aws cli, so your credentials need
  `ec2:Describe*`, `ec2:GetSpotPlacementScores`, `ec2:CreateTags`, `ec2:RunInstances`,
  `ec2:StartInstances`, `ec2:StopInstances`, `ec2:TerminateInstances`,
  `ec2:CancelSpotInstanceRequests`, `ec2:CreateKeyPair`, `ec2:ImportKeyPair`,
  `ec2:CreateSecurityGroup`, `ec2:AuthorizeSecurityGroupIngress`, `ec2:RevokeSecurityGroupIngress`,
  `ec2:AllocateAddress`, `ec2:AssociateAddress`, `ec2:ReleaseAddress`, `ssm:GetParameter` (the
  public AMI parameter) and `pricing:GetProducts` (on-demand prices). The first spot launch in an
  account also creates the `AWSServiceRoleForEC2Spot` service-linked role, which needs
  `iam:CreateServiceLinkedRole`. An admin user or `PowerUserAccess` covers all of it.

## Setup

    cp config.example.env config.env
    $EDITOR config.env       # region, models, disk size... every setting is documented there
    ./up.sh

The first run creates what is missing and asks before anything that costs money:

- **Key pair**: if `KEY_NAME` does not exist in EC2, it offers to create one (private key saved to
  `SSH_KEY`) or to import the public key of an existing `SSH_KEY`. AWS never re-issues a private
  key, so keep the file.
- **Elastic IP** (`ELASTIC_IP=auto`): offers to allocate one so the instance keeps the same public
  IP across stop/start (~$3.6/month, billed even while stopped). Say no, or set `ELASTIC_IP=none`,
  to skip it; the scripts rewrite `~/.ssh/config` with the new IP on every start anyway.
  Set `ELASTIC_IP=eipalloc-...` to reuse an address you already own.
- **Security group** `TAG_NAME`: created once, and its two inbound rules (22 and `OLLAMA_PORT`)
  are rewritten to `<your public IP>/32` on every run. If your IP changes, rerun `./up.sh`.

Everything the scripts create carries the tag `Name=<TAG_NAME>`, and they only ever act on
resources with that tag.

## Commands

    ./up.sh                    start the stopped instance, or launch a new one (interactive)
    ./up.sh --fresh            terminate the existing instance and launch a new one (root disk lost)
    ./down.sh                  stop (disk + models kept; EBS and elastic IP still billed)
    ./down.sh --terminate      terminate and cancel the spot request (elastic IP kept)
    ./status.sh                state, IP, price now vs cap, pulled and loaded models
    ./models.sh list           pulled models, what is loaded in VRAM, disk usage
    ./models.sh sync           pull every model in MODELS that the instance is missing
    ./models.sh pull <name>    pull one model (checks it exists and fits on disk first)
    ./models.sh rm <name>      delete a model from the instance
    ./models.sh load <name>    fit OLLAMA_CONTEXT_LENGTH to the GPU for this model and load it
    ./models.sh context <name> <tokens>
                               force a context length (overflow runs on the CPU, slower)
    ./models.sh unload [name]  evict from VRAM (default: everything)

Every script accepts `-h`.

## What up.sh does on a fresh launch

1. **GPU**: a menu of the single-GPU types of `INSTANCE_FAMILIES`, grouped by GPU with its VRAM -
   the number that decides which models fit. The default list covers every x86 family with a
   one-GPU size (T4 16 GB up to RTX PRO 6000 96 GB); families the region does not offer are simply
   not shown.
2. **Type, AZ and market**: one price-sorted list mixing spot rows (one per type x AZ, with AWS's
   spot placement score 1-10 as a capacity hint) and on-demand rows (one per type; AWS picks the
   AZ). You choose a row; spot rows then ask for a **price cap** (default: the current price
   + `PRICE_HEADROOM`). You pay the market price; if it rises above the cap AWS stops the
   instance (disk kept) until it drops back.
3. **Disk check**: model sizes are fetched from the Ollama registry and compared to `ROOT_GB`
   before launch; unknown model names abort here rather than on the instance.
4. **Launch** with the latest Deep Learning Base OSS NVIDIA GPU AMI (Amazon Linux 2023) resolved
   via SSM, a `ROOT_GB` gp3 root, `user-data.sh` as first-boot script. There is no capacity API
   for on-demand, so on `InsufficientInstanceCapacity` the launch retries every other AZ of the
   region before giving up.
5. **First boot** (`user-data.sh`, logged to `/var/log/llm-sandbox.log` on the box): install
   Ollama, write the systemd override from `OLLAMA_ENV`, pull every model in `MODELS`. Progress
   is streamed back to your terminal step by step, with a percentage during pulls.
6. **Public IP**: associate the elastic IP (or read the assigned one), rewrite the
   `Host <SSH_HOST_ALIAS>` entry of `~/.ssh/config`.
7. **Load** the first model, fitted to the GPU (below), and print the endpoint and price.

A **stopped** instance skips all of this: `./up.sh` shows the current price vs your cap (spot) or
the fixed price (on-demand), asks, starts it, and reloads the model.

## Models and VRAM

Ollama keeps one model resident on a single GPU and swaps on demand when a client asks for
another one (a few seconds per swap), so any pulled model is usable through the one endpoint.
`MODELS` is what gets pulled at first boot; `./models.sh pull/rm/sync` change the live instance
without a relaunch (edit `MODELS` too if you want the change to survive `--fresh`).

**Context length is fitted, not guessed.** Loading a model (end of `up.sh`, `./models.sh load`)
loads it at the service's current `OLLAMA_CONTEXT_LENGTH`, measures the real KV-cache cost per
token from what Ollama allocated (`/api/ps`), computes the largest context that stays fully in
VRAM (8% headroom, multiple of 4096, capped at the model's own maximum), and if it differs
rewrites the systemd override on the box, restarts Ollama and reloads. Whatever does not fit in
VRAM runs on the CPU, several times slower - this keeps you on the right side of that line. A
30B model on a 24 GB card lands around 45k tokens; on a 48 GB card it keeps its full window.
The fitted value lives on the instance; copy it into `OLLAMA_ENV` if you want it as the default.
`./models.sh context <name> <tokens>` overrides it when you knowingly want a bigger window.

## Costs to keep in mind

- Running: the instance's hourly price (shown before you confirm).
- Stopped: the root volume (`ROOT_GB` x ~$0.095/GB-month for gp3) and the elastic IP if any.
- Terminated: only the elastic IP, until you release it (`down.sh --terminate` prints the command).

## Files

    up.sh, down.sh, status.sh, models.sh   the commands
    lib.sh                                 shared helpers (AWS lookups, pricing, VRAM fitting, ssh)
    user-data.sh                           first-boot script run on the instance by cloud-init
    config.example.env                     documented template -> copy to config.env (gitignored)
