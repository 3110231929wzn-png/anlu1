// Asynchronous assertion, two local clock edges before reset release.
module reset_release_sync(
    input wire I_clk,
    input wire I_async_rst,
    output wire O_rst
);
reg [1:0] release_pipe = 2'b11;
always @(posedge I_clk or posedge I_async_rst) begin
    if (I_async_rst)
        release_pipe <= 2'b11;
    else
        release_pipe <= {release_pipe[0], 1'b0};
end
assign O_rst = release_pipe[1];
endmodule
