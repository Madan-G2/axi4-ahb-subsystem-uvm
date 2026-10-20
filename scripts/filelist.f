# Compile order for the Phase 2 testbench.
#
# Paths are relative to sim/build, which is where the tools are invoked from.
# Include directories use --include, not +incdir+ : XSim's -f parser rejects the
# +incdir+ form with "Can not find file: +incdir+...".
#
# Packages must precede anything that imports them.

--include ../../rtl/common
--include ../../verif/uvm/axi4_agent
--include ../../verif/uvm/env
--include ../../verif/uvm/seq_lib
--include ../../verif/uvm/tests
--include ../../verif/sva

# ---- RTL: common ----
../../rtl/common/axi4_pkg.sv
../../rtl/common/axi4_if.sv
../../rtl/common/axi4_rr_arbiter.sv
../../rtl/common/ahb_pkg.sv

# ---- RTL: AXI ----
../../rtl/axi/axi4_addr_decoder.sv
../../rtl/axi/axi4_id_hazard.sv
../../rtl/axi/axi4_w_router.sv
../../rtl/axi/axi4_default_slave.sv
../../rtl/axi/axi4_sram_ctrl.sv
../../rtl/axi/axi4_crossbar.sv

# ---- RTL: AHB + bridge ----
../../rtl/ahb/ahb_subsystem.sv
../../rtl/bridge/axi2ahb_bridge.sv
../../rtl/ahb/ahb_s1_wrapper.sv

# ---- RTL: top ----
../../rtl/top/soc_subsystem_top.sv

# ---- SVA / coverage ----
../../verif/sva/axi4_protocol_checker.sv
../../verif/sva/axi_cov_lib.sv
../../verif/sva/axi4_cov.sv
../../verif/sva/ahb_cov.sv
../../verif/sva/axi4_observer.sv

# ---- UVM ----
../../verif/uvm/axi4_agent/axi4_agent_pkg.sv
../../verif/uvm/env/soc_env_pkg.sv

# ---- TB top ----
../../verif/tb/tb_top.sv
