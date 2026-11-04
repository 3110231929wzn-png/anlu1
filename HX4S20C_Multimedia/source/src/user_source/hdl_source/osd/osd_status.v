module osd_status(
 input sd_clk,sd_rst,mem_clk,mem_rst,video_clk,video_rst,video_vs,
 input [2:0] display_page,
 input [1:0] transition_mode,
 input [3:0] image_total,input autoplay,
 input e3_on,
 output reg [2:0] video_page,
 output reg [1:0] video_mode,
 output reg [3:0] video_total,output reg video_auto,output reg video_e3
);
 wire [8:0] player_snapshot;
 wire [1:0] mode_snapshot;
 reg vs_d;
 osd_snapshot_cdc #(.WIDTH(9)) player_mailbox(
   .src_clk(sd_clk),.src_rst(sd_rst),.src_data({e3_on,autoplay,image_total,display_page}),
   .dst_clk(video_clk),.dst_rst(video_rst),.dst_data(player_snapshot));
 osd_snapshot_cdc #(.WIDTH(2)) mode_mailbox(
   .src_clk(mem_clk),.src_rst(mem_rst),.src_data(transition_mode),
   .dst_clk(video_clk),.dst_rst(video_rst),.dst_data(mode_snapshot));
 // V3 640x480 VS is active low. Its rising edge is the end of sync,
 // two blank lines AFTER the read-frame request; plenty of CDC settling time.
 // Page comes from the SD display-confirm observer, never the early load index.
 always @(posedge video_clk or posedge video_rst) begin
   if(video_rst)begin vs_d<=0;video_page<=0;video_total<=0;video_auto<=0;video_mode<=0;video_e3<=0;end
   else begin
     vs_d<=video_vs;
     if(video_vs && !vs_d)begin
       {video_e3,video_auto,video_total,video_page}<=player_snapshot;
       video_mode<=mode_snapshot;
     end
   end
 end
endmodule
