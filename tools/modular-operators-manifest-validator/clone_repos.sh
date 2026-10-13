#!/bin/bash
#
# Usage: ./clone_repos.sh [--operator <name>] [--config <file>] [--output <dir>]
#
# Clones modular operator and component controller repos at their exact commits.
# Requires: git, yq
#
# Options:
#   --operator <name>   Clone only the specified operator (for matrix jobs)
#   --config <file>     Path to effective config (default: effective-modular-manifests-map.yaml)
#   --output <dir>      Output directory for cloned repos (default: cloned-repos)
#
# Output structure:
#   <output-dir>/<operator-name>/<operator-name>/     (modular operator repo)
#   <output-dir>/<operator-name>/<controller-name>/   (component controller repo)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/effective-modular-manifests-map.yaml"
CLONE_DIR="${SCRIPT_DIR}/cloned-repos"
TARGET_OPERATOR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --operator) TARGET_OPERATOR="$2"; shift 2 ;;
    --config)   CONFIG_FILE="$2"; shift 2 ;;
    --output)   CLONE_DIR="$2"; shift 2 ;;
    *)          echo "Unknown option: $1"; exit 1 ;;
  esac
done

log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*"; }
log_ok()    { echo "[OK]    $*"; }
log_skip()  { echo "[SKIP]  $*"; }

clone_at_commit() {
  local git_url="$1"
  local commit="$2"
  local dest="$3"
  local label="$4"

  if [[ -d "${dest}" ]]; then
    log_skip "${label} — already cloned"
    return
  fi

  log_info "Cloning ${label} (${commit:0:12})"
  git clone --quiet --no-checkout "${git_url}" "${dest}"
  git -C "${dest}" -c advice.detachedHead=false checkout --quiet "${commit}"
  log_ok "${label} cloned successfully"
}

log_info "Config: ${CONFIG_FILE}"
log_info "Output: ${CLONE_DIR}"
echo ""

mkdir -p "${CLONE_DIR}"

if [[ -n "${TARGET_OPERATOR}" ]]; then
  operators="${TARGET_OPERATOR}"
else
  operators=$(yq '.modular_operators | keys | .[]' "${CONFIG_FILE}")
fi

for operator in ${operators}; do
  log_info "Processing modular operator: ${operator}"

  op_url=$(yq ".modular_operators.\"${operator}\".\"git.url\"" "${CONFIG_FILE}")
  op_commit=$(yq ".modular_operators.\"${operator}\".\"git.commit\"" "${CONFIG_FILE}")

  if [[ "${op_url}" == "null" || "${op_commit}" == "null" ]]; then
    log_warn "${operator} — missing git.url or git.commit, skipping"
    continue
  fi

  operator_dir="${CLONE_DIR}/${operator}"
  mkdir -p "${operator_dir}"

  clone_at_commit "${op_url}" "${op_commit}" "${operator_dir}/${operator}" "${operator}"

  controllers=$(yq ".modular_operators.\"${operator}\".controllers | keys | .[]" "${CONFIG_FILE}")

  for controller in ${controllers}; do
    controller_url=$(yq ".modular_operators.\"${operator}\".controllers.\"${controller}\".\"git.url\"" "${CONFIG_FILE}")
    controller_commit=$(yq ".modular_operators.\"${operator}\".controllers.\"${controller}\".\"git.commit\"" "${CONFIG_FILE}")

    if [[ "${controller_url}" == "null" || "${controller_commit}" == "null" ]]; then
      log_warn "${controller} — missing git.url or git.commit, skipping"
      continue
    fi

    clone_at_commit "${controller_url}" "${controller_commit}" "${operator_dir}/${controller}" "${controller}"
  done

  echo ""
done

log_info "Done. All repos cloned to: ${CLONE_DIR}"
