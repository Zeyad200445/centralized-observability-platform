import os
import subprocess
import sys
import time
from pathlib import Path
import httpx

KUBECONFIG = os.getenv("KUBECONFIG", ".floci/kubeconfig")
TRIAGE_URL = os.getenv("TRIAGE_URL", "http://127.0.0.1:18080")
FAULTS_DIR = Path("agents/eval/faults")

CASES = [
    {
        "name": "CrashLoopBackOff (DB connection refused)",
        "manifest": FAULTS_DIR / "crashloop.yaml",
        "pod": "eval-crashloop",
        "alertname": "WorkloadPodCrashLooping",
        "expected_keywords": ["crashloop", "exit", "database", "3306", "connection refused"],
    },
    {
        "name": "ImagePullBackOff (Invalid image)",
        "manifest": FAULTS_DIR / "image-pull.yaml",
        "pod": "eval-imagepull",
        "alertname": "WorkloadPodCrashLooping",
        "expected_keywords": ["imagepull", "errimagepull", "pull", "non-existent-registry", "image"],
    },
    {
        "name": "OOMKilled (Memory limit exceeded)",
        "manifest": FAULTS_DIR / "oom.yaml",
        "pod": "eval-oom",
        "alertname": "WorkloadPodCrashLooping",
        "expected_keywords": ["oom", "memory", "137", "32mi"],
    },
    {
        "name": "ReadinessProbe Failure (Port 9999)",
        "manifest": FAULTS_DIR / "bad-probe.yaml",
        "pod": "eval-badprobe",
        "alertname": "WorkloadPodCrashLooping",
        "expected_keywords": ["readiness", "probe", "9999", "unhealthy"],
    },
]


def kubectl(*args: str) -> None:
    subprocess.run(
        ["kubectl", "--kubeconfig", KUBECONFIG, *args],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def run_case(case: dict) -> tuple[bool, str]:
    fp = f"eval-{case['pod']}-{int(time.time())}"
    print(f"\n==> Injecting fault: {case['name']}")
    kubectl("apply", "-f", str(case["manifest"]))
    time.sleep(20)

    payload = {
        "status": "firing",
        "alerts": [
            {
                "status": "firing",
                "fingerprint": fp,
                "labels": {
                    "alertname": case["alertname"],
                    "namespace": "workload",
                    "pod": case["pod"],
                    "severity": "critical",
                },
                "annotations": {"summary": f"Pod {case['pod']} is unhealthy in namespace workload"},
            }
        ],
    }

    try:
        with httpx.Client(timeout=15.0) as client:
            r = client.post(f"{TRIAGE_URL}/alert", json=payload)
            r.raise_for_status()

            report = None
            for _ in range(45):
                time.sleep(2)
                g = client.get(f"{TRIAGE_URL}/triage/{fp}")
                if g.status_code == 200:
                    report = g.json()
                    break

        if not report or report.get("outcome") != "ok" or not report.get("note"):
            return False, f"Triage failed: {report}"

        note = report["note"]
        haystack = (
            note.get("summary", "")
            + " "
            + note.get("likely_cause", "")
            + " "
            + " ".join(note.get("evidence", []))
        ).lower()
        matched = [kw for kw in case["expected_keywords"] if kw in haystack]
        passed = len(matched) >= 2
        detail = (
            f"confidence={note.get('confidence')} | duration={report.get('duration_seconds')}s | "
            f"matched={matched} | cause={note.get('likely_cause')[:120]}"
        )
        return passed, detail
    finally:
        kubectl("delete", "-f", str(case["manifest"]), "--ignore-not-found=true")


def main() -> int:
    pf = subprocess.Popen(
        ["kubectl", "--kubeconfig", KUBECONFIG, "-n", "triage", "port-forward", "svc/triage-agent", "18080:8080"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    time.sleep(3)
    hits = 0
    try:
        for case in CASES:
            ok, detail = run_case(case)
            status = "PASS" if ok else "FAIL"
            if ok:
                hits += 1
            print(f"    [{status}] {detail}")
    finally:
        pf.terminate()

    print("\n====================================================")
    print(f" Evaluation Hit Rate: {hits} / {len(CASES)}")
    print("====================================================")
    return 0 if hits == len(CASES) else 1


if __name__ == "__main__":
    sys.exit(main())
