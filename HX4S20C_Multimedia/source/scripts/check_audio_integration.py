"""Read-only audio bindings/project/PLL checks; not a synthesis or board test."""
from pathlib import Path
import hashlib,re,sys
ROOT=Path(__file__).resolve().parents[1]
SRC=ROOT/'src/user_source/hdl_source'
def check():
 errors=[]
 files=['hdmi_basic_audio.v','hdmi_audio_tone_i2s_64fs.v','I2S_receiver.v','audio_arc_calculate.v','IP/PLL_HDMI_AUDIO.v','IP/PLL_HDMI_AUDIO.vhd','IP/PLL_HDMI_AUDIO.ipc']
 for f in files:
  if not (SRC/f).is_file():errors.append('missing '+f)
 top=(SRC/'top_tf_hdmi_audio.v').read_text(encoding='utf-8')
 for port,net in [('I_audio_valid','audio_valid'),('I_audio_left_data','audio_left_data'),('I_audio_right_data','audio_right_data'),('I_acr_valid','acr_valid'),('I_acr_cts','acr_cts'),('I_acr_n','acr_n')]:
  if not re.search(r'\.'+port+r'\s*\(\s*'+net+r'\s*\)',top):errors.append('HDMI binding '+port+' -> '+net+' missing')
 if not re.search(r'hdmi_basic_audio\s+u_hdmi_basic_audio\s*\(',top):errors.append('audio chain instance missing')
 al=(ROOT/'src/td_project/lab_ex5_i2s_v1.0.al').read_text(encoding='utf-8')
 for f in files[:4]+['IP/PLL_HDMI_AUDIO.ipc']:
  if f not in al:errors.append('project reference '+f+' missing')
 for ref in re.findall(r'<File\s+Path="([^"]+)"',al):
  if not (ROOT/'src/td_project'/ref).exists():errors.append('unresolved project path '+ref)
 if not errors:
  receiver=(SRC/'I2S_receiver.v').read_bytes()
  if hashlib.sha256(receiver).hexdigest()!='b757a1a974c3a1e2b55e55d146f01bd2981f5bc292c127fa01520621fd2be6dd':errors.append('receiver differs from verified reset-fixed version')
  if len(re.findall(r'always @\(posedge I_clk or posedge I_rst\)',receiver.decode('utf-8')))!=7:errors.append('receiver reset fix missing')
  pll=(SRC/'IP/PLL_HDMI_AUDIO.v').read_text()
  for p,v in [('REFCLK_DIV',2),('FBCLK_DIV',3),('CLKC0_DIV',10),('CLKC2_DIV',61)]:
   if not re.search(r'\.'+p+r'\(\s*'+str(v)+r'\s*\)',pll):errors.append('unexpected PLL parameter '+p)
  ipc=(SRC/'IP/PLL_HDMI_AUDIO.ipc').read_text()
  if '12.295081967' not in ipc:errors.append('IPC still claims nominal12.288MHz instead of actual clock')
  physical=ROOT/'src/user_source/constraints_source/audio_reset_physical.sdc'
  if not physical.exists():errors.append('physical-stage audio reset constraint missing')
  else:
   commands=[s.strip() for s in physical.read_text().splitlines() if s.strip() and not s.lstrip().startswith('#')]
   expected=['set_false_path -setup -to [get_pins -of [get_cells -of [get_nets {u_hdmi_basic_audio/u_audio_mclk_reset/release_pipe[0]}]] {*.sr}]']
   if commands!=expected:errors.append('audio reset exception differs from reviewed connectivity selector; TD build must prove mapped scope')
  section=re.search(r'<File Path="../user_source/constraints_source/audio_reset_physical.sdc">(.*?)</File>',al,re.S)
  if not section or 'Name="UsedInSyn" Val="false"' not in section[1]:errors.append('physical audio reset constraint must not be used in RTL synthesis')
 for e in errors:print('FAIL:',e)
 if not errors:print('PASS audio source dependencies, six HDMI bindings, reset fix, project references and PLL ratio')
 return bool(errors)
if __name__=='__main__':sys.exit(check())
