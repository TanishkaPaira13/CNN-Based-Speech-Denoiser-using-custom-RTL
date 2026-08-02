################################################################
# create_project.tcl
# Vivado 2024.2 — ZCU102 CNN Denoiser Project
#
# Usage (from Vivado Tcl console or batch mode):
#   cd <path_to>/fpga_inference
#   source create_project.tcl
#
# What this script does:
#   1. Creates Vivado project targeting ZCU102 (xczu9eg-ffvb1156-2-e)
#   2. Adds all RTL sources and weight .mem files
#   3. Creates block design:
#        Zynq PS → SmartConnect → AXI DMA → denoiser_top (CNN)
#        AXI DMA ↔ PS DDR (HP0 FPD)
#        denoiser_top IRQ → PS interrupt
#   4. Generates HDL wrapper and sets it as top
#   5. Creates timing constraints (200 MHz PL clock)
#   6. Optionally launches synthesis (see bottom of script)
################################################################

# ── User-configurable settings ────────────────────────────────────────────
set PROJ_NAME    "denoiser_zcu102"
set PROJ_DIR     "[file normalize ./vivado_project]"
set BD_NAME      "denoiser_bd"
set PART         "xczu9eg-ffvb1156-2-e"
set BOARD_PART   "xilinx.com:zcu102:part0:3.4"
set PL_CLK_MHZ   200

# Paths relative to this script's directory
set SCRIPT_DIR   [file normalize [file dirname [info script]]]
set RTL_DIR      [file normalize "$SCRIPT_DIR/rtl"]
set MEM_DIR      [file normalize "$SCRIPT_DIR/tools/mem"]

# ── Create project ────────────────────────────────────────────────────────
puts "INFO: Creating project $PROJ_NAME in $PROJ_DIR"
create_project $PROJ_NAME $PROJ_DIR -part $PART -force

# Apply ZCU102 board part (installs DDR/MIO presets for the PS)
set_property board_part $BOARD_PART [current_project]

# Use VHDL-2008 / Verilog-2001 (default is fine; make synthesis use 2001)
set_property default_lib work [current_project]
set_property simulator_language "Mixed" [current_project]

# ── Add RTL source files ──────────────────────────────────────────────────
puts "INFO: Adding RTL sources from $RTL_DIR"

foreach f {feature_bram.v weight_rom.v conv_engine.v denoiser_top.v} {
    set fpath "$RTL_DIR/$f"
    if {[file exists $fpath]} {
        add_files -norecurse $fpath
        puts "  added: $f"
    } else {
        puts "  WARNING: $fpath not found — skipping"
    }
}

# Weight memory init files for \$readmemh (mark as non-global, mem files only)
if {[file exists $MEM_DIR]} {
    set mem_files [glob -nocomplain "$MEM_DIR/*.mem"]
    if {[llength $mem_files] > 0} {
        add_files -norecurse $mem_files
        set_property file_type "Memory Initialization Files" \
            [get_files -filter {FILE_TYPE == "Unknown"} -of [current_fileset]]
        puts "  added [llength $mem_files] .mem weight files from $MEM_DIR"
    } else {
        puts "  WARNING: No .mem files found in $MEM_DIR (run extract_weights.py first)"
    }
}

update_compile_order -fileset sources_1

# ── Create Block Design ───────────────────────────────────────────────────
puts "INFO: Creating block design '$BD_NAME'"
create_bd_design $BD_NAME
current_bd_design $BD_NAME

# ════════════════════════════════════════════════════════════════════
#  IP INSTANTIATION
# ════════════════════════════════════════════════════════════════════

# ── 1. Zynq UltraScale+ PS ────────────────────────────────────────────────
puts "  Adding Zynq PS ..."
set ps [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 zynq_ultra_ps_e_0]

# Apply ZCU102 board preset (DDR timing, MIO config, etc.)
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} $ps

# Enable/configure required PS interfaces:
#   M_AXI_HPM0_FPD  (32-bit, GP master 0) — drives AXI DMA ctrl + CNN AXI-Lite
#   S_AXI_HP0_FPD   (128-bit HP slave 0, PSU__USE__S_AXI_GP4) — DMA DDR access
#   pl_clk0 @ 200 MHz  — PL fabric clock
#   pl_resetn0         — PL active-low reset
#   IRQ F2P[0]         — one PL→PS interrupt
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0                   {1} \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH              {32} \
    CONFIG.PSU__USE__M_AXI_GP1                   {0} \
    CONFIG.PSU__USE__S_AXI_GP4                   {1} \
    CONFIG.PSU__SAXIGP4__DATA_WIDTH             {128} \
    CONFIG.PSU__USE__IRQ0                        {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ  $PL_CLK_MHZ \
    CONFIG.PSU__FPGA_PL0_ENABLE                  {1} \
] $ps

# ── 2. Processor System Reset ─────────────────────────────────────────────
puts "  Adding proc_sys_reset ..."
set rst [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]

# ── 3. AXI DMA ────────────────────────────────────────────────────────────
# Simple mode (no SG), 32-bit AXI memory bus, 32-bit AXI-Stream (matches denoiser_top)
puts "  Adding AXI DMA ..."
set dma [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0]

set_property -dict [list \
    CONFIG.c_include_sg                  {0}  \
    CONFIG.c_sg_include_stscntrl_strm    {0}  \
    CONFIG.c_include_mm2s                {1}  \
    CONFIG.c_include_s2mm                {1}  \
    CONFIG.c_m_axi_mm2s_data_width      {32}  \
    CONFIG.c_m_axi_s2mm_data_width      {32}  \
    CONFIG.c_m_axis_mm2s_tdata_width    {32}  \
    CONFIG.c_s_axis_s2mm_tdata_width    {32}  \
    CONFIG.c_mm2s_burst_size            {64}  \
    CONFIG.c_s2mm_burst_size            {64}  \
    CONFIG.c_addr_width                 {32}  \
    CONFIG.c_sg_length_width            {14}  \
] $dma

# ── 4. denoiser_top (module reference from RTL sources) ───────────────────
# Vivado infers AXI4-Stream and AXI4-Lite interfaces from port naming:
#   s_axis_{tdata,tvalid,tready,tlast}  → AXI4-Stream slave  "S_AXIS"
#   m_axis_{tdata,tvalid,tready,tlast}  → AXI4-Stream master "M_AXIS"
#   s_axil_{aw*,w*,b*,ar*,r*}          → AXI4-Lite slave    "S_AXIL"
puts "  Adding denoiser_top (module reference) ..."
set cnn [create_bd_cell -type module -reference denoiser_top denoiser_top_0]

# ── 5. SmartConnect: control path (PS HPM0 → DMA ctrl + CNN AXI-Lite) ─────
puts "  Adding SmartConnect (ctrl) ..."
set sc_ctrl [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_ctrl]
set_property -dict [list \
    CONFIG.NUM_SI {1} \
    CONFIG.NUM_MI {2} \
] $sc_ctrl

# ── 6. SmartConnect: memory path (DMA MM2S + S2MM → PS HP0 FPD) ──────────
puts "  Adding SmartConnect (mem) ..."
set sc_mem [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_mem]
set_property -dict [list \
    CONFIG.NUM_SI {2} \
    CONFIG.NUM_MI {1} \
] $sc_mem

# ════════════════════════════════════════════════════════════════════
#  CLOCK AND RESET CONNECTIONS
# ════════════════════════════════════════════════════════════════════
puts "  Connecting clocks and resets ..."

# PL fabric clock (pl_clk0 → everything, including PS HP0 slave clock)
connect_bd_net \
    [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins proc_sys_reset_0/slowest_sync_clk] \
    [get_bd_pins axi_dma_0/s_axi_lite_aclk] \
    [get_bd_pins axi_dma_0/m_axi_mm2s_aclk] \
    [get_bd_pins axi_dma_0/m_axi_s2mm_aclk] \
    [get_bd_pins smartconnect_ctrl/aclk] \
    [get_bd_pins smartconnect_mem/aclk] \
    [get_bd_pins denoiser_top_0/aclk] \
    [get_bd_pins zynq_ultra_ps_e_0/saxihp0fpd_aclk]

# Active-low reset from PS → proc_sys_reset input
connect_bd_net \
    [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] \
    [get_bd_pins proc_sys_reset_0/ext_reset_in]

# proc_sys_reset peripheral_aresetn → all AXI resets
connect_bd_net \
    [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins axi_dma_0/axi_resetn] \
    [get_bd_pins smartconnect_ctrl/aresetn] \
    [get_bd_pins smartconnect_mem/aresetn] \
    [get_bd_pins denoiser_top_0/aresetn]

# ════════════════════════════════════════════════════════════════════
#  AXI INTERFACE CONNECTIONS
# ════════════════════════════════════════════════════════════════════
puts "  Connecting AXI interfaces ..."

# ── Control path ──────────────────────────────────────────────────────────
# PS HPM0 → SmartConnect_ctrl
connect_bd_intf_net \
    [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] \
    [get_bd_intf_pins smartconnect_ctrl/S00_AXI]

# SmartConnect_ctrl → AXI DMA S_AXI_LITE
connect_bd_intf_net \
    [get_bd_intf_pins smartconnect_ctrl/M00_AXI] \
    [get_bd_intf_pins axi_dma_0/S_AXI_LITE]

# SmartConnect_ctrl → denoiser_top AXI4-Lite
connect_bd_intf_net \
    [get_bd_intf_pins smartconnect_ctrl/M01_AXI] \
    [get_bd_intf_pins denoiser_top_0/S_AXIL]

# ── Memory path ───────────────────────────────────────────────────────────
# AXI DMA MM2S (read from DDR) → SmartConnect_mem
connect_bd_intf_net \
    [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] \
    [get_bd_intf_pins smartconnect_mem/S00_AXI]

# AXI DMA S2MM (write to DDR) → SmartConnect_mem
connect_bd_intf_net \
    [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] \
    [get_bd_intf_pins smartconnect_mem/S01_AXI]

# SmartConnect_mem → PS HP0 FPD slave (enabled via PSU__USE__S_AXI_GP4)
connect_bd_intf_net \
    [get_bd_intf_pins smartconnect_mem/M00_AXI] \
    [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]

# ── AXI-Stream data path ──────────────────────────────────────────────────
# AXI DMA MM2S output → denoiser_top input
connect_bd_intf_net \
    [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] \
    [get_bd_intf_pins denoiser_top_0/S_AXIS]

# denoiser_top output → AXI DMA S2MM input
connect_bd_intf_net \
    [get_bd_intf_pins denoiser_top_0/M_AXIS] \
    [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

# ── IRQ: denoiser_top done → PS interrupt ────────────────────────────────
connect_bd_net \
    [get_bd_pins denoiser_top_0/irq] \
    [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]

# ════════════════════════════════════════════════════════════════════
#  ADDRESS MAP
# ════════════════════════════════════════════════════════════════════
puts "  Assigning address map ..."

# Auto-assign everything first, then override offsets
assign_bd_address

# ── PS master (HPM0) address segments ────────────────────────────────────
# AXI DMA control registers @ 0xA000_0000 (64 KB)
set seg_dma [get_bd_addr_segs \
    zynq_ultra_ps_e_0/Data/SEG_axi_dma_0_Reg]
if {$seg_dma ne ""} {
    set_property offset 0xA0000000 $seg_dma
    set_property range  64K        $seg_dma
}

# denoiser_top AXI-Lite @ 0xA001_0000 (4 KB)
set seg_cnn [get_bd_addr_segs \
    zynq_ultra_ps_e_0/Data/SEG_denoiser_top_0_S_AXIL_reg0]
if {$seg_cnn ne ""} {
    set_property offset 0xA0010000 $seg_cnn
    set_property range  4K         $seg_cnn
} else {
    # Fallback: try inferred name from Vivado interface inference
    set seg_cnn2 [get_bd_addr_segs -of [get_bd_intf_pins denoiser_top_0/S_AXIL]]
    if {$seg_cnn2 ne ""} {
        set_property offset 0xA0010000 [lindex $seg_cnn2 0]
        set_property range  4K         [lindex $seg_cnn2 0]
    }
}

# ── DMA master → PS HP0 DDR: 0x0000_0000 – 0x7FFF_FFFF (2 GB) ─────────
# Use filter-based selection — segment name depends on Vivado version
# (HP0_DDR_LOW in 2024.x; HPC0_DDR_LOW if the port was S_AXI_HPC0_FPD).
foreach seg [get_bd_addr_segs -of_objects [get_bd_intf_pins axi_dma_0/M_AXI_MM2S]] {
    set_property offset 0x00000000 $seg
    set_property range  2G         $seg
}
foreach seg [get_bd_addr_segs -of_objects [get_bd_intf_pins axi_dma_0/M_AXI_S2MM]] {
    set_property offset 0x00000000 $seg
    set_property range  2G         $seg
}

# ════════════════════════════════════════════════════════════════════
#  VALIDATE AND SAVE BLOCK DESIGN
# ════════════════════════════════════════════════════════════════════
puts "INFO: Validating block design ..."
validate_bd_design
save_bd_design

# ── Generate HDL wrapper ──────────────────────────────────────────────────
puts "INFO: Generating HDL wrapper ..."
make_wrapper -files [get_files ${BD_NAME}.bd] -top
set wrapper_file [glob -nocomplain \
    "$PROJ_DIR/${PROJ_NAME}.srcs/sources_1/bd/${BD_NAME}/hdl/${BD_NAME}_wrapper.v"]
if {[llength $wrapper_file] == 0} {
    # Vivado 2024.x may place wrapper under gen/
    set wrapper_file [glob -nocomplain \
        "$PROJ_DIR/${PROJ_NAME}.gen/sources_1/bd/${BD_NAME}/hdl/${BD_NAME}_wrapper.v"]
}
if {[llength $wrapper_file] > 0} {
    add_files -norecurse [lindex $wrapper_file 0]
    set_property top ${BD_NAME}_wrapper [current_fileset]
} else {
    puts "WARNING: Could not find generated wrapper; set top manually."
}
update_compile_order -fileset sources_1

# ════════════════════════════════════════════════════════════════════
#  TIMING CONSTRAINTS (XDC)
# ════════════════════════════════════════════════════════════════════
puts "INFO: Writing timing constraints ..."

set xdc_path "$PROJ_DIR/denoiser_zcu102.xdc"
set xdc_fd [open $xdc_path w]
puts $xdc_fd {################################################################
# denoiser_zcu102.xdc — Timing constraints for ZCU102 CNN denoiser
# Vivado 2024.2
################################################################

# PL fabric clock (driven by PS CRL pl_clk0 @ 200 MHz)
# The PS drives pl_clk0 internally — create a virtual clock for reference.
create_clock -name clk_pl_0 -period 5.000 \
    [get_pins -hierarchical -filter {NAME =~ */BUFGCTRL*/O}]

# False paths on resets (sync'ed by proc_sys_reset)
set_false_path -from [get_pins -hierarchical -filter {NAME =~ *proc_sys_reset*/C}] \
               -to   [get_pins -hierarchical -filter {NAME =~ */rst_n_reg*/D}]

# Input/output delays for AXI-Stream (adjust if using external FIFO)
# set_input_delay  -clock clk_pl_0 -max 2.000 [get_ports s_axis_*]
# set_output_delay -clock clk_pl_0 -max 2.000 [get_ports m_axis_*]
}
close $xdc_fd

add_files -fileset constrs_1 -norecurse $xdc_path
puts "  constraints: $xdc_path"

# ════════════════════════════════════════════════════════════════════
#  OPTIONAL: LAUNCH SYNTHESIS
# ════════════════════════════════════════════════════════════════════
# Uncomment to auto-run synthesis + implementation + bitstream:
#
# set_property strategy "Vivado Implementation Defaults" [get_runs impl_1]
# launch_runs synth_1 -jobs 8
# wait_on_run synth_1
# if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
#     error "Synthesis FAILED"
# }
# launch_runs impl_1 -to_step write_bitstream -jobs 8
# wait_on_run impl_1
# puts "INFO: Bitstream written to:"
# puts "      $PROJ_DIR/${PROJ_NAME}.runs/impl_1/${BD_NAME}_wrapper.bit"

# ════════════════════════════════════════════════════════════════════
#  SUMMARY
# ════════════════════════════════════════════════════════════════════
puts ""
puts "╔══════════════════════════════════════════════════════════╗"
puts "║  Project created successfully                            ║"
puts "╠══════════════════════════════════════════════════════════╣"
puts "║  Project : $PROJ_DIR/${PROJ_NAME}.xpr"
puts "║  Part    : $PART"
puts "║  Board   : $BOARD_PART"
puts "║  PL clk  : ${PL_CLK_MHZ} MHz"
puts "╠══════════════════════════════════════════════════════════╣"
puts "║  AXI-Lite map:                                          ║"
puts "║    AXI DMA ctrl  → 0xA000_0000  (64 KB)                ║"
puts "║    CNN AXI-Lite  → 0xA001_0000  ( 4 KB)                ║"
puts "║  DMA DDR buffers (configure in ps_driver/pl_driver.h):  ║"
puts "║    Input  patch  → 0x1000_0000  (64 KB)                ║"
puts "║    Output patch  → 0x1001_0000  (64 KB)                ║"
puts "╠══════════════════════════════════════════════════════════╣"
puts "║  Next steps:                                            ║"
puts "║  1. Open project in Vivado 2024.2                       ║"
puts "║     open_project $PROJ_DIR/${PROJ_NAME}.xpr             ║"
puts "║  2. Run synthesis (Flow → Run Synthesis)                ║"
puts "║  3. Run implementation + write bitstream                ║"
puts "║  4. Export hardware (.xsa) for Vitis:                   ║"
puts "║     File → Export → Export Hardware (include bitstream) ║"
puts "║  5. Create Vitis platform from .xsa                     ║"
puts "║  6. Add ps_driver/*.c/.h + lwipopts.h to Vitis app      ║"
puts "╚══════════════════════════════════════════════════════════╝"
puts ""
