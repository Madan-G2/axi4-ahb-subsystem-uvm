#==============================================================================
# Makefile -- build and run on XSim or VCS
#
#   make comp                              compile + elaborate
#   make run TEST=soc_smoke_test [SEED=1] [PLUS="+SLV_BP=30"] [WAVES=1]
#   make smoke                             the two-minute sanity check
#   make regress                           every maintained test, seeds included
#   make cov_report SIM=vcs                merge + report VCS coverage (urg)
#   make clean
#
#   Select the backend with SIM=xsim (default) or SIM=vcs.
#
# STATUS -- read this before relying on either branch:
#
#   XSim  The flow below mirrors what scripts/run.py does, and run.py is what is
#         actually used and exercised day to day (GNU make is not available on the
#         Windows development host, and run.py adds parallel jobs, coverage merging
#         and expected-failure handling that this file does not).
#
#   VCS   NEVER RUN. The project was developed without a VCS licence. The VCS
#         branch was written against the VCS/URG documentation and the project's
#         own file list; it has not been compiled, elaborated or simulated by
#         anyone. Expect to fix the first error it prints. Anything claiming "ran
#         on VCS" about this repository would be untrue.
#
#   Two things are known to need attention on VCS:
#     * the file list uses XSim's --include; it is translated to +incdir+ below;
#     * 120 SVA cover properties are written but XSim ignores `cover property`.
#       VCS can count them: build with COVER_SVA=1 to define AXI_COVER_SVA. That
#       is the one place a VCS run would add information XSim cannot.
#==============================================================================

SIM      ?= xsim
TEST     ?= soc_smoke_test
SEED     ?= 1
N_TXN    ?= 200
TIMEOUT  ?= 2000000
PLUS     ?=

ROOT     := $(abspath ..)
BUILD    := $(ROOT)/sim/build
LOGS     := $(ROOT)/sim/logs
REFDIR   := $(ROOT)/verif/ref_model
FILELIST := $(ROOT)/scripts/filelist.f
PY       ?= python3

# Same sources, same defines, whichever simulator.
DEFINES  :=
ifdef COVER_SVA
  DEFINES += +define+AXI_COVER_SVA
endif
ifdef REPLAY
  DEFINES += +define+REPLAY_$(REPLAY)       # e.g. make comp REPLAY=A5 (docs/bug_replays.md)
endif

PLUSARGS := +UVM_TESTNAME=$(TEST) +N_TXN=$(N_TXN) +TIMEOUT_NS=$(TIMEOUT) $(PLUS)
ifdef WAVES
  PLUSARGS += +WAVES
endif

.PHONY: all comp run smoke regress cov_report dpi_check clean dirs

all: comp

dirs:
	@mkdir -p $(BUILD) $(LOGS) $(ROOT)/sim/cov

#==============================================================================
ifeq ($(SIM),xsim)

VIVADO ?= E:/Vivado/2024.1

# Three directories, not one. bin/ alone is not enough: xsc builds the DPI
# object with Vivado's bundled MinGW g++, so the simulation needs that
# toolchain's runtime DLLs at load time. Without them xsim dies before reaching
# time 0 with a bare "Simulation exited with status code -1073741511".
export PATH := $(VIVADO)/bin:$(VIVADO)/tps/mingw/6.2.0/win64.o/nt/bin:$(VIVADO)/lib/win64.o:$(PATH)

# On Windows xsc emits an ar archive, and xelab -sv_lib looks for <name>.a.
DPI_LIB := dpi_ref

comp: dirs
	cd $(BUILD) && xsc $(REFDIR)/soc_ref_model.cpp $(REFDIR)/dpi_shim.cpp \
	    -o $(DPI_LIB).a 2>&1 | tee $(LOGS)/xsc.log
	cd $(BUILD) && xvlog -sv -L uvm $(subst +define+,-d ,$(DEFINES)) -f $(FILELIST) \
	    2>&1 | tee $(LOGS)/xvlog.log
	cd $(BUILD) && xelab tb_top -L uvm -relax -s tb_snap \
	    -sv_lib $(DPI_LIB) -timescale 1ns/1ps 2>&1 | tee $(LOGS)/xelab.log

# Plusargs go through an options file: the xsim wrapper rewrites
# `-testplusarg NAME=value` into `NAME value`, dropping the value.
run: dirs
	@rm -f $(BUILD)/opts.f
	@for a in $(PLUSARGS); do printf -- '-testplusarg %s\n' "$${a#+}" >> $(BUILD)/opts.f; done
	cd $(BUILD) && xsim tb_snap -runall -sv_seed $(SEED) -f opts.f \
	    2>&1 | tee $(LOGS)/$(TEST)_$(SEED).log

dpi_check: dirs
	cd $(BUILD) && xsc $(REFDIR)/soc_ref_model.cpp $(REFDIR)/dpi_shim.cpp -o $(DPI_LIB).a
	@echo "xsc OK. Now: make comp && make run TEST=soc_smoke_test"

cov_report:
	cd $(ROOT)/scripts && $(PY) run.py cov-report --regress $(ROOT)/sim/regress/$(STAMP)

endif

#==============================================================================
ifeq ($(SIM),vcs)

VCS_FILELIST := $(BUILD)/filelist_vcs.f
CM           := line+cond+fsm+tgl+branch+assert

# filelist.f is written for XSim (--include <dir>); VCS wants +incdir+<dir>.
# Paths in it are relative to sim/build, which is where VCS is invoked from.
$(VCS_FILELIST): $(FILELIST) | dirs
	sed -e 's|^--include |+incdir+|' $(FILELIST) > $@

comp: dirs $(VCS_FILELIST)
	cd $(BUILD) && vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
	    -debug_access+all -cm $(CM) $(DEFINES) \
	    -CFLAGS "-std=c++11" -f $(VCS_FILELIST) \
	    $(REFDIR)/soc_ref_model.cpp $(REFDIR)/dpi_shim.cpp \
	    -top tb_top -o simv 2>&1 | tee $(LOGS)/vcs.log

run: dirs
	cd $(BUILD) && ./simv $(PLUSARGS) +ntb_random_seed=$(SEED) \
	    -cm $(CM) -cm_name $(TEST)_$(SEED) \
	    2>&1 | tee $(LOGS)/$(TEST)_$(SEED).log

# Merge every run's coverage and write the HTML report. The parsing and the
# closure gate (check_cov_closure.py) expect XSim's report layout and are NOT yet
# adapted to URG's; on VCS read the URG report directly.
cov_report:
	cd $(BUILD) && urg -full64 -dir simv.vdb -report $(ROOT)/sim/cov/urg

dpi_check:
	@echo "VCS compiles the DPI C++ inline with the design; no separate check."

endif

#==============================================================================
smoke:
	$(MAKE) comp SIM=$(SIM)
	$(MAKE) run SIM=$(SIM) TEST=soc_smoke_test SEED=1

# One make invocation per job, straight from the maintained test list in run.py
# (`run.py list-tests` prints: test seed n_txn timeout [+plusargs]).
# Negative tests are skipped here: judging them against their expected-failure
# lists is run.py's job (run.py regress), and this loop only knows pass/fail.
regress:
	$(MAKE) comp SIM=$(SIM)
	cd $(ROOT)/scripts && $(PY) run.py list-tests --positive | while read t s n to plus; do \
	    $(MAKE) -C $(ROOT)/scripts run SIM=$(SIM) TEST=$$t SEED=$$s N_TXN=$$n TIMEOUT=$$to PLUS="$$plus" \
	      || exit 1; \
	done

clean:
	rm -rf $(ROOT)/sim/build $(ROOT)/sim/logs $(ROOT)/sim/cov $(ROOT)/sim/work $(ROOT)/sim/regress
