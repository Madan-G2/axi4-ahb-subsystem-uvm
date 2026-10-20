# Test library

The maintained list is the `TESTS` table in [`scripts/run.py`](../scripts/run.py): name, seeds,
transaction count, timeout, extra plusargs, and — for negative tests — the assertions that must fire.
`python scripts/run.py list-tests` prints it flat; `python scripts/run.py regress --tests a,b` runs a subset;
`--extra-seeds N` adds random seeds without editing the table.

Each test below says **why it exists**. The directed ones exist because coverage measurement showed
a hole that random stimulus does not fill (the baseline was random-only: 84.9% functional, 91.5%
statement, 78.1% branch).

## Random

| test | seeds | what it does |
|---|---|---|
| `soc_smoke_test` | 1 | one write, one read; the two-minute sanity check |
| `axi_random_test` | 1, 7 | one master, SRAM only: constrained-random mix of bursts, sizes, strobes, IDs |
| `axi_backpressure_test` | 1 | the same with the master slow to take responses |
| `axi_decerr_test` | 1 | unmapped addresses: the default slave must answer DECERR with the right beat count and RLAST |
| `soc_multi_master_test` | 1, 7, 42, 99 | three masters at once across SRAM, AHB registers and CSR |
| `soc_multi_master_bp_test` | 1, 7 | with response backpressure on every master |
| `soc_multi_master_slvbp_test` | 1, 7, 42 | with the **slaves** randomly withholding AW/W/AR READY (`+SLV_BP=50`). Added after bug A6, whose feature it exercises |
| `soc_arb_stress_test` | 1, 7 | all three masters onto one slave: arbitration and grant hold |
| `axi_bridge_test` | 1, 7, 42 | traffic to the AHB register block through the bridge (narrow, unaligned, sparse strobes) |
| `axi_bridge_rom_test` | 1 | boot ROM: reads fine, writes refused with SLVERR |
| `axi_bridge_wait_test` | 1, 7 | the wait/error slave: waits from the address, ERROR from the address |
| `soc_all_targets_test` | 1, 7, 42 | every master, every kind of target (SRAM, firmware region for M0, registers, ROM, wait/error, AHB hole, CSR, unmapped) |

## Directed — each fills a hole the random tests leave

| test | fills |
|---|---|
| `axi_incr_edge_test` | INCR bursts at the page base, ending exactly on / one beat short of a 4KB boundary, unaligned, all lengths 1–256 and all sizes |
| `axi_wrap_edge_test` | every legal WRAP length × size × start slot in the container |
| `axi_fixed_edge_test` | FIXED at every length and size, including unaligned starts |
| `axi_strobe_test` | zero strobes, sparse strobes, partial first/last beat, every narrow lane position — against a known background so an unprotected byte shows |
| `axi_ahb_forms_test` | the exact shapes the bridge turns into INCR4/8/16, WRAP4/8/16, undefined-length INCR, and the 1KB restart |
| `axi_wait_error_test` | wait states 0–15, ERROR from the first transfer, ERROR part-way through an AHB burst (SEQ position), ERROR in WRAP/FIXED, the AHB hole, ROM writes |
| `axi_exclusive_test` | exclusive access: success, broken by a write, wrong address, no reservation, two IDs on one location, sizes, capacity, re-arming, writes that do *not* clear the reservation; single-master and cross-master; SRAM, CSR and the AHB window (which must answer plain OKAY). **Found bug A5** |
| `axi_outstanding_test` | 16 reads in flight, writes to slaves of different speed, same ID to different slaves, one ID saturating its budget, back-to-back unmapped requests, write data ahead of its address |
| `axi_queue_full_test` | the SRAM slave's AW, B and AR queues driven to their limits (AW first with late data; BREADY crawling; RREADY crawling) |
| `axi_b_backpressure_test` | long response backpressure on B and R |
| `axi_ready_toggle_test` | RREADY/BREADY toggling while idle, and slave-side READY jitter |

## Negative — one deliberate protocol violation each

Each passes only if the listed assertions fire, nothing unexplained fires, every UVM error is accounted
for, and the driver reports that it really applied the violation. They are left out of coverage runs.

| test | breaks | expected |
|---|---|---|
| `axi_inj_illegal_req_test` | seven kinds of illegal burst request, as write and as read: WRAP length, WRAP alignment, FIXED length, 4KB crossing, reserved burst type, size wider than the bus, 3-byte exclusive. The scoreboard stays on: the legal traffic around each illegal one is checked, so "the DUT carried on working" is part of the test | the 14 rules × master-side and slave-side checker = 28 distinct assertions |
| `axi_inj_aw_drop_test` / `ar_drop` / `w_drop` | VALID withdrawn while VALID && !READY | `a_awvalid_stable` etc. (+ the arbiter's own assertion for AW/AR) |
| `axi_inj_aw_payload_test` / `ar_payload` / `w_payload` | a payload field changed while stalled | `a_aw_payload_stable` etc. |
| `axi_inj_aw_x_test` / `ar_x` / `w_x` | a control field driven X | `a_aw_no_x` etc. |
| `axi_inj_wlast_early_test` | WLAST one beat early | `a_wlast_beat_count` |
| `axi_inj_wlast_missing_test` | last beat without WLAST, extra beat carries it | `a_wlast_beat_count`, `a_w_not_past_end` |

Why they exist: the unit harness (`neg-checker`) proves every property *can* fire, but not that the
checker instance on master 1 is wired to master 1. Each injection happens on master 0 only, and any
assertion firing on masters 1 or 2 would fail the test.
