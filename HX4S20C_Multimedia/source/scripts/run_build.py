"""TD offline elaboration or P&R. No bit generation and no board access."""
from pathlib import Path
import argparse
import os
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--td-bin", type=Path, default=Path(os.environ.get("TD_BIN", "C:/Anlogic/TD_6.2.1_SP1_6.2.178.840/bin")))
    parser.add_argument("--elaborate-only", action="store_true")
    parser.add_argument("--routed-db", type=Path, help="STA only on an existing routed DB; never synthesize/place/route")
    parser.add_argument("--out", type=Path, default=ROOT / "build/td_final")
    args = parser.parse_args()
    if args.routed_db and args.elaborate_only:
        parser.error("--routed-db cannot be combined with --elaborate-only")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["STAGE1_BUILD_DIR"] = out.as_posix()
    env["STAGE1_ELABORATE_ONLY"] = "1" if args.elaborate_only else "0"
    if not args.routed_db:
        command = [str(args.td_bin / "td_commands_prompt.exe"), (ROOT / "scripts/build.tcl").as_posix()]
        result = subprocess.run(command, cwd=ROOT / "src/td_project", env=env,
                                capture_output=True, text=True, errors="replace", timeout=1800)
        transcript = result.stdout + result.stderr
        (out / "build.log").write_text(transcript, encoding="utf-8")
        marker = "STAGE1_ELABORATION_COMPLETE:" if args.elaborate_only else "STAGE1_BUILD_COMPLETE:"
        if result.returncode or marker not in transcript or "STAGE1_BUILD_FAILED:" in transcript:
            print("\n".join(transcript.splitlines()[-12:]))
            print(f"BUILD FAILED (not a timing pass): {out / 'build.log'}")
            return 1
        if args.elaborate_only:
            print(f"ELABORATION PASS (synthesis/P&R not run): {out / 'build.log'}")
            return 0
    database = args.routed_db.resolve() if args.routed_db else out / "routed.db"
    if not database.is_file():
        print(f"Missing routed DB; no automatic rebuild: {database}")
        return 1
    env["STAGE1_ROUTED_DB"] = database.as_posix()
    command = [str(args.td_bin / "td_commands_prompt.exe"), (ROOT / "scripts/audit_routed_timing.tcl").as_posix()]
    result = subprocess.run(command, cwd=ROOT / "src/td_project", env=env,
                            capture_output=True, text=True, errors="replace", timeout=180)
    transcript = result.stdout + result.stderr
    (out / "routed_sta.log").write_text(transcript, encoding="utf-8")
    if result.returncode or "ROUTED_STA_COMPLETE:" not in transcript:
        print("\n".join(transcript.splitlines()[-12:]))
        print("Isolated final STA failed; no automatic rebuild")
        return 1
    text = (out / "final_timing.rpt").read_text(encoding="utf-8", errors="replace")
    setup = re.search(r"SWNS:\s*([-+\d.]+)", text)
    hold = re.search(r"HWNS:\s*([-+\d.]+)", text)
    if not setup or not hold:
        print(f"P&R completed, timing status unparsed; inspect {out / 'final_timing.rpt'}")
        return 2
    print(f"Setup WNS={setup[1]} ns, Hold WNS={hold[1]} ns")
    if float(setup[1]) < 0 or float(hold[1]) < 0:
        print("TIMING FAILED; do not treat P&R completion as timing closure")
        return 2
    print("Isolated routed STA setup/hold WNS PASS; inspect coverage and reset-boundary reports separately")
    return 0

if __name__ == "__main__":
    sys.exit(main())
