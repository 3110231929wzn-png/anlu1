//=============================================================================
//  audio_capture.v : 24 bit PCM 采样窗口采集（512 点，乒乓两个 bank）
//
//  数据来源：hdmi_basic_audio 的 O_audio_left_data / O_audio_valid，
//  与 video_clk 同域（I2S_receiver 本身就是用像素时钟采 I2S 信号的），
//  所以这里没有跨时钟域问题，也不需要异步 FIFO。
//
//  定点：24 bit 有符号 → 右移 9 位取 16 bit。24 bit 满量程 ±8388607 右移 9 位
//  后为 ±16383，正好留出 1 bit 余量给 FFT 第一级蝶形的加法，全程不会溢出。
//
//  为什么写地址要位倒序：
//    radix-2 DIT 的迭代实现要求输入按"位倒序"落位，之后按自然顺序做 9 级蝶形，
//    输出就是自然顺序的频谱。倒序在这里做掉，FFT 核里就不用再算倒序地址。
//
//  乒乓：一帧采满立刻翻转 bank，FFT 去算刚采满的那一块，采集继续写另一块，
//  两边互不干扰（FFT 全程 ~0.65 ms，一帧窗口 10.7 ms，时间上也不冲突）。
//=============================================================================

module audio_capture (
    input  wire        clk,
    input  wire        rst,             // 高有效

    // 来自音频通路
    input  wire        I_valid,         // audio_valid，每个采样点一个单拍脉冲
    input  wire [23:0] I_pcm,           // 左声道 24 bit 有符号

    // 写 bank
    output reg         O_we,
    output reg  [8:0]  O_waddr,
    output reg  [31:0] O_wdata,
    output reg         O_bank,          // 当前正在采的 bank：0 / 1
    output reg         O_wbank,         // 这一拍写使能真正落到哪一块（与 O_we 同拍）

    // 一帧采满
    output reg         O_frame_ready,   // 单拍脉冲
    output reg         O_done_bank      // 刚采满的那一块（与 ready 同拍有效）
);

reg [8:0] cnt;

// 9 bit 位倒序
function [8:0] rev9;
    input [8:0] a;
    begin
        rev9 = {a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8]};
    end
endfunction

always @(posedge clk) begin
    if (rst) begin
        cnt           <= 9'd0;
        O_we          <= 1'b0;
        O_waddr       <= 9'd0;
        O_wdata       <= 32'd0;
        O_bank        <= 1'b0;
        O_wbank       <= 1'b0;
        O_frame_ready <= 1'b0;
        O_done_bank   <= 1'b0;
    end else begin
        O_we          <= 1'b0;
        O_frame_ready <= 1'b0;

        if (I_valid) begin
            O_we    <= 1'b1;
            O_waddr <= rev9(cnt);
            O_wdata <= {16'd0, I_pcm[23], I_pcm[23:9]};   // 实部低 16 位，虚部补 0
            O_wbank <= O_bank;                 // 写使能晚一拍落地，bank 要跟着一起延迟，
                                               // 否则第 512 个点会写进翻转后的新 bank

            if (cnt == 9'd511) begin
                cnt           <= 9'd0;
                O_frame_ready <= 1'b1;
                O_done_bank   <= O_bank;       // 刚写完的是这一块
                O_bank        <= ~O_bank;      // 下一帧换另一块
            end else begin
                cnt <= cnt + 9'd1;
            end
        end
    end
end

endmodule
