//=============================================================================
//  dpram_512x32.v : 512 深 32 bit 简单双口 RAM（1 写 1 读，读延迟 1 拍）
//
//  用途：频谱前端的采样缓存 / FFT 工作区。
//  一个 bank 存一帧 512 个复数点：{im[31:16], re[15:0]}，采集阶段 im 恒为 0。
//
//  读写在同一个 always 里、读不旁路写（读的是旧值）。FFT 的读地址与写地址永远
//  不会在同一拍命中同一单元（先读后写、跨状态），所以不用做 write-first 旁路。
//=============================================================================

module dpram_512x32 (
    input  wire        clk,

    input  wire        we,
    input  wire [8:0]  waddr,
    input  wire [31:0] wdata,

    input  wire [8:0]  raddr,
    output reg  [31:0] rdata
);

reg [31:0] mem [0:511];

always @(posedge clk) begin
    if (we)
        mem[waddr] <= wdata;
    rdata <= mem[raddr];
end

endmodule
