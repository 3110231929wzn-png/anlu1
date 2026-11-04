"""Stage-1 standalone ModelSim test. No TD, project edit or board access.

Run with --out pointing outside the source tree. A new output directory is
required to prevent accidentally accepting a previous simulation transcript.
"""
from pathlib import Path
import argparse
import json
import os
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--modelsim", type=Path,
                        default=Path(os.environ.get("MODELSIM_BIN", "C:/modeltech64_2020.4/win64")))
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    (out / "run.do").write_text(
        "onerror {quit -code 1}\nonbreak {quit -code 1}\nrun -all\nquit -code 0\n",
        encoding="ascii")
    commands = [
        [str(args.modelsim / "vlib.exe"), "work"],
        [str(args.modelsim / "vlog.exe"), "-sv", "-work", "work",
         str(ROOT / "src/user_source/hdl_source/transition/transition_pixels.v"),
         str(ROOT / "tests/tb_transition_pixels.sv")],
        [str(args.modelsim / "vsim.exe"), "-c", "work.tb_transition_pixels", "-do", "do run.do"],
    ]
    transcript = ""
    steps = []
    for command in commands:
        result = subprocess.run(command, cwd=out, capture_output=True,
                                text=True, errors="replace", timeout=180)
        transcript += "$ " + subprocess.list2cmdline(command) + "\n" + result.stdout + result.stderr + "\n"
        steps.append({"command": command, "exit_code": result.returncode})
        if result.returncode:
            break
    passed = (len(steps) == 3 and steps[-1]["exit_code"] == 0
              and "PASS tb_transition_pixels:" in transcript and "** Fatal:" not in transcript)
    (out / "result.log").write_text(transcript, encoding="utf-8")
    (out / "summary.json").write_text(json.dumps({"passed": passed, "steps": steps}, indent=2), encoding="utf-8")
    print("\n".join(transcript.splitlines()[-16:]))
    print("PASS" if passed else "FAIL", out / "result.log")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
