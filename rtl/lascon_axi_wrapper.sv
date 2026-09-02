/*
 * Module Name: lascon_axi_wrapper
 * Author(s):   Kiet Le
 * Description:
 * AXI4-Lite wrapper for the Lascon Cryptographic Hardware Accelerator.
 * Provides memory-mapped registers for software control (start, mode, abort)
 * and status polling (done, busy, tag_fail) on Zynq/PYNQ architectures.
 * Passes through high-speed AXI4-Stream interfaces directly to the core.
 *
 * Register Map:
 * 0x00 (RW): Control
 *            Bit 0: START (pulse)
 *            Bit 1: ABORT (pulse)
 *            Bits 4:2: MODE (0=AEAD128, 1=Hash256, 2=XOF128, 3=CXOF128)
 *            Bit 5: IRQ_EN
 * 0x04 (RW): XOF Length
 *            Bits 31:0: XOF length in bytes
 * 0x08 (RO/W1C): Status
 *            Bit 0: BUSY (RO, live level)
 *            Bit 1: DONE (Latched, Write 1 to clear)
 *            Bit 2: TAG_FAIL (Latched, Write 1 to clear)
 */

`timescale 1ns / 1ps

import lascon_pkg::*;

module lascon_axi_wrapper #(
    parameter int C_S_AXI_DATA_WIDTH = 32,
    parameter int C_S_AXI_ADDR_WIDTH = 4,
    parameter int LASCON_VARIANT = 0
)(
    // -----------------------------------------------------------------------
    // System Clock and Reset
    // -----------------------------------------------------------------------
    input  logic                                s_axi_aclk,
    input  logic                                s_axi_aresetn,

    // -----------------------------------------------------------------------
    // Interrupt Output
    // -----------------------------------------------------------------------
    output logic                                irq_o,

    // -----------------------------------------------------------------------
    // AXI4-Lite Slave Interface (Control & Status)
    // -----------------------------------------------------------------------
    input  logic [C_S_AXI_ADDR_WIDTH-1:0]       s_axi_awaddr,
    input  logic [2:0]                          s_axi_awprot,
    input  logic                                s_axi_awvalid,
    output logic                                s_axi_awready,

    input  logic [C_S_AXI_DATA_WIDTH-1:0]       s_axi_wdata,
    input  logic [(C_S_AXI_DATA_WIDTH/8)-1:0]   s_axi_wstrb,
    input  logic                                s_axi_wvalid,
    output logic                                s_axi_wready,

    output logic [1:0]                          s_axi_bresp,
    output logic                                s_axi_bvalid,
    input  logic                                s_axi_bready,

    input  logic [C_S_AXI_ADDR_WIDTH-1:0]       s_axi_araddr,
    input  logic [2:0]                          s_axi_arprot,
    input  logic                                s_axi_arvalid,
    output logic                                s_axi_arready,

    output logic [C_S_AXI_DATA_WIDTH-1:0]       s_axi_rdata,
    output logic [1:0]                          s_axi_rresp,
    output logic                                s_axi_rvalid,
    input  logic                                s_axi_rready,

    // -----------------------------------------------------------------------
    // AXI4-Stream Slave Interface (Data IN: Key, Nonce, AD, PT, CT, Msg)
    // -----------------------------------------------------------------------
    input  logic [WORD_WIDTH-1:0]               s_axis_tdata,
    input  logic [(WORD_WIDTH/8)-1:0]           s_axis_tkeep,
    input  logic [TUSER_WIDTH-1:0]              s_axis_tuser,
    input  logic                                s_axis_tlast,
    input  logic                                s_axis_tvalid,
    output logic                                s_axis_tready,

    // -----------------------------------------------------------------------
    // AXI4-Stream Master Interface (Data OUT: CT, PT, Tag, Digest)
    // -----------------------------------------------------------------------
    output logic [WORD_WIDTH-1:0]               m_axis_tdata,
    output logic [(WORD_WIDTH/8)-1:0]           m_axis_tkeep,
    output logic [TUSER_WIDTH-1:0]              m_axis_tuser,
    output logic                                m_axis_tlast,
    output logic                                m_axis_tvalid,
    input  logic                                m_axis_tready
);

    // =========================================================================
    // Internal Signals
    // =========================================================================
    logic rst;
    assign rst = ~s_axi_aresetn; // Convert AMBA active-low to internal active-high

    // Core Control Signals
    lascon_mode_t   core_mode;
    logic [31:0]    core_xof_len;
    logic           core_start;
    logic           core_abort;
    logic           core_busy;
    logic           core_done;
    logic           core_tag_fail;

    // Register Storage
    logic [31:0]    reg_ctrl;
    logic [31:0]    reg_xof_len;

    // Latched Status
    logic           latched_done;
    logic           latched_tag_fail;

    // Software Pulses
    logic           start_pulse;
    logic           abort_pulse;

    // AXI-Lite State
    logic aw_en;

    // =========================================================================
    // AXI-Lite Write Handshake
    // =========================================================================
    always_ff @(posedge s_axi_aclk) begin
        if (~s_axi_aresetn) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            aw_en         <= 1'b1;
        end else begin
            // Address Write Channel
            if (~s_axi_awready && s_axi_awvalid && s_axi_wvalid && aw_en) begin
                s_axi_awready <= 1'b1;
                aw_en         <= 1'b0;
            end else if (s_axi_bready && s_axi_bvalid) begin
                s_axi_awready <= 1'b0;
                aw_en         <= 1'b1;
            end else begin
                s_axi_awready <= 1'b0;
            end

            // Data Write Channel
            if (~s_axi_wready && s_axi_wvalid && s_axi_awvalid && aw_en) begin
                s_axi_wready <= 1'b1;
            end else begin
                s_axi_wready <= 1'b0;
            end

            // Write Response Channel
            if (s_axi_awready && s_axi_awvalid && s_axi_wready && s_axi_wvalid && ~s_axi_bvalid) begin
                s_axi_bvalid <= 1'b1;
            end else if (s_axi_bready && s_axi_bvalid) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    assign s_axi_bresp = 2'b00; // OKAY

    // =========================================================================
    // AXI-Lite Write Data & CSR Logic
    // =========================================================================
    logic slv_reg_wren;
    assign slv_reg_wren = s_axi_wready && s_axi_wvalid && s_axi_awready && s_axi_awvalid;

    localparam ADDR_CTRL    = 4'h0;
    localparam ADDR_XOF_LEN = 4'h4;
    localparam ADDR_STATUS  = 4'h8;

    always_ff @(posedge s_axi_aclk) begin
        if (~s_axi_aresetn) begin
            reg_ctrl         <= '0;
            reg_xof_len      <= '0;
            start_pulse      <= 1'b0;
            abort_pulse      <= 1'b0;
            latched_done     <= 1'b0;
            latched_tag_fail <= 1'b0;
        end else begin
            // Default pulse de-assertion
            start_pulse <= 1'b0;
            abort_pulse <= 1'b0;

            // Core asserting signals latches them
            if (core_done)     latched_done     <= 1'b1;
            if (core_tag_fail) latched_tag_fail <= 1'b1;

            if (slv_reg_wren) begin
                case (s_axi_awaddr)
                    ADDR_CTRL: begin
                        if (s_axi_wstrb[0]) begin
                            if (s_axi_wdata[0]) start_pulse <= 1'b1;
                            if (s_axi_wdata[1]) abort_pulse <= 1'b1;
                            reg_ctrl[4:2] <= s_axi_wdata[4:2];
                            reg_ctrl[5]   <= s_axi_wdata[5];
                        end
                    end
                    ADDR_XOF_LEN: begin
                        if (s_axi_wstrb[0]) reg_xof_len[7:0]   <= s_axi_wdata[7:0];
                        if (s_axi_wstrb[1]) reg_xof_len[15:8]  <= s_axi_wdata[15:8];
                        if (s_axi_wstrb[2]) reg_xof_len[23:16] <= s_axi_wdata[23:16];
                        if (s_axi_wstrb[3]) reg_xof_len[31:24] <= s_axi_wdata[31:24];
                    end
                    ADDR_STATUS: begin
                        if (s_axi_wstrb[0]) begin
                            // W1C for DONE (bit 1) and TAG_FAIL (bit 2)
                            // We only clear if the core isn't simultaneously setting it
                            if (s_axi_wdata[1] && !core_done)     latched_done     <= 1'b0;
                            if (s_axi_wdata[2] && !core_tag_fail) latched_tag_fail <= 1'b0;
                        end
                    end
                endcase
            end
        end
    end

    // =========================================================================
    // AXI-Lite Read Handshake
    // =========================================================================
    always_ff @(posedge s_axi_aclk) begin
        if (~s_axi_aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
        end else begin
            // Address Read Channel
            if (~s_axi_arready && s_axi_arvalid) begin
                s_axi_arready <= 1'b1;
            end else begin
                s_axi_arready <= 1'b0;
            end

            // Data Read Channel
            if (s_axi_arready && s_axi_arvalid && ~s_axi_rvalid) begin
                s_axi_rvalid <= 1'b1;
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    assign s_axi_rresp = 2'b00; // OKAY

    // =========================================================================
    // AXI-Lite Read Data & CSR Logic
    // =========================================================================
    logic slv_reg_rden;
    assign slv_reg_rden = s_axi_arready && s_axi_arvalid && ~s_axi_rvalid;

    always_ff @(posedge s_axi_aclk) begin
        if (~s_axi_aresetn) begin
            s_axi_rdata <= '0;
        end else begin
            if (slv_reg_rden) begin
                case (s_axi_araddr)
                    ADDR_CTRL:    s_axi_rdata <= reg_ctrl;
                    ADDR_XOF_LEN: s_axi_rdata <= reg_xof_len;
                    ADDR_STATUS:  s_axi_rdata <= {29'd0, latched_tag_fail, latched_done, core_busy};
                    default:      s_axi_rdata <= '0;
                endcase
            end
        end
    end

    // =========================================================================
    // Core Integration & Passthrough Connections
    // =========================================================================
    assign core_start   = start_pulse;
    assign core_abort   = abort_pulse;
    assign core_mode    = lascon_mode_t'(reg_ctrl[4:2]);
    assign core_xof_len = reg_xof_len;
    assign irq_o        = latched_done & reg_ctrl[5];

    lascon_top #(
        .LASCON_VARIANT (LASCON_VARIANT)
    ) lascon_core_inst (
        .clk            (s_axi_aclk),
        .rst            (rst),

        .mode_i         (core_mode),
        .xof_len_i      (core_xof_len),
        .start_i        (core_start),
        .abort_i        (core_abort),

        .busy_o         (core_busy),
        .done_o         (core_done),
        .tag_fail_o     (core_tag_fail),

        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tkeep   (s_axis_tkeep),
        .s_axis_tuser   (s_axis_tuser),
        .s_axis_tlast   (s_axis_tlast),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),

        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tkeep   (m_axis_tkeep),
        .m_axis_tuser   (m_axis_tuser),
        .m_axis_tlast   (m_axis_tlast),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready)
    );

endmodule
