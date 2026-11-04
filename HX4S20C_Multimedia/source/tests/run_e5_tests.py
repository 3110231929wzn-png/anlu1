"""Bounded compile/run targets. Default is compile-only; never retries or calls TD."""
from pathlib import Path
import argparse, json, subprocess, sys
ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'src/user_source/hdl_source'
SIM = Path('C:/modeltech64_2020.4/win64')
VENDOR = Path('C:/Anlogic/TD_6.2.1_SP1_6.2.178.840/sim_release/eg4')
VIDEO = ['adjust/rgb_adjust_shiftadd.v', 'adjust/param_ctrl.v', 'adjust/param_font.v',
         'adjust/param_osd.v', 'adjust/video_e4.v', 'osd/osd_overlay.v',
         'osd/osd_font_cn.v', 'osd/osd_font_5x7.v', 'osd/osd_video.v',
         'osd/osd_status.v', 'osd/osd_snapshot_cdc.v',
         'transition/transition_pixels.v', 'video_rgb_to_axis_640x480.v']
AUDIO = ['hdmi_basic_audio.v', 'hdmi_audio_tone_i2s_64fs.v', 'I2S_receiver.v',
         'audio_arc_calculate.v', 'reset_release_sync.v']
# Clock-cycle limits are enforced by e5_progress in each fixture.
LIMITS = {'audio': 2500000, 'video': 3600000, 'real_audio': 480000,
          'integration': 3600000, 'modules': 750000, 'smoke': 800000}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('target', choices=list(LIMITS))
    p.add_argument('--out', type=Path, required=True)
    mode = p.add_mutually_exclusive_group()
    mode.add_argument('--run', action='store_true', help='Explicitly authorize one simulation')
    mode.add_argument('--compile-only', action='store_true', help='Default; never starts vsim')
    a = p.parse_args()
    out = a.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    name = 'e5_' + a.target
    top = 'tb_' + name
    marker = 'PASS tb_hdmi_basic_audio:' if a.target == 'real_audio' else 'PASS '+top+':'
    files = [] if a.target == 'real_audio' else sorted((SRC/'spectrum').glob('*.v'))
    verilog_files = []
    if a.target in ['video', 'integration', 'smoke']:
        files += [SRC/f for f in VIDEO]
    if a.target in ['real_audio', 'integration']:
        verilog_files = [VENDOR/'eg_logic_clk.v', VENDOR/'eg_phy_pll.v', SRC/'IP/PLL_HDMI_AUDIO.v']
        files += [SRC/f for f in AUDIO]
    if a.target == 'real_audio':
        files += [ROOT/'tests/tb_hdmi_basic_audio.sv']
    if a.target != 'modules':
        files += [ROOT/'tests/e5_progress.sv']
    files += [ROOT/'tests'/(top+'.sv')]
    commands = [('vlib', [str(SIM/'vlib.exe'), 'work'])]
    if verilog_files:
        commands += [('verilog', [str(SIM/'vlog.exe'), *map(str,verilog_files)])]
    commands += [('systemverilog', [str(SIM/'vlog.exe'), '-sv', *map(str,files)]),
                 ('elaboration', [str(SIM/'vopt.exe'), '+acc', 'work.'+top, '-o', top+'_checked'])]
    result = {'target': name, 'mode': 'run' if a.run else 'compile-only',
              'compilation_passed': False, 'simulation_passed': None, 'attempt': 1,
              'max_pixel_cycles': LIMITS[a.target], 'wall_timeout_seconds': 180,
              'steps': [], 'last_progress': None}
    phase = 'compile'
    try:
        for step, cmd in commands:
            result['current_step'] = step
            with (out/'compile.log').open('a', encoding='utf-8') as f:
                f.write('$ '+subprocess.list2cmdline(cmd)+'\n'); f.flush()
                r = subprocess.run(cmd, cwd=out, stdout=f, stderr=subprocess.STDOUT, timeout=60)
            result['steps'].append({'step': step, 'command': cmd, 'exit_code': r.returncode})
            if r.returncode:
                break
        result['compilation_passed'] = len(result['steps']) == len(commands) and r.returncode == 0
        if result['compilation_passed'] and a.run:
            phase = 'simulation'
            result['current_step'] = phase
            result['simulation_passed'] = False
            cmd = [str(SIM/'vsim.exe'), '-c', 'work.'+top+'_checked', '-do',
                   'onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0']
            result['simulation_command'] = cmd
            with (out/'simulation.log').open('a', encoding='utf-8') as f:
                f.write('$ '+subprocess.list2cmdline(cmd)+'\n'); f.flush()
                r = subprocess.run(cmd, cwd=out, stdout=f, stderr=subprocess.STDOUT, timeout=180)
            result['simulation_exit_code'] = r.returncode
            log = (out/'simulation.log').read_text(errors='replace')
            result['simulation_passed'] = (r.returncode == 0 and marker in log
                                           and '** Fatal:' not in log and '** Error:' not in log)
    except (subprocess.TimeoutExpired, OSError) as e:
        result['exception'] = repr(e)
        result['failed_phase'] = phase
    finally:
        logpath = out/'simulation.log'
        if logpath.exists():
            progress = [line for line in logpath.read_text(errors='replace').splitlines()
                        if 'PROGRESS target=' in line]
            result['last_progress'] = progress[-1] if progress else 'No heartbeat observed; simulated time advancement is unknown.'
        (out/'summary.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False), flush=True)
    if a.run and not result['simulation_passed']:
        print('LAST OBSERVED STATE:', result['last_progress'], flush=True)
    return 0 if result['compilation_passed'] and (not a.run or result['simulation_passed']) else 1

if __name__ == '__main__':
    sys.exit(main())
