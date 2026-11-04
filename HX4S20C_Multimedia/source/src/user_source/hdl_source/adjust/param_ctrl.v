//=============================================================================
//  param_ctrl.v : 亮度 / 对比度参数控制（SW3 选参数 + KEY3 按住滑动）
//
//  操作方式：
//    SW3 拨下（0）→ 当前调「亮度」，拨上（1）→ 当前调「对比度」；静态电平，随时可拨
//    KEY3 点一下（<300ms）→ 当前参数 +1 档
//    KEY3 按住            → 300ms 后进入滑动：进滑动先走一步，之后每 30ms 一步，
//                           按住超过 1.5s 提速到 15ms 一步；松手即停，停在当前位置
//    走到头自动回绕（亮度 +64 → -64，对比度 +16 → -16），一个键就能扫完整段范围
//
//  数值范围：
//    亮度   -64 ~ +64（129 档，每档 ±1 级灰度偏移）
//    对比度 -16 ~ +16 编码，增益 = 1 + q/32，即 0.50 ~ 1.50（33 档，每档 3.125%）
//    回到原图：按 KEY1 整机复位，或掉电重来（参数不保存）
//
//  实现要点：
//    1) 全模块只用一个 1ms 时基（25MHz 下 25000 拍），消抖、长按、步进全部按毫秒计数。
//       相比「每种时间各配一个宽计数器」，触发器从 ~105 个降到 ~60 个，
//       video_clk 的负载和时钟树深度都更小——这一版就是为了不给像素时钟域添负担；
//    2) SW3 / KEY3 都是异步输入，各走两级触发器同步；KEY3 再 15ms 消抖，SW3 再 10ms 消抖，
//       避免拨码开关触点抖动在滑动过程中把步进打到另一个参数上；
//    3) 按下瞬间把「这次要调谁」锁进 tgt，整个按压期间不再看 SW3。这样滑动中途拨 SW3
//       不会出现「前半段加亮度、后半段加对比度」的混乱，也不会误改另一个参数；
//    4) 点动与长按都至少 +1 档：进滑动时立刻走一步，不会出现「按了 310ms 什么都没变、
//       按 290ms 反而变了」的怪现象；
//    5) 输出参数在 vs 上升沿整帧锁存，rgb_adjust 与 param_osd 读同一组值，屏幕上写的数
//       就是这一帧真实生效的值，也不会在一帧中间换值把画面拉出一条横向断层。
//=============================================================================

module param_ctrl #(
    parameter integer CLK_FREQ      = 25_000_000,  // video_clk，像素时钟
    parameter integer DEB_MS        = 15,          // KEY3 消抖时间（ms）
    parameter integer SW_DEB_MS     = 10,          // SW3 消抖时间（ms）
    parameter integer HOLD_MS       = 300,         // 长按判定门限（ms）
    parameter integer TICK_MS       = 30,          // 滑动基础步进间隔（ms）
    parameter integer FAST_MS       = 15,          // 提速后的步进间隔（ms）
    parameter integer FAST_AFTER_MS = 1500         // 按住多久开始提速（ms）
)(
    input  wire              clk,
    input  wire              rst,          // 高有效，接 rst_video

    input  wire              I_vs,         // 像素域场同步，用于帧锁存
    input  wire              I_sw_sel,     // SW3：0 = 调亮度，1 = 调对比度（异步）
    input  wire              I_key,        // KEY3：按下为低（异步）

    output reg  signed [7:0] O_bri,        // 亮度偏移，vs 沿更新
    output reg  signed [5:0] O_con,        // 对比度编码 q，vs 沿更新
    output reg               O_sel         // 当前选中的参数，vs 沿更新（0 亮度 / 1 对比度）
);

//-----------------------------------------------------------------------------
//  1ms 时基：整个模块唯一的"慢时钟"，触发器就此一处
//-----------------------------------------------------------------------------
localparam integer MS_N = CLK_FREQ / 1000;      // 25MHz → 25000 拍

reg [14:0] ms_cnt;
reg        tick1ms;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        ms_cnt  <= 15'd0;
        tick1ms <= 1'b0;
    end else if (ms_cnt >= MS_N - 1) begin
        ms_cnt  <= 15'd0;
        tick1ms <= 1'b1;
    end else begin
        ms_cnt  <= ms_cnt + 15'd1;
        tick1ms <= 1'b0;
    end
end

//-----------------------------------------------------------------------------
//  异步输入同步（两级触发器）
//-----------------------------------------------------------------------------
reg sw_s1, sw_s2;
reg key_s1, key_s2;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sw_s1  <= 1'b0;
        sw_s2  <= 1'b0;
        key_s1 <= 1'b1;          // 按键松开为高
        key_s2 <= 1'b1;
    end else begin
        sw_s1  <= I_sw_sel;
        sw_s2  <= sw_s1;
        key_s1 <= I_key;
        key_s2 <= key_s1;
    end
end

//-----------------------------------------------------------------------------
//  电平消抖：按毫秒计数，连续稳定够久才认账（KEY3 与 SW3 各一份，互不影响）
//-----------------------------------------------------------------------------
reg       key_st;                // 消抖后的按键电平：1 = 松开，0 = 按下
reg [7:0] kdb_ms;
reg       key_st_d;              // 上一拍，用来抓下降沿

always @(posedge clk or posedge rst) begin
    if (rst) begin
        key_st   <= 1'b1;
        key_st_d <= 1'b1;
        kdb_ms   <= 8'd0;
    end else begin
        key_st_d <= key_st;
        if (tick1ms) begin
            if (key_s2 != key_st) begin
                if (kdb_ms >= DEB_MS - 1) begin
                    kdb_ms <= 8'd0;
                    key_st <= key_s2;
                end else begin
                    kdb_ms <= kdb_ms + 8'd1;
                end
            end else begin
                kdb_ms <= 8'd0;
            end
        end
    end
end

reg       sw_st;                 // 消抖后的 SW3 电平
reg [7:0] sdb_ms;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sw_st  <= 1'b0;
        sdb_ms <= 8'd0;
    end else if (tick1ms) begin
        if (sw_s2 != sw_st) begin
            if (sdb_ms >= SW_DEB_MS - 1) begin
                sdb_ms <= 8'd0;
                sw_st  <= sw_s2;
            end else begin
                sdb_ms <= sdb_ms + 8'd1;
            end
        end else begin
            sdb_ms <= 8'd0;
        end
    end
end

wire key_press = key_st_d & ~key_st;     // 按下瞬间的单拍脉冲

//-----------------------------------------------------------------------------
//  参数工作值（vs 之前先改这里，再由 vs 沿搬到输出）
//-----------------------------------------------------------------------------
reg signed [7:0] bri_acc;
reg signed [5:0] con_acc;
reg              tgt;                    // 本次按压锁定的目标参数：0 亮度 / 1 对比度

// 走一步（到端点回绕）
task do_step;
    begin
        if (tgt) begin
            if (con_acc == 6'sd16)
                con_acc <= -6'sd16;
            else
                con_acc <= con_acc + 6'sd1;
        end else begin
            if (bri_acc == 8'sd64)
                bri_acc <= -8'sd64;
            else
                bri_acc <= bri_acc + 8'sd1;
        end
    end
endtask

//-----------------------------------------------------------------------------
//  状态机（全部按 1ms 节拍推进）
//    IDLE  : 等按下，按下瞬间锁存目标参数
//    HOLD  : 量按压时长；300ms 内松手 = 点动，走一步
//    SLIDE : 进状态即走一步，之后每 TICK/FAST 毫秒走一步，松手停住
//-----------------------------------------------------------------------------
localparam [1:0] ST_IDLE  = 2'd0;
localparam [1:0] ST_HOLD  = 2'd1;
localparam [1:0] ST_SLIDE = 2'd2;

reg [1:0]  st;
reg [10:0] hold_ms;              // 按住时长，最大记到 1500+，11 位够（0~2047）
reg [4:0]  step_ms;              // 步进节拍计数，最大 30，5 位够（0~31）

localparam [4:0]  TICK_PERIOD = TICK_MS;
localparam [4:0]  FAST_PERIOD = FAST_MS;
localparam [10:0] HOLD_LIMIT  = HOLD_MS;

wire [4:0] step_period = (hold_ms >= FAST_AFTER_MS) ? FAST_PERIOD : TICK_PERIOD;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        st       <= ST_IDLE;
        hold_ms  <= 11'd0;
        step_ms  <= 5'd0;
        bri_acc  <= 8'sd0;
        con_acc  <= 6'sd0;
        tgt      <= 1'b0;
    end else begin
        case (st)
            ST_IDLE: begin
                hold_ms <= 11'd0;
                step_ms <= 5'd0;
                if (key_press) begin
                    st  <= ST_HOLD;
                    tgt <= sw_st;              // 本次按压只看按下的那一刻
                end
            end

            ST_HOLD: begin
                if (!key_st) begin             // 还按着，继续量
                    if (tick1ms) begin
                        if (hold_ms >= HOLD_LIMIT - 11'd1) begin
                            st       <= ST_SLIDE;
                            hold_ms  <= HOLD_LIMIT;
                            step_ms  <= 5'd0;
                            do_step;               // 进滑动先走一步，点动/长按都不落空
                        end else begin
                            hold_ms <= hold_ms + 11'd1;
                        end
                    end
                end else begin                 // 300ms 内松手：点动走一步
                    st <= ST_IDLE;
                    do_step;
                end
            end

            ST_SLIDE: begin
                if (key_st) begin              // 松手，停在当前值
                    st      <= ST_IDLE;
                    hold_ms <= 11'd0;
                    step_ms <= 5'd0;
                end else if (tick1ms) begin
                    if (hold_ms != 11'h7FF)    // 饱和，别回绕
                        hold_ms <= hold_ms + 11'd1;

                    if (step_ms >= step_period - 5'd1) begin
                        step_ms <= 5'd0;
                        do_step;
                    end else begin
                        step_ms <= step_ms + 5'd1;
                    end
                end
            end

            default: st <= ST_IDLE;
        endcase
    end
end

//-----------------------------------------------------------------------------
//  帧锁存：vs 上升沿把工作值搬到输出，整帧一套参数
//  高亮跟着「正在调谁」走：按住期间显示 tgt，松开后回到 SW3 的实时位置
//-----------------------------------------------------------------------------
reg vs_d;

always @(posedge clk or posedge rst) begin
    if (rst)
        vs_d <= 1'b0;
    else
        vs_d <= I_vs;
end

wire vs_rise = I_vs & ~vs_d;
wire sel_now = (st == ST_IDLE) ? sw_st : tgt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        O_bri <= 8'sd0;
        O_con <= 6'sd0;
        O_sel <= 1'b0;
    end else if (vs_rise) begin
        O_bri <= bri_acc;
        O_con <= con_acc;
        O_sel <= sel_now;
    end
end

endmodule
