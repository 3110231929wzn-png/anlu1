//=============================================================================
//  fft512_core.v : 512 点基-2 DIT 定点 FFT 核（单蝶形迭代，无流水线并行）
//
//  为什么选 512 点：
//    Fs = 48027.66 Hz，512 点对应 bin 宽度 93.8 Hz、窗口 10.66 ms，
//    一帧刚好覆盖一次显示刷新期，也够把低频几段分开；点数再大 BRAM 和
//    蝶形次数都要翻倍，而 32 段柱状图并不需要那么细的分辨率。
//
//  结构：
//    一块 512x32 的 RAM 存复数（{im, re}），本核用"单蝶形 + 迭代"的方式跑，
//    9 级 × 256 个蝶形 = 2304 个蝶形，每个蝶形 7 拍，共 ~16.1k 拍，
//    25 MHz 下约 0.65 ms 算完一帧（一帧窗口 10.66 ms，占用率 6%）。
//    资源上只用了 4 个 16x16 乘法（推 2~4 个 DSP），不占额外 BRAM 做乒乓。
//
//  定点约定（与 doc/python/model_check.py 逐位一致）：
//    * 数据 16 bit 有符号，旋转因子 Q15
//    * t = b*w，乘积加 16384 后算术右移 15 位（四舍五入）
//    * 蝶形输出再右移 1 位，9 级累计缩比 1/512，保证不溢出
//    * 收尾做 16 bit 饱和（正常数据到不了饱和，纯属保险）
//
//  地址生成（不用除法、不用变量移位）：
//    half       = 2^(stage-1)，本级蝶形跨度的一半
//    第 g 组第 j 个蝶形：addr_a = g*2*half + j，addr_b = addr_a + half
//    tw_idx    = j * (256/half)
//    g*2*half 用 base 累加，j*(256/half) 用 tw_idx 累加，两者都是加法器。
//=============================================================================

module fft512_core (
    input  wire        clk,
    input  wire        rst,          // 高有效

    input  wire        start,        // 单拍脉冲，busy 期间忽略
    output reg         busy,
    output reg         done,         // 单拍脉冲

    // 数据 RAM 接口（bank 由上层选通）
    output reg  [8:0]  ram_raddr,
    input  wire [31:0] ram_rdata,
    output reg         ram_we,
    output reg  [8:0]  ram_waddr,
    output reg  [31:0] ram_wdata
);

localparam integer N      = 512;
localparam integer STAGES = 9;

//-----------------------------------------------------------------------------
//  状态
//-----------------------------------------------------------------------------
localparam [2:0] ST_IDLE = 3'd0,
                 ST_A    = 3'd1,   // 发 addr_a / 旋转因子地址
                 ST_B    = 3'd2,   // 发 addr_b（此时 ram_rdata 才刚拿到 a）
                 ST_C    = 3'd3,   // 收 a 与 w
                 ST_D    = 3'd4,   // 收 b
                 ST_E    = 3'd5,   // 乘加，算出两个输出
                 ST_F    = 3'd6,   // 写回 a'
                 ST_G    = 3'd7;   // 写回 b' + 更新计数器

reg [2:0]  st;

//-----------------------------------------------------------------------------
//  计数器
//-----------------------------------------------------------------------------
reg [3:0]  stage;        // 1 ~ 9
reg [8:0]  half;         // 1,2,4,...,256
reg [8:0]  tw_step;      // 256,128,...,1
reg [8:0]  base;         // 当前组的起始地址
reg [7:0]  off;          // 组内第几个蝶形
reg [8:0]  tw_idx;       // 旋转因子下标
reg [8:0]  groups_left;  // 本级还剩几组
reg [8:0]  groups_num;   // 本级一共几组（= 256/half），换级时要靠它算下一级

//-----------------------------------------------------------------------------
//  地址
//-----------------------------------------------------------------------------
wire [8:0] addr_a = base + {1'b0, off};
wire [8:0] addr_b = addr_a + half;

//-----------------------------------------------------------------------------
//  旋转因子 ROM（同步读，地址由这里给）
//-----------------------------------------------------------------------------
reg  [7:0]  tw_addr;
wire [31:0] tw_data;

fft_tw_rom u_tw_rom (
    .clk  (clk),
    .addr (tw_addr),
    .data (tw_data)
);

//-----------------------------------------------------------------------------
//  数据通路寄存器
//-----------------------------------------------------------------------------
reg signed [15:0] a_re, a_im;
reg signed [15:0] b_re, b_im;
reg signed [15:0] tw_re, tw_im;

// t = b * w（Q15 乘法，四舍五入右移 15 位）
wire signed [15:0] b_re_s = b_re;
wire signed [15:0] b_im_s = b_im;
// Each 16x16 product is signed32; complex sum/difference needs 33 bits.
wire signed [31:0] m_rr = b_re_s * tw_re;
wire signed [31:0] m_ii = b_im_s * tw_im;
wire signed [31:0] m_ri = b_re_s * tw_im;
wire signed [31:0] m_ir = b_im_s * tw_re;
wire signed [32:0] p_re = $signed({m_rr[31],m_rr}) - $signed({m_ii[31],m_ii});
wire signed [32:0] p_im = $signed({m_ri[31],m_ri}) + $signed({m_ir[31],m_ir});
wire signed [33:0] p_re_r = $signed({p_re[32],p_re}) + 34'sd16384;
wire signed [33:0] p_im_r = $signed({p_im[32],p_im}) + 34'sd16384;
wire signed [18:0] t_re = p_re_r[33:15];
wire signed [18:0] t_im = p_im_r[33:15];

// 蝶形：a' = (a+t)/2，b' = (a-t)/2
wire signed [18:0] s_re = a_re + t_re;
wire signed [18:0] s_im = a_im + t_im;
wire signed [18:0] d_re = a_re - t_re;
wire signed [18:0] d_im = a_im - t_im;

function [15:0] sat16;
    input signed [18:0] v;
    begin
        if (v > 19'sd32767)
            sat16 = 16'sh7FFF;
        else if (v < -19'sd32768)
            sat16 = 16'sh8000;
        else
            sat16 = v[15:0];
    end
endfunction

reg [31:0] wd_a, wd_b;

//-----------------------------------------------------------------------------
//  是否最后一个蝶形（本级最后一组的最后一个）
//-----------------------------------------------------------------------------
wire last_group = (groups_left == 9'd1);
wire last_in_gr = ({1'b0, off} == (half - 9'd1));
wire last_bf    = (stage == 4'd9) && last_group && last_in_gr;

//-----------------------------------------------------------------------------
//  主状态机
//-----------------------------------------------------------------------------
always @(posedge clk) begin
    if (rst) begin
        st          <= ST_IDLE;
        busy        <= 1'b0;
        done        <= 1'b0;
        stage       <= 4'd1;
        half        <= 9'd1;
        tw_step     <= 9'd256;
        base        <= 9'd0;
        off         <= 8'd0;
        tw_idx      <= 9'd0;
        groups_left <= 9'd256;
        groups_num  <= 9'd256;
        ram_raddr   <= 9'd0;
        ram_we      <= 1'b0;
        ram_waddr   <= 9'd0;
        ram_wdata   <= 32'd0;
        tw_addr     <= 8'd0;
        a_re <= 16'sd0; a_im <= 16'sd0;
        b_re <= 16'sd0; b_im <= 16'sd0;
        tw_re <= 16'sd0; tw_im <= 16'sd0;
        wd_a <= 32'd0; wd_b <= 32'd0;
    end else begin
        done    <= 1'b0;
        ram_we  <= 1'b0;

        case (st)
            //-------------------------------------------------------------
            ST_IDLE: begin
                if (start) begin
                    busy        <= 1'b1;
                    stage       <= 4'd1;
                    half        <= 9'd1;
                    tw_step     <= 9'd256;
                    base        <= 9'd0;
                    off         <= 8'd0;
                    tw_idx      <= 9'd0;
                    groups_left <= 9'd256;
                    groups_num  <= 9'd256;
                    st          <= ST_A;
                end
            end

            //-------------------------------------------------------------
            //  BRAM 读延迟 1 拍：本拍发出的地址，下一拍 ram_rdata 才有效，
            //  所以 a 要在 ST_C 收、b 要在 ST_D 收，不能提前。
            //-------------------------------------------------------------
            ST_A: begin
                ram_raddr <= addr_a;
                tw_addr   <= tw_idx[7:0];
                st        <= ST_B;
            end

            //-------------------------------------------------------------
            ST_B: begin
                ram_raddr <= addr_b;
                st        <= ST_C;
            end

            //-------------------------------------------------------------
            ST_C: begin
                a_re  <= ram_rdata[15:0];
                a_im  <= ram_rdata[31:16];
                tw_re <= tw_data[31:16];
                tw_im <= tw_data[15:0];
                st    <= ST_D;
            end

            //-------------------------------------------------------------
            ST_D: begin
                b_re <= ram_rdata[15:0];
                b_im <= ram_rdata[31:16];
                st   <= ST_E;
            end

            //-------------------------------------------------------------
            ST_E: begin
                wd_a <= {sat16(s_im >>> 1), sat16(s_re >>> 1)};
                wd_b <= {sat16(d_im >>> 1), sat16(d_re >>> 1)};
                st   <= ST_F;
            end

            //-------------------------------------------------------------
            ST_F: begin
                ram_we    <= 1'b1;
                ram_waddr <= addr_a;
                ram_wdata <= wd_a;
                st        <= ST_G;
            end

            //-------------------------------------------------------------
            //  写 addr_b 与更新计数器同拍：地址/数据都在上一拍锁存好了，
            //  这里改 base/off 不会影响本次写。
            //-------------------------------------------------------------
            ST_G: begin
                ram_we    <= 1'b1;
                ram_waddr <= addr_b;
                ram_wdata <= wd_b;

                if (last_bf) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    st   <= ST_IDLE;
                end else if (last_in_gr) begin
                    off    <= 8'd0;
                    tw_idx <= 9'd0;
                    if (last_group) begin
                        // 本级做完，进下一级
                        base        <= 9'd0;
                        // 下一级组数 = 本级组数/2；用 groups_num 而不是 groups_left，
                        // 因为此刻 groups_left 已经减到 1 了，再右移就变成 0。
                        groups_left <= groups_num >> 1;
                        groups_num  <= groups_num >> 1;
                        half        <= half << 1;
                        tw_step     <= tw_step >> 1;
                        stage       <= stage + 4'd1;
                    end else begin
                        base        <= base + {half[7:0], 1'b0};
                        groups_left <= groups_left - 9'd1;
                    end
                    st <= ST_A;
                end else begin
                    off    <= off + 8'd1;
                    tw_idx <= tw_idx + tw_step;
                    st     <= ST_A;
                end
            end

            default: st <= ST_IDLE;
        endcase
    end
end

endmodule
