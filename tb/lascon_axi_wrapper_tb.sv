/*
 * Module Name: lascon_axi_wrapper_tb
 * Author(s):   Kiet Le
 * Description:
 * Isolated testbench for the Lascon AXI4-Lite control wrapper.
 * Validates register read/writes, W1C latching, and IRQ generation
 * without requiring full AXI-Stream cryptographic stimulus.
 */

`timescale 1ns / 1ps

import lascon_pkg::*;

module lascon_axi_wrapper_tb;

    // -------------------------------------------------------------------------
    // TB Signals & Clock/Reset
    // -------------------------------------------------------------------------
    logic        s_axi_aclk = 0;
    logic        s_axi_aresetn = 0;
    logic        irq_o;

    // AXI-Lite Write Interface
    logic [3:0]  s_axi_awaddr;
    logic [2:0]  s_axi_awprot;
    logic        s_axi_awvalid = 0;
    logic        s_axi_awready;
    logic [31:0] s_axi_wdata;
    logic [3:0]  s_axi_wstrb;
    logic        s_axi_wvalid = 0;
    logic        s_axi_wready;
    logic [1:0]  s_axi_bresp;
    logic        s_axi_bvalid;
    logic        s_axi_bready = 0;

    // AXI-Lite Read Interface
    logic [3:0]  s_axi_araddr;
    logic [2:0]  s_axi_arprot;
    logic        s_axi_arvalid = 0;
    logic        s_axi_arready;
    logic [31:0] s_axi_rdata;
    logic [1:0]  s_axi_rresp;
    logic        s_axi_rvalid;
    logic        s_axi_rready = 0;

    // AXI-Stream Passthrough (Stubbed)
    logic [63:0]            s_axis_tdata = 0;
    logic [7:0]             s_axis_tkeep = 0;
    logic [TUSER_WIDTH-1:0] s_axis_tuser = '0;
    logic                   s_axis_tlast = 0;
    logic                   s_axis_tvalid = 0;
    logic                   s_axis_tready;

    logic [63:0]            m_axis_tdata;
    logic [7:0]             m_axis_tkeep;
    logic [TUSER_WIDTH-1:0] m_axis_tuser;
    logic                   m_axis_tlast;
    logic                   m_axis_tvalid;
    logic                   m_axis_tready = 1;

    // -------------------------------------------------------------------------
    // Unit Under Test (UUT)
    // -------------------------------------------------------------------------
    lascon_axi_wrapper #(
        .C_S_AXI_DATA_WIDTH(32),
        .C_S_AXI_ADDR_WIDTH(4)
    ) uut (
        .s_axi_aclk    (s_axi_aclk),
        .s_axi_aresetn (s_axi_aresetn),
        .irq_o         (irq_o),

        .s_axi_awaddr  (s_axi_awaddr),
        .s_axi_awprot  (s_axi_awprot),
        .s_axi_awvalid (s_axi_awvalid),
        .s_axi_awready (s_axi_awready),
        .s_axi_wdata   (s_axi_wdata),
        .s_axi_wstrb   (s_axi_wstrb),
        .s_axi_wvalid  (s_axi_wvalid),
        .s_axi_wready  (s_axi_wready),
        .s_axi_bresp   (s_axi_bresp),
        .s_axi_bvalid  (s_axi_bvalid),
        .s_axi_bready  (s_axi_bready),

        .s_axi_araddr  (s_axi_araddr),
        .s_axi_arprot  (s_axi_arprot),
        .s_axi_arvalid (s_axi_arvalid),
        .s_axi_arready (s_axi_arready),
        .s_axi_rdata   (s_axi_rdata),
        .s_axi_rresp   (s_axi_rresp),
        .s_axi_rvalid  (s_axi_rvalid),
        .s_axi_rready  (s_axi_rready),

        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tkeep  (s_axis_tkeep),
        .s_axis_tuser  (s_axis_tuser),
        .s_axis_tlast  (s_axis_tlast),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),

        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tkeep  (m_axis_tkeep),
        .m_axis_tuser  (m_axis_tuser),
        .m_axis_tlast  (m_axis_tlast),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready)
    );

    // 100MHz Clock
    always #5 s_axi_aclk = ~s_axi_aclk;

    // -------------------------------------------------------------------------
    // AXI-Lite BFM Tasks
    // -------------------------------------------------------------------------
    task axi_write(input [3:0] addr, input [31:0] data);
        begin
            // Setup channels
            s_axi_awaddr  = addr;
            s_axi_awprot  = 3'b000;
            s_axi_awvalid = 1'b1;

            s_axi_wdata   = data;
            s_axi_wstrb   = 4'hF; // Full 32-bit write
            s_axi_wvalid  = 1'b1;

            s_axi_bready  = 1'b1;

            // Wait for address & data accept
            fork
                begin
                    wait(s_axi_awready);
                    @(posedge s_axi_aclk);
                    s_axi_awvalid = 1'b0;
                end
                begin
                    wait(s_axi_wready);
                    @(posedge s_axi_aclk);
                    s_axi_wvalid = 1'b0;
                end
            join

            // Wait for response
            wait(s_axi_bvalid);
            @(posedge s_axi_aclk);
            s_axi_bready = 1'b0;
            @(posedge s_axi_aclk);
        end
    endtask

    task axi_read(input [3:0] addr, output [31:0] data);
        begin
            // Setup Address Channel
            s_axi_araddr  = addr;
            s_axi_arprot  = 3'b000;
            s_axi_arvalid = 1'b1;
            s_axi_rready  = 1'b1;

            wait(s_axi_arready);
            @(posedge s_axi_aclk);
            s_axi_arvalid = 1'b0;

            // Wait for data
            wait(s_axi_rvalid);
            data = s_axi_rdata;
            @(posedge s_axi_aclk);
            s_axi_rready = 1'b0;
            @(posedge s_axi_aclk);
        end
    endtask

    // -------------------------------------------------------------------------
    // Main Test Sequence
    // -------------------------------------------------------------------------
    logic [31:0] rdata;
    int err_count = 0;

    initial begin
        $display("==================================================");
        $display("Starting AXI-Lite Wrapper Testbench");
        $display("==================================================");

        // 1. Reset Sequence
        s_axi_aresetn = 0;
        #100;
        s_axi_aresetn = 1;
        #20;

        $display("[TB] 1. Verifying Default Register States...");
        axi_read(4'h0, rdata);
        if (rdata !== 32'h0) begin $display("ERROR: Control Reg reset value mismatch: %08x", rdata); err_count++; end

        // 2. Register Map Check
        $display("[TB] 2. Verifying Register Write/Read...");
        // Write Mode = 0x1 (Hash256), IRQ_EN = 0 -> Control Reg = 0x04 (bits 4:2 = 0x1)
        axi_write(4'h0, 32'h04);
        // Write dummy XOF length
        axi_write(4'h4, 32'h12345678);

        axi_read(4'h0, rdata);
        if (rdata !== 32'h04) begin $display("ERROR: Control Reg readback mismatch: %08x", rdata); err_count++; end
        axi_read(4'h4, rdata);
        if (rdata !== 32'h12345678) begin $display("ERROR: XOF Len readback mismatch: %08x", rdata); err_count++; end

        // 3. Start Pulse Check
        $display("[TB] 3. Verifying Start Pulse Generation...");
        // Write 1 to bit 0
        axi_write(4'h0, 32'h05); // Mode Hash, start = 1
        @(posedge s_axi_aclk);
        // Because start bit auto-clears inside wrapper, we should read back 0x04
        axi_read(4'h0, rdata);
        if (rdata !== 32'h04) begin $display("ERROR: Start bit didn't auto-clear: %08x", rdata); err_count++; end

        // 4. Interrupt & Status Polling Check (via Forcing)
        $display("[TB] 4. Verifying IRQ and W1C Latching...");
        // Enable IRQ (Bit 5 = 1) -> 0x24
        axi_write(4'h0, 32'h24);

        // Force the core's internal 'done' signal to simulate completion
        $display("[TB] Forcing internal core_done signal to HIGH for 1 cycle...");
        force uut.core_done = 1'b1;
        @(posedge s_axi_aclk);
        force uut.core_done = 1'b0;
        @(posedge s_axi_aclk);
        release uut.core_done;
        @(posedge s_axi_aclk);

        // Verify IRQ output goes high
        if (irq_o !== 1'b1) begin $display("ERROR: irq_o did not assert!"); err_count++; end

        // Read Status Register (0x08)
        axi_read(4'h8, rdata);
        if ((rdata & 32'h02) == 0) begin $display("ERROR: DONE bit (bit 1) not latched in Status Reg: %08x", rdata); err_count++; end

        // Write-1-to-Clear DONE bit
        $display("[TB] Issuing Write-1-to-Clear (W1C) on Status Register...");
        axi_write(4'h8, 32'h02);

        // Verify IRQ de-asserts
        @(posedge s_axi_aclk);
        if (irq_o !== 1'b0) begin $display("ERROR: irq_o did not de-assert after W1C!"); err_count++; end

        // Verify Status Register cleared
        axi_read(4'h8, rdata);
        if ((rdata & 32'h02) != 0) begin $display("ERROR: DONE bit (bit 1) did not clear: %08x", rdata); err_count++; end

        // 5. Abort Pulse Check
        $display("[TB] 5. Verifying Abort Pulse Generation...");
        axi_write(4'h0, 32'h06); // Mode Hash (0x04) + abort (0x02)
        @(posedge s_axi_aclk);
        axi_read(4'h0, rdata);
        if (rdata !== 32'h04) begin $display("ERROR: Abort bit didn't auto-clear: %08x", rdata); err_count++; end

        // 6. Interrupt Masking Check (IRQ_EN = 0)
        $display("[TB] 6. Verifying Interrupt Masking (IRQ_EN = 0)...");
        axi_write(4'h0, 32'h04); // Mode Hash, IRQ_EN = 0
        force uut.core_done = 1'b1;
        @(posedge s_axi_aclk);
        force uut.core_done = 1'b0;
        @(posedge s_axi_aclk);
        release uut.core_done;
        @(posedge s_axi_aclk);

        if (irq_o !== 1'b0) begin $display("ERROR: irq_o asserted while masked!"); err_count++; end
        axi_read(4'h8, rdata);
        if ((rdata & 32'h02) == 0) begin $display("ERROR: DONE bit not latched when IRQ is masked: %08x", rdata); err_count++; end
        axi_write(4'h8, 32'h02); // Clear DONE

        // 7. TAG_FAIL Latching & W1C Check
        $display("[TB] 7. Verifying TAG_FAIL Latching & W1C...");
        force uut.core_tag_fail = 1'b1;
        @(posedge s_axi_aclk);
        force uut.core_tag_fail = 1'b0;
        @(posedge s_axi_aclk);
        release uut.core_tag_fail;
        @(posedge s_axi_aclk);

        axi_read(4'h8, rdata);
        if ((rdata & 32'h04) == 0) begin $display("ERROR: TAG_FAIL bit not latched in Status Reg: %08x", rdata); err_count++; end
        axi_write(4'h8, 32'h04); // Clear TAG_FAIL via W1C
        axi_read(4'h8, rdata);
        if ((rdata & 32'h04) != 0) begin $display("ERROR: TAG_FAIL bit did not clear after W1C: %08x", rdata); err_count++; end

        // 8. Mode Configuration Decoding Check
        $display("[TB] 8. Verifying Mode Configuration Decoding...");
        for (int m = 0; m <= 4; m++) begin
            axi_write(4'h0, (m << 2));
            axi_read(4'h0, rdata);
            if (((rdata >> 2) & 3'h7) !== m[2:0]) begin
                $display("ERROR: Mode readback mismatch for mode %0d: got %0d", m, (rdata >> 2) & 3'h7);
                err_count++;
            end
            if (uut.core_mode !== lascon_mode_t'(m[2:0])) begin
                $display("ERROR: uut.core_mode mismatch for mode %0d", m);
                err_count++;
            end
        end

        // 9. Unmapped Address Handling Check
        $display("[TB] 9. Verifying Unmapped Address Handling...");
        axi_read(4'hC, rdata);
        if (rdata !== 32'h0) begin $display("ERROR: Unmapped address 0x0C did not return 0: %08x", rdata); err_count++; end
        axi_write(4'hC, 32'hDEADBEEF);
        axi_read(4'h4, rdata);
        if (rdata !== 32'h12345678) begin $display("ERROR: Unmapped write corrupted XOF Len reg: %08x", rdata); err_count++; end

        // 10. Mid-Operation Reset Recovery Check
        $display("[TB] 10. Verifying Mid-Operation Hardware Reset...");
        axi_write(4'h0, 32'h24); // Enable IRQ
        axi_write(4'h4, 32'hA5A5A5A5);
        force uut.core_done = 1'b1;
        @(posedge s_axi_aclk);
        force uut.core_done = 1'b0;
        @(posedge s_axi_aclk);
        release uut.core_done;
        @(posedge s_axi_aclk);

        // Trigger active-low reset
        s_axi_aresetn = 0;
        #50;
        @(posedge s_axi_aclk);
        s_axi_aresetn = 1;
        #20;

        if (irq_o !== 1'b0) begin $display("ERROR: irq_o did not reset!"); err_count++; end
        axi_read(4'h0, rdata);
        if (rdata !== 32'h0) begin $display("ERROR: Control Reg did not reset: %08x", rdata); err_count++; end
        axi_read(4'h4, rdata);
        if (rdata !== 32'h0) begin $display("ERROR: XOF Len Reg did not reset: %08x", rdata); err_count++; end
        axi_read(4'h8, rdata);
        if ((rdata & 32'h06) !== 32'h0) begin $display("ERROR: Status latches did not reset: %08x", rdata); err_count++; end

        // Final Result
        $display("==================================================");
        if (err_count == 0) begin
            $display("TEST PASSED: All 10 AXI-Lite wrapper checks succeeded.");
            $display("==================================================");
            $finish;
        end else begin
            $fatal(1, "TEST FAILED: %0d errors encountered.", err_count);
        end
    end

endmodule
