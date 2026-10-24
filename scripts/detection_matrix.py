#!/usr/bin/env python3
"""Run the suite against every seeded-bug vault and print the detection matrix.

Every vault in test/detection/ has exactly one bug, so every one of them MUST fail at least one check.
Exits non-zero if any seeded bug goes undetected, so CI proves the suite still catches everything.

Each check runs on its own. Newer Foundry versions run all invariants of a contract as one combined
campaign and report the result under a single name, which would credit the wrong check; running them
one at a time keeps the "Caught by" column exact on every Foundry version.

Usage:  python3 scripts/detection_matrix.py
"""
import json
import os
import shutil
import subprocess
import sys

CHECKS = [
    ("invariant_backing", "backing"),
    ("invariant_solvency", "solvency"),
    ("invariant_noValueCreated", "no value created"),
    ("invariant_previewsAreHonest", "honest previews"),
    ("invariant_limitsAreHonest", "honest limits"),
    ("invariant_roundingFavoursVault", "rounding direction"),
    ("invariant_noZeroShareDeposits", "zero-share deposits"),
    ("testFuzz_depositRedeemRoundTrip", "deposit/redeem round trip"),
    ("testFuzz_mintWithdrawRoundTrip", "mint/withdraw round trip"),
]


def run_check(test_name: str) -> dict:
    """Run one check across all seeded-bug vaults. Returns {contract: failed?}."""
    env = dict(os.environ, FOUNDRY_PROFILE="detection")
    cmd = ["forge", "test", "--match-test", f"^{test_name}\\(", "--json"]
    proc = subprocess.run(cmd, env=env, capture_output=True, text=True)
    try:
        results = json.loads(proc.stdout)
    except json.JSONDecodeError:
        print(proc.stdout[-2000:], proc.stderr[-2000:], sep="\n")
        raise SystemExit(f"could not parse forge output for {test_name}")

    outcome = {}
    for key, suite in results.items():
        contract = key.split(":")[-1]
        statuses = [res.get("status") for res in suite["test_results"].values()]
        outcome[contract] = "Failure" in statuses
    return outcome


def main() -> int:
    # drop cached counterexamples so every run searches from scratch
    shutil.rmtree("cache/invariant", ignore_errors=True)

    caught: dict[str, list[str]] = {}
    for test_name, label in CHECKS:
        print(f"running {label}...", file=sys.stderr)
        for contract, failed in run_check(test_name).items():
            caught.setdefault(contract, [])
            if failed:
                caught[contract].append(label)

    print("| Seeded bug | Caught by |")
    print("|---|---|")
    missed = []
    for contract in sorted(caught):
        labels = caught[contract]
        if not labels:
            missed.append(contract)
        print(f"| `{contract}` | {', '.join(labels) or 'NOT CAUGHT'} |")

    if missed:
        print(f"\nUNDETECTED: {', '.join(missed)}")
        return 1
    print(f"\nAll {len(caught)} seeded bugs detected.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
