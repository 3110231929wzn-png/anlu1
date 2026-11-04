// V3 E4 insertion: one pixel register before existing E1, no storage/audio changes.
module video_e4 #(
    parameter integer CTRL_CLK_FREQ = 25_000_000
)(
    input sd_clk,sd_rst,mem_clk,mem_rst,video_clk,video_rst,
    input [2:0] display_page,
    input [1:0] transition_mode,
    input [3:0] image_total,
    input autoplay,display_enable,I_de,I_hs,I_vs,
    input e3_on,
    input [23:0] I_rgb,
    input adjust_select,adjust_key_n,
    output O_de,O_hs,O_vs,
    output [23:0] O_rgb
);
    wire signed [7:0] brightness;
    wire signed [5:0] contrast;
    wire selection;
    wire adjusted_de,adjusted_hs,adjusted_vs;
    wire [23:0] adjusted_rgb,overlay_rgb,panel_rgb;
    wire overlay_de,overlay_hs,overlay_vs;
    reg display_enable_d;

    // Keep the existing frame-admitted display flag aligned with rgb_adjust.
    always @(posedge video_clk or posedge video_rst) begin
        if(video_rst) display_enable_d <= 1'b0;
        else display_enable_d <= display_enable;
    end
    param_ctrl #(.CLK_FREQ(CTRL_CLK_FREQ)) params(
        .clk(video_clk),.rst(video_rst),.I_vs(I_vs),
        .I_sw_sel(adjust_select),.I_key(adjust_key_n),
        .O_bri(brightness),.O_con(contrast),.O_sel(selection)
    );
    rgb_adjust_shiftadd pixels(
        .I_clk(video_clk),.I_rst(video_rst),.I_de(I_de),.I_hs(I_hs),.I_vs(I_vs),
        .I_rgb(I_rgb),.I_bri(brightness),.I_con(contrast),.I_vld(display_enable),
        .O_de(adjusted_de),.O_hs(adjusted_hs),.O_vs(adjusted_vs),.O_rgb(adjusted_rgb)
    );
    // E1 retains its original status mailboxes, page acceptance and FX meaning.
    osd_video u_osd_video(
        .sd_clk(sd_clk),.sd_rst(sd_rst),.mem_clk(mem_clk),.mem_rst(mem_rst),
        .video_clk(video_clk),.video_rst(video_rst),
        .display_page(display_page),.transition_mode(transition_mode),
        .image_total(image_total),.autoplay(autoplay),.e3_on(e3_on),.display_enable(display_enable_d),
        .I_de(adjusted_de),.I_hs(adjusted_hs),.I_vs(adjusted_vs),.I_rgb(adjusted_rgb),
        .O_de(overlay_de),.O_hs(overlay_hs),.O_vs(overlay_vs),.O_rgb(overlay_rgb)
    );
    param_osd panel(
        .I_clk(video_clk),.I_rst(video_rst),.I_de(overlay_de),.I_hs(overlay_hs),.I_vs(overlay_vs),
        .I_rgb(overlay_rgb),.I_bri(brightness),.I_con(contrast),.I_sel(selection),
        .O_de(O_de),.O_hs(O_hs),.O_vs(O_vs),.O_rgb(panel_rgb)
    );
    // Gate AFTER the parameter panel too: no letters before first image.
    assign O_rgb = display_enable_d ? panel_rgb : 24'd0;
endmodule
