# Implementation Guide — Project Setup and Build

Pipelined RISC-V ALU + Booth MAC · ZedBoard (Zynq-7000, XC7Z020-CLG484-1)

This guide covers **getting the project built**: which files go where, how the
two debug IP cores must be configured, and what a correct build looks like.

For what to do once the board is programmed — the VIO dashboard, ILA triggering,
and the seven hardware test cases — see `docs/FPGA_Implementation_Guide.md`.
The two are meant to be read in that order.

| | |
|---|---|
| **Target** | Digilent ZedBoard, XC7Z020-CLG484-1, PL only |
| **Toolchain** | Vivado 2020.1 (built and verified); 2019.1+ should work |
| **Project** | `KOUSHIK_PROJ` — `fpga/tcl/build_koushik_proj.tcl` |
| **DUT** | `riscv_alu_mac_5stage`, **seven** stages: IF / ID / EX1 / EX2 / EX3 / MEM / WB |
| **Latency** | `result_valid` asserts **5** clocks after the issue edge |
| **Timing** | **100 MHz met — WNS +0.298 ns, TNS 0.000 ns** |
| **Debug** | ILA 6.2 (12 probes × 2048), VIO 3.0 (16 in / 12 out) |

> **The pipeline was restructured to close timing.** The six-stage version
> failed at 100 MHz (WNS −1.865 ns post-synthesis, −0.741 ns post-implementation).
> See `docs/FPGA_IMPLEMENTATION_REPORT.md` for the measured critical path and
> the two changes that fixed it.

---

## 1. File inventory

### 1.1 Design sources — fileset `sources_1`

Exactly five files. Every one must be file type **SystemVerilog**, not Verilog.

| # | File | Status | Role |
|---|---|---|---|
| 1 | `rtl/alu_mac_integrate.sv` | **revised — 7-stage, timing-optimised** | `riscv_alu_mac_5stage`, the DUT |
| 2 | `rtl/alu_mac_cmd_ctrl.sv` | unmodified | issue FSM: preload rs1, preload rs2, encode, issue, wait, return |
| 3 | `rtl/alu_mac_selftest.sv` | unmodified | 16-step BIST, compares in hardware |
| 4 | `rtl/alu_mac_fpga_core.sv` | unmodified | integration, arbitration, telemetry, ILA taps |
| 5 | `fpga/fpga_top.sv` | unmodified | **synthesis top** — reset sync, LEDs, `ila_0`, `vio_0` |

Files 2–5 needed no change when the DUT went from six stages to seven, exactly
as they needed none for five-to-six. That is not luck: `alu_mac_cmd_ctrl` waits
on `result_valid` rather than counting a fixed number of cycles, so pipeline
depth is invisible to it. The BIST compares values, not timings, for the same
reason.

### 1.2 Constraints — fileset `constrs_1`

| File | Status |
|---|---|
| `constraints/zedboard_alu_mac.xdc` | **updated** |

Pin assignments and the 100 MHz `create_clock` are unaffected by the pipeline
change — the XDC references only `fpga_top`'s three ports, and those did not
move. Two things did change; both are explained in section 5.

### 1.3 Simulation — fileset `sim_1`

| File | Status | Notes |
|---|---|---|
| `Test/tb/tb_alu_mac_core.sv` | **updated** | 23 checks / 7 groups against `alu_mac_fpga_core` |
| `Test/tb/tb_alu_mac_integrate.sv` | revised | the 410-case OOP suite, drives the DUT directly |

**Never add either to `sources_1`.** Both contain classes, covergroups and
constrained randomization. Synthesis will fail on all three.

### 1.4 Generated IP — not files you add

`ila_0` and `vio_0` do not exist on disk until you generate them.
`fpga_top.sv` instantiates them **by name**, so they must exist before
elaboration and their probe widths must match section 4 exactly.

### 1.5 Scripts and documentation — not added to the project

| File | Purpose |
|---|---|
| `fpga/tcl/build_koushik_proj.tcl` | creates the project, generates both IP cores from width tables, runs synthesis → bitstream |
| `fpga/tcl/program_zedboard.tcl` | Hardware Manager download of `.bit` + `.ltx` |
| `docs/FPGA_Implementation_Guide.md` | board bring-up and hardware test cases |
| `IMPLEMENTATION_GUIDE.md` | this file |

### 1.6 Alternatives — not present in this project

Two other routes exist for this design and are mentioned only so you recognise
them if you meet them elsewhere. **Neither is in this repository**, and neither
should be mixed with the five files above.

| Files | What they are instead |
|---|---|
| `alu_mac_vio_ila_top.sv`, `tb_alu_mac_vio_ila_top.sv` | a single-file wrapper replacing files 2–5 |
| `riscv_alu_mac_ip/package_ip.tcl`, `verify_ip.tcl` | the IP-packaging route instead of the harness |

The single-file wrapper needs a **10-in / 10-out VIO and a 10-probe ILA**, not
the 16 / 12 / 12 configuration in section 4. Adding both wrappers to one project
gives two conflicting probe maps and a port width mismatch at elaboration.

### 1.7 Hierarchy

```
fpga_top.sv ............................ the ONLY file that names ILA/VIO
  |
  +-- vio_0 ............................ generated IP - the dashboard
  +-- ila_0 ............................ generated IP - the waveform recorder
  +-- alu_mac_fpga_core.sv ............. integration, arbitration, telemetry
        |
        +-- alu_mac_cmd_ctrl.sv ........ encodes and issues instructions
        +-- alu_mac_selftest.sv ........ drives the 16-step BIST
        +-- alu_mac_integrate.sv ....... riscv_alu_mac_5stage (the DUT)
```

Everything from `alu_mac_fpga_core` down is plain RTL any simulator can run.
Everything above it is Xilinx-specific. That split is why
`tb_alu_mac_core.sv` can test the exact logic that goes into the PL without
needing the debug IP.

---

## 2. Build it — one command

```powershell
cd fpga\tcl
& "C:\Vivado\Vivado\2020.1\bin\vivado.bat" -mode batch -source build_koushik_proj.tcl
```

This creates **KOUSHIK_PROJ**, adds the five sources and the XDC, generates
`ila_0` and `vio_0` at the correct widths from a table, registers
`tb_alu_mac_core.sv` as the `sim_1` top, and runs synthesis, implementation and
bitstream generation. It prints WNS/TNS/WHS at the end and fails loudly if
either run does not reach 100%. Output:

```
vivado/KOUSHIK_PROJ/KOUSHIK_PROJ.runs/impl_1/fpga_top.bit
vivado/KOUSHIK_PROJ/KOUSHIK_PROJ.runs/impl_1/fpga_top.ltx
fpga/reports/post_impl_timing.rpt
fpga/reports/post_impl_paths.rpt
fpga/reports/post_impl_util.rpt
```

Keep the `.bit` and `.ltx` together — the Hardware Manager needs the `.ltx` to
show probe names instead of `probe0`, `probe1`, …

Two shorter modes:

```powershell
# create the project and stop, so you can inspect it
... -source build_koushik_proj.tcl -tclargs nobuild
# stop after synthesis (fast timing check, no place and route)
... -source build_koushik_proj.tcl -tclargs synth
```

---

## 3. Build it — GUI, step by step

1. **Create Project → RTL Project**, do not specify sources yet.
2. **Part:** search `xc7z020clg484-1`.
3. **Add Sources → Add Files** — add exactly the five files from 1.1.
   Do **not** add either testbench.
4. In the Sources pane, confirm every `.sv` shows file type **SystemVerilog**.
   Right-click → *Set File Type* if not. This is the single most common setup
   mistake, and its symptom is syntax errors on `logic` and `always_ff`.
5. Right-click `fpga_top` → **Set as Top**. `ila_0` and `vio_0` will show as
   missing until step 7.
6. **Add Sources → Add or create constraints** → `zedboard_alu_mac.xdc`.
7. **IP Catalog** → generate `ila_0` and `vio_0` per section 4.
8. **Add Sources → Add or create simulation sources** →
   `Test/tb/tb_alu_mac_core.sv`, set as `sim_1` top.
9. **Generate Bitstream.**

---

## 4. Debug IP configuration

The component names must be exactly `ila_0` and `vio_0` — `fpga_top.sv`
instantiates them by those names.

### 4.1 `vio_0` — Virtual Input/Output 3.0

Input Probe Count **16**, Output Probe Count **12**.

**Output probes (controls)**

| Probe | Width | Signal | Init | Purpose |
|---|---|---|---|---|
| `probe_out0` | 32 | `vio_a` | `0x00000010` | value preloaded into rs1 |
| `probe_out1` | 32 | `vio_b` | `0x00000020` | value preloaded into rs2 |
| `probe_out2` | 4 | `vio_op` | `0x0` | operation select |
| `probe_out3` | 1 | `vio_use_imm` | `0x0` | 1 = I-type, 0 = R-type |
| `probe_out4` | 12 | `vio_imm` | `0x000` | immediate, I-type only |
| `probe_out5` | 5 | `vio_rs1` | `0x01` | source register 1 |
| `probe_out6` | 5 | `vio_rs2` | `0x02` | source register 2 |
| `probe_out7` | 5 | `vio_rd` | `0x03` | destination register |
| `probe_out8` | 1 | `vio_start` | `0x0` | rising edge issues one instruction |
| `probe_out9` | 1 | `vio_selftest` | `0x0` | rising edge runs the BIST |
| `probe_out10` | 1 | `vio_acc_clear` | `0x0` | rising edge clears the accumulator |
| `probe_out11` | 1 | `soft_rst` | `0x0` | level-held soft reset |

**Input probes (readouts)**

| Probe | Width | Signal | Purpose |
|---|---|---|---|
| `probe_in0` | 32 | `sts_result[31:0]` | low word of the 64-bit result |
| `probe_in1` | 32 | `sts_result[63:32]` | high word |
| `probe_in2` | 5 | `sts_result_rd` | destination register that retired |
| `probe_in3` | 1 | `sts_txn_done` | sticky, cleared by the next start |
| `probe_in4` | 1 | `sts_busy` | instruction in flight |
| `probe_in5` | 1 | `sts_illegal` | last instruction was illegal |
| `probe_in6` | 1 | `sts_ovf` | last MAC accumulate overflowed |
| `probe_in7` | 1 | `sts_timeout` | pipeline never retired |
| `probe_in8` | 16 | `sts_txn_count` | instructions retired since reset |
| `probe_in9` | 16 | `sts_err_count` | illegal + timeout responses |
| `probe_in10` | 16 | `sts_ovf_count` | MAC overflows since reset |
| `probe_in11` | 1 | `sts_st_done` | BIST finished |
| `probe_in12` | 1 | `sts_st_pass` | BIST verdict |
| `probe_in13` | 16 | `sts_st_fail_mask` | bit N = step N failed |
| `probe_in14` | 8 | `sts_st_step` | current or last BIST step |
| `probe_in15` | 32 | `sts_last_instr` | instruction word actually issued |

### 4.2 `ila_0` — Integrated Logic Analyzer 6.2

Number of Probes **12**, Sample Data Depth **2048**, Capture Control **enabled**.

| Probe | Width | Signal | Good trigger? |
|---|---|---|---|
| `probe0` | 32 | `dbg_instr` | on a specific opcode |
| `probe1` | 1 | `dbg_instr_valid` | **yes** — instruction issue |
| `probe2` | 1 | `dbg_acc_clear` | accumulator clears |
| `probe3` | 1 | `dbg_init_en` | the register preload |
| `probe4` | 5 | `dbg_init_addr` | — |
| `probe5` | 32 | `dbg_init_data` | — |
| `probe6` | 64 | `dbg_result` | set **Data Only** |
| `probe7` | 5 | `dbg_result_rd` | — |
| `probe8` | 1 | `dbg_result_valid` | **yes** — writeback |
| `probe9` | 1 | `dbg_illegal_instr` | **yes** — decode faults |
| `probe10` | 1 | `dbg_mac_overflow` | **yes** — the instruction that tipped the accumulator |
| `probe11` | 8 | `dbg_status` | — |

`dbg_status` packs eight flags, LSB first: `cmd_valid`, `rsp_valid`,
`mst_busy`, `bist_busy`, `st_done`, `st_pass`, `err_seen`, `ovf_seen`.

Set `probe6` to **Data Only** on the Probe Ports tab. A 64-bit trigger
comparator is expensive in fabric and you will never trigger on an exact
result value.

### 4.3 Sizing

The ILA totals 152 probe bits at depth 2048 — roughly 9 BRAM36 tiles, which is
comfortable on an XC7Z020. If you widen probes or add more, drop the depth to
1024 rather than absorbing the BRAM pressure.

---

## 5. What changed in the constraints

**Removed a line that would have failed.** The XDC previously ended with
`connect_debug_port dbg_hub/clk [get_nets clk_100mhz]`. The clock reaches the
fabric through IBUF and BUFG, so the net is actually named
`clk_100mhz_IBUF_BUFG` and the literal port name does not match. Because
`ila_0` and `vio_0` are instantiated in RTL and already share `clk_100mhz`,
Vivado infers the hub clock on its own — no `connect_debug_port` is needed.
What *is* needed is `C_CLK_INPUT_FREQ_HZ`, without which the Hardware Manager
reports "debug hub core was not detected".

**Added a commented Fmax sweep.** The EX1/EX2 split was made to remove negative
slack, so the headroom it bought is worth measuring rather than assuming.
Comment out the 10.000 ns `create_clock`, uncomment one of the shorter periods,
rebuild, and read WNS; walk down until WNS goes negative and the last passing
period is your Fmax. Note that this proves timing closure only — the board
oscillator is still 100 MHz and this design instantiates no MMCM, so a passing
build at 5 ns does not make the hardware run faster.

---

## 6. Simulate before you synthesise

Synthesis and implementation take 10–15 minutes. The simulation takes seconds
and checks the same logic, so always run it first.

`Test/tb/tb_alu_mac_core.sv` instantiates `alu_mac_fpga_core` — the exact
module that goes into the PL, minus the Xilinx debug IP.

**QuestaSim** — scripted, run one at a time:

```powershell
cd Test\sim
& "C:\questasim64_2021.1\win64\vsim.exe" -c -do run_core.do
& "C:\questasim64_2021.1\win64\vsim.exe" -c -do run_integrate.do
```

**Vivado XSim** — the build script already registers `tb_alu_mac_core` as the
`sim_1` top; just click Run Simulation.

Expected tail:

```
-- Group 7: measured pipeline latency ----------------------
  result_valid asserts 5 clocks after the issue edge
  [ ok ] latency is 5 clocks (IF/ID/EX1/EX2/EX3/MEM/WB)

  transactions retired : 30
  error responses      : 2
  checks               : 23
  RESULT               : *** PASS ***
```

The 2 error responses are intentional: the illegal-instruction step inside the
BIST, and the standalone illegal test in group 6. Both check that the decoder
reports a bad opcode instead of executing it.

Group 7 measures the pipeline latency rather than assuming it. The harness does
not depend on the number, but a silent change in depth is exactly the kind of
thing that invalidates a throughput claim in a report — so it is asserted.

---

## 7. Expected build results

**DSP packing.** The multiplier now registers its product into `e2_booth_prod`
at the EX1/EX2 boundary. That lets Vivado pack the result register *inside* the
DSP48 slice rather than in fabric, which is the entire point of the EX split.
Confirm it worked: check that `MREG`/`PREG` are in use on the DSP in
`utilization.rpt`. If the product register ended up in fabric, the split cost
you a cycle and bought nothing.

**Resources.** The DUT itself is small. Most of the LUT and FF count is the two
debug cores, plus BRAM for the ILA capture buffer. The 32-entry register bank
maps to flip-flops rather than LUTRAM — the `for` loop reset in the WB stage
prevents distributed-RAM inference despite the `ram_style` attribute.

**Timing.** 100 MHz closes with **WNS +0.298 ns, TNS 0.000 ns, 0 failing
endpoints** on the current RTL.

The speculation that used to sit here — that the remaining critical path was
EX1's 64-bit ALU — was only half right. The measured path was a combinational
*loop*: the MAC accumulator fed the EX1 forwarding mux, which fed `op_a` back
into the multiplier's combinational input, so a full 32×32 multiply (3.851 ns)
and the accumulate carry chain both had to settle in one period. Narrowing the
ALU to 32 bits helped; registering the multiplier operands is what actually
closed it. Full analysis in `docs/FPGA_IMPLEMENTATION_REPORT.md`.

---

## 8. Program the board

Check all four before powering on:

| Item | Setting |
|---|---|
| Power switch | OFF while setting jumpers |
| USB cable | **J17 (PROG)**, not J14 (UART) |
| JP7–JP11 | all to GND = JTAG mode |
| JP6 | fitted — enables PL programming |

```
vivado -mode batch -source fpga/tcl/program_zedboard.tcl
```

Program `xc7z020_1`. The `arm_dap_0` also in the chain is the ARM debug access
port, not a programming target.

Confirm: blue DONE LED lit, LD0 blinking at about 1.5 Hz. LD0 is a free-running
heartbeat off the 100 MHz clock — if it blinks, the clock is live and the
bitstream is running.

Then continue with `docs/FPGA_Implementation_Guide.md` section 6.

---

## 9. Setup troubleshooting

| Symptom | Cause and fix |
|---|---|
| Syntax errors on `logic`, `always_ff`, `exec_op_e` | A `.sv` file is typed as Verilog. Right-click → Set File Type → SystemVerilog. |
| Errors on `class`, `covergroup`, `randomize` | A testbench was added to `sources_1`. Remove it — testbenches belong in `sim_1`. |
| `ila_0` / `vio_0` not found at elaboration | IP not generated, or the component name is not exactly `ila_0` / `vio_0`. |
| Port width mismatch on `ila_0` / `vio_0` | A probe width disagrees with `fpga_top.sv`. Compare against section 4, or rerun the Tcl script. |
| Vivado picks the wrong top | Right-click `fpga_top` → Set as Top, or `set_property top fpga_top [current_fileset]`. |
| `[DRC BIVC-1]` bank voltage conflict | BTNC was set to LVCMOS33. It is on a 1.8 V bank — must be LVCMOS18. |
| `connect_debug_port` cannot find the net | Expected — that line was removed. See section 5. |
| "Debug hub core was not detected" | `C_CLK_INPUT_FREQ_HZ` missing. Confirm the XDC is in `constrs_1` and enabled. |
| Simulation hangs, `sts_busy` stuck at 1 | The pipeline never retired and the 32-cycle timeout fired. Check `sts_timeout`. |
| BIST fails only steps 13 and 14 | The accumulator or its clear path is broken. Step 12 (MUL) passing while 13/14 fail isolates the fault to the accumulate adder, not the multiplier. |

---

## 10. Verification status of this harness

The harness is verified, not merely written. Against the current six-stage DUT:

- `tb_alu_mac_core.sv` — 23 checks across 7 groups, all passing, 30
  instructions retired.
- **Mutation test.** Injecting three independent faults into the DUT —
  `ALU_SRA` changed to a logical shift, the MAC accumulate flipped to a
  subtract, and the multiplier truncated to 16 bits — produced BIST fail mask
  `0x7200`: bits 9, 12, 13 and 14. Those are precisely the SRA, MUL and both
  MAC steps. The BIST detects real failures rather than passing vacuously.

That last property is the one worth carrying into the report. A test suite that
passes is only evidence if it also fails when the design is broken.

**Note on the OOP testbench — FIXED.** This section previously recorded that
`Test/tb/tb_alu_mac_integrate.sv` lacked that property: `monitor_and_score`
incremented `pass_cnt` on every retired instruction without comparing anything,
`fail_cnt` was never incremented, and "ALL 410 TEST CASES PASSED" printed
unconditionally. That diagnosis was correct and has been acted on.

It now runs a **shadow-pipeline reference checker** that snoops the operands at
EX1, models the expected value, and compares at WB every cycle. Validated both
directions: 410/410 on the good DUT, and 38 mismatches against a DUT whose
`ADD` was mutated to return `0xDEADBEEF` (the original bench reported a clean
pass on that same mutant).

The hardcoded statement/branch/condition/toggle coverage constants were also
removed — they were fabricated, and overstated condition coverage by 26 points.
Real code coverage now comes from the Questa UCDB. See
`CONTEXT_MKDWN/04_KNOWN_ISSUES.md`.

---

## 11. Where to go next

- **Add a back-to-back issue mode.** The DUT now forwards from three distances
  (EX2, MEM and WB) into EX1, and nothing in this harness exercises any of
  them, because `alu_mac_cmd_ctrl` issues one instruction at a time and waits
  for it to retire. The deeper the pipeline gets, the more forwarding paths
  there are to get wrong. This is the highest-value addition.
- **Widen the BIST.** The vector table is a plain case statement; adding a step
  is three lines and costs nothing at runtime. The fail mask is 16 bits, so
  going past step 15 means widening it.
- **Drive it from the Zynq PS.** Add a `processing_system7` instance and an
  AXI4-Lite shim in front of `alu_mac_cmd_ctrl`, so software issues
  instructions instead of the VIO. This is the point at which packaging the
  core as an IP starts to pay off.
