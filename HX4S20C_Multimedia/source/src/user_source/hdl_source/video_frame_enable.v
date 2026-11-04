// Admit the first complete image only at the next frame-read boundary.
module video_frame_enable(
    input wire clk,
    input wire rst,
    input wire async_display_valid,
    input wire frame_req,
    output reg display_enable
);
reg [1:0] valid_sync;
reg frame_req_d;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        valid_sync <= 2'b00;
        frame_req_d <= 1'b0;
        display_enable <= 1'b0;
    end else begin
        valid_sync <= {valid_sync[0], async_display_valid};
        frame_req_d <= frame_req;
        if (frame_req && !frame_req_d)
            display_enable <= valid_sync[1];
    end
end
endmodule
