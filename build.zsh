#!/usr/bin/env zsh
# build.zsh -- Build and verify the dotfiles-backed development image.
# Author: Pete Ehlke
# Date: 2026-08-18
# Usage: build.zsh [--full]
#   --full  Pass --no-cache --pull to `docker compose build`, discarding the layer cache and
#           re-pulling the base image. Default is a plain cached build.
# Required environment: SSH_AUTH_SOCK.
# Exit status: zero on a verified build; nonzero on invalid input or failed verification.

setopt ERR_EXIT NO_UNSET PIPE_FAIL WARN_CREATE_GLOBAL
umask 077

export DOTFILES_AGE_IDENTITY_REF='op://Private/dotfiles-private age key/private_key'
export DOTFILES_AGE_RECIPIENT_REF='op://Private/dotfiles-private age key/public_key'

readonly BUILD_SCRATCH_PREFIX='devcontainer-build.'
typeset -g BUILD_SCRATCH_DIR=""

function _die() {
  local message="${1}"

  print -u2 -r -- "error: ${message}"
  return 1
}

function _require_command() {
  local command_name="${1}"

  command -v "${command_name}" >/dev/null 2>&1 || \
    _die "required command is unavailable: ${command_name}"
}

function _require_secret_reference() {
  local variable_name="${1}"
  local reference="${(P)variable_name:-}"

  [[ -n "${reference}" ]] || _die "${variable_name} is required"
  [[ "${reference}" == op://* ]] || \
    _die "${variable_name} must be a 1Password reference"
  (( ${#reference} <= 2048 )) || _die "${variable_name} is too long"
  [[ "${reference}" != *$'\n'* ]] || _die "${variable_name} contains a newline"
}

function _preflight() {
  local agent_socket="${SSH_AUTH_SOCK:-}"
  local command_name
  local -a required_commands=(chmod cmp docker mktemp op sort ssh-add)

  for command_name in "${(@)required_commands}"; do
    _require_command "${command_name}"
  done

  [[ -n "${agent_socket}" ]] || _die "SSH_AUTH_SOCK is required"
  [[ -S "${agent_socket}" ]] || _die "SSH_AUTH_SOCK does not name a socket"
  ssh-add -L >/dev/null 2>&1 || _die "the selected SSH agent exposes no keys"
  op whoami >/dev/null 2>&1 || _die "1Password CLI authentication is required"
  docker compose version >/dev/null 2>&1 || _die "Docker Compose is unavailable"
  docker info >/dev/null 2>&1 || _die "Docker daemon is unavailable"
}

function _create_scratch_directory() {
  local temporary_root="${TMPDIR:-/tmp}"
  local scratch_directory

  [[ -d "${temporary_root}" ]] || _die "temporary directory root is unavailable"
  scratch_directory=$(mktemp -d \
    "${temporary_root%/}/${BUILD_SCRATCH_PREFIX}XXXXXXXX")
  typeset -g BUILD_SCRATCH_DIR="${scratch_directory}"
  chmod 0700 "${BUILD_SCRATCH_DIR}"
}

function _stage_secret() {
  local reference="${1}"
  local destination="${2}"

  op read "${reference}" >"${destination}"
  chmod 0600 "${destination}"
  [[ -s "${destination}" ]] || _die "1Password returned an empty value"
}

function _verify_runtime_agent() {
  local host_keys_file="${BUILD_SCRATCH_DIR}/host-agent-keys"
  local container_keys_file="${BUILD_SCRATCH_DIR}/container-agent-keys"

  ssh-add -L 2>/dev/null | LC_ALL=C sort -u >"${host_keys_file}"
  [[ -s "${host_keys_file}" ]] || _die "the host SSH agent exposes no keys"

  docker compose run --rm --no-deps devcontainer zsh -fc \
    'setopt ERR_EXIT PIPE_FAIL; ssh-add -L 2>/dev/null | LC_ALL=C sort -u' \
    >"${container_keys_file}"
  [[ -s "${container_keys_file}" ]] || \
    _die "the container SSH agent exposes no keys"

  if cmp --silent "${host_keys_file}" "${container_keys_file}"; then
    return 0
  fi

  _die "host and container SSH agent identities do not match"
}

function _verify_private_git_authentication() {
  local git_ssh_command
  local -a compose_arguments

  git_ssh_command='ssh -F /dev/null -o BatchMode=yes '
  git_ssh_command+='-o IdentityAgent=/home/pde/.1password/agent.sock '
  git_ssh_command+='-o IdentityFile=none -o IdentitiesOnly=no '
  git_ssh_command+='-o StrictHostKeyChecking=yes '
  git_ssh_command+='-o UserKnownHostsFile=/home/pde/.ssh/known_hosts'
  compose_arguments=(
    compose run --rm --no-deps
    --env "GIT_SSH_COMMAND=${git_ssh_command}"
    devcontainer
    git ls-remote git@github.com:pdehlke/dotfiles-private.git HEAD
  )

  # Suppress Git output so successful and failed probes cannot expose agent details.
  if docker "${(@)compose_arguments}" >/dev/null 2>&1; then
    return 0
  fi

  _die "runtime SSH agent cannot authenticate the private dotfiles checkout"
}

# Remove only a scratch directory created with this script's mktemp prefix.
function _cleanup() {
  if [[ -z "${BUILD_SCRATCH_DIR}" || ! -d "${BUILD_SCRATCH_DIR}" ]]; then
    return 0
  fi

  [[ "${BUILD_SCRATCH_DIR:t}" == ${BUILD_SCRATCH_PREFIX}* ]] || \
    _die "refusing to remove an unexpected scratch directory"
  command rm -rf -- "${BUILD_SCRATCH_DIR}"
  typeset -g BUILD_SCRATCH_DIR=""
}

# Preserve command failure while removing temporary secret files on every exit.
function TRAPEXIT() {
  local exit_code="${?}"

  _cleanup
  return "${exit_code}"
}

# ERR_EXIT can bypass TRAPEXIT when a command fails inside a zsh function.
function TRAPZERR() {
  local exit_code="${?}"

  _cleanup
  return "${exit_code}"
}

function TRAPHUP() {
  _cleanup
  exit 129
}

function TRAPINT() {
  _cleanup
  exit 130
}

function TRAPTERM() {
  _cleanup
  exit 143
}

function main() {
  local identity_file
  local recipient_file
  local -a build_flags=()
  local arg

  for arg in "${@}"; do
    case "${arg}" in
      --full)
        build_flags=(--no-cache --pull)
        ;;
      *)
        _die "unrecognized option: ${arg} (build.zsh accepts only --full)"
        ;;
    esac
  done

  _require_secret_reference DOTFILES_AGE_IDENTITY_REF
  _require_secret_reference DOTFILES_AGE_RECIPIENT_REF
  _preflight
  _create_scratch_directory

  identity_file="${BUILD_SCRATCH_DIR}/age-identity"
  recipient_file="${BUILD_SCRATCH_DIR}/age-recipient"
  _stage_secret "${DOTFILES_AGE_IDENTITY_REF}" "${identity_file}"
  _stage_secret "${DOTFILES_AGE_RECIPIENT_REF}" "${recipient_file}"

  export DOTFILES_AGE_IDENTITY_FILE="${identity_file}"
  export DOTFILES_AGE_RECIPIENT_FILE="${recipient_file}"

  docker compose build "${(@)build_flags}"
  _verify_runtime_agent
  _verify_private_git_authentication
}

if [[ "${ZSH_EVAL_CONTEXT}" == toplevel ]]; then
  main "${@}"
fi
