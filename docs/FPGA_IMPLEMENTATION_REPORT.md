# FPGA Implementation Report — Timing Closure at 100 MHz

Pipelined RISC-V ALU + Booth MAC · ZedBoard XC7Z020-CLG484-1 · Vivado 2020.1

| | |
|---|---|
| **Project** | `KOUSHIK_PROJ` (`vivado/KOUSHIK_PROJ`) |
| **Device** | XC7Z020-CLG484-1, speed grade **−1** |
| **Target clock** | 100 MHz — 10.000 ns period, `sys_clk` on Y9 |
| **Build script** | `fpga/tcl/build_koushik_proj.tcl` |
| **Result** | **Timing met. WNS +0.298 ns, TNS 0.000 ns, 0 failing endpoints.** |

---

## 1. Summary

| Metric | Baseline | Optimised | Δ |
|---|---|---|---|
| Post-synthesis WNS | **−1.865 ns** | **+0.617 ns** | +2.482 ns |
| Post-implementation WNS | **−0.741 ns** | **+0.298 ns** | +1.039 ns |
| Post-implementation TNS | −53.796 ns | **0.000 ns** | +53.796 ns |
| Failing endpoints (setup) | 139 (synth) | **0** | — |
| Worst hold slack (WHS) | +0.053 ns | +0.049 ns | met throughout |
| Issue-to-`result_valid` latency | 4 clocks | 5 clocks | +1 clock |
| Pipeline depth | 6 stages | 7 stages | +1 |

The −1.865 ns figure is the post-**synthesis** number and is the one in the
screenshot that opened this investigation. Implementation recovered part of it
on its own (−0.741 ns), but the design still missed 100 MHz by a comfortable
margin in both views.

Two RTL changes closed it. Neither changes what the design computes: the
verification suite passes bit-identically before and after (section 6).

---

## 2. The baseline critical path

Measured, not guessed — `fpga/reports/post_impl_paths.rpt` from the baseline run:

```
Slack (VIOLATED) : -0.741ns
  Source:      u_core/u_dut/e2_booth_prod_reg__0/CLK   (DSP48E1)
  Destination: u_core/u_dut/e2_booth_prod_reg/PCIN[0]  (DSP48E1)
  Data Path Delay: 9.277ns  (logic 6.612ns 71.3%, route 2.665ns 28.7%)
  Logic Levels:    7  (CARRY4=4  DSP48E1=1  LUT2=1  LUT6=1)
```

Walking the path:

```
DSP48E1 P[3]              multiplier product           0.434 ns
  -> LUT2                 accumulator input logic      0.124 ns
  -> CARRY4 x4            64-bit MAC accumulate adder  1.896 ns
  -> e2_mac_next_acc[31]
  -> LUT6                 EX1 forwarding mux           0.307 ns
  -> a_sext[31]
  -> DSP48E1 B[15]->PCOUT 32x32 multiply               3.851 ns   <-- dominant
  -> PCIN
```

**The design had a combinational loop through the MAC unit.** The accumulator
output fed the EX1 forwarding mux, which fed `op_a` straight back into the
multiplier's *combinational* input. A full 32×32 signed multiply and the 64-bit
accumulate carry chain were therefore both required to settle inside one 10 ns
period.

Two properties made this expensive:

1. **The multiply was unregistered at its inputs.** A 32×32 signed multiply on
   7-series needs a cascade of DSP48E1s. With operands arriving from a mux
   rather than a flip-flop, Vivado could not use the DSP's internal A/B input
   registers, so the entire multiply array sat in the combinational path —
   3.851 ns in one hop.

2. **The ALU was 64 bits wide.** Every ALU operation was performed on
   zero-extended 64-bit operands, so the adder, subtractor and all three
   shifters were twice as deep as the architecture actually requires.

Note that the earlier EX1/EX2 split was *not* wrong — it removed the
multiplier's output register from fabric. It simply did not address the input
side of the multiply, which is where the real delay was.

---

## 3. Optimisation 1 — 32-bit ALU datapath

**What changed:** the ALU now computes on 32-bit operands and reconstructs the
64-bit result from a 33-bit add/sub plus cheap fills.

**Why it is safe.** The architectural behaviour is that both operands are
zero-extended to 64 bits before the operation, so `ADD` carries out into the
upper word instead of truncating. That behaviour does not require 64-bit
arithmetic, because the upper word is never arbitrary:

| Op | Upper 32 bits of the 64-bit result | Lower 32 bits |
|---|---|---|
| `ADD` | `{31'b0, carry_out}` | 32-bit sum |
| `SUB` | `{32{borrow}}` — all-ones iff `a < b` | 32-bit difference |
| `AND` / `OR` / `XOR` | always `0` | 32-bit logical op |
| `SLL` | bits shifted off the top: `a >> (32−sh)` | `a << sh` |
| `SRL` | always `0` | `a >> sh` |
| `SRA` | `{32{a[31]}}` — sign fill | `$signed(a) >>> sh` |
| `SLT` / `SLTU` | always `0` | `0` or `1` |

A 33-bit add and a 33-bit subtract yield the carry and the borrow directly, and
the shifters shrink from 64-bit to 32-bit barrel structures. Roughly half the
logic depth in EX1 for an identical result — verified operation by operation by
the 410-case suite.

## 4. Optimisation 2 — registered multiplier operands (the decisive change)

**What changed:** `op_a` / `op_b` are captured into `e2_mul_a` / `e2_mul_b` at
the EX1/EX2 boundary, and the multiply happens in the following stage from
those flops:

```systemverilog
// EX1 -> EX2 : register the operands
e2_mul_a <= op_a;
e2_mul_b <= op_b;

// EX2 -> EX3 : a whole clock period for the multiply
e3_booth_prod <= $signed(e2_mul_a) * $signed(e2_mul_b);
```

This does two things at once:

1. **It breaks the loop.** The forwarded accumulator value now only has to
   reach a flip-flop input, not propagate through the multiply array. The
   3.851 ns DSP leg leaves the critical path entirely.
2. **It lets Vivado use the DSP48E1 A/B input registers.** With operands
   arriving from flops, the tool absorbs them into the DSP, so the multiply is
   register-to-register inside the block instead of a fabric-fed array.

**Cost:** one extra pipeline stage. `IF/ID/EX1/EX2/MEM/WB` becomes
`IF/ID/EX1/EX2/EX3/MEM/WB`, and issue-to-`result_valid` latency goes from 4
clocks to 5. Throughput is unchanged at one instruction per clock once the pipe
is full. This was the explicit trade accepted for the frequency target.

### 4.1 The interlock this required

A MAC or MUL sitting in EX2 has no result yet — the product is still inside the
DSP. A dependent instruction directly behind it therefore cannot be forwarded
to, and takes a **one-cycle stall**:

```systemverilog
assign stall = e1_valid && e2_valid && e2_is_mul_class && (e2_rd != 5'd0) &&
               ( (e1_rs1 == e2_rd) || (e1_uses_rs2 && (e1_rs2 == e2_rd)) );
```

After that single cycle the producer has moved to EX3 and the normal forwarding
path covers it. An **ALU** instruction in EX2 is not a hazard —
`e2_alu_result` is already registered and is forwarded directly, which is why
the stall condition tests `e2_is_mul_class` rather than simply `e2_valid`.

Forwarding into EX1 now comes from four places, nearest producer first:
EX2 (ALU results only) → EX3 → MEM → WB.

> **Known limitation.** `stall` holds the IF/ID and ID/EX1 registers. If a new
> `instr_valid` pulse arrived during a stalled cycle it would be dropped. Every
> issue path in this system — `alu_mac_cmd_ctrl` and the OOP bench's driver —
> waits for the previous instruction to retire before issuing, so this cannot
> occur here. It would need a ready/valid handshake before the DUT could accept
> genuinely back-to-back issue.

---

## 5. Result

```
============================================================
  POST-IMPLEMENTATION TIMING
    WNS = 0.298456 ns
    TNS = 0.000000 ns
    WHS = 0.049096 ns
    *** TIMING MET at 100 MHz ***
============================================================
```

Setup: 0 failing endpoints. Hold: 0 failing endpoints. Pulse width: 0 failing
endpoints.

### 5.1 The new critical path

```
Slack (MET) : 0.298ns
  Source:      u_core/u_dut/mac_accumulator[19]_i_9_psdsp/C  (FDRE)
  Destination: u_core/u_dut/e2_alu_result_reg[26]/D          (FDRE)
  Data Path Delay: 9.754ns  (logic 3.850ns 39.5%, route 5.904ns 60.5%)
  Logic Levels:    14  (CARRY4=5  LUT2=1  LUT5=3  LUT6=5)
```

The path is now accumulator → forwarding mux → 32-bit ALU → register. The
multiply is gone from it. Note the character has inverted: logic delay fell
from 6.612 ns to 3.850 ns, and the path is now **60% routing**. That means the
remaining slack is placement- and congestion-limited rather than logic-limited,
so further RTL restructuring would buy little. If more margin is ever needed,
the next lever is an implementation strategy with post-route physical
optimisation, not another pipeline stage.

### 5.2 Utilisation (post-implementation)

| Resource | Used | Available | % |
|---|---|---|---|
| Slice LUTs | 4724 | 53200 | 8.88 |
| — LUT as Logic | 4390 | 53200 | 8.25 |
| — LUT as Memory | 334 | 17400 | 1.92 |
| Slice Registers (all FF) | 6817 | 106400 | 6.41 |
| Block RAM Tile | 8.5 | 140 | 6.07 |
| DSP48E1 | 4 | 220 | 1.82 |
| Bonded IOB | 10 | 200 | 5.00 |
| BUFGCTRL | 2 | 32 | 6.25 |

Four DSP48E1s implement the 32×32 signed multiply. Most of the LUT, FF and all
of the BRAM belongs to `ila_0` and `vio_0`, not to the DUT — the ILA's
2048-sample × 152-bit capture buffer is the 8.5 BRAM tiles.

> Baseline utilisation is not tabulated here: the baseline reports were
> overwritten by the optimised run, and quoting remembered numbers would be
> guessing. The optimised figures above are measured.

---

## 6. Functional verification of the change

A timing fix that changes behaviour is not a fix. Both benches were re-run in
Questa Sim 2021.1 against the optimised RTL:

| Bench | Scope | Result |
|---|---|---|
| `tb_alu_mac_core` | `alu_mac_fpga_core` incl. 16-step BIST | **23/23 checks PASS**, 0 warnings |
| `tb_alu_mac_integrate` | `riscv_alu_mac_5stage` | **410/410 checks PASS**, 0 warnings |

Both were passing before the change and pass after, with identical expected
values — the reference model in the integrate bench was not relaxed to
accommodate the new pipeline; only its shadow-pipeline depth was extended to
mirror the new EX2/EX3 split.

**This evidence is only meaningful because the benches were repaired first.**
As delivered, `tb_alu_mac_integrate` incremented `pass_cnt` on every retired
instruction without comparing against anything, and printed "ALL 410 TEST CASES
PASSED" as a literal string — it reported a clean pass against a DUT whose
`ADD` had been mutated to return `0xDEADBEEF`. It now runs a shadow-pipeline
reference model that catches that mutation with 38 mismatches. Full detail in
`CONTEXT_MKDWN/04_KNOWN_ISSUES.md`.

The only intentional behavioural difference is latency: `tb_alu_mac_core`
group 7 measures it and now asserts **5** clocks instead of 4.

---

## 7. Reproducing this

```powershell
# simulate first - seconds, versus ~12 minutes for a bitstream
cd Test\sim
& "C:\questasim64_2021.1\win64\vsim.exe" -c -do run_core.do
& "C:\questasim64_2021.1\win64\vsim.exe" -c -do run_integrate.do

# build KOUSHIK_PROJ end to end
cd ..\..\fpga\tcl
& "C:\Vivado\Vivado\2020.1\bin\vivado.bat" -mode batch -source build_koushik_proj.tcl
```

Reports land in `fpga/reports/`. The pre-optimisation DUT is preserved at
`fpga/baseline_rtl/alu_mac_integrate_baseline.sv` — swap it in to reproduce the
−1.865 ns / −0.741 ns baseline.

Outputs:

```
vivado/KOUSHIK_PROJ/KOUSHIK_PROJ.runs/impl_1/fpga_top.bit
vivado/KOUSHIK_PROJ/KOUSHIK_PROJ.runs/impl_1/fpga_top.ltx
```

Keep the `.bit` and `.ltx` together — the Hardware Manager needs the `.ltx` to
show probe names instead of `probe0`, `probe1`, …

---

## 8. If you need more margin

+0.298 ns is met but not generous. In order of effort:

1. **Implementation strategy.** The path is 60% routing, so
   `Performance_ExplorePostRoutePhysOpt` targets exactly the right thing. No
   RTL change; costs build time only.
2. **Split the forwarding mux out of EX1.** The current path is accumulator →
   mux → ALU → flop. Registering the mux output would halve it, at the cost of
   another stage and a wider interlock.
3. **Reduce ILA pressure.** Dropping the capture depth from 2048 to 1024 frees
   BRAM and eases congestion around the debug hub, which is where the routing
   delay is concentrated.

Do **not** reach for a shorter `create_clock` period to "prove" headroom — the
ZedBoard oscillator is fixed at 100 MHz and this design instantiates no MMCM, so
a passing build at a shorter period demonstrates timing closure only. The
commented Fmax sweep in the XDC exists for that measurement and says so.
