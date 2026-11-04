`timescale 1ns/1ps
// Independent integer oracle + hand-calculated fixtures. No SDRAM/FIFO/IP.
// Catches wrong boundary comparisons, slide coordinate wrap, fade overflow,
// channel mixup, missing progress endpoints and stale combinational outputs.
module tb_transition_pixels;
    reg [1:0] mode;
    reg [6:0] progress;
    reg [9:0] x;
    reg [8:0] y;
    reg [23:0] old_rgb, new_rgb;
    wire [23:0] rgb;
    wire [9:0] old_x, new_x;
    wire [8:0] source_y;
    wire old_needed, new_needed, valid;
    integer checks[0:3], mode_failures[0:3], failures=0, total=0, directed=0;
    integer m,p,xx,yy,row,edge_x,ov,nv;

    transition_pixels dut(
        .I_mode(mode), .I_progress(progress), .I_x(x), .I_y(y),
        .I_old_rgb(old_rgb), .I_new_rgb(new_rgb), .O_rgb(rgb),
        .O_old_x(old_x), .O_new_x(new_x), .O_source_y(source_y),
        .O_old_needed(old_needed), .O_new_needed(new_needed), .O_valid(valid)
    );

    function [23:0] pattern(input bit n,input integer sx,input integer sy);
        // Injective within each 640x480 source and distinct between sources.
        pattern=(n ? 24'h800000 : 24'h100000) | (sy*640+sx);
    endfunction

    task automatic check_pixel(
        input integer tm,tp,tx,ty,
        input bit literal_pixels,
        input [23:0] old_literal,new_literal,
        input bit fixture,
        input [23:0] fixture_rgb,
        input string label_text
    );
        integer cp,k,cut,ox,nx,sy,r,g,b;
        bit ev,eo,en,choose_new;
        reg [23:0] a,bp,expected;
        begin
            mode=tm;progress=tp;x=tx;y=ty;
            cp=(tp>64)?64:tp;
            k=640*cp/64; cut=480*cp/64;
            ev=(tx<640 && ty<480);
            ox=0;nx=0;sy=0;eo=0;en=0;choose_new=0;
            if(ev) begin
                sy=ty;
                case(tm)
                    0: begin choose_new=tx<k;eo=!choose_new;en=choose_new;end
                    1: begin choose_new=ty<cut;eo=!choose_new;en=choose_new;end
                    2: begin choose_new=tx+ k>=640;eo=!choose_new;en=choose_new;end
                    3: begin eo=cp<64;en=cp>0;end
                endcase
                if(eo) ox=(tm==2)?tx+k:tx;
                if(en) nx=(tm==2)?tx+k-640:tx;
            end
            #1;
            // Feed DUT using its advertised source coordinates, then compare
            // against an independently derived spatial pattern and RGB oracle.
            old_rgb=literal_pixels?old_literal:pattern(0,old_x,source_y);
            new_rgb=literal_pixels?new_literal:pattern(1,new_x,source_y);
            a=literal_pixels?old_literal:pattern(0,ox,sy);
            bp=literal_pixels?new_literal:pattern(1,nx,sy);
            if(!ev) expected=0;
            else if(tm==3 && cp==0) expected=a;
            else if(tm==3 && cp==64) expected=bp;
            else if(tm==3) begin
                r=(integer'(a[23:16])*(64-cp)+integer'(bp[23:16])*cp)/64;
                g=(integer'(a[15:8])*(64-cp)+integer'(bp[15:8])*cp)/64;
                b=(integer'(a[7:0])*(64-cp)+integer'(bp[7:0])*cp)/64;
                expected={r[7:0],g[7:0],b[7:0]};
            end else expected=choose_new?bp:a;
            #1;
            total++;checks[tm]++;
            if(valid!==ev || old_needed!==eo || new_needed!==en ||
               old_x!==10'(ox) || new_x!==10'(nx) || source_y!==9'(sy) ||
               rgb!==expected || (fixture && rgb!==fixture_rgb)) begin
                failures++;mode_failures[tm]++;
                if(failures<=20)
                    $display("MISMATCH %s mode=%0d p=%0d xy=%0d,%0d expected_rgb=%h actual_rgb=%h expected_src=%0d,%0d,%0d actual_src=%0d,%0d,%0d expected_flags=%b%b%b actual_flags=%b%b%b",
                        label_text,tm,tp,tx,ty,expected,rgb,ox,nx,sy,old_x,new_x,source_y,ev,eo,en,valid,old_needed,new_needed);
            end
            if((old_needed && (old_x>=640 || source_y>=480 || source_y*640+old_x>307199)) ||
               (new_needed && (new_x>=640 || source_y>=480 || source_y*640+new_x>307199))) begin
                failures++;mode_failures[tm]++;$display("ADDRESS_RANGE_FAILURE %s",label_text);
            end
            if(fixture) begin
                directed++;
                $display("FIXTURE %s mode=%0d p=%0d xy=%0d,%0d expected=%h actual=%h old_x=%0d new_x=%0d flags=%b%b%b",
                    label_text,tm,tp,tx,ty,fixture_rgb,rgb,old_x,new_x,valid,old_needed,new_needed);
            end
        end
    endtask

    initial begin
        for(m=0;m<4;m++) begin checks[m]=0;mode_failures[m]=0;end
        // RGB literals also prove that selection uses the supplied pixel ports.
        for(m=0;m<4;m++) begin
            check_pixel(m,0,639,479,1,24'h123456,24'habcdef,1,24'h123456,"endpoint_old");
            check_pixel(m,64,639,479,1,24'h123456,24'habcdef,1,24'habcdef,"endpoint_new");
        end
        check_pixel(0,32,319,0,1,24'h123456,24'habcdef,1,24'habcdef,"horizontal_before_cut");
        check_pixel(0,32,320,479,1,24'h123456,24'habcdef,1,24'h123456,"horizontal_at_cut");
        check_pixel(1,32,0,239,1,24'h123456,24'habcdef,1,24'habcdef,"vertical_before_cut");
        check_pixel(1,32,639,240,1,24'h123456,24'habcdef,1,24'h123456,"vertical_at_cut");
        // Hand-computed linear addresses: row479*640=306560 (0x4ad80).
        check_pixel(2,32,319,479,0,0,0,1,24'h14afff,"slide_old_last_x639_addr307199");
        check_pixel(2,32,320,479,0,0,0,1,24'h84ad80,"slide_new_first_x0_last_row");
        check_pixel(2,32,639,0,0,0,0,1,24'h80013f,"slide_new_x319_first_row");
        check_pixel(2,64,639,479,0,0,0,1,24'h84afff,"slide_new_last_address");
        check_pixel(3,32,0,0,1,24'h000000,24'hffffff,1,24'h7f7f7f,"fade_black_white_floor");
        check_pixel(3,32,639,479,1,24'hffffff,24'hffffff,1,24'hffffff,"fade_max_no_overflow");
        check_pixel(3,1,0,479,1,24'hff0000,24'h00ff80,1,24'hfb0302,"fade_channels_p1");
        check_pixel(3,63,639,0,1,24'hff0000,24'h00ff80,1,24'h03fb7e,"fade_channels_p63");
        check_pixel(3,32,0,0,1,24'h000000,24'h000000,1,24'h000000,"fade_zero");
        // An unused source may be unavailable/X; it must not poison output.
        for(m=0;m<4;m++) begin
            check_pixel(m,0,0,0,1,24'h123456,24'hxxxxxx,1,24'h123456,"unused_new_unknown");
            check_pixel(m,64,639,479,1,24'hxxxxxx,24'habcdef,1,24'habcdef,"unused_old_unknown");
        end
        // Every 8-bit old/new pair at three interior progress values. Other
        // channels use different pairs so channel swaps cannot pass unnoticed.
        for(p=1;p<=63;p=p+31) for(ov=0;ov<256;ov++) for(nv=0;nv<256;nv++)
            check_pixel(3,p,0,0,1,{8'(ov),8'(255-ov),8'(ov^85)},
                        {8'(nv),8'(255-nv),8'(nv^170)},0,0,"all_channel_pairs");
        // Sweep every progress, every column on six representative rows.
        for(m=0;m<4;m++) for(p=0;p<=64;p++) for(row=0;row<6;row++) begin
            case(row) 0:yy=0;1:yy=1;2:yy=239;3:yy=240;4:yy=478;5:yy=479;endcase
            for(xx=0;xx<640;xx++) check_pixel(m,p,xx,yy,0,0,0,0,0,"spatial_sweep");
        end
        // Every row around the horizontal/slide cut and at image edges.
        for(m=0;m<4;m++) for(p=0;p<=64;p++) for(yy=0;yy<480;yy++)
            for(edge_x=0;edge_x<4;edge_x++) begin
                case(edge_x)
                    0:xx=0;1:xx=639;
                    2:xx=(p*10==0)?0:((p*10>=640)?639:p*10-1);
                    3:xx=(p*10>=640)?639:p*10;
                endcase
                check_pixel(m,p,xx,yy,0,0,0,0,0,"all_rows_edges");
            end
        for(m=0;m<4;m++) begin
            check_pixel(m,32,640,0,1,24'hffffff,24'hffffff,1,0,"invalid_x");
            check_pixel(m,32,0,480,1,24'hffffff,24'hffffff,1,0,"invalid_y");
            check_pixel(m,32,1023,511,1,24'hffffff,24'hffffff,1,0,"invalid_both");
            check_pixel(m,65,639,479,1,24'h123456,24'habcdef,1,24'habcdef,"clamp_progress65");
            check_pixel(m,127,0,0,1,24'h123456,24'habcdef,1,24'habcdef,"clamp_progress127");
        end
        for(m=0;m<4;m++) $display("MODE_RESULT mode=%0d expected_mismatches=0 actual_mismatches=%0d checks=%0d",m,mode_failures[m],checks[m]);
        $display("RESULT total=%0d directed=%0d expected_failures=0 actual_failures=%0d",total,directed,failures);
        if(failures) $fatal(1,"transition pixel mismatches");
        $display("PASS tb_transition_pixels: four algorithms, spatial coordinates, endpoints, extrema and bounds");
        $finish;
    end
    initial begin #10000000;$fatal(1,"watchdog");end
endmodule
