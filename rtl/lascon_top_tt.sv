`timescale 1ns / 1ps

import lascon_pkg::*;

module lascon_top_tt (
    // -----------------------------------------------------------------------
    // Global Clock and Reset
    // -----------------------------------------------------------------------
    input  logic                                clk,
    input  logic                                rst,

    // -----------------------------------------------------------------------
    // Basic Control & Status Interface
    // -----------------------------------------------------------------------
    input  lascon_mode_t                        mode_i,
    input  logic [31:0]                         xof_len_i,
    input  logic                                start_i,
    input  logic                                abort_i,
    output logic                                busy_o,
    output logic                                done_o,
    output logic                                tag_fail_o,

    // -----------------------------------------------------------------------
    // AXI4-Stream Slave Interface (Data IN: Key, Nonce, AD, PT, CT)
    // -----------------------------------------------------------------------
    input  logic [WORD_WIDTH-1:0]               s_axis_tdata,
    input  logic [(WORD_WIDTH/8)-1:0]           s_axis_tkeep,
    input  logic [TUSER_WIDTH-1:0]              s_axis_tuser,
    input  logic                                s_axis_tlast,
    input  logic                                s_axis_tvalid,
    output logic                                s_axis_tready,

    // -----------------------------------------------------------------------
    // AXI4-Stream Master Interface (Data OUT: CT, PT, Tag, Hash Digest)
    // -----------------------------------------------------------------------
    output logic [WORD_WIDTH-1:0]               m_axis_tdata,
    output logic [(WORD_WIDTH/8)-1:0]           m_axis_tkeep,
    output logic [TUSER_WIDTH-1:0]              m_axis_tuser,
    output logic                                m_axis_tlast,
    output logic                                m_axis_tvalid,
    input  logic                                m_axis_tready
);

    lascon_top #(
        .LASCON_VARIANT(1)
    ) u_lascon_top (
        .clk(clk),
        .rst(rst),
        .mode_i(mode_i),
        .xof_len_i(xof_len_i),
        .start_i(start_i),
        .abort_i(abort_i),
        .busy_o(busy_o),
        .done_o(done_o),
        .tag_fail_o(tag_fail_o),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tuser(s_axis_tuser),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tuser(m_axis_tuser),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready)
    );

endmodule
