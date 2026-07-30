#!/usr/bin/env python3
"""Render all .jsonnet examples to YAML files next to the source."""

import json
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("pip install pyyaml")


def main():
    stage = sys.argv[1] if len(sys.argv) > 1 else "dev"
    examples_dir = Path(__file__).parent

    for f in sorted(examples_dir.glob("*.jsonnet")):
        subprocess.run(["jsonnetfmt", "-i", str(f)], check=True)
        out = f.with_suffix(".yaml")
        print(f"{f.name} → {out.name}")
        result = subprocess.run(
            ["jsonnet", "--preserve-field-order", "--ext-str", f"stage={stage}", str(f)],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            print(f"  ERROR: {result.stderr.strip()}", file=sys.stderr)
            continue
        data = json.loads(result.stdout)
        out.write_text(yaml.dump(data, default_flow_style=False, sort_keys=False))

        lint = subprocess.run(
            ["cfn-lint", str(out)],
            capture_output=True, text=True,
        )
        if lint.stdout.strip():
            print(lint.stdout.strip())


if __name__ == "__main__":
    main()
