//=============================================================================
//  spectrum_top.v : 音频频谱分析前端（PCM -> 32 段柱高）
//
//  一条直线走到底：
//    audio_valid/24bit PCM
//      -> audio_capture（512 点，位倒序落位，乒乓两 bank）
//      -> fft512_core（512 点基-2 DIT，单蝶形迭代，~0.65 ms/帧）
//      -> spectrum_bands（幅度 -> 对数 -> 32 段 + AGC + 平滑）
//      -> O_cur / O_peak（32x8 bit，直接喂 spectrum_render）
//
//  两个 bank 的用法：
//    采集写 bank[cap_bank]，FFT 算 bank[fft_bank]，两者恒为相反的一块。
//    frame_ready 那一拍 bank 翻转，fft_bank 锁到刚采满的那一块，于是采集和
//    计算各用一块、互不踩内存，不需要第三个 bank、也不需要拷贝。
//
//  防死锁：如果音频链路断了（PLL 失锁、I2S 停摆），frame_ready 不再来，
//    柱子会僵在最后一帧。这里用一个 20 ms 超时产生"静音帧"，让 AGC 和
//    柱子照常衰减到 0，屏幕上不会留一屏不动的柱子。
//=============================================================================

module spectrum_top #(
    parameter integer CLK_FREQ  = 25_000_000,
    parameter integer SILENCE_MS = 20
)(
    input  wire        clk,
    input  wire        rst,             // 高有效

    // 音频采样（与 clk 同域，来自 hdmi_basic_audio）
    input  wire        I_audio_valid,
    input  wire [23:0] I_audio_pcm,

    // 输出给渲染模块
    output wire        O_update,
    output reg         O_overrun,
    output wire [255:0] O_cur,
    output wire [255:0] O_peak,
    output wire [7:0]   O_ref,          // AGC 参考（调试用）
    output wire         O_data_ok,      // 已收到至少一帧真实数据
    output wire         O_active        // 有音频在跑（调试用）
);

//-----------------------------------------------------------------------------
//  采集
//-----------------------------------------------------------------------------
wire        cap_we;
wire [8:0]  cap_waddr;
wire [31:0] cap_wdata;
wire        cap_bank;
wire        cap_wbank;
wire        frame_ready;
wire        done_bank;
wire        fft_busy;
wire        fft_done;
wire        bd_busy;
reg         fft_bank;

// Stall only writes that would touch a bank still owned by FFT/band scan.
wire processing = fft_busy | fft_done | bd_busy;
wire capture_blocked = processing && (cap_bank == fft_bank);
wire capture_valid = I_audio_valid && !capture_blocked;

audio_capture u_capture (
    .clk            (clk),
    .rst            (rst),
    .I_valid        (capture_valid),
    .I_pcm          (I_audio_pcm),
    .O_we           (cap_we),
    .O_waddr        (cap_waddr),
    .O_wdata        (cap_wdata),
    .O_bank         (cap_bank),
    .O_wbank        (cap_wbank),
    .O_frame_ready  (frame_ready),
    .O_done_bank    (done_bank)
);

//-----------------------------------------------------------------------------
//  FFT
//-----------------------------------------------------------------------------
wire        fft_start;
wire [8:0]  fft_raddr;
wire [31:0] fft_rdata;
wire        fft_we;
wire [8:0]  fft_waddr;
wire [31:0] fft_wdata;

fft512_core u_fft (
    .clk        (clk),
    .rst        (rst),
    .start      (fft_start),
    .busy       (fft_busy),
    .done       (fft_done),
    .ram_raddr  (fft_raddr),
    .ram_rdata  (fft_rdata),
    .ram_we     (fft_we),
    .ram_waddr  (fft_waddr),
    .ram_wdata  (fft_wdata)
);

//-----------------------------------------------------------------------------
//  32 段
//-----------------------------------------------------------------------------
wire        bd_done;
wire [8:0]  bd_raddr;
reg         silence_tick;

spectrum_bands u_bands (
    .clk        (clk),
    .rst        (rst),
    .start      (fft_done),
    .I_silence  (silence_tick),
    .busy       (bd_busy),
    .done       (bd_done),
    .ram_raddr  (bd_raddr),
    .ram_rdata  (fft_rdata),
    .O_cur      (O_cur),
    .O_peak     (O_peak),
    .O_ref      (O_ref),
    .O_data_ok  (O_data_ok)
);

//-----------------------------------------------------------------------------
//  两个 bank 的端口分配
//    · 写：采集与 FFT 各写一块，用 bank 选通，天然不会撞
//    · 读：只有 FFT / 频带扫描用，选 fft_bank 那一块
//-----------------------------------------------------------------------------
wire [8:0]  ram_raddr = fft_busy ? fft_raddr : bd_raddr;

wire        cap_to_b0 = cap_we & ~cap_wbank;
wire        cap_to_b1 = cap_we &  cap_wbank;
wire        fft_to_b0 = fft_we & ~fft_bank;
wire        fft_to_b1 = fft_we &  fft_bank;

wire [31:0] b0_rdata, b1_rdata;

dpram_512x32 u_bank0 (
    .clk   (clk),
    .we    (cap_to_b0 | fft_to_b0),
    .waddr (cap_to_b0 ? cap_waddr : fft_waddr),
    .wdata (cap_to_b0 ? cap_wdata : fft_wdata),
    .raddr (ram_raddr),
    .rdata (b0_rdata)
);

dpram_512x32 u_bank1 (
    .clk   (clk),
    .we    (cap_to_b1 | fft_to_b1),
    .waddr (cap_to_b1 ? cap_waddr : fft_waddr),
    .wdata (cap_to_b1 ? cap_wdata : fft_wdata),
    .raddr (ram_raddr),
    .rdata (b1_rdata)
);

assign fft_rdata = fft_bank ? b1_rdata : b0_rdata;

//-----------------------------------------------------------------------------
//  帧调度：采满且 FFT 空闲就开算
//-----------------------------------------------------------------------------
assign fft_start = frame_ready && !fft_busy && !bd_busy && !fft_done && !silence_tick;
assign O_update = bd_done;

always @(posedge clk) begin
    if (rst)
        fft_bank <= 1'b0;
    else if (fft_start)
        fft_bank <= done_bank;
end

//-----------------------------------------------------------------------------
//  音频停顿检测：超过 SILENCE_MS 没有新窗口就假装来了一帧静音
//-----------------------------------------------------------------------------
// Counter width supports all practical CLK_FREQ/SILENCE_MS settings.
localparam integer SIL_N = (CLK_FREQ / 1000) * SILENCE_MS;
reg [31:0] idle_cnt;
reg active_r;
always @(posedge clk) begin
    if (rst) begin
        idle_cnt <= 0;
        active_r <= 0;
        silence_tick <= 0;
        O_overrun <= 0;
    end else begin
        silence_tick <= 0;
        if ((I_audio_valid && capture_blocked) || (frame_ready && !fft_start))
            O_overrun <= 1;
        if (frame_ready) begin
            idle_cnt <= 0;
            active_r <= 1;
        end else if (silence_tick) begin
            idle_cnt <= 0;
        end else if (idle_cnt < SIL_N-1) begin
            idle_cnt <= idle_cnt + 1'b1;
        end else if (!fft_busy && !bd_busy && !fft_done) begin
            silence_tick <= 1;
            active_r <= 0;
        end
    end
end
assign O_active = active_r;
endmodule
