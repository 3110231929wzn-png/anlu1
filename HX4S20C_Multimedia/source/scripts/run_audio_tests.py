"""Only the necessary nominal audio regression and actual-PLL wrapper test."""
from pathlib import Path
import argparse,hashlib,json,subprocess,sys
ROOT=Path(__file__).resolve().parents[1]
def main():
 p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);a=p.parse_args()
 out=a.out.resolve();out.mkdir(parents=True,exist_ok=False)
 sim=Path('C:/modeltech64_2020.4/win64');lib=Path('C:/Anlogic/TD_6.2.1_SP1_6.2.178.840/sim_release/eg4');src=ROOT/'src/user_source/hdl_source'
 three=[src/n for n in ['hdmi_audio_tone_i2s_64fs.v','I2S_receiver.v','audio_arc_calculate.v']]
 cases={'official_audio_chain':three,'hdmi_basic_audio':three+[src/'hdmi_basic_audio.v',src/'reset_release_sync.v']}
 results={}
 for name,files in cases.items():
  folder=out/name;folder.mkdir()
  tb=ROOT/'tests'/('tb_'+name+'.sv')
  (folder/'run.do').write_text('onerror {quit -code 1}\nonbreak {quit -code 1}\nlog -r sim:/tb_'+name+'/*\nrun -all\nquit -code 0\n')
  commands=[[str(sim/'vlib.exe'),'work']]
  if name=='hdmi_basic_audio':commands.append([str(sim/'vlog.exe'),str(lib/'eg_logic_clk.v'),str(lib/'eg_phy_pll.v'),str(src/'IP/PLL_HDMI_AUDIO.v')])
  commands += [[str(sim/'vlog.exe'),'-sv',*[str(f) for f in files],str(tb)],[str(sim/'vsim.exe'),'-c','-voptargs=+acc','work.tb_'+name,'-wlf','audio.wlf','-do','do run.do']]
  transcript='';steps=[]
  for command in commands:
   result=subprocess.run(command,cwd=folder,capture_output=True,text=True,errors='replace',timeout=180)
   transcript+='$ '+subprocess.list2cmdline(command)+'\n'+result.stdout+result.stderr+'\n';steps.append({'command':command,'exit_code':result.returncode})
   if result.returncode:break
  (folder/'result.log').write_text(transcript,encoding='utf-8')
  passed=result.returncode==0 and 'PASS tb_'+name+':' in transcript and '** Fatal:' not in transcript
  results[name]={'pass':passed,'steps':steps,'testbench_sha256':hashlib.sha256(tb.read_bytes()).hexdigest()}
  print(('PASS ' if passed else 'FAIL ')+name,flush=True);print('\n'.join(transcript.splitlines()[-8:]),flush=True)
 (out/'summary.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
 return 0 if all(v['pass'] for v in results.values()) else 1
if __name__=='__main__':sys.exit(main())
