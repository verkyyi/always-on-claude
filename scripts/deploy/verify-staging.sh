#!/bin/bash
# verify-staging.sh — Verify the current local checkout on a disposable EC2 host.
#
# What it does:
#   1. Launches a fresh Ubuntu 24.04 EC2 instance with a temporary key pair + SG
#   2. Uploads the current local repo snapshot to the instance
#   3. Runs install.sh from that snapshot (LOCAL_BUILD=1 by default)
#   4. Verifies host tools, container health, persisted config, and the selected agent
#   5. Optionally runs a live Codex exec + picker check if OPENAI_API_KEY is set
#   6. Optionally reboots the instance and re-runs the critical checks
#   7. Tears everything down on success by default
#
# Defaults are intentionally staging-safe:
#   - Unique Project tag per run
#   - Unique instance / key / SG names per run
#   - DEFAULT_CODE_AGENT=codex
#   - LOCAL_BUILD=1 so local Dockerfile/runtime changes are tested
#   - AMI_BUILD_INSTANCE_TYPE is used by default for better install/build headroom
#
# Common overrides:
#   AWS_REGION=us-west-2 bash scripts/deploy/verify-staging.sh
#   INSTANCE_TYPE=t4g.medium DEFAULT_CODE_AGENT=claude bash scripts/deploy/verify-staging.sh
#   KEEP_ON_FAILURE=0 KEEP_ON_SUCCESS=1 bash scripts/deploy/verify-staging.sh
#   STAGING_VERIFY_REBOOT=0 STAGING_VERIFY_LIVE_AGENT=0 bash scripts/deploy/verify-staging.sh

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  bash scripts/deploy/verify-staging.sh

Purpose:
  Launch a disposable EC2 host, upload the current local checkout, run install.sh
  against that snapshot, verify the runtime, optionally exercise Codex live, and
  then clean everything up.

Key environment overrides:
  AWS_REGION                 AWS region to use
  INSTANCE_TYPE              EC2 instance type (default: AMI_BUILD_INSTANCE_TYPE or t3.medium)
  VOLUME_SIZE                Root volume size in GB (default: AMI_BUILD_VOLUME_SIZE or 20)
  DEFAULT_CODE_AGENT         claude | codex (default: codex)
  LOCAL_BUILD                1 to build locally on the remote host, 0 to pull image
  STAGING_AMI_SOURCE         stock | prebuilt | auto (default: stock)
  STAGING_VERIFY_LIVE_AGENT  1 to run live Codex checks when OPENAI_API_KEY is set
  STAGING_VERIFY_REBOOT      1 to reboot and re-check boot persistence
  KEEP_ON_FAILURE            1 to keep failed staging resources for debugging
  KEEP_ON_SUCCESS            1 to keep successful staging resources
  STAGING_RUN_ID             custom suffix for resource names

Notes:
  - This script intentionally uses remote Linux paths like /home/dev/dev-env,
    even if your local machine uses different defaults.
  - OPENAI_API_KEY enables the live Codex exec + picker checks when
    DEFAULT_CODE_AGENT=codex.
EOF
}

step=""
status="success"

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
warn()  { echo "  WARN: $*"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

_had_instance_type="${INSTANCE_TYPE+set}"
_had_volume_size="${VOLUME_SIZE+set}"
_had_instance_name="${INSTANCE_NAME+set}"
_had_key_name="${KEY_NAME+set}"
_had_sg_name="${SG_NAME+set}"
_had_project_tag="${PROJECT_TAG+set}"
_had_default_agent="${DEFAULT_CODE_AGENT+set}"
_had_dev_env="${DEV_ENV+set}"
_had_projects_dir="${PROJECTS_DIR+set}"
_had_ssh_user="${SSH_USER+set}"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/load-config.sh"

normalize_code_agent() {
    case "${1:-}" in
        codex) echo "codex" ;;
        claude|"") echo "claude" ;;
        *) echo "claude" ;;
    esac
}

resolve_instance_arch() {
    case "${1:-}" in
        *g.*) echo "arm64" ;;
        *) echo "x86_64" ;;
    esac
}

validate_remote_user() {
    if [[ "${SSH_USER:-dev}" != "dev" ]]; then
        die "verify-staging.sh currently requires SSH_USER=dev"
    fi
}

resolve_remote_paths() {
    REMOTE_HOME="/home/dev"

    if [[ -z "${_had_dev_env:-}" ]]; then
        DEV_ENV="${REMOTE_HOME}/dev-env"
    fi

    if [[ -z "${_had_projects_dir:-}" ]]; then
        PROJECTS_DIR="${REMOTE_HOME}/projects"
    fi

    REMOTE_ORIGIN_DIR="${STAGING_REMOTE_ORIGIN_DIR:-${REMOTE_HOME}/dev-env-origin.git}"
}

RUN_ID="${STAGING_RUN_ID:-$(date -u +%Y%m%d%H%M%S)-$RANDOM}"

if [[ -z "${_had_instance_type:-}" ]]; then
    INSTANCE_TYPE="${AMI_BUILD_INSTANCE_TYPE:-t3.medium}"
fi
if [[ -z "${_had_volume_size:-}" ]]; then
    VOLUME_SIZE="${AMI_BUILD_VOLUME_SIZE:-20}"
fi
if [[ -z "${_had_instance_name:-}" ]]; then
    INSTANCE_NAME="aoc-stage-${RUN_ID}"
fi
if [[ -z "${_had_key_name:-}" ]]; then
    KEY_NAME="${INSTANCE_NAME}-key"
fi
if [[ -z "${_had_sg_name:-}" ]]; then
    SG_NAME="${INSTANCE_NAME}-sg"
fi
if [[ -z "${_had_project_tag:-}" ]]; then
    PROJECT_TAG="always-on-claude-staging-${RUN_ID}"
fi
if [[ -z "${_had_default_agent:-}" ]]; then
    DEFAULT_CODE_AGENT="codex"
fi
if [[ -z "${_had_ssh_user:-}" ]]; then
    SSH_USER="dev"
fi

DEFAULT_CODE_AGENT="$(normalize_code_agent "${DEFAULT_CODE_AGENT:-claude}")"
validate_remote_user
resolve_remote_paths

LOCAL_BUILD="${LOCAL_BUILD:-1}"
KEEP_ON_FAILURE="${KEEP_ON_FAILURE:-1}"
KEEP_ON_SUCCESS="${KEEP_ON_SUCCESS:-0}"
STAGING_AMI_SOURCE="${STAGING_AMI_SOURCE:-stock}"   # stock | prebuilt | auto
STAGING_VERIFY_LIVE_AGENT="${STAGING_VERIFY_LIVE_AGENT:-1}"
STAGING_VERIFY_REBOOT="${STAGING_VERIFY_REBOOT:-1}"
STAGING_SSH_TIMEOUT_SECONDS="${STAGING_SSH_TIMEOUT_SECONDS:-180}"
STAGING_PICKER_TIMEOUT_SECONDS="${STAGING_PICKER_TIMEOUT_SECONDS:-20}"
STAGING_TEST_REPO_NAME="${STAGING_TEST_REPO_NAME:-staging-smoke}"
STAGING_TEST_REPO_PATH="${PROJECTS_DIR}/${STAGING_TEST_REPO_NAME}"

TMP_DIR="$(mktemp -d)"
KEY_FILE="${TMP_DIR}/${KEY_NAME}.pem"
ARCH=""
AMI_ID=""
AMI_SOURCE_USED=""
INSTANCE_ID=""
PUBLIC_IP=""
SG_ID=""
VPC_ID=""
REPO_ARCHIVE=""
live_checks_ran=0

ssh_opts=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=5
    -o BatchMode=yes
    -i "$KEY_FILE"
)

remote_ssh() {
    ssh "${ssh_opts[@]}" "${SSH_USER}@${PUBLIC_IP}" "$@"
}

remote_scp() {
    scp "${ssh_opts[@]}" "$@"
}

run_with_timeout() {
    local seconds="$1"
    shift

    "$@" &
    local cmd_pid=$!

    (
        sleep "$seconds"
        kill -TERM "$cmd_pid" 2>/dev/null || true
        sleep 2
        kill -KILL "$cmd_pid" 2>/dev/null || true
    ) &
    local timer_pid=$!

    local rc=0
    wait "$cmd_pid" || rc=$?
    kill "$timer_pid" 2>/dev/null || true
    wait "$timer_pid" 2>/dev/null || true

    if [[ $rc -eq 143 || $rc -eq 137 ]]; then
        return 124
    fi
    return "$rc"
}

wait_for_ssh() {
    local deadline=$((SECONDS + STAGING_SSH_TIMEOUT_SECONDS))
    echo "  Waiting for SSH..."
    while (( SECONDS < deadline )); do
        if remote_ssh "echo ok" >/dev/null 2>&1; then
            ok "SSH is ready"
            return 0
        fi
        sleep 5
    done
    return 1
}

wait_for_container() {
    local deadline=$((SECONDS + 300))
    echo "  Waiting for container ${CONTAINER_NAME}..."
    while (( SECONDS < deadline )); do
        if remote_ssh "docker ps --format '{{.Names}}' | grep -q '^${CONTAINER_NAME}\$'" >/dev/null 2>&1; then
            ok "Container is running"
            return 0
        fi
        sleep 5
    done
    return 1
}

find_stock_ubuntu_ami() {
    local name_pattern
    case "$ARCH" in
        arm64) name_pattern="ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*" ;;
        x86_64) name_pattern="ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" ;;
        *) die "Unsupported architecture: $ARCH" ;;
    esac

    aws ec2 describe-images \
        --owners 099720109477 \
        --region "$AWS_REGION" \
        --filters "Name=name,Values=${name_pattern}" "Name=state,Values=available" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text
}

find_prebuilt_ami() {
    aws ec2 describe-images \
        --owners self \
        --region "$AWS_REGION" \
        --filters \
            "Name=tag:Project,Values=always-on-claude" \
            "Name=state,Values=available" \
            "Name=architecture,Values=${ARCH}" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text 2>/dev/null || echo "None"
}

find_ami() {
    case "$STAGING_AMI_SOURCE" in
        stock)
            AMI_ID="$(find_stock_ubuntu_ami)"
            AMI_SOURCE_USED="stock"
            ;;
        prebuilt)
            AMI_ID="$(find_prebuilt_ami)"
            if [[ "$AMI_ID" == "None" || -z "$AMI_ID" ]]; then
                die "No prebuilt AMI found for ${ARCH} in ${AWS_REGION}"
            fi
            AMI_SOURCE_USED="prebuilt"
            ;;
        auto)
            AMI_ID="$(find_prebuilt_ami)"
            if [[ "$AMI_ID" == "None" || -z "$AMI_ID" ]]; then
                AMI_ID="$(find_stock_ubuntu_ami)"
                AMI_SOURCE_USED="stock"
            else
                AMI_SOURCE_USED="prebuilt"
            fi
            ;;
        *)
            die "STAGING_AMI_SOURCE must be stock, prebuilt, or auto"
            ;;
    esac

    if [[ "$AMI_ID" == "None" || -z "$AMI_ID" ]]; then
        die "Could not resolve AMI for ${ARCH} in ${AWS_REGION}"
    fi
}

create_key_pair() {
    info "Creating temporary SSH key pair"
    step="create key pair"

    aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$KEY_NAME" >/dev/null 2>&1 \
        && die "Key pair already exists: $KEY_NAME"

    aws ec2 create-key-pair \
        --region "$AWS_REGION" \
        --key-name "$KEY_NAME" \
        --key-type ed25519 \
        --query 'KeyMaterial' \
        --output text > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    ok "Created key pair: $KEY_NAME"
}

create_security_group() {
    info "Creating security group"
    step="create security group"

    VPC_ID="$(aws ec2 describe-vpcs \
        --region "$AWS_REGION" \
        --filters 'Name=isDefault,Values=true' \
        --query 'Vpcs[0].VpcId' \
        --output text)"

    if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
        die "No default VPC found in ${AWS_REGION}"
    fi

    SG_ID="$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name "$SG_NAME" \
        --description "SSH access for staging verification" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' \
        --output text)"

    aws ec2 create-tags \
        --region "$AWS_REGION" \
        --resources "$SG_ID" \
        --tags Key=Project,Value="$PROJECT_TAG" Key=Name,Value="$SG_NAME" Key=Purpose,Value=staging-verification >/dev/null

    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 >/dev/null

    ok "Created security group: $SG_ID"
}

launch_instance() {
    info "Launching staging instance"
    step="launch instance"

    local user_data
    user_data=$(cat <<'USERDATA'
#cloud-config
system_info:
  default_user:
    name: dev
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [sudo]
    homedir: /home/dev
USERDATA
)

    INSTANCE_ID="$(aws ec2 run-instances \
        --region "$AWS_REGION" \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --security-group-ids "$SG_ID" \
        --user-data "$user_data" \
        --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$VOLUME_SIZE,VolumeType=gp3,DeleteOnTermination=true}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Project,Value=$PROJECT_TAG},{Key=Purpose,Value=staging-verification}]" \
        --query 'Instances[0].InstanceId' \
        --output text)"

    aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"

    PUBLIC_IP="$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)"

    if [[ "$PUBLIC_IP" == "None" || -z "$PUBLIC_IP" ]]; then
        die "Instance launched but public IP is missing"
    fi

    ok "Instance running: $INSTANCE_ID ($PUBLIC_IP)"
}

archive_local_repo() {
    info "Archiving local repo snapshot"
    step="archive local repo"

    REPO_ARCHIVE="$TMP_DIR/dev-env.tgz"
    tar \
        --exclude='.git' \
        --exclude='.env' \
        --exclude='.env.*' \
        --exclude='node_modules' \
        --exclude='.DS_Store' \
        -czf "$REPO_ARCHIVE" \
        -C "$REPO_ROOT" .

    ok "Created repo archive: $REPO_ARCHIVE"
}

upload_repo_snapshot() {
    info "Uploading repo snapshot"
    step="upload repo snapshot"

    remote_scp "$REPO_ARCHIVE" "${SSH_USER}@${PUBLIC_IP}:/tmp/dev-env.tgz"

    remote_ssh bash <<EOF
set -euo pipefail
rm -rf $(printf %q "$DEV_ENV") $(printf %q "$REMOTE_ORIGIN_DIR")
mkdir -p $(printf %q "$DEV_ENV")
tar -xzf /tmp/dev-env.tgz -C $(printf %q "$DEV_ENV")
cd $(printf %q "$DEV_ENV")
git init -q
git config user.name "Staging Verifier"
git config user.email "staging@example.com"
git add .
git commit --allow-empty -q -m "Staging snapshot"
git branch -M main
git clone --bare $(printf %q "$DEV_ENV") $(printf %q "$REMOTE_ORIGIN_DIR") >/dev/null 2>&1
git remote add origin $(printf %q "$REMOTE_ORIGIN_DIR")
git push -u origin main >/dev/null 2>&1 || true
EOF

    ok "Uploaded local repo snapshot to ${DEV_ENV}"
}

run_remote_install() {
    info "Running install.sh from local snapshot"
    step="run remote install"

    remote_ssh "cloud-init status --wait >/dev/null 2>&1 || true"

    remote_ssh bash <<EOF 2>&1 | while IFS= read -r line; do echo "  $line"; done
set -euo pipefail
export AWS_REGION=$(printf %q "$AWS_REGION")
export INSTANCE_TYPE=$(printf %q "$INSTANCE_TYPE")
export VOLUME_SIZE=$(printf %q "$VOLUME_SIZE")
export INSTANCE_NAME=$(printf %q "$INSTANCE_NAME")
export KEY_NAME=$(printf %q "$KEY_NAME")
export SG_NAME=$(printf %q "$SG_NAME")
export PROJECT_TAG=$(printf %q "$PROJECT_TAG")
export DOCKER_IMAGE=$(printf %q "$DOCKER_IMAGE")
export CONTAINER_NAME=$(printf %q "$CONTAINER_NAME")
export CONTAINER_HOSTNAME=$(printf %q "$CONTAINER_HOSTNAME")
export DEV_ENV=$(printf %q "$DEV_ENV")
export PROJECTS_DIR=$(printf %q "$PROJECTS_DIR")
export DEFAULT_CODE_AGENT=$(printf %q "$DEFAULT_CODE_AGENT")
export LOCAL_BUILD=$(printf %q "$LOCAL_BUILD")
export NON_INTERACTIVE=1
bash $(printf %q "$DEV_ENV/scripts/deploy/install.sh")
EOF
}

create_remote_test_repo() {
    info "Creating remote test repo"
    step="create remote test repo"

    remote_ssh bash <<EOF
set -euo pipefail
mkdir -p $(printf %q "$STAGING_TEST_REPO_PATH")
cd $(printf %q "$STAGING_TEST_REPO_PATH")
git init -q
git config user.name "Staging Verifier"
git config user.email "staging@example.com"
printf '%s\n' '# staging smoke repo' > README.md
git add README.md
git commit --allow-empty -q -m "Initial commit"
EOF

    ok "Created test repo: ${STAGING_TEST_REPO_PATH}"
}

verify_host_runtime() {
    info "Verifying host runtime"
    step="verify host runtime"

    remote_ssh "bash -lc 'command -v docker >/dev/null && command -v claude >/dev/null && command -v codex >/dev/null && command -v node >/dev/null && command -v gh >/dev/null && command -v tmux >/dev/null'"
    remote_ssh "bash -lc 'id -nG | grep -qw docker && id -nG | grep -qw sudo'"
    remote_ssh "bash -lc 'test -d ~/.claude && test -d ~/.codex && test -f ~/.claude.json && test -f ~/.tmux.conf && test -f ~/.tmux-status.sh'"
    remote_ssh "systemctl is-enabled always-on-claude >/dev/null"
    remote_ssh "grep -q '^export DEFAULT_CODE_AGENT=\"${DEFAULT_CODE_AGENT}\"$' ~/.bash_profile"
    remote_ssh "grep -q 'ssh-login.sh' ~/.bash_profile"
    remote_ssh "bash -lc 'test \"\$DEFAULT_CODE_AGENT\" = $(printf %q "$DEFAULT_CODE_AGENT")'"

    ok "Host runtime looks healthy"
}

verify_container_runtime() {
    info "Verifying container runtime"
    step="verify container runtime"

    wait_for_container || die "Container ${CONTAINER_NAME} did not start in time"

    remote_ssh "docker exec $(printf %q "$CONTAINER_NAME") bash -lc 'whoami | grep -qx dev && command -v claude >/dev/null && command -v codex >/dev/null && test -d ~/.claude && test -d ~/.codex && test -f ~/.claude/remote-settings.json && test -x /home/dev/dev-env/scripts/runtime/run-code-agent.sh'"

    ok "Container runtime looks healthy"
}

verify_live_codex_exec() {
    [[ "$DEFAULT_CODE_AGENT" == "codex" ]] || return 0
    [[ "$STAGING_VERIFY_LIVE_AGENT" == "1" ]] || return 0

    if [[ -z "${OPENAI_API_KEY:-}" ]]; then
        warn "OPENAI_API_KEY not set — skipping live Codex exec + picker checks"
        return 0
    fi

    info "Running live Codex exec check"
    step="live codex exec"

    local output
    output="$(
        remote_ssh bash <<EOF
set -euo pipefail
docker exec \
  -e OPENAI_API_KEY=$(printf %q "$OPENAI_API_KEY") \
  -w $(printf %q "/home/dev/projects/${STAGING_TEST_REPO_NAME}") \
  $(printf %q "$CONTAINER_NAME") \
  bash -lc 'out_file=\$(mktemp); codex exec --ignore-user-config -s read-only --color never -o "\$out_file" "Reply with READY and nothing else." >/dev/null; cat "\$out_file"; rm -f "\$out_file"'
EOF
    )"

    [[ "$output" == *"READY"* ]] || die "Live Codex exec check did not return READY"
    live_checks_ran=1
    ok "Live Codex exec returned READY"
}

verify_picker_session() {
    [[ "$DEFAULT_CODE_AGENT" == "codex" ]] || return 0
    [[ "$STAGING_VERIFY_LIVE_AGENT" == "1" ]] || return 0

    if [[ -z "${OPENAI_API_KEY:-}" ]]; then
        return 0
    fi

    info "Verifying picker launches a Codex tmux session"
    step="verify picker session"

    local session_name="${DEFAULT_CODE_AGENT}-${STAGING_TEST_REPO_NAME}"
    local remote_cmd
    local picker_status=0

    remote_ssh "tmux kill-session -t $(printf %q "$session_name") 2>/dev/null || true"
    printf '1\n' > "$TMP_DIR/picker-input.txt"

    remote_cmd="export DEFAULT_CODE_AGENT=$(printf %q "$DEFAULT_CODE_AGENT"); export OPENAI_API_KEY=$(printf %q "$OPENAI_API_KEY"); exec bash $(printf %q "$DEV_ENV/scripts/runtime/start-claude.sh")"

    run_with_timeout "$STAGING_PICKER_TIMEOUT_SECONDS" \
        ssh "${ssh_opts[@]}" -tt "${SSH_USER}@${PUBLIC_IP}" "$remote_cmd" \
        < "$TMP_DIR/picker-input.txt" >/dev/null 2>&1 || picker_status=$?

    if [[ $picker_status -ne 0 && $picker_status -ne 124 ]]; then
        die "Picker session command exited with status $picker_status"
    fi

    sleep 3
    remote_ssh "tmux has-session -t $(printf %q "$session_name")"
    remote_ssh "tmux kill-session -t $(printf %q "$session_name")"

    ok "Picker created tmux session: $session_name"
}

reboot_and_reverify() {
    [[ "$STAGING_VERIFY_REBOOT" == "1" ]] || return 0

    info "Rebooting instance"
    step="reboot instance"

    aws ec2 reboot-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
    sleep 10
    wait_for_ssh || die "SSH did not return after reboot"
    remote_ssh "cloud-init status --wait >/dev/null 2>&1 || true"

    verify_host_runtime
    verify_container_runtime
    verify_picker_session
}

collect_remote_diagnostics() {
    if [[ -z "$PUBLIC_IP" ]]; then
        return 0
    fi

    if ! remote_ssh "echo diagnostics-ready" >/dev/null 2>&1; then
        return 0
    fi

    echo ""
    echo "=== Remote Diagnostics ==="
    remote_ssh "echo '--- groups ---'; id -nG; echo '--- service ---'; systemctl status always-on-claude --no-pager || true; echo '--- docker ps ---'; docker ps --format '{{.Names}} ({{.Status}})' || true; echo '--- tmux ---'; tmux list-sessions 2>/dev/null || true" || true
}

cleanup_all() {
    if [[ -z "$INSTANCE_ID" && -z "$SG_ID" ]]; then
        rm -rf "$TMP_DIR"
        return 0
    fi

    if [[ "$status" != "success" && "$KEEP_ON_FAILURE" == "1" ]]; then
        warn "Keeping staging resources for inspection (KEEP_ON_FAILURE=1)"
        echo "  Instance:     $INSTANCE_ID"
        echo "  Public IP:    $PUBLIC_IP"
        echo "  Project tag:  $PROJECT_TAG"
        echo "  SSH key file: $KEY_FILE"
        return 0
    fi

    if [[ "$status" == "success" && "$KEEP_ON_SUCCESS" == "1" ]]; then
        warn "Keeping staging resources (KEEP_ON_SUCCESS=1)"
        echo "  Instance:     $INSTANCE_ID"
        echo "  Public IP:    $PUBLIC_IP"
        echo "  Project tag:  $PROJECT_TAG"
        echo "  SSH key file: $KEY_FILE"
        return 0
    fi

    echo ""
    echo "=== Cleanup ==="
    AWS_REGION="$AWS_REGION" \
    KEY_NAME="$KEY_NAME" \
    PROJECT_TAG="$PROJECT_TAG" \
    bash "$SCRIPT_DIR/destroy.sh" </dev/null >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
    ok "Destroyed staging resources"
}

on_exit() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        status="failed"
        echo ""
        echo "ERROR: Failed during: $step"
        collect_remote_diagnostics
    fi
    cleanup_all
    exit "$exit_code"
}

main() {
    cd "$REPO_ROOT"

    info "Preflight checks"
    step="preflight checks"

    command -v aws >/dev/null || die "AWS CLI not found"
    command -v ssh >/dev/null || die "ssh not found"
    command -v scp >/dev/null || die "scp not found"
    command -v tar >/dev/null || die "tar not found"
    aws sts get-caller-identity >/dev/null || die "AWS credentials not configured"

    if [[ "$PROJECT_TAG" == "always-on-claude" && "${ALLOW_PROD_TAG:-0}" != "1" ]]; then
        die "Refusing to run with PROJECT_TAG=always-on-claude. Set a staging tag or ALLOW_PROD_TAG=1."
    fi

    if [[ "$INSTANCE_NAME" == "claude-dev" && "${ALLOW_DEFAULT_NAMES:-0}" != "1" ]]; then
        die "Refusing to run with INSTANCE_NAME=claude-dev. Use staging-safe names or ALLOW_DEFAULT_NAMES=1."
    fi

    ARCH="$(resolve_instance_arch "$INSTANCE_TYPE")"

    info "Resolved settings"
    echo "  Region:               $AWS_REGION"
    echo "  Instance type:        $INSTANCE_TYPE"
    echo "  Architecture:         $ARCH"
    echo "  Instance name:        $INSTANCE_NAME"
    echo "  Key name:             $KEY_NAME"
    echo "  Security group:       $SG_NAME"
    echo "  Project tag:          $PROJECT_TAG"
    echo "  Remote dev env:       $DEV_ENV"
    echo "  Remote projects dir:  $PROJECTS_DIR"
    echo "  Default code agent:   $DEFAULT_CODE_AGENT"
    echo "  Local build:          $LOCAL_BUILD"
    echo "  AMI source:           $STAGING_AMI_SOURCE"
    echo "  Verify reboot:        $STAGING_VERIFY_REBOOT"

    find_ami
    echo "  AMI selected:         $AMI_ID ($AMI_SOURCE_USED)"

    create_key_pair
    create_security_group
    launch_instance
    wait_for_ssh || die "SSH did not become ready in time"
    archive_local_repo
    upload_repo_snapshot
    run_remote_install
    verify_host_runtime
    verify_container_runtime
    create_remote_test_repo
    verify_live_codex_exec
    verify_picker_session
    reboot_and_reverify

    echo ""
    echo "============================================"
    echo "  Staging verification complete."
    echo "============================================"
    echo ""
    echo "  Instance:        $INSTANCE_ID"
    echo "  Public IP:       $PUBLIC_IP"
    echo "  Project tag:     $PROJECT_TAG"
    echo "  AMI source:      $AMI_SOURCE_USED"
    echo "  Live agent test: $(if [[ $live_checks_ran -eq 1 ]]; then echo "ran"; else echo "skipped"; fi)"
    echo ""
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap on_exit EXIT
    main "$@"
fi
