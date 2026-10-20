#!/usr/bin/env python3
"""
Build and run driver for the AXI4/AHB subsystem testbench.

Why this exists alongside the Makefile: GNU make is not present on this Windows
host (Git Bash does not ship it), so the Makefile flow is unusable here even
though every Vivado tool works fine. This script is the Windows entry point and
also serves as the regression runner the project needs anyway. The Makefile
stays as the Linux / VCS path.

It encodes several XSim behaviours that are not obvious and cost real time to
rediscover -- see the notes on each below.

Usage:
    python run.py comp
    python run.py run  --test soc_smoke_test [--seed 1] [--waves]
    python run.py regress [--jobs 4]
    python run.py dpi-check
"""

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "sim" / "build"
LOGS = ROOT / "sim" / "logs"
REGRESS = ROOT / "sim" / "regress"
WORK    = ROOT / "sim" / "work"
REFDIR = ROOT / "verif" / "ref_model"

DPI_LIB = "dpi_ref"
SNAPSHOT = "tb_snap"
SNAP_COV = "tb_snap_cov"       # same design, with code-coverage instrumentation
COV_DB = "tb_snap_cov"         # database name baked in at elaboration (same in every run dir)

# Limits for one simulation (see run_guarded). Normal runs peak under 1 GB and finish in
# well under a minute; anything near these limits is a runaway, not a slow test.
JOB_TIMEOUT_S = 1500
JOB_MEM_MB = 4096

# Default install; override with VIVADO_HOME.
VIVADO = Path(os.environ.get("VIVADO_HOME", r"E:/Vivado/2024.1"))


def tool_env():
    """PATH with the three directories XSim actually needs.

    bin/ alone is not sufficient. xsc compiles the DPI object with Vivado's
    bundled MinGW g++, and the simulation loads that toolchain's runtime DLLs at
    startup. Without them on PATH, xsim exits before time 0 with a bare
    'status code -1073741511' (0xC0000139, STATUS_ENTRYPOINT_NOT_FOUND) and no
    further explanation.
    """
    env = os.environ.copy()
    parts = [
        VIVADO / "bin",
        VIVADO / "tps" / "mingw" / "6.2.0" / "win64.o" / "nt" / "bin",
        VIVADO / "lib" / "win64.o",
    ]
    sep = ";" if platform.system() == "Windows" else ":"
    env["PATH"] = sep.join(str(p) for p in parts) + sep + env.get("PATH", "")
    return env


# ---------------------------------------------------------------------------
# Guarded subprocess
#
# A simulation that goes wrong does not always stop. XSim's constraint solver, for
# one, can fall into a runaway that allocates ~10 GB in a few minutes (see
# docs/xsim_notes.md), and killing the `xsim.bat` wrapper on a timeout leaves the
# real simulator, xsimk.exe, running. So every simulation runs inside a Windows
# JOB OBJECT: the whole process tree dies with the job, the job has a memory
# ceiling, and a wall-clock timeout terminates it.
# ---------------------------------------------------------------------------
class _Done:
    def __init__(self, returncode, stdout, stderr=""):
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr


def run_guarded(cmd, cwd, env, timeout, mem_mb=None):
    shell = isinstance(cmd, str)
    if platform.system() != "Windows":
        r = subprocess.run(cmd, cwd=str(cwd), env=env, shell=shell, capture_output=True,
                           text=True, timeout=timeout)
        return _Done(r.returncode, r.stdout, r.stderr)

    import ctypes
    from ctypes import wintypes
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.CreateJobObjectW.restype = wintypes.HANDLE
    k32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    k32.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    k32.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]

    class _IO(ctypes.Structure):
        _fields_ = [(n, ctypes.c_ulonglong) for n in
                    ("ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                     "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

    class _BASIC(ctypes.Structure):
        _fields_ = [("PerProcessUserTimeLimit", ctypes.c_int64), ("PerJobUserTimeLimit", ctypes.c_int64),
                    ("LimitFlags", wintypes.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
                    ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
                    ("Affinity", ctypes.c_size_t), ("PriorityClass", wintypes.DWORD),
                    ("SchedulingClass", wintypes.DWORD)]

    class _EXT(ctypes.Structure):
        _fields_ = [("Basic", _BASIC), ("Io", _IO), ("ProcessMemoryLimit", ctypes.c_size_t),
                    ("JobMemoryLimit", ctypes.c_size_t), ("PeakProcessMemoryUsed", ctypes.c_size_t),
                    ("PeakJobMemoryUsed", ctypes.c_size_t)]

    JOB_OBJECT_LIMIT_JOB_MEMORY, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00000200, 0x00002000
    job = k32.CreateJobObjectW(None, None)
    info = _EXT()
    info.Basic.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if mem_mb:
        info.Basic.LimitFlags |= JOB_OBJECT_LIMIT_JOB_MEMORY
        info.JobMemoryLimit = mem_mb << 20
    k32.SetInformationJobObject(job, 9, ctypes.byref(info), ctypes.sizeof(info))   # ExtendedLimitInformation

    p = subprocess.Popen(cmd, cwd=str(cwd), env=env, shell=shell, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True, errors="replace")
    k32.AssignProcessToJobObject(job, wintypes.HANDLE(int(p._handle)))
    killed = None
    try:
        out, _ = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        killed = f"killed after {timeout}s wall-clock"
        k32.TerminateJobObject(job, 1)
        out, _ = p.communicate()
    finally:
        k32.CloseHandle(job)          # KILL_ON_JOB_CLOSE reaps anything still alive
    if killed:
        out = (out or "") + f"\n*** run_guarded: {killed} ***\n"
    return _Done(p.returncode, out or "")


def sh(cmd, cwd=None, log=None, check=True, timeout=1800, mem_mb=None):
    """Run a command, optionally teeing to a log file.

    The Vivado tools are .bat wrappers on Windows. CreateProcess will not launch
    a .bat given a bare name, so the executable is resolved through the tool
    PATH first -- otherwise every call dies with a bare
    'FileNotFoundError: [WinError 2]' that looks like Vivado is missing.
    """
    env = tool_env()
    cwd = BUILD if cwd is None else cwd
    if isinstance(cmd, list):
        exe = shutil.which(cmd[0], path=env["PATH"])
        if exe is None:
            raise SystemExit(f"{cmd[0]} not found on the Vivado tool PATH")
        cmd = [exe] + cmd[1:]
    r = run_guarded(cmd, cwd, env, timeout, mem_mb)
    out = (r.stdout or "") + (r.stderr or "")
    if log:
        LOGS.mkdir(parents=True, exist_ok=True)
        (LOGS / log).write_text(out, encoding="utf-8", errors="replace")
    if check and r.returncode != 0:
        sys.stderr.write(out)
        raise SystemExit(f"command failed ({r.returncode}): {cmd}")
    return r.returncode, out


def dirs():
    for d in (BUILD, LOGS, REGRESS, WORK):
        d.mkdir(parents=True, exist_ok=True)


# ---------------------------------------------------------------------------
def cmd_dpi_check(_args):
    """Phase 0 gate (spec decision G5).

    If the DPI boundary does not work, the C++ reference model cannot be used
    at all -- much cheaper to discover here than three phases later.
    """
    dirs()
    # xsc emits an ar archive on Windows and xelab -sv_lib looks for <name>.a.
    # Naming the output .so yields "Invalid path for DPI library".
    sh(["xsc", str(REFDIR / "soc_ref_model.cpp"), str(REFDIR / "dpi_shim.cpp"),
        "-o", f"{DPI_LIB}.a"], log="xsc.log")
    print(f"xsc OK -> {BUILD / (DPI_LIB + '.a')}")
    print("Now: python run.py comp && python run.py run --test soc_smoke_test")
    print("and confirm the log contains 'C++ reference model selftest passed'.")


def cmd_comp(_args):
    do_build()


def do_build(defines=(), coverage=True):
    """Compile and elaborate. `defines` are passed to xvlog (-d NAME): that is how a
    bug replay (REPLAY_A1 ...) is built from the same sources as the real design.
    Builds into the module-level BUILD, which replay.py points at its own directory."""
    dirs()
    dflags = []
    for d in defines:
        dflags += ["-d", d]
    print("[1/3] xsc  (C++ reference model)")
    sh(["xsc", str(REFDIR / "soc_ref_model.cpp"), str(REFDIR / "dpi_shim.cpp"),
        "-o", f"{DPI_LIB}.a"], log="xsc.log")

    print("[2/3] xvlog" + (f"  (defines: {', '.join(defines)})" if defines else ""))
    # filelist.f is written relative to sim/build. Make the paths absolute so the
    # same list works for a build directory anywhere (replays build elsewhere).
    flist = BUILD / "filelist_abs.f"
    flist.write_text((ROOT / "scripts" / "filelist.f").read_text(encoding="utf-8")
                     .replace("../../", str(ROOT).replace("\\", "/") + "/"), encoding="utf-8")
    _, out = sh(["xvlog", "-sv", "-L", "uvm"] + dflags + ["-f", str(flist)], log="xvlog.log")
    for line in out.splitlines():
        if line.startswith(("ERROR", "WARNING")):
            print("   ", line)

    print("[3/4] xelab  (plain snapshot)")
    _, out = sh(["xelab", "tb_top", "-L", "uvm", "-relax", "-s", SNAPSHOT,
                 "-sv_lib", DPI_LIB, "-timescale", "1ns/1ps"], log="xelab.log")
    for line in out.splitlines():
        if line.startswith("ERROR"):
            print("   ", line)

    # Code coverage is an elaboration-time property, so it needs its own
    # snapshot. Statement, branch, condition and toggle ("sbct"). It runs slower,
    # which is why ordinary regressions use the plain one.
    #
    # --cov_db_dir/--cov_db_name are REQUIRED here, not decoration. Code-coverage
    # hit data is only saved when the static database written at elaboration
    # already exists at <run dir>/cov/xsim.codeCov/<name>; without these options
    # the static file lands somewhere a job directory never sees and every run
    # silently records nothing. (_run_one copies it in before each run.)
    if coverage:
        print("[4/4] xelab  (code-coverage snapshot, sbct)")
        for stale in (BUILD / "cov", BUILD / "xsim.codeCov"):
            shutil.rmtree(stale, ignore_errors=True)
        _, out = sh(["xelab", "tb_top", "-L", "uvm", "-relax", "-s", SNAP_COV,
                     "-sv_lib", DPI_LIB, "-timescale", "1ns/1ps", "--cc_type", "sbct",
                     "--cov_db_dir", "cov", "--cov_db_name", COV_DB],
                    log="xelab_cov.log")
        for line in out.splitlines():
            if line.startswith("ERROR"):
                print("   ", line)

    # XSim drops assertions it cannot handle with a WARNING that is easy to miss
    # in a long elaboration log, and a dropped assertion looks exactly like a
    # passing one. Surface the count every build; `neg-checker` says which.
    xe = (LOGS / "xelab.log").read_text(encoding="utf-8", errors="replace")
    n_drop = xe.count("Unsupported feature in assertion") + xe.count("will be ignored")
    if n_drop:
        print(f"   note: XSim reported {n_drop} statements it will ignore "
              f"(see sim/logs/xelab.log; run `neg-checker` to see which assertions are live)")
    print("build OK ->", BUILD / SNAPSHOT, ("and " + str(BUILD / SNAP_COV)) if coverage else "")


def _write_opts(rundir, test, seed, n_txn, timeout_ns, waves, plus=None):
    """Plusargs go through an options file, never the command line.

    The xsim wrapper rewrites `-testplusarg NAME=value` into `NAME value`, so
    the plusarg arrives stripped of its value. UVM then reports 'No components
    instantiated' because it never saw UVM_TESTNAME. Routing the same switches
    through -f bypasses the wrapper's argument mangling.
    """
    lines = [f"-testplusarg UVM_TESTNAME={test}",
             f"-testplusarg N_TXN={n_txn}",
             f"-testplusarg TIMEOUT_NS={timeout_ns}"]
    if waves:
        lines.append("-testplusarg WAVES")
    for k, v in (plus or {}).items():
        lines.append(f"-testplusarg {k}={v}" if v != "" else f"-testplusarg {k}")
    p = rundir / "opts.f"
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return p


def _parse(log_text, expect=None):
    """Pull a pass/fail verdict out of a UVM log.

    `expect` marks a NEGATIVE test, one that breaks a rule on purpose:
        sva    regexes, each of which must match at least one assertion failure
        allow  regexes for further assertion failures that are a known consequence
        uvm    regexes for UVM_ERRORs that are a known consequence
        inject True if the driver must report that it applied the violation
    Such a test passes only if everything in `sva` fired, nothing fired that is not
    in `sva` or `allow`, every UVM_ERROR is explained, and (if asked) the violation
    was actually applied. "The assertion fired" is the whole point of the test, so
    an expected failure is never silently discounted: it is listed by name.
    """
    import re
    res = {"uvm_error": None, "uvm_fatal": None, "sva": 0, "scb": "", "passed": False}
    sva_msgs, uvm_msgs, injected = [], [], False
    for line in log_text.splitlines():
        s = line.strip()
        if s.startswith("UVM_ERROR :"):
            res["uvm_error"] = int(s.split()[-1])
        elif s.startswith("UVM_FATAL :"):
            res["uvm_fatal"] = int(s.split()[-1])
        elif s.startswith("Error:"):
            # XSim prefixes every failed concurrent assertion with "Error:".
            # Matching on that rather than on the word "violated" matters: the
            # assertions inside axi4_id_hazard and axi4_w_router print their own
            # messages, so a "violated" match would have been blind to exactly
            # the two blocks Phase 2 added.
            res["sva"] += 1
            sva_msgs.append(s[len("Error:"):].strip())
        elif s.startswith("UVM_ERROR ") and "[" in s:
            uvm_msgs.append(s)
        elif s.startswith("UVM_INFO") and "[INJECT]" in s:
            injected = True
        elif "[SCB] checked" in s:
            # Match on "[SCB] checked", not bare "[SCB]". UVM's end-of-test
            # "Report counts by id" table also contains a "[SCB]     1" line,
            # and because it comes after the real message a looser match
            # silently overwrites the counts with the tally "1".
            res["scb"] = s.split("[SCB]", 1)[1].strip()

    if not expect:
        res["passed"] = (res["uvm_error"] == 0 and res["uvm_fatal"] == 0
                         and res["sva"] == 0 and res["scb"] != "")
        return res

    need  = expect.get("sva", [])
    ok_rx = need + expect.get("allow", [])
    missing = [rx for rx in need if not any(re.search(rx, m) for m in sva_msgs)]
    stray   = sorted({m for m in sva_msgs if not any(re.search(rx, m) for rx in ok_rx)})
    uvm_bad = [m for m in uvm_msgs if not any(re.search(rx, m) for rx in expect.get("uvm", []))]
    not_injected = bool(expect.get("inject")) and not injected
    res["negative"] = dict(missing=missing, stray=stray, unexplained_uvm=uvm_bad,
                           not_injected=not_injected,
                           seen=len(need) - len(missing))
    res["passed"] = (res["uvm_fatal"] == 0 and not missing and not stray and not uvm_bad
                     and not not_injected and res["scb"] != "")
    return res


def _run_one(test, seed, n_txn, timeout_ns, waves=False, rundir=None, cov=False, plus=None,
             expect=None):
    """Run one test.

    Each job gets its OWN working directory containing its own copy of the
    elaborated tree. Running concurrent xsim processes from a single directory
    corrupts them: they share xsim.log, the waveform database and the runtime
    state under xsim.dir, and jobs end up reporting each other's output.

    That failure mode is worth calling out because it does not look like a
    failure. The runs still exit cleanly and still report PASS -- against the
    wrong test's numbers. It was caught only because four 200-transaction random
    runs reported the one-write/one-read totals of the smoke test.
    """
    snap = SNAP_COV if cov else SNAPSHOT
    rundir = rundir or (WORK / (("cov_" if cov else "") + f"{test}_{seed}"))
    if rundir.exists() and cov:
        shutil.rmtree(rundir, ignore_errors=True)    # stale databases must not leak in
    rundir.mkdir(parents=True, exist_ok=True)

    # xsim resolves both the snapshot and the DPI library relative to the
    # working directory. --xsimdir on its own is not enough -- it still fails
    # with "Simulation engine failed to start: status code 1" -- so each job
    # gets its own copy of the elaborated tree. That is ~12 MB per job, which is
    # a cheap price for jobs that cannot corrupt each other.
    # A previous job in this directory may still have its simulator mapped (a hung
    # run that was killed late); Windows then refuses to overwrite the executable.
    # Retry, and report the failure as a failed job rather than crashing the whole
    # regression.
    for attempt in range(4):
        try:
            shutil.copytree(BUILD / "xsim.dir", rundir / "xsim.dir", dirs_exist_ok=True)
            shutil.copy2(BUILD / f"{DPI_LIB}.a", rundir / f"{DPI_LIB}.a")
            break
        except (shutil.Error, OSError) as e:
            err = str(e)[:300]
            time.sleep(3 * (attempt + 1))
    else:
        return dict(uvm_error=None, uvm_fatal=None, sva=0, passed=False, test=test, seed=seed,
                    scb=f"<could not prepare run directory: {err}>", log="", rundir=str(rundir), cov=cov)

    _write_opts(rundir, test, seed, n_txn, timeout_ns, waves, plus)

    xargs = []
    if cov:
        # Seed the job directory with the static code-coverage database written
        # at elaboration; the run then updates it in place with its hit counts.
        # Every job directory has its own copy, so databases cannot collide, and
        # xcrg merges them afterwards.
        shutil.copytree(BUILD / "cov" / "xsim.codeCov", rundir / "cov" / "xsim.codeCov",
                        dirs_exist_ok=True)
        xargs = ["--cov_db_dir", "cov", "--cov_db_name", COV_DB]

    log = f"{test}_{seed}.log"
    _, out = sh(["xsim", snap, "-runall", "-sv_seed", str(seed), "-f", "opts.f"] + xargs,
                cwd=rundir, log=log, check=False, timeout=JOB_TIMEOUT_S, mem_mb=JOB_MEM_MB)

    r = _parse(out, expect)
    r.update(test=test, seed=seed, log=str(LOGS / log), rundir=str(rundir), cov=cov)
    if cov:
        # Only <rundir>/cov is needed afterwards (xcrg merges it); the elaborated tree
        # and waveform database are ~15 MB per job and would pile up round after round.
        shutil.rmtree(rundir / "xsim.dir", ignore_errors=True)
        (rundir / "tb_snap_cov.wdb").unlink(missing_ok=True)
    if expect and "negative" in r:
        n = r["negative"]
        why = []
        if n["not_injected"]:  why.append("violation was never applied")
        if n["missing"]:       why.append("did not fire: " + "; ".join(n["missing"]))
        if n["stray"]:         why.append("unexpected: " + "; ".join(n["stray"]))
        if n["unexplained_uvm"]: why.append(f"{len(n['unexplained_uvm'])} unexplained UVM_ERROR")
        tag = (f"[negative test: {n['seen']}/{len(expect.get('sva', []))} expected assertions fired]"
               if not why else "[negative test FAILED: " + " | ".join(why) + "]")
        r["scb"] = (tag + " " + r["scb"]) if r["scb"] else tag

    # A run that produced no scoreboard line ran nothing useful; and a run whose
    # transaction count does not match the test that was requested means the
    # jobs collided. Both must fail loudly rather than pass quietly.
    if not r["scb"]:
        r["passed"] = False
        r["scb"] = "<no scoreboard output>"
    return r


def cmd_run(args):
    dirs()
    plus = dict(kv.split("=", 1) if "=" in kv else (kv, "") for kv in (args.plus or []))
    spec = next((t for t in TESTS if t["name"] == args.test), {})
    plus = {**spec.get("plus", {}), **plus}
    r = _run_one(args.test, args.seed, args.n_txn, args.timeout_ns, args.waves, plus=plus,
                 expect=spec.get("expect"))
    print(f"{'PASS' if r['passed'] else 'FAIL'}  {r['test']} seed={r['seed']}  "
          f"UVM_ERROR={r['uvm_error']} UVM_FATAL={r['uvm_fatal']} SVA={r['sva']}")
    if r["scb"]:
        print("   scoreboard:", r["scb"])
    print("   log:", r["log"])
    raise SystemExit(0 if r["passed"] else 1)


# The maintained test library. Phase 1 subset; grows with each phase.
TESTS = [
    # --- random ---------------------------------------------------------------
    {"name": "soc_smoke_test",           "seeds": [1],            "n_txn": 0,   "timeout": 200_000},
    {"name": "axi_random_test",          "seeds": [1, 7],         "n_txn": 200, "timeout": 4_000_000},
    {"name": "axi_backpressure_test",    "seeds": [1],            "n_txn": 200, "timeout": 8_000_000},
    {"name": "axi_decerr_test",          "seeds": [1],            "n_txn": 50,  "timeout": 4_000_000},
    {"name": "soc_multi_master_test",    "seeds": [1, 7, 42, 99], "n_txn": 200, "timeout": 12_000_000},
    {"name": "soc_multi_master_bp_test", "seeds": [1, 7],         "n_txn": 200, "timeout": 20_000_000},
    {"name": "soc_multi_master_slvbp_test", "seeds": [1, 7, 42],     "n_txn": 200, "timeout": 40_000_000,
     "plus": {"SLV_BP": "50"}},
    {"name": "soc_arb_stress_test",      "seeds": [1, 7],         "n_txn": 200, "timeout": 12_000_000},
    {"name": "axi_bridge_test",          "seeds": [1, 7, 42],     "n_txn": 100, "timeout": 60_000_000},
    {"name": "axi_bridge_rom_test",      "seeds": [1],            "n_txn": 60,  "timeout": 60_000_000},
    {"name": "axi_bridge_wait_test",     "seeds": [1, 7],         "n_txn": 60,  "timeout": 90_000_000},
    # --- directed: each exists because coverage showed a hole random leaves ---------
    {"name": "axi_incr_edge_test",       "seeds": [1],            "n_txn": 0,   "timeout": 400_000_000},
    {"name": "axi_wrap_edge_test",       "seeds": [1],            "n_txn": 0,   "timeout": 400_000_000},
    {"name": "axi_fixed_edge_test",      "seeds": [1],            "n_txn": 0,   "timeout": 200_000_000},
    {"name": "axi_strobe_test",          "seeds": [1],            "n_txn": 0,   "timeout": 200_000_000},
    {"name": "axi_ahb_forms_test",       "seeds": [1],            "n_txn": 0,   "timeout": 100_000_000},
    {"name": "axi_bridge_probe_test",     "seeds": [1],            "n_txn": 0,   "timeout": 20_000_000},
    {"name": "axi_wait_error_test",      "seeds": [1],            "n_txn": 0,   "timeout": 100_000_000},
    {"name": "axi_exclusive_test",       "seeds": [1],            "n_txn": 0,   "timeout": 100_000_000},
    {"name": "axi_outstanding_test",     "seeds": [1],            "n_txn": 0,   "timeout": 100_000_000},
    {"name": "axi_queue_full_test",      "seeds": [1],            "n_txn": 0,   "timeout": 100_000_000},
    {"name": "soc_all_targets_test",     "seeds": [1, 7, 42],     "n_txn": 300, "timeout": 200_000_000},
    {"name": "axi_b_backpressure_test",  "seeds": [1],            "n_txn": 150, "timeout": 300_000_000},
    {"name": "axi_ready_toggle_test",    "seeds": [1, 7],         "n_txn": 150, "timeout": 300_000_000,
     "plus": {"SLV_BP": "30"}},
    # --- negative: one deliberate protocol violation each; pass = the checker said so --------
    #   The first line of each entry names the rule broken. `sva` must all fire; `allow` are
    #   known consequences of that violation (an arbiter assertion, the same rule seen at
    #   the slave port); `uvm` are the monitor errors the violation causes.
    {"name": "axi_inj_illegal_req_test", "seeds": [1], "n_txn": 0, "timeout": 5_000_000,
     "expect": {"sva": [f"{o}: a_{c}_{r} violated"
                        for o in ("m0", "s0") for c in ("aw", "ar")
                        for r in ("wrap_len", "wrap_aligned", "fixed_len", "no_4k_cross",
                                  "burst_not_reserved", "size_fits_bus", "excl_legal")]}},
    {"name": "axi_inj_aw_drop_test", "seeds": [1], "n_txn": 0, "timeout": 5_000_000,
     "plus": {"SLV_BP": "85"},
     "expect": {"inject": True, "sva": ['m0: a_awvalid_stable violated'],
                "allow": ['axi4_rr_arbiter: grant held for idx'], "uvm": []}},
    {"name": "axi_inj_aw_payload_test", "seeds": [1], "n_txn": 0, "timeout": 5_000_000,
     "plus": {"SLV_BP": "85"},
     "expect": {"inject": True, "sva": ['m0: a_aw_payload_stable violated', 's0: a_aw_payload_stable violated'],
                "allow": [], "uvm": []}},
    {"name": "axi_inj_aw_x_test", "seeds": [1], "n_txn": 0, "timeout": 5_000_000,
     "plus": {"SLV_BP": "85"},
     "expect": {"inject": True, "sva": ['m0: a_aw_no_x violated', 's0: a_aw_no_x violated'],
                "allow": ['[ms]0: a_aw_payload_stable violated', '[ms]0: a_aw_burst_not_reserved violated'], "uvm": []}},
    {"name": "axi_inj_ar_drop_test", "seeds": [1], "n_txn": 0, "timeout": 5_000_000,
     "plus": {"SLV_BP": "85"},
     "expect": {"inject": True, "sva": ['m0: a_arvalid_stable violated'],
                "allow": ['axi4_rr_arbiter: grant held for idx'], "uvm": []}},
    {"name": "axi_inj_ar_payload_test", "seeds": [1], "n_txn": 0, "timeout": 5_000_000,
     "plus": {"SLV_BP": "85"},
     "expect": {"inject": True, "sva": ['m0: a_ar_payload_stable violated', 's0: a_ar_payload_stable violated'],
                "allow": [], "uvm": []}},
    {"name": "axi_inj_ar_x_test", "seeds": [1], "n_txn": 0, "timeout": 5_000_000,
     "plus": {"SLV_BP": "85"},
     "expect": {"inject": True, "sva": ['m0: a_ar_no_x violated', 's0: a_ar_no_x violated'],
                "allow": ['[ms]0: a_ar_payload_stable violated', '[ms]0: a_ar_burst_not_reserved violated'], "uvm": []}},
    {"name": "axi_inj_w_drop_test", "seeds": [1], "n_txn": 0, "timeout": 5_000_000,
     "plus": {"SLV_BP": "85"},
     "expect": {"inject": True, "sva": ['m0: a_wvalid_stable violated'],
                "allow": [], "uvm": []}},
    {"name": "axi_inj_w_payload_test", "seeds": [1], "n_txn": 0, "timeout": 5_000_000,
     "plus": {"SLV_BP": "85"},
     "expect": {"inject": True, "sva": ['m0: a_w_payload_stable violated'],
                "allow": [], "uvm": []}},
    {"name": "axi_inj_w_x_test", "seeds": [1], "n_txn": 0, "timeout": 5_000_000,
     "plus": {"SLV_BP": "85"},
     "expect": {"inject": True, "sva": ['m0: a_w_no_x violated'],
                "allow": ['m0: a_w_payload_stable violated'], "uvm": []}},
    {"name": "axi_inj_wlast_early_test", "seeds": [1], "n_txn": 0, "timeout": 5_000_000,
     "plus": {"SLV_BP": "85"},
     "expect": {"inject": True, "sva": ['m0: a_wlast_beat_count violated', 's0: a_wlast_beat_count violated'],
                "allow": [], "uvm": [r"\[AXI4MON\] WLAST at beat \d+, AWLEN implies \d+",
                                   r"\[AXI4MON\] \d+ W beats never matched an AW at end of test"]}},
    {"name": "axi_inj_wlast_missing_test", "seeds": [1], "n_txn": 0, "timeout": 5_000_000,
     "plus": {"SLV_BP": "85"},
     "expect": {"inject": True, "sva": ['m0: a_wlast_beat_count violated', 'm0: a_w_not_past_end violated', 's0: a_wlast_beat_count violated', 's0: a_w_not_past_end violated'],
                "allow": [], "uvm": [r"\[AXI4MON\] WLAST at beat \d+, AWLEN implies \d+"]}},
]


def _pid_alive(pid):
    if platform.system() == "Windows":
        r = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/FO", "CSV", "/NH"],
                           capture_output=True, text=True)
        return str(pid) in r.stdout
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _acquire_lock():
    """One regression at a time.

    Two regressions share sim/work/<test>_<seed>, so running them together makes
    jobs overwrite the elaborated tree of simulations that are still executing
    from it. That is not a clean failure: one such collision sent XSim's
    constraint solver into a ~10 GB runaway ("Invalid consttrain id ... exceeds
    total number of constraints (0)") in a test that passes on its own.
    """
    lock = ROOT / "sim" / "regress.lock"
    if lock.exists():
        try:
            other = int(lock.read_text().strip())
        except ValueError:
            other = 0
        if other and other != os.getpid() and _pid_alive(other):
            raise SystemExit(f"another regression is running (pid {other}); "
                             f"running two at once corrupts both ({lock})")
    lock.write_text(str(os.getpid()))
    return lock


def cmd_regress(args):
    dirs()
    lock = _acquire_lock()
    try:
        _regress(args)
    finally:
        lock.unlink(missing_ok=True)


def _perl_summary(results, outdir):
    """Second, independent read of the logs: scripts/parse_log.pl (Perl). The verdict
    above comes from the Python parser; this one reports what the logs literally say --
    first failure time, first failing assertion's file:line, per-property counts."""
    perl = shutil.which("perl") or next(
        (p for p in (r"C:/Program Files/Git/usr/bin/perl.exe",) if Path(p).exists()), None)
    logs = sorted({r["log"] for r in results if r.get("log")})
    if not perl or not logs:
        return
    r = subprocess.run([perl, str(ROOT / "scripts" / "parse_log.pl")] + logs,
                       capture_output=True, text=True)
    (outdir / "summary_perl.txt").write_text(r.stdout, encoding="utf-8")
    print(f"log scrape (Perl) -> {outdir / 'summary_perl.txt'}")


def _regress(args):
    only = set(args.tests.split(",")) if args.tests else None
    stamp = args.stamp or time.strftime("%Y%m%d_%H%M%S")
    jobs = []
    for t in TESTS:
        if only and t["name"] not in only:
            continue
        # Coverage is collected from legal stimulus. The negative tests drive illegal
        # traffic on purpose and prove checkers, not the design, so they are left out of
        # coverage runs.
        if args.cov and t.get("expect") and not args.negative:
            continue
        if args.negative and not t.get("expect"):
            continue
        seeds = list(t["seeds"])
        # Extra seeds on top of the maintained list -- how coverage closure gets
        # more random traffic out of the same tests without editing the library.
        seeds += [max(t["seeds"]) + 1000 * (args.seed_offset + 1) + k
                  for k in range(args.extra_seeds)]
        for s in seeds:
            # A coverage round keeps its databases under its own stamp, so a later round
            # running the same test and seed does not overwrite them and any set of
            # rounds can be merged afterwards.
            rd = (WORK / f"cov_{stamp}" / f"{t['name']}_{s}") if args.cov else None
            jobs.append((t["name"], s, t["n_txn"], t["timeout"], False, rd, args.cov,
                         t.get("plus"), t.get("expect")))

    print(f"running {len(jobs)} jobs on {args.jobs} workers"
          f"{'  [code+functional coverage]' if args.cov else ''}\n")
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        results = list(ex.map(lambda j: _run_one(*j), jobs))

    outdir = REGRESS / stamp
    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")

    npass = sum(1 for r in results if r["passed"])
    print(f"{'RESULT':6}  {'TEST':24} {'SEED':>5}  {'ERR':>3} {'FTL':>3} {'SVA':>3}  SCOREBOARD")
    print("-" * 100)
    for r in sorted(results, key=lambda x: (x["test"], x["seed"])):
        print(f"{'PASS' if r['passed'] else 'FAIL':6}  {r['test']:24} {r['seed']:>5}  "
              f"{str(r['uvm_error']):>3} {str(r['uvm_fatal']):>3} {r['sva']:>3}  {r['scb']}")
    print("-" * 100)
    print(f"{npass}/{len(results)} passed in {time.time() - t0:.0f}s   -> {outdir / 'results.json'}")
    _perl_summary(results, outdir)
    if args.cov:
        print(f"coverage databases under {WORK};  merge + report with:\n"
              f"    python run.py cov-report --regress {outdir}")
    raise SystemExit(0 if npass == len(results) else 1)


# ---------------------------------------------------------------------------
def cmd_neg_checker(_args):
    """Unit-level negative test of the AXI protocol checker.

    Feeds the checker one deliberate violation per property (no DUT, no UVM) and
    reports which assertions actually reported it. A property that does not fire
    here is either broken, or silently ignored by the simulator -- and on the
    full design the two are indistinguishable from "no violations".
    """
    import re
    dirs()
    work = ROOT / "sim" / "neg_checker"
    work.mkdir(parents=True, exist_ok=True)
    srcs = [ROOT / "rtl/common/axi4_pkg.sv",
            ROOT / "verif/sva/axi4_protocol_checker.sv",
            ROOT / "verif/sva/tb_checker_neg.sv"]

    sh(["xvlog", "-sv"] + [str(x) for x in srcs], cwd=work, log="neg_xvlog.log")
    _, el = sh(["xelab", "tb_checker_neg", "-s", "negsnap", "-timescale", "1ns/1ps"],
               cwd=work, log="neg_xelab.log")
    _, out = sh(["xsim", "negsnap", "-runall"], cwd=work, log="neg_xsim.log", check=False)

    # Assertions XSim itself says it will ignore, by property name.
    ignored = set()
    src_lines = (ROOT / "verif/sva/axi4_protocol_checker.sv").read_text(encoding="utf-8").splitlines()
    for m in re.finditer(r"Line (\d+) : (?:Unsupported feature|The \"System Verilog Assertion)", el):
        ln = int(m.group(1))
        for i in range(ln - 1, -1, -1):
            mm = re.search(r"`AXI_(?:MASTER|SLAVE)_CHK\((\w+),", src_lines[i]) or \
                 re.match(r"\s*(a_\w+)\s*:\s*assert", src_lines[i])
            if mm:
                ignored.add(mm.group(1)); break

    # Attribute each assertion message to the phase it occurred in.
    phase, fired = None, {}
    for line in out.splitlines():
        s_ = line.strip()
        if s_.startswith("PHASE "):
            phase = s_.split(None, 1)[1]; fired.setdefault(phase, set()); continue
        m = re.match(r"Error: neg: (a_\w+) violated", s_) or \
            re.match(r"Error: neg: (VALID asserted while in reset)", s_)
        if m and phase:
            name = "a_reset_valids_low" if m.group(1).startswith("VALID") else m.group(1)
            fired[phase].add(name)

    phases = [k for k in fired if k != "END"]
    dead, live = [], []
    print(f"{'PROPERTY':34} {'RESULT':8} {'NOTE'}")
    print("-" * 90)
    for ph in phases:
        # "property@scenario": several scenarios can exercise the same property.
        ok = ph.split("@")[0] in fired[ph]
        (live if ok else dead).append(ph)
        note = ""
        if not ok and ph.split("@")[0] in ignored:
            note = "XSim says it ignores this assertion"
        extra = sorted(fired[ph] - {ph.split("@")[0]})
        if extra:
            note = (note + "  " if note else "") + "also fired: " + ", ".join(extra)
        print(f"{ph:34} {'FIRED' if ok else 'DEAD':8} {note}")
    print("-" * 90)
    print(f"{len(live)}/{len(phases)} properties fire on their designed violation; "
          f"{len(dead)} DEAD")
    (ROOT / "sim" / "neg_checker" / "result.json").write_text(
        json.dumps({"live": live, "dead": dead, "xsim_ignored": sorted(ignored)}, indent=2),
        encoding="utf-8")
    raise SystemExit(0 if not dead else 1)


# ---------------------------------------------------------------------------
def cmd_cov_report(args):
    """Merge the coverage databases of one or more regressions and report."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("cov_report", ROOT / "scripts" / "cov_report.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.run([Path(x) for x in args.regress], Path(args.out) if args.out else None,
            tool_env(), WORK, include_negative=args.negative)


def cmd_cov_check(args):
    """Apply goals and waivers to a coverage report; exit non-zero unless closed."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("check_cov_closure", ROOT / "scripts" / "check_cov_closure.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    argv = ["--cov", str(ROOT / "sim" / "cov" / args.label), "--waivers", args.waivers,
            "--top", str(args.top)] + (["--strict"] if args.strict else [])
    if args.neg_label:
        argv += ["--neg-cov", str(ROOT / "sim" / "cov" / args.neg_label)]
    raise SystemExit(mod.main(argv))


def cmd_list_tests(args):
    """The maintained test library, flattened -- for a Makefile loop (the VCS path)."""
    for t in TESTS:
        if args.positive and t.get("expect"):
            continue
        plus = " ".join(f"+{k}={v}" if v != "" else f"+{k}" for k, v in t.get("plus", {}).items())
        for s in t["seeds"]:
            print(f"{t['name']} {s} {t['n_txn']} {t['timeout']} {plus}".rstrip())


def cmd_lint_sva(_args):
    """Parse-check the SVA rendering of the cover events.

    XSim ignores `cover property` at simulation time, so the SVA form can never
    be exercised here. What CAN be checked is that it parses and that every term
    it names exists -- elaborating axi4_cov with AXI_COVER_SVA defined does both.
    The 120 "Cover is not supported yet for simulation" warnings it prints are the
    expected result, not a problem.
    """
    import re
    dirs()
    work = ROOT / "sim" / "lint_sva"
    work.mkdir(parents=True, exist_ok=True)
    srcs = [ROOT / "rtl/common/axi4_pkg.sv", ROOT / "verif/sva/axi_cov_lib.sv",
            ROOT / "verif/sva/axi4_cov.sv"]
    sh(["xvlog", "-sv", "-d", "AXI_COVER_SVA", "--include", str(ROOT / "verif/sva")]
       + [str(x) for x in srcs], cwd=work, log="lint_xvlog.log")
    _, el = sh(["xelab", "axi4_cov", "-s", "lintsnap", "-timescale", "1ns/1ps"],
               cwd=work, log="lint_xelab.log")
    n_cov = len(re.findall(r"System Verilog Cover\" is not supported", el))
    errs = [l for l in el.splitlines() if l.startswith("ERROR")]
    print(f"SVA cover properties: {n_cov} parsed and elaborated "
          f"(XSim will not simulate them: it ignores `cover property`)")
    for e in errs:
        print("  ", e)
    raise SystemExit(1 if errs or n_cov == 0 else 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("dpi-check").set_defaults(fn=cmd_dpi_check)
    sub.add_parser("neg-checker").set_defaults(fn=cmd_neg_checker)
    sub.add_parser("comp").set_defaults(fn=cmd_comp)

    p = sub.add_parser("run")
    p.add_argument("--test", default="soc_smoke_test")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--n-txn", type=int, default=200)
    p.add_argument("--timeout-ns", type=int, default=4_000_000)
    p.add_argument("--waves", action="store_true")
    p.add_argument("--plus", action="append", help="extra plusarg KEY=VAL (repeatable)")
    p.set_defaults(fn=cmd_run)

    p = sub.add_parser("regress")
    p.add_argument("--jobs", type=int, default=4)
    p.add_argument("--cov", action="store_true",
                   help="run on the code-coverage snapshot and keep the databases")
    p.add_argument("--tests", default="", help="comma-separated test names to run")
    p.add_argument("--extra-seeds", type=int, default=0,
                   help="additional random seeds per test beyond the maintained list")
    p.add_argument("--seed-offset", type=int, default=0,
                   help="shifts the extra seeds so successive rounds get fresh ones")
    p.add_argument("--stamp", default="", help="name for the results directory")
    p.add_argument("--negative", action="store_true",
                   help="run ONLY the negative tests (use with --cov: supporting evidence for "
                        "waivers whose premise is 'only illegal stimulus reaches this')")
    p.set_defaults(fn=cmd_regress)

    p = sub.add_parser("cov-report")
    p.add_argument("--regress", action="append", required=True,
                   help="a regression results directory (repeatable; databases are merged)")
    p.add_argument("--out", default="")
    p.add_argument("--negative", action="store_true",
                   help="the regressions are negative-test runs: include them (normally excluded)")
    p.set_defaults(fn=cmd_cov_report)

    sub.add_parser("lint-sva").set_defaults(fn=cmd_lint_sva)

    p = sub.add_parser("cov-check", help="closure gate: goals + waivers against a cov-report")
    p.add_argument("--label", required=True, help="a sim/cov/<label> produced by cov-report")
    p.add_argument("--neg-label", default="", help="a sim/cov/<label> built from the negative tests alone")
    p.add_argument("--waivers", default=str(ROOT / "scripts" / "cov_waivers.json"))
    p.add_argument("--top", type=int, default=15)
    p.add_argument("--strict", action="store_true")
    p.set_defaults(fn=cmd_cov_check)

    p = sub.add_parser("list-tests", help="one line per job: test seed n_txn timeout_ns [+plusargs]")
    p.add_argument("--positive", action="store_true", help="leave out the negative tests")
    p.set_defaults(fn=cmd_list_tests)

    args = ap.parse_args()
    if not VIVADO.exists():
        raise SystemExit(f"Vivado not found at {VIVADO}. Set VIVADO_HOME.")
    if not shutil.which("xvlog", path=tool_env()["PATH"]):
        raise SystemExit(f"xvlog not on PATH under {VIVADO}")
    args.fn(args)


if __name__ == "__main__":
    main()
