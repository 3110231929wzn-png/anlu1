// Reference HDMI test tone; all resets here affect audio only.
// Manufacturer PLL ratio: MCLK=750/61MHz, Fs=MCLK/256=48027.663934Hz.
// Dynamic ACR follows this actual rate; it is not an exact48kHz source.
module hdmi_basic_audio(
    input wire I_refclk,
    input wire I_pixel_clk,
    input wire I_async_rst,
    output wire O_audio_valid,
    output wire [23:0] O_audio_left_data,
    output wire [23:0] O_audio_right_data,
    output wire O_acr_valid,
    output wire [19:0] O_acr_cts,
    output wire [19:0] O_acr_n
);
    wire audio_mclk,audio_pll_lock;
    wire audio_async_rst,rst_audio_mclk,rst_audio_pixel;
    wire audio_i2s_bclk,audio_i2s_lrck,audio_i2s_dout;
    wire pcm_valid,acr_valid;
    wire [23:0] pcm_left,pcm_right;
    wire [19:0] acr_cts,acr_n;

    PLL_HDMI_AUDIO u_audio_pll(
        .refclk(I_refclk),.reset(I_async_rst),.extlock(audio_pll_lock),
        .clk0_out(),.clk1_out(),.clk2_out(audio_mclk)
    );
    assign audio_async_rst=I_async_rst | ~audio_pll_lock;
    reset_release_sync u_audio_mclk_reset(
        .I_clk(audio_mclk),.I_async_rst(audio_async_rst),.O_rst(rst_audio_mclk)
    );
    reset_release_sync u_audio_pixel_reset(
        .I_clk(I_pixel_clk),.I_async_rst(audio_async_rst),.O_rst(rst_audio_pixel)
    );
    hdmi_audio_tone_i2s_64fs u_tone(
        .I_mclk(audio_mclk),.I_rst(rst_audio_mclk),
        .O_i2s_BCLK(audio_i2s_bclk),.O_i2s_LRCK(audio_i2s_lrck),.O_i2s_DOUT(audio_i2s_dout)
    );
    I2S_receiver u_receiver(
        .I_clk(I_pixel_clk),.I_rst(rst_audio_pixel),
        .I_i2s_BCLK(audio_i2s_bclk),.I_i2s_LRCK(audio_i2s_lrck),.I_i2s_DOUT(audio_i2s_dout),
        .O_audio_valid(pcm_valid),.O_audio_left_data(pcm_left),.O_audio_right_data(pcm_right)
    );
    audio_arc_calculate #(.ACR_N(6144)) u_acr(
        .I_clk(I_pixel_clk),.I_rst(rst_audio_pixel),.I_audio_valid(pcm_valid),
        .O_acr_valid(acr_valid),.O_acr_cts(acr_cts),.O_acr_n(acr_n)
    );
    // Do not deliver stale PCM/ACR during audio reset or PLL lock loss.
    assign O_audio_valid=~rst_audio_pixel & pcm_valid;
    assign O_audio_left_data=O_audio_valid ? pcm_left : 24'd0;
    assign O_audio_right_data=O_audio_valid ? pcm_right : 24'd0;
    assign O_acr_valid=~rst_audio_pixel & acr_valid;
    assign O_acr_cts=O_acr_valid ? acr_cts : 20'd0;
    assign O_acr_n=O_acr_valid ? acr_n : 20'd0;
endmodule
