"""Targeted actual ModelSim RTL runs; no TD/board access. Fresh output required."""
from pathlib import Path
import argparse, json, re, subprocess, sys
ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'src/user_source/hdl_source'
SIM = Path('C:/modeltech64_2020.4/win64')

def run(name, files, out):
    out.mkdir(parents=True, exist_ok=False)
    for stem, count in [('osd_font_cn', 256), ('osd_font_5x7', 1024)]:
        values = [0]*count
        for idx, value in re.findall(r"\d+'d(\d+)\s*:\s*data\s*=\s*\d+'h([0-9A-Fa-f]+)", (SRC/'osd'/f'{stem}.v').read_text(encoding='utf8')):
            values[int(idx)] = int(value, 16)
        (out/(stem+'.hex')).write_text('\n'.join(format(v, '06x' if count==256 else '03x') for v in values)+'\n')
    commands = [[str(SIM/'vlib.exe'), 'work'],
        [str(SIM/'vlog.exe'), '-sv', *map(str, files), str(ROOT/'tests'/f'tb_{name}.sv')],
        [str(SIM/'vsim.exe'), '-c', '-voptargs=+acc', 'work.tb_'+name, '-do',
         'onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0']]
    log = ''; steps=[]
    for cmd in commands:
        p = subprocess.run(cmd, cwd=out, capture_output=True, text=True, errors='replace', timeout=240)
        log += '$ '+subprocess.list2cmdline(cmd)+'\n'+p.stdout+p.stderr+'\n'
        steps.append({'command':cmd, 'exit_code':p.returncode})
        if p.returncode: break
    passed = len(steps)==3 and p.returncode==0 and ('PASS tb_'+name+':') in log and '** Fatal:' not in log
    (out/'result.log').write_text(log,encoding='utf8')
    (out/'summary.json').write_text(json.dumps({'passed':passed,'steps':steps},indent=2),encoding='utf8')
    print('\n'.join(log.splitlines()[-18:]),flush=True)
    return passed

def main():
    p=argparse.ArgumentParser(); p.add_argument('--out',type=Path,required=True)
    p.add_argument('--test',choices=['osd_overlay','osd_timer','osd_status','osd_integration'],default='osd_overlay'); a=p.parse_args()
    core=[SRC/'osd'/f for f in ['osd_overlay.v','osd_font_cn.v','osd_font_5x7.v']]
    files=core if a.test in ['osd_overlay','osd_timer'] else [SRC/'osd'/f for f in ['osd_snapshot_cdc.v','osd_status.v']]
    if a.test=='osd_integration':
        files+=core+[SRC/'osd/osd_video.v',SRC/'video_rgb_to_axis_640x480.v',SRC/'SD/video_delay.v']
    return 0 if run(a.test,files,a.out.resolve()) else 1
if __name__=='__main__':sys.exit(main())
