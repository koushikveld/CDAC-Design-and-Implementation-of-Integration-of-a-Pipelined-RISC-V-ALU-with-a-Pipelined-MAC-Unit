# Pipelined RISC-V ALU + Booth MAC
## FPGA Implementation Guide — ZedBoard (Zynq-7000, XC7Z020)

Hardware bring-up with ILA and VIO, no block design required.

| | |
|---|---|
| **Target** | Digilent ZedBoard — Zynq-7000 XC7Z020-CLG484-1 (PL only) |
| **Toolchain** | Vivado 2019.1 or newer, WebPACK sufficient |
| **Debug** | ILA 6.2 (12 probes × 2048) and VIO 3.0 (16 in / 12 out) |

---

## 1. What this guide covers

The execution core in `rtl/alu_mac_integrate.sv` is verified in simulation by
the OOP environment in `Test/tb/`. This guide takes the same RTL,
**unmodified**, and runs it inside the programmable logic of a ZedBoard, where
you drive it live from a VIO dashboard and watch every pipeline stage on an ILA.

**Why there is no block design.** IP Integrator cannot instantiate raw
SystemVerilog modules. You would first have to package `riscv_alu_mac_5stage`
as an IP with the IP Packager, which hides the RTL behind a generated wrapper
and makes debugging harder. Instead this flow instantiates the debug cores as
ordinary RTL instances inside a SystemVerilog top level, and lets Vivado insert
the debug hub automatically. It is a smaller, faster and more transparent flow,
and the source you simulate is byte-for-byte the source you synthesise.

### 1.0 What gets built

```
                          JTAG (USB)
                              |
                    +---------+---------+
                    |     debug hub     |
                    +----+---------+----+
                         |         |
                   +-----+--+   +--+-----------------------------+
                   | vio_0  |   |            ila_0               |
                   | 12 out |   |   12 probes x 2048 samples     |
                   | 16 in  |   +--+-----------------------------+
                   +-----+--+      |  taps every DUT interface wire
                         |         |
        +----------------v---------+------------------------------+
        |                  alu_mac_fpga_core                      |
        |                                                         |
        |  +-----------------+   +-----------------------------+  |
        |  | alu_mac_cmd_ctrl|-->|   riscv_alu_mac_5stage      |  |
        |  |  issue FSM      |   |     (YOUR RTL, as-is)       |  |
        |  +--------^--------+   | IF-ID-EX1-EX2-EX3-MEM-WB    |  |
        |           |            +-----------------------------+  |
        |  +--------+--------+                                    |
        |  | alu_mac_selftest  (16-step BIST)                  |  |
        |  +-----------------+                                    |
        +---------------------------------------------------------+
```

### 1.1 The file set

Nothing in `rtl/` or `Test/tb/` is modified. Everything new lives under
`FPGA/`. Only the first two groups end up in the bitstream.

#### Group A — synthesis sources (all five are required)

| File | What it does | Needed for ILA/VIO? |
|---|---|---|
| `rtl/alu_mac_integrate.sv` | Your DUT, unmodified. `riscv_alu_mac_5stage` — IF/ID/EX1/EX2/EX3/MEM/WB pipeline (timing-optimised, 5-clock latency), 32-entry register bank, four-source EX2/EX3/MEM/WB forwarding with a one-cycle MAC interlock, RV32I ALU on a 64-bit result bus computed from a 32-bit datapath, signed Booth multiplier and 64-bit MAC accumulator. | It is what the probes observe |
| `rtl/alu_mac_cmd_ctrl.sv` | Synthesizable issue controller. A 6-state FSM that turns one `cmd_valid` pulse into: preload rs1, preload rs2, issue the encoded instruction, wait for retirement, return the 64-bit result. Replaces the class-based `driver`, which cannot be synthesised. Includes a 32-cycle timeout. It waits on `result_valid` rather than counting a fixed delay, so it is unaffected by changes in pipeline depth. | Yes — it turns a VIO button press into pipeline traffic |
| `rtl/alu_mac_selftest.sv` | The 16-step BIST. A vector table in a case statement plus a sequencer that issues each step, compares the 64-bit response against the expected value **in hardware**, and accumulates a fail bitmap. | Yes — it produces the `st_pass` / `fail_mask` values the VIO displays |
| `rtl/alu_mac_fpga_core.sv` | The integration layer. Instantiates the controller, your DUT and the BIST; arbitrates between BIST and manual commands; edge-detects the VIO controls; maintains the telemetry counters. Brings every DUT wire out as a port so the ILA attaches without hierarchical references. Contains no Xilinx IP, which is what makes it directly simulatable. | Yes — this is the glue between the debug cores and the DUT |
| `fpga/fpga_top.sv` | The synthesis top level. Instantiates `alu_mac_fpga_core`, `ila_0` and `vio_0`, plus the reset synchroniser and the LED logic. The only file that mentions the debug cores. | This is the ILA/VIO wrapper |

#### Group B — generated IP (not on disk until you generate it)

`ila_0` and `vio_0` are not source files you write. `fpga_top.sv` instantiates
them by name, so they must exist before elaboration and their probe widths must
match exactly.

| IP | Module | Configuration | Where it comes from |
|---|---|---|---|
| Integrated Logic Analyzer 6.2 | `ila_0` | 12 probes, 2048-sample depth, capture control on | `create_ip` in `build_koushik_proj.tcl`, or IP Catalog by hand |
| Virtual Input/Output 3.0 | `vio_0` | 16 input probes, 12 output probes, with power-on values | same |
| Debug Hub | `dbg_hub` | inserted automatically | Vivado adds it during `opt_design`; you never instantiate it |

#### Group C — constraints (required)

| File | What it does |
|---|---|
| `constraints/zedboard_alu_mac.xdc` | Pin assignment and I/O standard for the clock, the reset button and the eight LEDs; the 100 MHz `create_clock`; false paths on the asynchronous button and the LEDs; and the debug hub clock frequency, without which the Hardware Manager reports "debug hub core was not detected". |

#### Group D — build and download scripts (recommended, not required)

| File | What it does |
|---|---|
| `fpga/tcl/build_koushik_proj.tcl` | Creates the project, adds the five Group A sources and the XDC, generates `ila_0` and `vio_0` with the correct widths from a table, then runs synthesis, implementation and bitstream generation and prints timing. |
| `fpga/tcl/program_zedboard.tcl` | Opens the Hardware Manager, finds `xc7z020_1` in the JTAG chain, downloads the `.bit` and the `.ltx` probe file, and lists the debug cores it found. |

You can do all of this through the GUI instead (section 4, Option B). The script
exists because setting 28 probe widths by hand is where mistakes happen.

#### Group E — simulation and documentation (never synthesised)

| File | What it does |
|---|---|
| `Test/tb/tb_alu_mac_core.sv` | Self-checking bench for `alu_mac_fpga_core` — the exact logic that goes into the PL, minus the debug IP. 23 checks across 7 test groups. Run this before every synthesis. |
| `Test/tb/tb_alu_mac_integrate.sv` | Your existing 410-case OOP environment. Excluded from synthesis: it contains classes, covergroups and constrained randomization, none of which synthesise. Simulation only. See section 10. |
| `docs/FPGA_Implementation_Guide.md` | This document. |

### 1.2 How the files fit together

Read top down; each box is instantiated by the one above it.

```
fpga_top.sv ............................ the ONLY file that knows about ILA/VIO
  |
  +-- vio_0 ............................ generated IP - the dashboard
  +-- ila_0 ............................ generated IP - the waveform recorder
  +-- alu_mac_fpga_core.sv ............. integration + arbitration + telemetry
        |
        +-- alu_mac_cmd_ctrl.sv ........ encodes and issues instructions
        +-- alu_mac_selftest.sv ........ drives the 16-step BIST
        +-- alu_mac_integrate.sv ....... YOUR riscv_alu_mac_5stage
```

The split at `alu_mac_fpga_core` is deliberate. Everything below it is plain
RTL that any simulator can run; everything above it is Xilinx-specific. That is
why `tb_alu_mac_core.sv` can test the real synthesised logic without needing the
debug IP.

### 1.3 The minimum to get ILA and VIO working

The five Group A files, the XDC, and the two generated IP cores. That is it.
No block design, no IP packaging, no processing system, no SD card.

---

## 2. Prerequisites

**Software.** Vivado 2019.1 or newer (2020.2 and later recommended). WebPACK is
sufficient — XC7Z020 is a WebPACK device. Install the Digilent cable drivers:
run `<Vivado>/data/xicom/cable_drivers/nt64/digilent/install_digilent.exe`
once, as Administrator.

**Board setup** — check all four before powering on.

| Item | Setting |
|---|---|
| Power switch | OFF while you set jumpers |
| USB cable | Micro-USB into **J17 (PROG)**, not J14 (UART) |
| Boot mode jumpers JP7–JP11 | All to GND position = JTAG mode |
| JP6 | Fitted — enables PL programming |

This is a PL-only design. The Zynq processing system is not instantiated, no
`ps7_init` is needed, and no SD card or bootloader is involved.

---

## 3. Simulate before you synthesise

Synthesis and implementation take roughly 10–15 minutes. The simulation takes
seconds and checks the same logic, so always run it first.

`Test/tb/tb_alu_mac_core.sv` instantiates `alu_mac_fpga_core` — the exact
module that goes into the PL, minus the Xilinx debug IP — and self-checks 23
assertions across 7 test groups.

With QuestaSim or ModelSim:

```
vlib work
vlog -sv rtl/alu_mac_integrate.sv rtl/alu_mac_cmd_ctrl.sv ^
        rtl/alu_mac_selftest.sv rtl/alu_mac_fpga_core.sv ^
        Test/tb/tb_alu_mac_core.sv
vsim -c -do "run -all; quit -f" tb_alu_mac_core
```

With Vivado XSim, the build script already registers this file as the `sim_1`
top — just click Run Simulation.

Expected tail of the transcript:

```
  transactions retired : 30
  error responses      : 2
  checks               : 23
  RESULT               : *** PASS ***
```

The 2 error responses are intentional: the illegal-instruction step inside the
BIST, and the standalone illegal test in group 6. Both are checks that the
decoder reports a bad opcode rather than executing it.

---

## 4. Build the bitstream

### Option A — one command (recommended)

```
vivado -mode batch -source fpga/tcl/build_koushik_proj.tcl
```

Output lands in:

```
vivado/KOUSHIK_PROJ/KOUSHIK_PROJ.runs/impl_1/fpga_top.bit
vivado/KOUSHIK_PROJ/KOUSHIK_PROJ.runs/impl_1/fpga_top.ltx
```

The `.ltx` file is the probe description. The Hardware Manager needs it to show
meaningful probe names instead of `probe0`, `probe1`, and so on. Keep the two
files together.

To create the project and stop before synthesis:

```
vivado -mode batch -source fpga/tcl/build_koushik_proj.tcl -tclargs nobuild
```

### Option B — GUI, step by step

1. **Create Project → RTL Project →** do not specify sources yet.
2. **Part:** search `xc7z020clg484-1` and select it.
3. **Add Sources → Add Files**, and add exactly these five, in any order:
   `rtl/alu_mac_integrate.sv`, `rtl/alu_mac_cmd_ctrl.sv`,
   `rtl/alu_mac_selftest.sv`, `rtl/alu_mac_fpga_core.sv`,
   `fpga/fpga_top.sv`.
   **Do not add** `Test/tb/tb_alu_mac_integrate.sv` — it is a verification
   environment containing classes and covergroups, which do not synthesise.
4. In the Sources pane, confirm the file type of every `.sv` is **SystemVerilog**,
   not Verilog. Right-click → Set File Type if not.
5. Right-click `fpga_top` → **Set as Top**. The hierarchy should show `fpga_top`
   with `u_core`, and `ila_0` / `vio_0` marked as missing for now.
6. **Add Sources → Add or create constraints →**
   `constraints/zedboard_alu_mac.xdc`.
7. **IP Catalog → ILA → Integrated Logic Analyzer.** Component name exactly
   `ila_0`, Number of Probes 12, Sample Data Depth 2048, Capture Control
   enabled. On the Probe Ports tab set the widths from section 9. OK, then
   Generate.
8. **IP Catalog → VIO → Virtual Input/Output.** Component name `vio_0`, Input
   Probe Count 16, Output Probe Count 12. Set widths and initial values from
   section 9. OK, then Generate.
9. **Generate Bitstream.** Accept the prompt to run synthesis and implementation.

Setting the widths by hand across 28 probes is tedious and easy to get wrong —
a single mismatch is a synthesis error. Option A does it from a table.

### Expected results

The DUT itself is small. The multiplier now registers its product into
`e2_booth_prod` at the EX1/EX2 boundary, which lets Vivado pack the result
register *inside* the DSP48 slice rather than in fabric — that is the point of
the EX split, and it is what removes the negative slack the single-stage EX
version had. Confirm it worked by checking that `MREG`/`PREG` are used on the
DSP in the utilization report; if the product register ended up in fabric the
slack improvement will not appear. The multiplier infers DSP48 slices
because of the `(* use_dsp = "yes" *)` attribute, and the 32-entry register bank
maps to flip-flops rather than LUTRAM (the `for` loop reset in the WB stage
prevents distributed-RAM inference despite the `ram_style` attribute). Most of
the LUT and FF count in the final report is the debug cores, plus BRAM for the
ILA capture buffer. Timing should close comfortably at 100 MHz.

**Timing now closes at 100 MHz: WNS +0.298 ns, TNS 0.000 ns, 0 failing
endpoints.** Getting there needed a further pipeline change, not just the EX
split. The speculation that once sat here — that the culprit was EX1's 64-bit
ALU — was only half the story. The measured critical path was a combinational
*loop*: the MAC accumulator fed the EX1 forwarding mux, which fed `op_a` back
into the multiplier's combinational input, putting a full 32×32 multiply
(3.851 ns) and the accumulate carry chain in the same clock period.

Narrowing the ALU to a 32-bit datapath helped; **registering the multiplier
operands** is what actually closed it, at the cost of one pipeline stage
(latency 4 → 5 clocks). Full measured analysis in
`docs/FPGA_IMPLEMENTATION_REPORT.md`.

---

## 5. Program the board

Power on the board, then:

```
vivado -mode batch -source fpga/tcl/program_zedboard.tcl
```

Or in the GUI: **Open Hardware Manager → Open Target → Auto Connect →**
right-click `xc7z020_1` → **Program Device**.

You will see `arm_dap_0` and `xc7z020_1` in the chain. Program `xc7z020_1` —
the ARM debug access port is not a programming target.

Confirm it worked: the blue DONE LED lights, and LD0 blinks at about 1.5 Hz.
LD0 is a free-running heartbeat off the 100 MHz clock; if it is blinking, the
clock is live and the bitstream is running. If DONE is on but LD0 is dark,
suspect the clock constraint or the Y9 pin assignment.

---

## 6. Set up the dashboard

After programming, the Hardware Manager shows `hw_vio_1` and `hw_ila_1` under
the device. If it does not, right-click the device → **Refresh Device**.

### 6.1 Add the VIO probes

1. Double-click `hw_vio_1`. An empty VIO window opens.
2. Click **+** in the VIO Probes panel. A dialog lists all 28 probes by their
   `fpga_top` signal names — this is what the `.ltx` file buys you.
3. Select all of them and click OK.
4. Set the radix on the wide fields: right-click a probe → **Radix → Hex**. Do
   this for `vio_a`, `vio_b`, `sts_result_lo`, `sts_result_hi`,
   `sts_last_instr` and `sts_st_fail_mask`. Leave the single-bit controls in
   binary.
5. **Turn on refresh for the inputs.** VIO input probes are not live by default —
   they are sampled on demand. Open the VIO window's settings and set the
   auto-refresh interval to 500 ms.

Save the layout: **File → Save Dashboard**, so you do not rebuild it after
every reprogram.

### 6.2 How to enter a value

1. Click the Value cell of an output probe.
2. Type the value. In Hex radix, type the digits without a `0x` prefix —
   `FFFFFFFF`, not `0xFFFFFFFF`. Underscores are accepted: `FFFF_FFFF`.
3. **Press Enter.** The value is not applied until you do. Clicking away
   discards the edit.

### 6.3 The START control

`vio_start` is edge triggered: the design issues one instruction on each 0-to-1
transition. So a run is always three actions:

1. Set up `vio_a`, `vio_b`, `vio_op`, and the register numbers.
2. Set `vio_start` to 1, Enter. The instruction issues.
3. Set `vio_start` back to 0, Enter. This arms it for the next one.

If you forget step 3, the next START does nothing — by far the most common
confusion. `vio_selftest` and `vio_acc_clear` behave the same way.

The edge-triggered design is deliberate: a level-triggered start would re-issue
every clock cycle and you would never see a single clean instruction on the ILA.

### 6.4 Arm the ILA

1. Double-click `hw_ila_1`.
2. In Trigger Setup, click **+** and add a probe. Good choices:
   - `dbg_instr_valid == 1` to catch instruction issue
   - `dbg_result_valid == 1` to centre on writeback
   - `dbg_illegal_instr == 1` to catch only decode faults
   - `dbg_mac_overflow == 1` to catch only accumulator overflow
3. Set **Trigger position in window** to 512. With a 2048-sample buffer that
   gives 512 samples of history before the trigger and 1536 after — enough to
   see the register preload, the issue, and all five pipeline stages retire.
4. Click **Run Trigger**. Status shows *Waiting for Trigger*.
5. Now go to the VIO window and pulse START. The ILA fires.

**Order matters.** Arm the ILA first, then trigger from the VIO. An ILA armed
after the event has nothing to capture.

---

## 7. Test cases

The operation encoding every test below relies on (`vio_op`):

| Code | Operation | | Code | Operation |
|---|---|---|---|---|
| 0 | ADD | | 8 | OR |
| 1 | SUB (R-type only) | | 9 | AND |
| 2 | SLL | | 10 | MAC (accumulate) |
| 3 | SLT (signed) | | 11 | MUL (replaces accumulator) |
| 4 | SLTU (unsigned) | | 15 | illegal instruction |
| 5 | XOR | | | |
| 6 | SRL | | | |
| 7 | SRA | | | |

**Note on ALU semantics.** This design zero-extends both 32-bit operands to 64
bits *before* the operation, so ADD carries out into the upper word instead of
truncating, and SUB with a borrow produces a full 64-bit negative pattern. That
is the design intent — the whole point of the 64-bit result bus — and the
expected values below reflect it, not textbook RV32I.

### Test A — built-in self test (start here)

One control, sixteen instructions, a hardware verdict.

1. Set `vio_selftest` to 1, Enter.
2. Set `vio_selftest` back to 0, Enter.
3. Refresh the VIO inputs.

| Probe | Expected | Meaning |
|---|---|---|
| `sts_st_done` | 1 | the BIST ran to completion |
| `sts_st_pass` | 1 | all 16 steps passed |
| `sts_st_fail_mask` | 0000 | bit N set means step N failed |
| `sts_txn_count` | increased by 16 | sixteen instructions retired |
| `sts_err_count` | increased by 1 | the one deliberate illegal step |

On the board: LD1 on (done), LD2 on (pass). If LD2 is dark, read
`sts_st_fail_mask` and look up the failing step below.

The sixteen steps, in order:

| Step | Op | a | b | Expected result | Checks |
|---|---|---|---|---|---|
| 0 | ADD | 0000_0010 | 0000_0020 | 0000_0000_0000_0030 | basic add path |
| 1 | ADD | FFFF_FFFF | FFFF_FFFF | 0000_0001_FFFF_FFFE | **carry reaches the upper word** |
| 2 | SUB | 0000_0030 | 0000_0010 | 0000_0000_0000_0020 | subtract path |
| 3 | SUB | 0000_0010 | 0000_0030 | FFFF_FFFF_FFFF_FFE0 | **borrow propagates 64-bit** |
| 4 | AND | F0F0_F0F0 | FF00_FF00 | 0000_0000_F000_F000 | logical unit |
| 5 | OR | F0F0_F0F0 | 0F0F_0F0F | 0000_0000_FFFF_FFFF | logical unit |
| 6 | XOR | AAAA_AAAA | FFFF_FFFF | 0000_0000_5555_5555 | logical unit |
| 7 | SLL | 8000_0001 | 4 | 0000_0008_0000_0010 | barrel shifter, left |
| 8 | SRL | 8000_0001 | 4 | 0000_0000_0800_0000 | barrel shifter, logical right |
| 9 | SRA | 8000_0001 | 4 | FFFF_FFFF_F800_0000 | barrel shifter, **arithmetic right** |
| 10 | SLT | 8000_0000 | 0000_0001 | 0000_0000_0000_0001 | signed compare |
| 11 | SLTU | 8000_0000 | 0000_0001 | 0000_0000_0000_0000 | unsigned compare, same operands |
| 12 | MUL | FFFF_FFFF | 7FFF_FFFF | FFFF_FFFF_8000_0001 | **signed** multiply, −1 × 2147483647 |
| 13 | MAC | 0000_0010 | 0000_0010 | 0000_0000_0000_0100 | accumulate from a cleared accumulator |
| 14 | MAC | 0000_0002 | 0000_0003 | 0000_0000_0000_0106 | 256 + 6 — **accumulation actually accumulates** |
| 15 | — | — | — | expect `illegal_instr` | decode trap on opcode 1111111 |

Steps 10 and 11 are the interesting pair: identical operands, opposite answers.
They prove the comparator is genuinely signed in one case and unsigned in the
other, rather than both paths collapsing to the same comparison.

Step 14 is the one that catches a broken accumulator. Step 13 alone would pass
even if the accumulator were hardwired to zero, because 0 + 256 = 256. Only the
second accumulate distinguishes a working MAC from a bare multiplier.

Steps 13 and 14 run with an accumulator clear inserted before step 13, because
step 12's MUL leaves a non-zero value behind. The BIST is safely re-runnable
for that reason: run it as many times as you like without a reset.

### Test B — manual instruction

The core interaction. Values you type, results you watch retire.

| Probe | Value |
|---|---|
| `vio_op` | 0 (ADD) |
| `vio_a` | FFFF_FFFF |
| `vio_b` | FFFF_FFFF |
| `vio_rs1` / `vio_rs2` / `vio_rd` | 01 / 02 / 03 |
| `vio_start` | 1, then 0 |

Expect `sts_result_hi` = `00000001`, `sts_result_lo` = `FFFFFFFE`,
`sts_txn_done` = 1, `sts_illegal` = 0.

This is the headline result for the whole design: two 32-bit all-ones operands
producing a 33-bit sum without truncation. On the ILA (trigger on
`dbg_instr_valid == 1`) you should see, in order: `init_en` high for two cycles
as rs1 and rs2 are preloaded, then `instr_valid` for one cycle, then four
cycles later `result_valid` with the full 64-bit value on `dbg_result`. That gap is
four clocks — IF/ID → ID/EX1 → EX1/EX2 → EX2/MEM → MEM/WB — and Group 7 of
`tb_alu_mac_core.sv` measures and asserts it rather than assuming it.

### Test C — signed versus unsigned comparison

Set `vio_a` = `8000_0000`, `vio_b` = `0000_0001`, and run `vio_op` = 3, then
`vio_op` = 4. The result flips from 1 to 0 on identical operands. This is the
cleanest single demonstration that the comparator paths are distinct.

### Test D — MAC accumulation

1. Pulse `vio_acc_clear` (1, Enter, 0, Enter).
2. `vio_op` = 10, `vio_a` = 7, `vio_b` = 6 → START. Expect `sts_result_lo` = `2A` (42).
3. Leave op at 10, set `vio_a` = 10, `vio_b` = 10 → START. Expect `8E` (142).
4. Again with `vio_a` = 1, `vio_b` = 1 → START. Expect `8F` (143).

The accumulator is a running total across separate instructions. On the ILA,
`dbg_result` grows monotonically while `dbg_instr` changes only in its operand
register fields.

Now set `vio_op` = 11 (MUL) and issue any operands: the accumulator is
*replaced*, not added to. That is the architectural difference between the two
custom opcodes.

### Test E — MAC overflow

1. Pulse `vio_acc_clear`.
2. `vio_op` = 10, `vio_a` = `7FFF_FFFF`, `vio_b` = `7FFF_FFFF` → START.
3. Repeat START several more times without changing anything.

Each accumulate adds roughly 2⁶² to the total. After the third, the running sum
crosses the signed 64-bit boundary and `sts_ovf` goes high with
`sts_ovf_count` incrementing. Trigger the ILA on `dbg_mac_overflow == 1` to
catch the exact instruction that tipped it.

Pulse `vio_acc_clear` afterwards.

### Test F — illegal instruction trap

Set `vio_op` = 15 → START.

Expect `sts_illegal` = 1, `sts_err_count` incrementing, and — critically —
`sts_result_valid` **low**. LD3 lights.

The point of this test is what does *not* happen. Trigger the ILA on
`dbg_illegal_instr == 1` and look at `dbg_result_valid`: it must stay at 0 for
the entire instruction. A decoder that raised the illegal flag *and* still
retired a writeback would corrupt the register file on every bad opcode.

Issue any legal instruction afterwards and `sts_illegal` clears.

### Test G — reset

Press BTNC, or set `vio_soft_rst` to 1 then 0.

`sts_txn_count`, `sts_err_count`, `sts_ovf_count` and the BIST verdict all
clear. The register bank is zeroed by the DUT's own synchronous reset.

---

## 8. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| No hardware target found | USB in J14 instead of J17; or Digilent drivers not installed. Run `install_digilent.exe` as Administrator. |
| DONE LED on, LD0 not blinking | Clock not reaching the fabric. Check the Y9 assignment and that `create_clock` is present in the XDC. |
| "The debug hub core was not detected" | The hub's clock frequency is wrong. The XDC sets `C_CLK_INPUT_FREQ_HZ` to 100 MHz; make sure the constraints file is in the constraints set and enabled. |
| `[DRC BIVC-1]` bank voltage conflict | Something set the button to LVCMOS33. BTNC is on a 1.8 V bank — it must be LVCMOS18. |
| Synthesis errors about classes, `covergroup`, `randomize` | `tb_alu_mac_integrate.sv` was added to the sources set. Remove it — it belongs to simulation only. |
| `ila_0`/`vio_0` not found during elaboration | The IP was not generated, or the component name is not exactly `ila_0` / `vio_0`. Regenerate from the IP Catalog. |
| Port width mismatch on `ila_0`/`vio_0` | A probe width does not match `fpga_top.sv`. Compare against section 9, or rerun the Tcl script. |
| Vivado picks the wrong top module | Right-click `fpga_top` → Set as Top, or `set_property top fpga_top [current_fileset]`. |
| `logic`/`always_ff` syntax errors | A `.sv` file is typed as Verilog. Right-click → Set File Type → SystemVerilog. |
| VIO values never change | You did not press Enter after typing, or you did not refresh the input probes. See 6.2. |
| START does nothing the second time | `vio_start` was left at 1. It is edge triggered — return it to 0 first. |
| ILA never triggers | Armed after the event. Click Run Trigger first, then pulse START. |
| `sts_busy` stuck at 1 | The pipeline never retired and the timeout fired. Check `sts_timeout`; pulse `vio_soft_rst`. |
| BIST fails only steps 13 and 14 | The accumulator or its clear path is broken. Steps 12 (MUL) passing while 13/14 fail isolates it to the accumulate adder, not the multiplier. |

---

## 9. Reference tables

### VIO output probes — the controls

| Probe | Width | Signal | Init | Purpose |
|---|---|---|---|---|
| probe_out0 | 32 | `vio_a` | 0x00000010 | value preloaded into rs1 |
| probe_out1 | 32 | `vio_b` | 0x00000020 | value preloaded into rs2 |
| probe_out2 | 4 | `vio_op` | 0 | operation select, see section 7 |
| probe_out3 | 1 | `vio_use_imm` | 0 | 1 = I-type, 0 = R-type |
| probe_out4 | 12 | `vio_imm` | 0 | immediate field for I-type |
| probe_out5 | 5 | `vio_rs1` | 1 | source register 1 |
| probe_out6 | 5 | `vio_rs2` | 2 | source register 2 |
| probe_out7 | 5 | `vio_rd` | 3 | destination register |
| probe_out8 | 1 | `vio_start` | 0 | rising edge issues one instruction |
| probe_out9 | 1 | `vio_selftest` | 0 | rising edge runs the BIST |
| probe_out10 | 1 | `vio_acc_clear` | 0 | rising edge clears the MAC accumulator |
| probe_out11 | 1 | `soft_rst` | 0 | level-held soft reset |

### VIO input probes — the readouts

| Probe | Width | Signal | Purpose |
|---|---|---|---|
| probe_in0 | 32 | `sts_result_lo` | low word of the 64-bit result |
| probe_in1 | 32 | `sts_result_hi` | high word |
| probe_in2 | 5 | `sts_result_rd` | destination register that retired |
| probe_in3 | 1 | `sts_txn_done` | sticky, cleared by the next START |
| probe_in4 | 1 | `sts_busy` | an instruction is in flight |
| probe_in5 | 1 | `sts_illegal` | last instruction was illegal |
| probe_in6 | 1 | `sts_ovf` | last MAC accumulate overflowed |
| probe_in7 | 1 | `sts_timeout` | the pipeline never retired |
| probe_in8 | 16 | `sts_txn_count` | instructions retired since reset |
| probe_in9 | 16 | `sts_err_count` | illegal + timeout responses |
| probe_in10 | 16 | `sts_ovf_count` | MAC overflows since reset |
| probe_in11 | 1 | `sts_st_done` | BIST finished |
| probe_in12 | 1 | `sts_st_pass` | BIST verdict |
| probe_in13 | 16 | `sts_st_fail_mask` | bit N = step N failed |
| probe_in14 | 8 | `sts_st_step` | current or last BIST step |
| probe_in15 | 32 | `sts_last_instr` | instruction word actually issued |

### ILA probes

| Probe | Width | Signal | | Probe | Width | Signal |
|---|---|---|---|---|---|---|
| 0 | 32 | `instr` | | 6 | 64 | `result` |
| 1 | 1 | `instr_valid` | | 7 | 5 | `result_rd` |
| 2 | 1 | `acc_clear` | | 8 | 1 | `result_valid` |
| 3 | 1 | `init_en` | | 9 | 1 | `illegal_instr` |
| 4 | 5 | `init_addr` | | 10 | 1 | `mac_overflow` |
| 5 | 32 | `init_data` | | 11 | 8 | `dbg_status` |

`dbg_status` packs eight flags, LSB first: `cmd_valid`, `rsp_valid`,
`mst_busy`, `bist_busy`, `st_done`, `st_pass`, `err_seen`, `ovf_seen`.

### Board I/O

| Signal | Pin | Standard | Function |
|---|---|---|---|
| `clk_100mhz` | Y9 | LVCMOS33 | 100 MHz oscillator |
| `btn_rst` | P16 | LVCMOS18 | BTNC, active high reset |
| `led[0]` | T22 | LVCMOS33 | heartbeat, ~1.5 Hz |
| `led[1]` | T21 | LVCMOS33 | BIST done |
| `led[2]` | U22 | LVCMOS33 | BIST pass |
| `led[3]` | U21 | LVCMOS33 | illegal instruction seen |
| `led[7:4]` | V22, W22, U19, U14 | LVCMOS33 | BIST step number |

---

## 10. Testbench integrity — the scoreboard defect, and its fix

This section used to record an open defect in
`Test/tb/tb_alu_mac_integrate.sv`. The diagnosis was correct and the defect has
now been fixed; the history is kept because it explains why the current
verification evidence can be trusted.

**What was wrong.** `scoreboard::monitor_and_score` incremented `pass_cnt` on
every retired instruction without checking the result against any reference
model. `fail_cnt` was declared and printed but never incremented anywhere in
the file. The "ALL 410 TEST CASES PASSED" summary was a literal string printed
unconditionally.

**Proof it mattered.** With `ALU_ADD` mutated to return `64'hDEADBEEF` for every
addition, the original bench still reported `410/410 PASSED, FAILED CHECKS: 0`.

**The fix.** A shadow-pipeline reference checker now snoops the operands at EX1
(after forwarding), computes the expected value in a model, and pushes it down
a shadow pipeline that mirrors the DUT's EX1→EX2→EX3→MEM→WB timing exactly,
comparing against `result` / `result_valid` every clock. Modelling from the
post-forwarding operands rather than from the stimulus is deliberate: it
verifies the ALU, multiplier, accumulator and result mux without needing a
cycle-accurate copy of the register file and forwarding network.

**Validated both directions**, which is the standard that matters:

- 410/410 pass on the good DUT — no false positives.
- 38 mismatches, with correct expected values, against the `DEADBEEF` mutant.

The fabricated code-coverage functions were also removed. They returned
hardcoded constants presented as measured results and overstated condition
coverage by 26 points (claimed 97.20%, actual 71.26%). Real code coverage now
comes from the Questa UCDB via `vcover report -summary`. Details in
`CONTEXT_MKDWN/04_KNOWN_ISSUES.md`.

## 11. Where to go next

- **Drive it from the Zynq PS.** Add a `processing_system7` instance and an
  AXI4-Lite shim in front of `alu_mac_cmd_ctrl`, so software issues
  instructions instead of the VIO. This is the point at which packaging the
  core as an IP starts to pay off.
- **Widen the BIST.** The vector table in `alu_mac_selftest.sv` is a plain case
  statement. Adding a step is three lines and costs nothing at runtime. The
  fail mask is 16 bits, so extending past step 15 means widening it.
- **Add a hazard test group.** The DUT now forwards from three distances
  (EX2, MEM and WB) into EX1, and this BIST exercises none of them, because
  `alu_mac_cmd_ctrl` issues strictly one instruction at a time and waits for it
  to retire. A back-to-back issue mode in the controller would reach all three,
  and the deeper the pipeline gets the more forwarding paths there are to get
  wrong. This is the single most valuable thing to add next.
