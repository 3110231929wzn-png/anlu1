// V3 insertion boundary: post-video_delay gated RGB -> OSD -> original AXIS.
// Zero added pixel latency; metadata channels cannot backpressure playback.
module osd_video(
 input sd_clk,sd_rst,mem_clk,mem_rst,video_clk,video_rst,
 input [2:0] display_page,
 input [1:0] transition_mode,
 input [3:0] image_total,input autoplay,input e3_on,
 input display_enable,I_de,I_hs,I_vs,input [23:0] I_rgb,
 output O_de,O_hs,O_vs,output [23:0] O_rgb
);
 wire [2:0] page;
 wire [1:0] mode;
 wire [3:0] total;
 wire auto_play;
 wire e3_state;
 wire [23:0] overlay_rgb;
 osd_status status(.sd_clk(sd_clk),.sd_rst(sd_rst),.mem_clk(mem_clk),.mem_rst(mem_rst),
   .video_clk(video_clk),.video_rst(video_rst),.video_vs(I_vs),
   .display_page(display_page),.image_total(image_total),.autoplay(autoplay),.transition_mode(transition_mode),
   .e3_on(e3_on),
   .video_page(page),.video_total(total),.video_auto(auto_play),.video_mode(mode),.video_e3(e3_state));
 osd_overlay overlay(.I_clk(video_clk),.I_rst(video_rst),.I_de(I_de),.I_hs(I_hs),.I_vs(I_vs),.I_rgb(I_rgb),
   .O_de(O_de),.O_hs(O_hs),.O_vs(O_vs),.O_rgb(overlay_rgb),
   .I_page(page),.I_total(total),.I_auto(auto_play),.I_mode(mode),.I_e3(e3_state));
 // Keep the existing pre-first-image black screen, including title pixels.
 assign O_rgb=display_enable ? overlay_rgb : 24'd0;
endmodule
