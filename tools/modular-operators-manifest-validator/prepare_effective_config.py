#!/usr/bin/env python3
import json
import re
import subprocess
import sys

import yaml


def derive_branch(version):
    """Derive branch name from tracer version.

    version format: vX.Y.Z or vX.Y.Z-ea.N
    branch format:  rhoai-X.Y or rhoai-X.Y-ea.N
    """
    match = re.match(r"v(\d+\.\d+)\.\d+(-ea\.\d+)?", version)
    if not match:
        sys.exit(f"[ERROR] Cannot derive branch from version: {version}")
    major_minor = match.group(1)
    ea_suffix = match.group(2) or ""
    return f"rhoai-{major_minor}{ea_suffix}"


def resolve_branch_commit(git_url, branch):
    """Resolve the latest commit SHA for a branch via git ls-remote."""
    try:
        result = subprocess.run(
            ["git", "ls-remote", git_url, f"refs/heads/{branch}"],
            capture_output=True, text=True, check=True,
        )
    except subprocess.CalledProcessError as e:
        sys.exit(f"[ERROR] git ls-remote failed for {git_url}: {e.stderr.strip()}")

    sha = result.stdout.split()[0] if result.stdout.strip() else ""
    if not sha:
        sys.exit(
            f"[ERROR] Could not resolve branch '{branch}' from {git_url}"
        )
    return sha


def main():
    tracer_file = sys.argv[1] if len(sys.argv) > 1 else "tracer-output.json"
    config_file = sys.argv[2] if len(sys.argv) > 2 else "modular-manifests-map.yaml"
    output_file = sys.argv[3] if len(sys.argv) > 3 else "effective-modular-manifests-map.yaml"

    with open(tracer_file) as f:
        tracer_data = json.load(f)

    components = tracer_data.get("components", {})
    version = tracer_data.get("version", "")

    if not version:
        sys.exit("[ERROR] No version found in tracer output — cannot derive branch")
    branch = derive_branch(version)
    print(f"[INFO]  Derived branch: {branch} (from version: {version})")

    with open(config_file) as f:
        config = yaml.safe_load(f)

    operators = config.get("modular_operators", {})
    enriched_operators = {}

    for operator_name, operator_data in operators.items():
        if operator_name not in components:
            print(f"[SKIP]  {operator_name} — not found in tracer output")
            continue

        comp = components[operator_name]
        enriched_operator = {
            "git.url": comp["git.url"],
            "git.commit": comp["git.commit"],
            "controllers": {},
        }

        for controller_name, controller_data in operator_data.get("controllers", {}).items():
            ref_type = controller_data.get("ref_type", "image")

            if ref_type == "branch":
                git_url = controller_data.get("git.url")
                if not git_url:
                    sys.exit(
                        f"[ERROR] {controller_name} — ref_type: branch requires git.url in config"
                    )

                git_commit = resolve_branch_commit(git_url, branch)
                print(f"[OK]    {controller_name} — resolved {branch} → {git_commit[:12]}")

                entry = {
                    "src": controller_data["src"],
                    "dest": controller_data["dest"],
                    "ref_type": "branch",
                    "git.url": git_url,
                    "git.commit": git_commit,
                }
                if "ignore" in controller_data:
                    entry["ignore"] = controller_data["ignore"]
                enriched_operator["controllers"][controller_name] = entry
            else:
                if controller_name not in components:
                    print(f"[SKIP]  {controller_name} — not found in tracer output")
                    continue

                controller_comp = components[controller_name]
                enriched_operator["controllers"][controller_name] = {
                    **controller_data,
                    "git.url": controller_comp["git.url"],
                    "git.commit": controller_comp["git.commit"],
                }

        enriched_operators[operator_name] = enriched_operator

    enriched_config = {
        "branch": branch,
        "modular_operators": enriched_operators,
    }

    with open(output_file, "w") as f:
        yaml.dump(enriched_config, f, default_flow_style=False, sort_keys=False)

    print(f"[OK]    Effective config written to: {output_file}")


if __name__ == "__main__":
    main()
