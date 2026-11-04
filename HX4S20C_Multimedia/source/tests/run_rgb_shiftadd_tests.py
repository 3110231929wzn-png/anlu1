"""One-shot equivalence then selected integration. No TD or board access."""
from pathlib import Path
import argparse,sys
from run_e4_tests import run,ROOT,SRC
def main():
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True)
    p.add_argument('--stage',choices=['equivalence','integration'],required=True);a=p.parse_args()
    if a.stage=='equivalence':
        files=[SRC/'adjust/rgb_adjust.v',SRC/'adjust/rgb_adjust_shiftadd.v']
        name='rgb_shiftadd_equiv'
    else:
        files=[SRC/'adjust'/f for f in ['rgb_adjust.v','rgb_adjust_shiftadd.v','param_ctrl.v','param_osd.v','param_font.v','video_e4.v']]
        files += [SRC/'osd'/f for f in ['osd_overlay.v','osd_font_cn.v','osd_font_5x7.v','osd_video.v','osd_status.v','osd_snapshot_cdc.v']]
        files += [SRC/f for f in ['SD/video_delay.v','video_rgb_to_axis_640x480.v','video_frame_enable.v']]
        name='e4_integration'
    return 0 if run(name,files,a.out.resolve()/name) else 1
if __name__=='__main__':sys.exit(main())
