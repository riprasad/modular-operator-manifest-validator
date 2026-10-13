#!/bin/bash
#
# Usage: ./validate_manifests.sh [--operator <name>] [--config <file>] [--repos <dir>]
#
# Validates that manifests in the modular operator repo match the component
# controller repo for each controller defined in the effective config.
# Requires: git, yq
#
# Options:
#   --operator <name>   Validate only the specified operator (for matrix jobs)
#   --config <file>     Path to effective config (default: effective-modular-manifests-map.yaml)
#   --repos <dir>       Path to cloned repos (default: cloned-repos)
#
# Exit codes:
#   0 — all manifests are in sync
#   1 — one or more manifests are out of sync
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLONE_DIR="${SCRIPT_DIR}/cloned-repos"
CONFIG_FILE="${SCRIPT_DIR}/effective-modular-manifests-map.yaml"
TARGET_OPERATOR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --operator) TARGET_OPERATOR="$2"; shift 2 ;;
    --config)   CONFIG_FILE="$2"; shift 2 ;;
    --repos)    CLONE_DIR="$2"; shift 2 ;;
    *)          echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Logging ───────────────────────────────────────────────────────────────────

log_info()  { echo "[INFO]  $*"; }
log_ok()    { echo "[OK]    $*"; }
log_fail()  { echo "[FAIL]  $*"; }
log_warn()  { echo "[WARN]  $*"; }

indent() { awk '{print "    " $0}'; }

# Use colored diff output if supported (GNU diff), plain otherwise (BSD/macOS)
DIFF_COLOR=""
if diff --color=always /dev/null /dev/null 2>/dev/null; then
  DIFF_COLOR="--color=always"
fi

# ── Portable key-value helpers ─────────────────────────────────────────────────
# Uses indexed arrays with "key=value" or "key|value" entries instead of
# associative arrays, so the script runs on bash 3.2+ (macOS) and bash 5 (CI).

SWITCHED_REPOS=()    # repo paths already checked out to branch HEAD
REPO_HEAD_SHAS=()    # "repo_path=sha" — HEAD commit SHA after switching
HEAD_RESULTS=()      # "controller|status" — branch HEAD re-check result

is_switched() {
  local target="$1"
  [[ ${#SWITCHED_REPOS[@]} -eq 0 ]] && return 1
  for path in "${SWITCHED_REPOS[@]}"; do
    if [[ "${path}" == "${target}" ]]; then return 0; fi
  done
  return 1
}

lookup_sha() {
  local target="$1"
  [[ ${#REPO_HEAD_SHAS[@]} -eq 0 ]] && return
  for entry in "${REPO_HEAD_SHAS[@]}"; do
    if [[ "${entry%%=*}" == "${target}" ]]; then
      echo "${entry#*=}"
      return
    fi
  done
}

lookup_head_result() {
  local target="$1"
  [[ ${#HEAD_RESULTS[@]} -eq 0 ]] && return
  for entry in "${HEAD_RESULTS[@]}"; do
    if [[ "${entry%%|*}" == "${target}" ]]; then
      echo "${entry#*|}"
      return
    fi
  done
}

# Switches a repo to the branch HEAD. Skips if already switched.
# Records the HEAD SHA for later stale-build comparison.
switch_to_branch() {
  local repo="$1"
  local label="$2"
  local branch="$3"

  if is_switched "${repo}"; then return 0; fi

  if git -C "${repo}" rev-parse --verify "origin/${branch}" >/dev/null 2>&1; then
    git -C "${repo}" checkout --quiet "origin/${branch}" 2>/dev/null
    SWITCHED_REPOS+=("${repo}")
    REPO_HEAD_SHAS+=("${repo}=$(git -C "${repo}" rev-parse HEAD)")
    log_info "Switched ${label} to origin/${branch}"
    return 0
  else
    log_warn "${label} — branch origin/${branch} not found, skipping HEAD check"
    return 1
  fi
}

# ── State ─────────────────────────────────────────────────────────────────────

FAILED=0
FAILED_SUMMARIES=()   # "controller|reason|src_url|dest_url" — all failures for the summary
RECHECK_QUEUE=()      # "op|ctrl|src|dest|ctrl_url|op_url|op_commit|ctrl_commit" — out-of-sync controllers to re-check at HEAD

log_info "Config: ${CONFIG_FILE}"
log_info "Repos:  ${CLONE_DIR}"
echo ""

if [[ -n "${TARGET_OPERATOR}" ]]; then
  operators="${TARGET_OPERATOR}"
else
  operators=$(yq '.modular_operators | keys | .[]' "${CONFIG_FILE}")
fi

# ── Pass 1: Validate at the tracer-resolved commits (from builds) ────────────

for operator in ${operators}; do
  log_info "Validating modular operator: ${operator}"
  echo ""
  log_info "Effective config:"
  echo ""
  echo "  ${operator}:"
  yq ".modular_operators.\"${operator}\"" "${CONFIG_FILE}" | indent
  echo ""

  op_url=$(yq ".modular_operators.\"${operator}\".\"git.url\"" "${CONFIG_FILE}")
  op_commit=$(yq ".modular_operators.\"${operator}\".\"git.commit\"" "${CONFIG_FILE}")

  operator_dir="${CLONE_DIR}/${operator}"
  controllers=$(yq ".modular_operators.\"${operator}\".controllers | keys | .[]" "${CONFIG_FILE}")

  for controller in ${controllers}; do
    src=$(yq ".modular_operators.\"${operator}\".controllers.\"${controller}\".src" "${CONFIG_FILE}")
    dest=$(yq ".modular_operators.\"${operator}\".controllers.\"${controller}\".dest" "${CONFIG_FILE}")
    ctrl_url=$(yq ".modular_operators.\"${operator}\".controllers.\"${controller}\".\"git.url\"" "${CONFIG_FILE}")
    ctrl_commit=$(yq ".modular_operators.\"${operator}\".controllers.\"${controller}\".\"git.commit\"" "${CONFIG_FILE}")

    controller_path="${operator_dir}/${controller}/${src}"
    operator_path="${operator_dir}/${operator}/${dest}"
    src_url="${ctrl_url}/tree/${ctrl_commit}/${src%/}"
    dest_url="${op_url}/tree/${op_commit}/${dest%/}"

    # Build --exclude flags from the optional ignore list
    exclude_args=()
    while IFS= read -r pattern; do
      [[ -n "${pattern}" ]] && exclude_args+=("--exclude=${pattern}")
    done < <(yq ".modular_operators.\"${operator}\".controllers.\"${controller}\".ignore // [] | .[]" "${CONFIG_FILE}")

    if [[ ${#exclude_args[@]} -gt 0 ]]; then
      log_info "${controller} — ignoring: $(IFS=', '; echo "${exclude_args[*]}" | awk -F= '{printf "%s ", $2}')"
    fi

    if [[ ! -d "${controller_path}" ]]; then
      log_fail "${controller} — source path not found: ${controller_path}"
      FAILED=1
      FAILED_SUMMARIES+=("${controller}|source_not_found|${src_url}|${dest_url}")
      continue
    fi

    if [[ ! -d "${operator_path}" ]]; then
      log_fail "${controller} — dest path not found: ${operator_path}"
      FAILED=1
      FAILED_SUMMARIES+=("${controller}|dest_not_found|${src_url}|${dest_url}")
      continue
    fi

    if diff -rq ${exclude_args[@]+"${exclude_args[@]}"} "${controller_path}" "${operator_path}" > /dev/null 2>&1; then
      log_ok "${controller} — manifests are in sync"
    else
      log_fail "${controller} — manifests are OUT OF SYNC"
      echo ""
      diff -r ${DIFF_COLOR} ${exclude_args[@]+"${exclude_args[@]}"} "${controller_path}" "${operator_path}" || true
      echo ""
      FAILED=1
      FAILED_SUMMARIES+=("${controller}|out_of_sync|${src_url}|${dest_url}")
      RECHECK_QUEUE+=("${operator}|${controller}|${src}|${dest}|${ctrl_url}|${op_url}|${op_commit}|${ctrl_commit}")
    fi
  done

  echo ""
done

# ── Pass 2: Re-validate failed components at branch HEAD ─────────────────────
# Builds are resolved by the tracer from published images, which may lag behind
# the latest source commits. If manifests are out of sync at the built commits
# but in sync at the branch HEAD, it means the fix is already merged and only
# new builds are needed.

BRANCH=$(yq '.branch // ""' "${CONFIG_FILE}")

if [[ ${#RECHECK_QUEUE[@]} -gt 0 ]]; then
  if [[ -z "${BRANCH}" ]]; then
    log_warn "No branch in config — skipping branch HEAD re-check"
  else
    echo "========================================"
    echo "  RE-CHECKING AT BRANCH HEAD (${BRANCH})"
    echo "========================================"
    echo ""
    log_info "Re-validating ${#RECHECK_QUEUE[@]} out-of-sync component(s) against origin/${BRANCH}..."
    log_info "Builds may be outdated — checking if the manifests are already synced at branch HEAD."
    echo ""

    for entry in "${RECHECK_QUEUE[@]}"; do
      IFS='|' read -r op ctrl src dest ctrl_url op_url op_commit ctrl_commit <<< "${entry}"

      operator_dir="${CLONE_DIR}/${op}"
      ctrl_repo="${operator_dir}/${ctrl}"
      op_repo="${operator_dir}/${op}"

      ctrl_switched=true
      op_switched=true
      switch_to_branch "${ctrl_repo}" "${ctrl}" "${BRANCH}" || ctrl_switched=false
      switch_to_branch "${op_repo}" "${op}" "${BRANCH}" || op_switched=false

      controller_path="${ctrl_repo}/${src}"
      operator_path="${op_repo}/${dest}"

      # Re-read ignore patterns for this controller
      exclude_args=()
      while IFS= read -r pattern; do
        [[ -n "${pattern}" ]] && exclude_args+=("--exclude=${pattern}")
      done < <(yq ".modular_operators.\"${op}\".controllers.\"${ctrl}\".ignore // [] | .[]" "${CONFIG_FILE}")

      if [[ "${ctrl_switched}" != "true" || "${op_switched}" != "true" ]]; then
        HEAD_RESULTS+=("${ctrl}|skipped")
      elif [[ ! -d "${controller_path}" || ! -d "${operator_path}" ]]; then
        log_fail "${ctrl} — path not found at branch HEAD"
        HEAD_RESULTS+=("${ctrl}|error")
      elif diff -rq ${exclude_args[@]+"${exclude_args[@]}"} "${controller_path}" "${operator_path}" > /dev/null 2>&1; then
        log_ok "${ctrl} — in sync at origin/${BRANCH} (builds are outdated)"
        HEAD_RESULTS+=("${ctrl}|in_sync_at_head")
      else
        log_fail "${ctrl} — still OUT OF SYNC at origin/${BRANCH}"
        HEAD_RESULTS+=("${ctrl}|still_out_of_sync")
      fi
    done

    echo ""
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
# Prints a detailed report for each failed component with full GitHub URLs,
# branch HEAD check results, and stale build identification.

if [[ ${FAILED} -eq 0 ]]; then
  log_info "All manifests are in sync"
  exit 0
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                   VALIDATION SUMMARY — FAILED                    ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  ${#FAILED_SUMMARIES[@]} component(s) failed manifest validation."
echo ""

fixed_at_head=0
idx=0
for entry in "${FAILED_SUMMARIES[@]}"; do
  IFS='|' read -r ctrl reason src_url dest_url <<< "${entry}"
  ((++idx))

  echo "  ================================================================"
  echo "   ${idx}. ${ctrl}"
  echo "  ================================================================"

  if [[ "${reason}" == "out_of_sync" ]]; then
    echo ""
    echo "     Modular operator repo (destination):"
    echo "       ${dest_url}"
    echo ""
    echo "     Component controller repo (source):"
    echo "       ${src_url}"
    echo ""
    echo "     Manifests in the modular operator repo (destination) do not match"
    echo "     the manifests in the component controller repo (source)."

    head_status=$(lookup_head_result "${ctrl}")
    if [[ -n "${head_status}" ]]; then
      echo ""
      echo "     Branch HEAD check (origin/${BRANCH}):"

      if [[ "${head_status}" == "in_sync_at_head" ]]; then
        echo "       FIXED — Manifests are in sync at the branch HEAD."
        echo "       The following build(s) are outdated:"

        # Identify which repo(s) have newer commits than the built images
        for recheck in "${RECHECK_QUEUE[@]}"; do
          IFS='|' read -r r_op r_ctrl r_src r_dest r_ctrl_url r_op_url r_op_commit r_ctrl_commit <<< "${recheck}"
          if [[ "${r_ctrl}" == "${ctrl}" ]]; then
            op_head=$(lookup_sha "${CLONE_DIR}/${r_op}/${r_op}")
            ctrl_head=$(lookup_sha "${CLONE_DIR}/${r_op}/${r_ctrl}")
            if [[ -n "${op_head}" && "${op_head}" != "${r_op_commit}" ]]; then
              echo "         - ${r_op} (modular operator): built from ${r_op_commit:0:7}, HEAD at ${op_head:0:7}"
            fi
            if [[ -n "${ctrl_head}" && "${ctrl_head}" != "${r_ctrl_commit}" ]]; then
              echo "         - ${r_ctrl} (controller): built from ${r_ctrl_commit:0:7}, HEAD at ${ctrl_head:0:7}"
            fi
            break
          fi
        done

        echo "       Trigger new builds from the latest branch commits to resolve this."
        ((fixed_at_head++))

      elif [[ "${head_status}" == "still_out_of_sync" ]]; then
        echo "       NOT FIXED — Manifests are still out of sync at the branch HEAD."
        echo "       Action required: sync the modular operator repo with the latest"
        echo "       component controller manifests."

      elif [[ "${head_status}" == "error" ]]; then
        echo "       Path not found at branch HEAD — could not verify."

      elif [[ "${head_status}" == "skipped" ]]; then
        echo "       Branch ${BRANCH} not found in one or both repos — could not verify."
      fi
    fi

  elif [[ "${reason}" == "source_not_found" ]]; then
    echo ""
    echo "     Source path does not exist in the component controller repo:"
    echo "       ${src_url}"
    echo ""
    echo "     Verify the src path in the manifest config is correct,"
    echo "     or check if the manifests were moved in the controller repo."

  elif [[ "${reason}" == "dest_not_found" ]]; then
    echo ""
    echo "     Destination path does not exist in the modular operator repo:"
    echo "       ${dest_url}"
    echo ""
    echo "     Verify the dest path in the manifest config is correct,"
    echo "     or check if the manifests were not copied to the operator repo."
  fi

  echo ""
done

echo "  ────────────────────────────────────────────────────────────────"
if [[ ${fixed_at_head} -gt 0 ]]; then
  echo "  ${fixed_at_head} of ${#FAILED_SUMMARIES[@]} component(s) are already fixed at the branch HEAD"
  echo "  and need new builds from the latest commits to resolve."
  echo "  ────────────────────────────────────────────────────────────────"
fi
echo ""
log_fail "Validation failed — ${#FAILED_SUMMARIES[@]} component(s) out of sync"
exit 1
