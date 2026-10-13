# Modular Operators Manifest Validator

Validates that deployment manifests packaged in modular operators are in sync with their source component controller repositories.

## Table of Contents

- [Problem](#problem)
- [How It Works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
- [How to Configure](#how-to-configure)
  - [Find your component name](#1-find-your-component-name)
  - [Add your operator and controllers](#2-add-your-operator-and-controllers)
  - [Ignoring files or folders](#3-ignoring-files-or-folders)
  - [Controllers with ref_type: branch](#4-controllers-with-ref_type-branch)
- [Design Notes](#design-notes)
  - [Two-pass validation](#two-pass-validation)
  - [Validation summary](#validation-summary)
  - [Map-of-maps structure](#map-of-maps-structure)
  - [Version-agnostic config](#version-agnostic-config)
  - [effective-modular-manifests-map.yaml](#effective-modular-manifests-mapyaml-generated)
- [Caveats](#caveats)
- [File Structure](#file-structure)

## Problem

A modular operator bundles deployment manifests from one or more component controllers. These manifests can drift out of sync when the controller repo is updated but the modular operator hasn't re-synced.

## How It Works

1. **Tracer** resolves the exact git commits used in a given build image
2. **Prepare effective config** filters the static config to only the components present in that build
3. **Clone repos** checks out both the operator and controller repos at their exact build commits
4. **Validate manifests** diffs the controller source against the operator's packaged copy

## Prerequisites

- `bash`, `git`
- `yq` (Go-based YAML processor)
- `python3` with `pyyaml`
- Access to the source repositories

## Usage

### Standalone (local)

```bash
# Step 1: Run tracer to get build provenance
bash ../tracer/tracer.sh --image <image-url> --show-commits -f json > tracer-output.json

# Step 2: Generate effective config
python3 prepare_effective_config.py tracer-output.json modular-manifests-map.yaml effective-modular-manifests-map.yaml

# Step 3: Clone repos at exact commits
./clone_repos.sh effective-modular-manifests-map.yaml

# Step 4: Validate
./validate_manifests.sh
```

### GitHub Actions

The workflow at `.github/workflows/modular-operators-manifest-validator.yml` runs all steps automatically. Trigger it via workflow dispatch with an image URL.

## How to Configure

To onboard a new modular operator for validation, edit `src/config/modular-manifests-map.yaml`:

### 1. Find your component name

The operator and controller names must match the **konflux component name** (usually the image name without the `-rhel*` suffix). To find it, run tracer on your operator or controller image:

```bash
bash tools/tracer/tracer.sh --image quay.io/rhoai/<your-image>:<tag> -c -f json
```

The component name is the key under `"components"` in the JSON output:

```json
{
  "components": {
    "odh-ai-gateway-operator": {       <-- this is your component name
      "git.url": "https://github.com/...",
      "git.commit": "abc123..."
    }
  }
}
```

### 2. Add your operator and controllers

Add an entry in `src/config/modular-manifests-map.yaml` under `modular_operators` with your operator name, then list each controller it packages:

```yaml
modular_operators:                             # Top-level namespace
  <your-operator-name>:                        # Modular Operator (must match the konflux component name)
    controllers:                               # Map of Component Controllers deployed by this operator
      <your-controller-name>:                  # Component Controller (must match the konflux component name)
        src: <path-in-controller-repo>/        # Path in the controller repo where manifests live (source of truth)
        dest: <path-in-operator-repo>/         # Path in the operator repo where those manifests are copied to
      <another-controller-name>:
        src: <path>/
        dest: <path>/
```

Example:

```yaml
modular_operators:
  odh-ai-gateway-operator:
    controllers:
      odh-llm-d-batch-gateway-operator:
        src: config/
        dest: config/manifests/batchgateway/
```

That's it. The validator will automatically pick up your operator on the next run.

### 3. Ignoring files or folders

Some controllers may have files or folders in the source or destination that should not be compared (e.g. files generated during the build, or overlay directories that only exist in one repo). Add an `ignore` list to the controller entry to exclude them from validation:

```yaml
modular_operators:
  odh-kserve-module-operator:
    controllers:
      odh-kserve-controller:
        src: config/
        dest: config/
        ignore:
          - kustomization.yaml
          - overlays/
```

The `ignore` list uses `diff --exclude` under the hood. Each entry is matched against **file or directory names**, not their full paths. For example, `overlays` would exclude any file or directory named `overlays` regardless of where it appears in the tree.

**Supported patterns:**

| Pattern | What it excludes |
| --- | --- |
| `kustomization.yaml` | Any file named `kustomization.yaml` at any depth |
| `overlays` | Any file or directory named `overlays` at any depth |
| `*.bak` | Any file ending in `.bak` at any depth (shell glob) |
| `._*` | Any file starting with `._` at any depth (shell glob) |

**Not supported:**

| Pattern | Why it doesn't work |
| --- | --- |
| `config/overlays/production` | Path-based patterns are not supported; `--exclude` only matches names |
| `**/overlays` | Recursive glob (`**`) is not supported |
| `!important.yaml` | Negation patterns (like `.gitignore`) are not supported |
| `*.{yaml,yml}` | Brace expansion is not supported |
| Ignore directory `test` but not a file named `test` | `--exclude` does not distinguish between files and directories with the same name |

If you need to exclude a file at a specific path rather than by name, consider restructuring the `src`/`dest` paths to avoid including it in the first place.

### 4. Controllers with `ref_type: branch`

Some controllers don't have a container image in Quay. Instead, their manifests are sourced directly from a git branch (the same way the operator's `manifests-config.yaml` handles `ref_type: branch` entries). These controllers won't appear in the tracer output.

To configure a branch-based controller, add `ref_type: branch` and `git.url` to the controller entry:

```yaml
modular_operators:
  odh-workbenches-operator:
    controllers:
      notebooks:
        src: manifests/
        dest: opt/manifests/workbenches/notebooks/
        ref_type: branch
        git.url: https://github.com/red-hat-data-services/notebooks
```

**How it works:**

- `ref_type: branch` — tells the enrichment script to skip the tracer lookup for this controller
- `git.url` — required; the repository URL to resolve the branch from
- `git.commit` — resolved dynamically at runtime via `git ls-remote refs/heads/<branch>`, where the branch name (e.g., `rhoai-3.5`) is derived from the tracer output's `version` field (e.g., `v3.5.0`)

**Branch derivation from tracer version:**

| Tracer version | Derived branch |
| --- | --- |
| `v3.5.0` | `rhoai-3.5` |
| `v3.4.0-ea.2` | `rhoai-3.4-ea.2` |

**When to use `ref_type: branch`:**

Use this when a controller's manifests are tracked by branch reference rather than by an image build. The operator-processor workflow resolves these branches to commit SHAs and prefetches the manifests. The validator follows the same pattern to resolve and validate them.

## Design Notes

### Two-pass validation

The validator runs two passes to give actionable results:

- **Pass 1** — validates manifests at the exact commits resolved by the tracer (i.e. the commits used in the latest builds). Any out-of-sync results are queued for re-check.
- **Pass 2** — re-validates only the out-of-sync components at the branch HEAD (`origin/<branch>`). Since builds may lag behind the latest source, this distinguishes two cases:
  - **Fixed at HEAD** — manifests are already in sync at the branch HEAD; only new builds are needed.
  - **Still out of sync at HEAD** — manifests genuinely need to be synced from the controller repo.

### Validation summary

When failures are found, the validator prints a detailed per-component summary instead of a single generic failure line. Each entry includes:

- Full GitHub URLs for the source (controller) and destination (operator) manifests
- The failure reason (`out_of_sync`, `source_not_found`, `dest_not_found`)
- Branch HEAD check result, if applicable
- For outdated builds: which repo(s) have newer commits than the built images, with short SHAs
- Recommended action for each failure type

### Map-of-maps structure

Both operator and controller entries are keyed by their component name (rather than stored as arrays). This provides:

- **O(1) lookup** when matching against tracer output components
- **Clear hierarchy** — each operator contains its controllers, each controller contains its path mappings
- **Easy extensibility** — adding a new operator or controller is a single key-value addition

### Version-agnostic config

The config is **not versioned per release**. It works as a superset of all known mappings across all supported releases:

- Multiple versions are supported concurrently. A single file covers all of them.
- When a new modular operator is onboarded in a newer release, add it here once. Older releases simply won't have it in their tracer output, so it's silently skipped.
- When an operator is offboarded in a newer release, it continues working for older releases that still include it. The newer release's tracer output won't contain it, so it's skipped automatically.
- The `prepare_effective_config.py` script filters this superset down to only the entries present in the current build's tracer output, producing a release-specific `effective-modular-manifests-map.yaml`.

### `effective-modular-manifests-map.yaml` (generated)

Release-specific output containing only matched entries with `git.url` and `git.commit` at both operator and controller levels. The tracer output is version-specific, so only components present in that build appear in the effective config.

## Caveats

- The `src` and `dest` path mappings are static. If a controller changes the directory where its manifests live, or the modular operator reorganizes its destination layout, the config must be manually updated. This tool cannot detect path mapping changes automatically.

## File Structure

```text
tools/modular-operators-manifest-validator/
├── README.md
├── prepare_effective_config.py          # generate release-specific effective config
├── clone_repos.sh                       # clone repos at exact build commits
└── validate_manifests.sh                # diff manifests and report drift

src/config/
└── modular-manifests-map.yaml        # static config (all known mappings)
```
