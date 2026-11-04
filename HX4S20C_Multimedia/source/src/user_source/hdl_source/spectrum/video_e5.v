// Audio analysis is a read-only tap in the existing pixel clock domain.
// Completed band sets enter pending; display changes only on a VS edge.
// Pixel latency is exactly the renderer's two registers.
module video_e5(
    input wire clk, rst,
    input wire I_audio_valid,
    input wire [23:0] I_audio_pcm,
    input wire I_de, I_hs, I_vs,
    input wire [23:0] I_rgb,
    output wire O_de, O_hs, O_vs,
    output wire [23:0] O_rgb
);
    wire [255:0] cur,peak;
    wire [7:0] ref_level;
    wire data_ok,active,update,overrun;
    spectrum_top analyzer(
        .clk(clk),.rst(rst),.I_audio_valid(I_audio_valid),.I_audio_pcm(I_audio_pcm),
        .O_cur(cur),.O_peak(peak),.O_ref(ref_level),.O_data_ok(data_ok),
        .O_active(active),.O_update(update),.O_overrun(overrun)
    );
    reg [255:0] pending_cur,pending_peak,display_cur,display_peak;
    reg pending_ok,display_ok,vs_d;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            pending_cur<=0;pending_peak<=0;display_cur<=0;display_peak<=0;
            pending_ok<=0;display_ok<=0;vs_d<=0;
        end else begin
            vs_d<=I_vs;
            if(update && data_ok) begin
                pending_cur<=cur;pending_peak<=peak;pending_ok<=1;
            end
            // Both VS edges are in vertical blank for this baseline. Select
            // the rising edge; negative/positive sync both give a safe edge.
            if(I_vs && !vs_d) begin
                display_cur<=pending_cur;display_peak<=pending_peak;
                display_ok<=pending_ok;
            end
        end
    end
    spectrum_render renderer(
        .I_clk(clk),.I_rst(rst),.I_de(I_de),.I_hs(I_hs),.I_vs(I_vs),.I_rgb(I_rgb),
        .I_cur(display_cur),.I_peak(display_peak),.I_en(display_ok),
        .O_de(O_de),.O_hs(O_hs),.O_vs(O_vs),.O_rgb(O_rgb)
    );
endmodule
