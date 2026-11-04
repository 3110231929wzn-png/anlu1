//=============================================================================
//  spectrum_bands.v : 频谱幅度 -> 32 段柱高（含 AGC、平滑、峰值保持）
//
//  在 FFT 算完之后启动，分三步走：
//    P_SCAN  逐 bin（1~255）读幅度，按 band_map_rom 归到 32 段里的某一段，
//            段内取最大值。逐 bin 顺序扫描 + 当前段内累积，不需要按段随机寻址。
//    P_AGC   整帧只更新一次自动增益参考 ref：上来就跟峰，之后每帧掉 1 级。
//    P_APPLY 32 段逐段算高度：窗口 = ref 下方 64 个 level 单位（≈24 dB），
//            命中即时上升、松手指数衰减、峰值帽每帧 -1。
//
//  为什么要有 AGC 和窗口：
//    FFT 用矩形窗，正弦的旁瓣泄漏大约只低 25~30 dB，如果按绝对电平画，
//    整排柱子会有一条 40% 高的"地摊"，主峰也不一定顶满。把显示窗口压在
//    峰值下方 24 dB、并让窗口跟着峰值走，既能把泄漏压到 0，又能在换曲子、
//    换音量时自动适应，不用手工调增益。
//
//  level8 = {4 bit 指数, 4 bit 尾数}，每 1 个指数步 = 6.02 dB，所以
//  64 个 level 单位 ≈ 4 个指数步 ≈ 24 dB，正好是窗口宽度。
//=============================================================================

module spectrum_bands (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,        // 单拍，FFT done
    input  wire        I_silence,    // 单拍，音频停摆时由上层补的"静音帧"
    output reg         busy,
    output reg         done,

    // 读 FFT 结果（bank 由上层选通）
    output reg  [8:0]  ram_raddr,
    input  wire [31:0] ram_rdata,

    // 对外：32 段当前高度 / 峰值帽高度，各 8 bit × 32
    output wire [255:0] O_cur,
    output wire [255:0] O_peak,

    // 调试/显示：AGC 参考电平
    output reg  [7:0]  O_ref,

    // 已经跑完至少一帧真实数据（渲染级用它屏蔽上电初期的随机柱高）
    output reg         O_data_ok
);

localparam integer NB      = 32;
localparam integer MAX_H   = 116;   // 柱高上限（像素）
localparam integer AGC_WIN = 64;    // 显示窗口宽度（level 单位）
localparam integer AGC_MIN = 48;    // 低于此电平当静音，柱子归零
localparam integer H_SLOPE = 29;    // 116/64 ≈ 1.8125

//-----------------------------------------------------------------------------
//  幅度近似：max + min/2（免开方，最大偏差 11.8%）
//-----------------------------------------------------------------------------
function [15:0] mag16;
    input signed [15:0] r;
    input signed [15:0] i;
    reg [16:0] a, b, m, t;
    begin
        a = r[15] ? (17'd0 - {r[15], r}) : {1'b0, r};
        b = i[15] ? (17'd0 - {i[15], i}) : {1'b0, i};
        if (a < b) begin t = a; a = b; b = t; end
        m = a + (b >> 1);
        mag16 = (m > 17'd32767) ? 16'h7FFF : m[15:0];
    end
endfunction

//-----------------------------------------------------------------------------
//  对数编码：4 bit 指数 + 4 bit 尾数
//-----------------------------------------------------------------------------
function [7:0] log8;
    input [15:0] v;
    reg [3:0]  e;
    reg [4:0]  sh;
    reg [15:0] n;
    begin
        if      (v[15]) e = 4'd15;
        else if (v[14]) e = 4'd14;
        else if (v[13]) e = 4'd13;
        else if (v[12]) e = 4'd12;
        else if (v[11]) e = 4'd11;
        else if (v[10]) e = 4'd10;
        else if (v[9])  e = 4'd9;
        else if (v[8])  e = 4'd8;
        else if (v[7])  e = 4'd7;
        else if (v[6])  e = 4'd6;
        else if (v[5])  e = 4'd5;
        else if (v[4])  e = 4'd4;
        else if (v[3])  e = 4'd3;
        else if (v[2])  e = 4'd2;
        else if (v[1])  e = 4'd1;
        else            e = 4'd0;

        sh = 5'd15 - {1'b0, e};
        n  = v << sh;                    // 归一化到 bit14 为最高位
        log8 = {e, n[14:11]};
    end
endfunction

//-----------------------------------------------------------------------------
//  内部存储
//-----------------------------------------------------------------------------
reg [7:0] lv  [0:NB-1];      // 本帧各段电平
reg [7:0] cur [0:NB-1];      // 平滑后的柱高
reg [7:0] pk  [0:NB-1];      // 峰值帽

reg [7:0] ref_r;             // AGC 参考
reg [7:0] gmax;              // 本帧最大电平
reg       silence_f;         // 静音帧标志：本帧所有目标高度强制为 0

//-----------------------------------------------------------------------------
//  状态
//-----------------------------------------------------------------------------
localparam [2:0] P_IDLE  = 3'd0,
                 P_WAIT1 = 3'd1,   // 发地址那一拍之后先空等一拍（BRAM 读延迟 1 拍）
                 P_WAIT2 = 3'd2,   // 这时 ram_rdata 才是 bin 号对应的数据
                 P_FLUSH = 3'd3,   // 补写最后一段
                 P_AGC   = 3'd4,
                 P_APPLY = 3'd5;

reg [2:0] ph;
reg [8:0] bin;
reg [5:0] cb;                // 当前段号
reg [7:0] acc;               // 段内累积最大值
reg [5:0] flush_band;
reg [7:0] flush_val;
reg [5:0] ab;                // APPLY 的段计数器

wire [4:0] band_of_bin;
band_map_rom u_band_map (
    .bin  (bin[7:0]),
    .band (band_of_bin)
);

//-----------------------------------------------------------------------------
//  APPLY 段的组合运算
//-----------------------------------------------------------------------------
wire [7:0] off_w = (ref_r > AGC_WIN) ? (ref_r - AGC_WIN) : 8'd0;

wire [7:0] lv_b   = lv[ab];
wire [7:0] cur_b  = O_data_ok ? cur[ab] : 8'd0;
wire [7:0] pk_b   = O_data_ok ? pk[ab] : 8'd0;

wire [7:0]  d_w    = (lv_b > off_w) ? (lv_b - off_w) : 8'd0;
wire [15:0] h16    = d_w * H_SLOPE;                // 最大 255*29 = 7395
wire [8:0]  hgt_w  = h16[12:4];                    // (d*29)>>4，最大 462
wire [7:0]  tgt_w  = (ref_r < AGC_MIN || silence_f) ? 8'd0 :
                     (hgt_w > MAX_H)                ? MAX_H[7:0] : hgt_w[7:0];

wire [7:0] decay  = (cur_b >> 3) + 8'd1;
wire [7:0] cur_nx = (tgt_w >= cur_b) ? tgt_w :
                    (cur_b > decay)   ? (cur_b - decay) : 8'd0;
wire [7:0] pk_nx  = (cur_nx >= pk_b) ? cur_nx :
                    ((pk_b > 8'd0) ? (pk_b - 8'd1) : 8'd0);

//-----------------------------------------------------------------------------
//  主流程
//-----------------------------------------------------------------------------
reg [7:0]  lv_bin;
wire [15:0] mag_w = mag16(ram_rdata[15:0], ram_rdata[31:16]);
wire [7:0]  lv_w  = log8(mag_w);

always @(posedge clk) begin
    if (rst) begin
        ph         <= P_IDLE;
        busy       <= 1'b0;
        done       <= 1'b0;
        bin        <= 9'd1;
        cb         <= 6'd0;
        acc        <= 8'd0;
        gmax       <= 8'd0;
        ref_r      <= 8'd0;
        silence_f  <= 1'b0;
        O_ref      <= 8'd0;
        O_data_ok  <= 1'b0;
        ab         <= 6'd0;
        flush_band <= 6'd32;
        flush_val  <= 8'd0;
        ram_raddr  <= 9'd0;
        lv_bin     <= 8'd0;
    end else begin
        done <= 1'b0;

        case (ph)
            //-------------------------------------------------------------
            P_IDLE: begin
                if (start) begin
                    busy      <= 1'b1;
                    bin       <= 9'd1;
                    cb        <= 6'd0;
                    acc       <= 8'd0;
                    gmax      <= 8'd0;
                    silence_f <= 1'b0;
                    ram_raddr <= 9'd1;
                    ph        <= P_WAIT1;
                end else if (I_silence) begin
                    // 音频停摆：不扫 bin，直接走 AGC + 衰减
                    busy       <= 1'b1;
                    gmax       <= 8'd0;
                    silence_f  <= 1'b1;
                    flush_band <= 6'd32;      // 没有要补写的段
                    ph         <= P_FLUSH;
                end
            end

            //-------------------------------------------------------------
            //  空等一拍：地址在上一拍已经发出，这一拍末 ram_rdata 才更新
            //-------------------------------------------------------------
            P_WAIT1: begin
                ph <= P_WAIT2;
            end

            //-------------------------------------------------------------
            //  处理 bin（此时 bin 与 ram_rdata 是同一个下标）
            //-------------------------------------------------------------
            P_WAIT2: begin
                lv_bin <= lv_w;

                if (gmax < lv_w)
                    gmax <= lv_w;

                if ({1'b0, band_of_bin} != cb) begin
                    // 换段：收口上一段，当前 bin 起头新段
                    lv[cb] <= acc;
                    cb     <= {1'b0, band_of_bin};
                    acc    <= lv_w;
                end else if (lv_w > acc) begin
                    acc <= lv_w;
                end

                if (bin == 9'd255) begin
                    // 最后一 bin：把结果补写到位再进 AGC
                    if ({1'b0, band_of_bin} != cb) begin
                        lv[cb]        <= acc;
                        flush_band    <= {1'b0, band_of_bin};
                        flush_val     <= lv_w;
                    end else begin
                        lv[cb]        <= (lv_w > acc) ? lv_w : acc;
                        flush_band    <= 6'd32;      // 无效
                    end
                    ph <= P_FLUSH;
                end else begin
                    bin       <= bin + 9'd1;
                    ram_raddr <= bin + 9'd1;
                    ph        <= P_WAIT1;
                end
            end

            //-------------------------------------------------------------
            P_FLUSH: begin
                if (flush_band < 6'd32)
                    lv[flush_band] <= flush_val;

                // AGC 更新：跟峰快、回落慢
                if (gmax > ref_r)
                    ref_r <= gmax;
                else if (ref_r > 8'd1)
                    ref_r <= ref_r - 8'd1;

                O_ref <= gmax;
                ph    <= P_AGC;
            end

            //-------------------------------------------------------------
            P_AGC: begin
                ab <= 6'd0;
                ph <= P_APPLY;
            end

            //-------------------------------------------------------------
            P_APPLY: begin
                cur[ab] <= cur_nx;
                pk[ab]  <= pk_nx;
                if (ab == NB - 1) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    if (!silence_f)
                        O_data_ok <= 1'b1;      // 真帧才算，静音补帧不算
                    ph   <= P_IDLE;
                end else begin
                    ab <= ab + 6'd1;
                end
            end

            default: ph <= P_IDLE;
        endcase
    end
end

//-----------------------------------------------------------------------------
//  对外拼成 256 bit（低 8 位是第 0 段），渲染模块用 idx*8 +: 8 取
//-----------------------------------------------------------------------------
genvar gi;
generate
    for (gi = 0; gi < NB; gi = gi + 1) begin : g_pack
        assign O_cur [gi*8 +: 8] = cur[gi];
        assign O_peak[gi*8 +: 8] = pk[gi];
    end
endgenerate

endmodule
