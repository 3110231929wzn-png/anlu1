"""Bounded real RTL simulation, no TD or hardware. Each invocation owns fresh logs."""
from pathlib import Path
import argparse,json,subprocess,sys
ROOT=Path(__file__).resolve().parents[1]
SRC=ROOT/'src/user_source/hdl_source'
SIM=Path('C:/modeltech64_2020.4/win64')
def run(name,files,out):
    out.mkdir(parents=True,exist_ok=False)
    log='';steps=[]
    commands=[[str(SIM/'vlib.exe'),'work'],[str(SIM/'vlog.exe'),'-sv',*map(str,files),str(ROOT/'tests'/f'tb_{name}.sv')],
      [str(SIM/'vsim.exe'),'-c','-voptargs=+acc','work.tb_'+name,'-do','onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0']]
    for cmd in commands:
        with (out/'result.log').open('a',encoding='utf-8') as f:
            f.write('$ '+subprocess.list2cmdline(cmd)+'\n');f.flush()
            p=subprocess.run(cmd,cwd=out,stdout=f,stderr=subprocess.STDOUT,timeout=240)
        steps.append({'command':cmd,'exit_code':p.returncode})
        if p.returncode:break
    log=(out/'result.log').read_text(encoding='utf-8',errors='replace')
    passed=len(steps)==3 and p.returncode==0 and 'PASS tb_'+name+':' in log and '** Fatal:' not in log
    (out/'summary.json').write_text(json.dumps({'passed':passed,'steps':steps},indent=2))
    print('\n'.join(log.splitlines()[-10:]),flush=True)
    return passed
def main():
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True)
    p.add_argument('--only',choices=['e4_rgb','e4_ctrl','e4_panel','e4_integration']);a=p.parse_args()
    tests={'e4_rgb':[SRC/'adjust/rgb_adjust.v'],'e4_ctrl':[SRC/'adjust/param_ctrl.v'],
      'e4_panel':[SRC/'adjust/param_osd.v',SRC/'adjust/param_font.v']}
    if a.only=='e4_integration':
        core=['adjust/'+f for f in ['rgb_adjust.v','rgb_adjust_shiftadd.v','param_ctrl.v','param_osd.v','param_font.v','video_e4.v']]
        core+=['osd/'+f for f in ['osd_overlay.v','osd_font_cn.v','osd_font_5x7.v','osd_video.v','osd_status.v','osd_snapshot_cdc.v']]
        core+=['SD/video_delay.v','video_rgb_to_axis_640x480.v','video_frame_enable.v']
        tests={'e4_integration':[SRC/f for f in core]}
    for name in ([a.only] if a.only else tests):
        if not run(name,tests[name],a.out.resolve()/name):return 1
    return 0
if __name__=='__main__':sys.exit(main())
