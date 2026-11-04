"""Run actual RTL regression tests in local ModelSim; never touches hardware."""
from pathlib import Path
import argparse
import os
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
TESTS = {
    "spi_pad_budget": ["SD/spi_master.v", "SD/sd_card_top.v", "SD/sd_card_sec_read_write.v", "SD/sd_card_cmd.v"],
    "video_axis": ["video_rgb_to_axis_640x480.v"],
    "bmp_abort": ["SD/bmp_read.v"],
    "bmp_headers": ["SD/bmp_read.v"],
    "sd_abort": ["SD/sd_card_sec_read_write.v"],
    "display_guard": ["SD/sd_card_bmp.v", "SD/bmp_read.v"],
    "frame_reader": ["SD/frame_fifo_read.v"],
    "reset_frame": ["reset_release_sync.v", "video_frame_enable.v"],
    "scheduler_timeout": ["SD/sd_card_bmp.v", "SD/bmp_read.v"],
    "frame_pipeline": ["SD/frame_read_write.v", "SD/frame_fifo_write.v", "SD/frame_fifo_read.v",
                       "IP/afifo_16_32_256.v", "IP/afifo_32_16_256.v"],
    "player_pipeline": ["SD/sd_card_bmp.v", "SD/bmp_read.v", "SD/frame_read_write.v",
                        "SD/frame_fifo_write.v", "SD/frame_fifo_read.v", "IP/afifo_16_32_256.v", "IP/afifo_32_16_256.v"],
    "sdram_init": ["include/sdr_init_ref.enc.v", "include/sdr_wrrd.enc.v", "include/sdr_as_ram.enc.v", "SD/sdram.v"],
    "frame_pipeline_full": ["SD/frame_read_write.v", "SD/frame_fifo_write.v", "SD/frame_fifo_read.v",
                            "IP/afifo_16_32_256.v", "IP/afifo_32_16_256.v"],
    "v3_bmp_scan_pipeline": ["SD/bmp_read.v"],
    "v3_bmp_check_interrupts": ["SD/bmp_read.v"],
    "v3_sdram_busy_guard": ["SD/frame_fifo_write.v", "SD/frame_fifo_read.v"],
    "v3_sdram_data_loop": ["SD/frame_read_write.v", "SD/frame_fifo_write.v", "SD/frame_fifo_read.v",
                            "IP/afifo_16_32_256.v", "IP/afifo_32_16_256.v",
                            "include/sdr_init_ref.enc.v", "include/sdr_wrrd.enc.v", "include/sdr_as_ram.enc.v", "SD/sdram.v"],
    "v3_sdram_device_spec": ["include/sdr_init_ref.enc.v", "include/sdr_wrrd.enc.v", "include/sdr_as_ram.enc.v", "SD/sdram.v"],
    "v3_real_sdram_pipeline": ["SD/frame_read_write.v", "SD/frame_fifo_write.v", "SD/frame_fifo_read.v",
                               "IP/afifo_16_32_256.v", "IP/afifo_32_16_256.v",
                               "include/sdr_init_ref.enc.v", "include/sdr_wrrd.enc.v", "include/sdr_as_ram.enc.v", "SD/sdram.v"],
}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, default=ROOT / "src/user_source/hdl_source")
    parser.add_argument("--out", type=Path, default=ROOT / "build/sim")
    parser.add_argument("--test", choices=list(TESTS), action="append")
    parser.add_argument("--modelsim", type=Path, default=Path(os.environ.get("MODELSIM_BIN", "C:/modeltech64_2020.4/win64")))
    parser.add_argument("--td-root", type=Path, default=Path(os.environ.get("TD_ROOT", "C:/Anlogic/TD_6.2.1_SP1_6.2.178.840")))
    args = parser.parse_args()
    failures = []
    for name in args.test or TESTS:
        out = (args.out / name).resolve()
        out.mkdir(parents=True, exist_ok=True)
        lib = out / "work"
        commands = []
        if not lib.exists():
            commands.append([str(args.modelsim / "vlib.exe"), str(lib)])
        do_file = out / "run.do"
        do_file.write_text("onerror {quit -code 1}\nonbreak {quit -code 1}\nrun -all\nquit -code 0\n", encoding="ascii")
        support = [str(ROOT / "tests/support/sd_card_top_model.sv")] if name in ("display_guard", "scheduler_timeout", "player_pipeline") else []
        include_options = []
        if name in ("sdram_init", "v3_sdram_device_spec", "v3_real_sdram_pipeline", "v3_sdram_data_loop"):
            support = [str(ROOT / "tests/support/sdram_diagnostic_model.sv")] if name == "v3_sdram_data_loop" else [str(args.td_root / "sim_release/eg4/eg_phy_sdram_2m_32.v")]
            include_options = [f"+incdir+{(args.source_root / 'include').resolve()}",
                               f"+incdir+{(ROOT / 'src/td_project').resolve()}"]
        commands.extend([
            [str(args.modelsim / "vlog.exe"), "-sv", "-work", "work",
             *include_options,
             *[str((args.source_root / p).resolve()) for p in TESTS[name]],
             *support,
             str(ROOT / "tests" / ("tb_frame_pipeline.sv" if name == "frame_pipeline_full" else f"tb_{name}.sv"))],
            [str(args.modelsim / "vsim.exe"), "-c", f"work.tb_{name}",
             "-do", "do run.do"],
        ])
        transcript = ""
        passed = True
        for command in commands:
            result = subprocess.run(command, cwd=out, capture_output=True, text=True, errors="replace", timeout=180)
            transcript += "$ " + subprocess.list2cmdline(command) + "\n" + result.stdout + result.stderr + "\n"
            if result.returncode:
                passed = False
                break
        passed = passed and f"PASS tb_{name}:" in transcript and "** Fatal:" not in transcript
        (out / "result.log").write_text(transcript, encoding="utf-8")
        print(f"{'PASS' if passed else 'FAIL'} {name}: {out / 'result.log'}")
        if not passed:
            print("\n".join(transcript.splitlines()[-15:]))
            failures.append(name)
    print(f"RESULT: {len(args.test or TESTS)-len(failures)} passed, {len(failures)} failed")
    return bool(failures)

if __name__ == "__main__":
    sys.exit(main())
