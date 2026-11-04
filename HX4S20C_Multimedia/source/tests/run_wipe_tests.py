"""Actual stage2 path tests only; never invokes TD or board tools."""
from pathlib import Path
import argparse,json,subprocess,sys
ROOT=Path(__file__).resolve().parents[1]
SIM=Path('C:/modeltech64_2020.4/win64')
SRC=ROOT/'src/user_source/hdl_source'

def main():
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True)
    p.add_argument('--height',type=int,default=4)
    p.add_argument('--directions',type=int,default=2)
    p.add_argument('--player',action='store_true')
    p.add_argument('--mode',type=int,choices=range(4),default=0)
    p.add_argument('--samples-only',action='store_true');a=p.parse_args()
    out=a.out.resolve();out.mkdir(parents=True,exist_ok=False)
    files=[SRC/n for n in ['transition/transition_pixels.v','transition/frame_wipe_read.v',
        'SD/frame_fifo_read.v','SD/frame_fifo_write.v','SD/frame_read_write.v',
        'IP/afifo_16_32_256.v','IP/afifo_32_16_256.v',
        'include/sdr_init_ref.enc.v','include/sdr_wrrd.enc.v','include/sdr_as_ram.enc.v','SD/sdram.v']]
    files += [ROOT/'tests/support/sdram_diagnostic_model.sv',ROOT/'tests/tb_wipe_pipeline.sv']
    name='tb_wipe_player' if a.player else 'tb_wipe_pipeline'
    if a.player:
        files=[f for f in files if f.name not in ['sdr_init_ref.enc.v','sdr_wrrd.enc.v','sdr_as_ram.enc.v','sdram.v','sdram_diagnostic_model.sv','tb_wipe_pipeline.sv']]
        files += [SRC/'SD/sd_card_bmp.v',SRC/'SD/bmp_read.v',ROOT/'tests/tb_wipe_player.sv']
    commands=[[str(SIM/'vlib.exe'),'work'],[str(SIM/'vlog.exe'),'-sv',
        '+incdir+'+str(SRC/'include'),'+incdir+'+str(ROOT/'src/td_project'),*[str(f) for f in files]],
        [str(SIM/'vsim.exe'),'-c','-voptargs=+acc',*([f'-gHEIGHT={a.height}',f'-gDIRECTIONS={a.directions}',f'-gMODE={a.mode}',f'-gSAMPLES_ONLY={int(a.samples_only)}'] if not a.player else []),'work.'+name,'-do',
         'onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0']]
    transcript='';steps=[]
    for cmd in commands:
        r=subprocess.run(cmd,cwd=out,capture_output=True,text=True,errors='replace',timeout=1200)
        transcript+='$ '+subprocess.list2cmdline(cmd)+'\n'+r.stdout+r.stderr+'\n'
        steps.append({'command':cmd,'exit_code':r.returncode})
        if r.returncode:break
    passed=len(steps)==3 and r.returncode==0 and ('PASS '+name+':') in transcript and '** Fatal:' not in transcript
    (out/'result.log').write_text(transcript,encoding='utf-8')
    (out/'summary.json').write_text(json.dumps({'passed':passed,'steps':steps},indent=2),encoding='utf-8')
    print('\n'.join(transcript.splitlines()[-18:]));return 0 if passed else 1
if __name__=='__main__':sys.exit(main())
