# NVIDIA RTX Platform Research (June 2026)

Compiled 2026-06-03. Sources: nvidia.com (GeForce, RTX AI PC, DGX
Spark, RTX Spark, changelog), en.wikipedia.org/wiki/GeForce_RTX_50_series,
Tom's Hardware, PCMag, The Verge, The Register, The Guardian,
Engadget, MacRumors, TechSpot, runpod.io, videocardz, wccftech,
hotHardware, ofzenandcomputing, bestvaluegpu, brave search summaries.

---

## The correction: RTX Spark ≠ DGX Spark

This is important and I got it wrong in the first draft.

**Two separate products that share the same superchip silicon:**

| | **RTX Spark** | **DGX Spark** |
|---|---|---|
| **Audience** | Consumers, creators, gamers, AI PC users | AI developers, researchers, data scientists |
| **OS** | **Windows 11 on Arm** | **DGX OS (Ubuntu 24.04 custom)** |
| **Form factor** | **Slim laptops** (as thin as 14 mm) **+ small desktops** | Standalone 1.2 kg mini-PC |
| **Power budget** | 80 W (laptop) / 100 W (desktop) | ~200 W (the GB10 at rated performance) |
| **Launched** | Announced 2026-06-01 at **Computex 2026**; ships **fall 2026** | Announced CES 2025 as "Project Digits"; **shipping since Oct 2025** |
| **Available from** | ASUS, Dell, HP, Lenovo, Microsoft Surface, MSI (Acer, GIGABYTE to follow) | NVIDIA + OEM partners |
| **Initial price** | Not announced; partner SKUs (Microsoft Surface Laptop Ultra among them) TBA | $3,999 launch, ~$5,000 in 2026 due to memory shortage |

The silicon is the same **GB10 Grace Blackwell Superchip** — Blackwell
GPU + Grace Arm CPU + up to 128 GB LPDDR5x unified memory, NVLink-C2C
chip-to-chip interconnect. NVIDIA's productization of that chip
into two product lines (consumer Windows laptop vs Linux AI dev
workstation) is the "new RTX platform" story in 2026.

Sources for the split:
- The Register, 2026-06-01: "The silicon may be the same but the
  operating system isn't. While Nvidia's DGX Spark and GB10 partner
  systems shipped with DGX OS, a lightly customized version of
  Ubuntu 24.04, RTX Spark systems will ship with Windows."
- PCMag: "The key difference is that RTX Spark is specifically
  meant for consumers and the Windows 11 OS, whereas DGX Spark runs
  a custom version of Ubuntu Linux."
- NVIDIA Developer Forum (engineer response): "The CPU/GPU in the
  RTX products is similar to the GB10 in terms of ARM cores and
  tensors. The DGX spark can consume 200 W at rated performance,
  while the RTX systems are 80 W (laptop) and 100 W (desktop)."
- Tom's Hardware: "RTX Spark hasn't come out of nowhere; it's the
  consumer-oriented sibling of the GB10 Grace Blackwell superchip
  already shipping inside the Linux-based DGX Spark mini-PC."

The user was right to push back. Let me make sure the rest of the
research reflects this correctly.

---

## 1. The 2026 NVIDIA RTX platform: the full picture

NVIDIA's RTX brand in 2026 covers three product lines built on the
**Blackwell** architecture (TSMC 4N / 3N process):

1. **GeForce RTX 50 Series** — discrete consumer GPUs (desktop +
   laptop). Launched January 2025.
2. **NVIDIA RTX Spark** — a brand-new Windows-on-Arm laptop /
   compact-desktop platform, announced at Computex 2026 (June 1).
   Consumer sibling of the GB10 superchip.
3. **NVIDIA DGX Spark** — the Linux AI dev workstation cousin of
   RTX Spark, launched 2025 (originally "Project Digits").

The unifying message NVIDIA is pushing across all three in 2026 is
"personal AI computer" / "agentic AI on device" — local LLMs, local
agents (NemoClaw / OpenShell), local content creation, plus the
gaming / creator / productivity workloads that already lived on RTX.

---

## 2. GeForce RTX 50 Series ("Blackwell for the rest of us")

### 2.1 Announcement and release

- **Announced:** CES 2025, January 6, 2025
- **First cards on sale:** January 30, 2025 (RTX 5090, 5080, 5070)
- **Full stack rolled out** through Q1–Q3 2025
- **Fabrication:** TSMC custom node "4N" (5 nm-class)
- **Interface:** PCIe 5.0 (first consumer GPUs to use it; the 5050
  uses x8, everything else x16)
- **Memory:** GDDR7 across the lineup (RTX 5050 is the odd one out
  and still ships with GDDR6); first consumer GPUs with GDDR7
- **Power connector:** mandated 16-pin 12V-2x6 (the safer revision
  of the RTX 4090's 12VHPWR) on all AIB designs
- **Display output:** DisplayPort 2.1b UHBR20 (80 Gbps) + HDMI 2.1b
  — first GeForce to support 4K @ 480 Hz or 8K @ 165 Hz with DSC
- **Media engine:** 9th-gen NVENC (3 on 5090, 2 elsewhere) +
  6th-gen NVDEC (2 on 5080/5090, 1 elsewhere); first GeForce with
  4:2:2 hardware encode/decode for pro video

### 2.2 The lineup (MSRP, launch date, key specs)

| Card           | Launch MSRP | Date         | CUDA   | VRAM          | Bus   | TDP  |
|----------------|-------------|--------------|--------|---------------|-------|------|
| RTX 5050       | $249        | Jul 2025     | 2,560  | 8 GB GDDR6    | 128b  | 130 W |
| RTX 5060       | $299        | May 2025     | 3,840  | 8 GB GDDR7    | 192b  | 145 W |
| RTX 5060 Ti    | $379 (8 GB) / **$429 (16 GB)** | Apr 2025 | 4,608 | 8/16 GB GDDR7 | 256b | 180 W |
| RTX 5070       | $549        | Mar 2025     | 6,144  | 12 GB GDDR7   | 256b  | 250 W |
| RTX 5070 Ti    | $749        | Feb 20, 2025 | 8,960  | 16 GB GDDR7   | 256b  | 300 W |
| RTX 5080       | $999        | Jan 30, 2025 | 10,752 | 16 GB GDDR7   | 256b  | 360 W |
| RTX 5090       | **$1,999**  | Jan 30, 2025 | 21,760 | 32 GB GDDR7   | 512b  | 575 W |

**AI TOPS (the marketing number):** RTX 5090 — 3,352; 5080 — 1,801;
5070 — 1,000-ish (per-card in NVIDIA's spec sheets).

### 2.3 What's new vs RTX 40 series (Ada Lovelace)

- **5th-gen Tensor Cores** with **FP4** precision. FP4 is the step
  that made local LLMs (Llama 3.1 8B in int4, etc.) actually
  runnable on a consumer GPU. RTX 50 quotes "4× faster LLM chat"
  vs a non-RTX laptop.
- **4th-gen RT Cores** "built for Mega Geometry" — much higher
  ray-triangle throughput, enabling full path tracing in shipping
  titles.
- **DLSS 4** — a vision-transformer-based upscaling model (vs the
  CNN model in DLSS 3) and the new **Multi Frame Generation (MFG)**,
  exclusive to RTX 50. Where DLSS 3 interpolated 1 frame per
  rendered frame, MFG generates up to 3 additional frames per
  rendered frame; combined with the standard 1 that gives the
  "4× MFG" / 6× MFG modes in the marketing. 75 titles had MFG at
  launch.
- **DLSS 4.5** (mid-2026) — adds **Dynamic MFG** (frame count
  adapts to scene complexity) and a 2nd-gen transformer for ray
  reconstruction.
- **Reflex 2 with Frame Warp** — further input-latency reduction
  by warping frames based on the most recent mouse input.
- **NVIDIA ACE / NIM on RTX** — RTX 50 GPUs are positioned as
  on-device AI PCs running NIM microservices for Llama, Riva
  speech, FLUX vision, retrieval models. Local agents, local
  LLMs, local Stable Diffusion.
- **Max-Q updates for laptops** — Advanced Power Gating + an
  "ultra" low-voltage GDDR7 state, claimed to give up to 40%
  battery-life gain over RTX 40 laptops.

### 2.4 Real-world pricing in 2026

The MSRP column above is *launch list*. By mid-2026 the picture is
messed up:

- **RTX 5090**: per Wccftech, HotHardware, VideoCardz, Best Value
  GPU, retailers in early 2026 had no stock at $1,999; mean eBay
  sale price was ~$4,086 (Q1 2025) and the **MSRP card was still
  basically impossible to buy at MSRP in early 2026**, with real
  street prices $3,000–$5,000 driven by scalpers, AI demand, and
  the 2025–2026 GDDR7 / VRAM shortage. One-year retrospectives
  called it "nearly twice the MSRP." Best Value GPU's June 2026
  tracker showed ~$4,199 baseline.
- **RTX 5080** had somewhat better availability but was also above
  MSRP for most of 2025.
- **RTX 5070 / 5070 Ti** were the *actually attainable at MSRP*
  cards through 2025; 5070 specifically was a $549 1440p workhorse.

The reason for the squeeze: AI demand is siphoning Blackwell
allocation, GDDR7 supply is constrained, and tariffs during the
2024–2025 stockpiling window distorted inventories.

### 2.5 Reception and controversies

- **Jensen's "5070 = 4090 performance" claim** turned out to rely
  on DLSS 4 + MFG (i.e., generated frames, not raw rasterization).
  Wikipedia and several outlets flagged this as misleading.
- **RTX 5090 power** jumped to 575 W (vs 450 W on the 4090) — the
  highest of any consumer GeForce ever, requiring a 1,000 W PSU
  recommendation and the new 12V-2x6 connector.
- **Missing ROPs defect** in early 5090/5080 batches (some AIB
  cards shipped with fewer than advertised render output units;
  NVIDIA offered replacements).
- **Laptop variants** ship from March 2025 starting at $1,299 for
  the RTX 5070 laptop GPU, $2,599+ for the 5090 laptop tier.

---

## 3. NVIDIA RTX Spark (Computex 2026, the genuinely new platform)

This is the actually new product category unveiled 2026-06-01 at
Computex Taipei. NVIDIA's positioning: "the fusion of NVIDIA AI and
RTX graphics in a single chip redefines Windows PCs."

### 3.1 The chip: "RTX Spark Superchip"

Same silicon family as the DGX Spark's GB10, but tuned for the
80 W (laptop) / 100 W (desktop) power envelope:

- **CPU:** 20-core NVIDIA Grace (Arm), built with **MediaTek**.
  Same Cortex-X925 + Cortex-A725 layout as the GB10.
- **GPU:** NVIDIA Blackwell RTX, **up to 6,144 CUDA cores**,
  5th-gen Tensor Cores with FP4, RT Cores.
- **Interconnect:** **NVLink-C2C** chip-to-chip between CPU and
  GPU die (the same coherent interconnect as the GB10 in DGX
  Spark).
- **Memory:** **up to 128 GB LPDDR5x unified** (CPU + GPU share
  one pool). Same ceiling as DGX Spark.
- **AI performance:** **up to 1 PFLOP FP4** (with sparsity).
- **Process:** **TSMC 3 nm**, ~70 billion transistors.
- **AI-equivalent claim:** NVIDIA has said the integrated graphics
  are equivalent to an **RTX 5070 laptop GPU**.

Compared to the DGX Spark GB10:
- Same CPU + GPU core topology
- Same 128 GB unified memory ceiling
- Lower power budget (80 W / 100 W vs ~200 W) → lower sustained
  clocks
- **No ConnectX-7 200 Gbps networking** in the consumer SKUs (that
  stays as a DGX Spark / DGX Station data-center feature, although
  OEMs may add it)
- **No NemoClaw / NIM enterprise stack** — RTX Spark gets the
  consumer agent runtime (Windows-native agents on the new OS
  security primitives + NVIDIA OpenShell)

### 3.2 Form factor and partners

- **Laptops:** chassis as thin as 14 mm and as light as ~3 lb
  (~1.36 kg), precision-machined aluminum. Claim: "the most
  power-efficient RTX chip ever made, in a chassis so slim you'll
  forget you're carrying it."
- **Desktops:** small, ultra-efficient desktops, marketed for
  "always-on AI agent use cases."
- **Laptop launch partners (Computex 2026 reveal):** ASUS, Dell,
  HP, Lenovo, **Microsoft Surface** (the **Surface Laptop Ultra**
  is the most prominent), MSI. Acer and GIGABYTE to follow.
- **Microsoft collaboration:** Windows 11 on Arm is the OS.
  Microsoft and NVIDIA built new OS security primitives for
  on-device agents. NVIDIA OpenShell provides the agent runtime.

### 3.3 Confirmed RTX Spark laptops at Computex 2026

(Per PCMag's "Every Nvidia RTX Spark Laptop Announced So Far" and
the HP press release on their own site)

- **Microsoft Surface Laptop Ultra** — flagship Windows-on-ARM
  reference design, "signals a raw power revolution" per PCMag
- **HP OmniBook Ultra 16** and **HP OmniBook X 14** — HP
  claims the X 14 will be "the world's thinnest RTX Spark"
- **ASUS ProArt P16** — creator-targeted
- **Dell XPS 16** — premium thin-and-light
- **Lenovo Yoga Pro 9n**
- **MSI Prestige N16 Flip** — 2-in-1 convertible

Pricing was **not announced** at the Computex keynote. Reddit /
nvidia reaction: a 128 GB unified-memory SKU is widely expected to
land in the $3,000–$5,000+ range.

### 3.4 Software / agent story

- **NVIDIA OpenShell** — open-source runtime for open-weight
  agents, the consumer counterpart to the DGX Spark's
  NemoClaw / OpenClaw enterprise stack.
- **Project G-Assist** — on-device AI assistant for tuning /
  controlling the PC.
- **NIM microservices on RTX** — language, speech, vision,
  retrieval, design models running locally.
- **DLSS 4.5, Reflex 2, G-SYNC, OptiX, TensorRT, CUDA** — the
  full NVIDIA stack runs natively on RTX Spark (the first time
  the entire CUDA + RTX stack has been on a Windows-on-Arm SoC).
- **Native 4:2:2 hardware encode/decode, AV1 encoders, NVIDIA
  Broadcast** — for creator / streaming workflows.
- **AI Blueprints** — pre-built agentic workflows
  (PDF-to-Podcast, 3D object generation, 3D-guided generative AI).

### 3.5 Why this matters strategically

This is NVIDIA's first direct shot at the Apple Silicon /
Qualcomm / AMD Strix Halo "AI PC" category, but with the
full CUDA + RTX stack on the chip. Key competitive angles:

- **vs Apple M-series:** Unified memory and per-watt efficiency
  in the same ballpark, but you get CUDA, RTX graphics, full
  Windows, and a "1 PFLOP FP4" AI claim.
- **vs Qualcomm Snapdragon X (Windows on Arm):** Qualcomm's
  exclusivity deal just expired; NVIDIA is the obvious next
  serious Windows-on-Arm player. PCMag headline: "Welcome to the
  Superchip Era: 6 Ways the Nvidia RTX Spark Will Upend the PC
  Industry."
- **vs AMD Strix Halo (Ryzen AI Max+ 395):** AMD already has
  128 GB unified memory on a single chip in 2025, and Tom's
  Hardware's DGX Spark review noted that the GB10 "beats out
  AMD's Ryzen AI Max+ 395" in many AI workloads. RTX Spark is
  the laptop counterpart.
- **vs Intel:** per Yahoo Finance, "taking aim at Intel and AMD
  with the debut of the RTX Spark superchip for Windows
  laptops."

---

## 4. NVIDIA DGX Spark (the Linux AI dev workstation)

This is the one that already shipped. Announced CES 2025 as
"Project Digits," renamed to DGX Spark at GTC 2025, shipping
since October 2025.

### 4.1 What it is

- **Form factor:** 150 × 150 × 50.5 mm, 1.2 kg — Mac Mini / Intel
  NUC class chassis. Quiet (35 dB idle).
- **Power:** 240 W external supply, GB10 TDP ~140 W.
- **OS:** DGX OS (Ubuntu 24.04 with NVIDIA's stack).

### 4.2 The chip: GB10 Grace Blackwell Superchip

- **CPU:** 20-core Arm — 10× Cortex-X925 + 10× Cortex-A725
- **GPU:** Blackwell with 5th-gen Tensor Cores (FP4) and 4th-gen
  RT Cores
- **Memory:** **128 GB LPDDR5x coherent unified**, 256-bit
  interface, **273 GB/s bandwidth** (the bottleneck — much lower
  than H100's HBM3)
- **Storage:** 4 TB NVMe M.2 with self-encryption
- **Networking:** 1× RJ-45 10 GbE **+** a **ConnectX-7 NIC at
  200 Gbps** (the killer feature — you can link two Sparks to
  work with 405-billion-parameter models)
- **I/O:** 4× USB Type-C, Wi-Fi 7, BT 5.4, 1× HDMI 2.1a + up to
  3× DisplayPort over USB-C, 1× NVENC, 1× NVDEC

### 4.3 Performance claims

- **Up to 1 PFLOP FP4 AI** (with sparsity)
- 128 GB unified memory → **AI models up to 200B parameters** for
  inference on a single unit
- **Fine-tune models up to 70B parameters** on one unit
- **Two units linked** via ConnectX-7 → 405B parameters
- Pre-installed DGX OS with the full NVIDIA AI software stack:
  NeMo, RAPIDS, NIM microservices, Isaac, Metropolis, Holoscan
  for robotics / edge

### 4.4 Pricing and availability

- **Launch price:** **$3,999** (held through 2025)
- **2026 real-world:** **~$5,000** due to the same GDDR7 / memory
  shortage that pushed the RTX 5090 above MSRP
- **Channel:** NVIDIA + OEM partners (Dell Pro Max, ASUS, MSI, HP
  all ship GB10-based boxes; the Spark itself is the quietest of
  the bunch per InsiderLLM's comparison)
- **DGX Station** — a higher-end GB300 / Blackwell Ultra
  workstation variant also announced in 2025 for users who need
  more memory bandwidth than the Spark's 273 GB/s; a "DGX Station
  for Windows" was teased by Microsoft at the RTX Spark launch

### 4.5 Software story (Linux / AI dev focus)

- **NVIDIA NemoClaw** — part of the Agent Toolkit, an open-source
  reference stack that adds security/privacy guardrails to
  **OpenClaw** (the local-agent runtime). Runs on RTX PCs, DGX
  Station, and DGX Spark.
- **NVIDIA OpenShell** — open-source runtime for open-weight
  agents (the enterprise version).
- Pre-installed DGX OS with the entire NVIDIA AI stack.
- Designed to be the desktop counterpart to cloud-hosted agents;
  "always-on, private, on-device" is the pitch.

---

## 5. RTX 50 series vs RTX Spark vs DGX Spark — how to think about them

| | **RTX 50 Series (GeForce)** | **RTX Spark (laptop/desktop)** | **DGX Spark (mini-PC)** |
|---|---|---|---|
| Audience | gamers, creators, AI PC users | consumers, creators, gamers, AI PC developers | AI developers, researchers, robotics |
| Form factor | discrete GPU in a desktop / laptop | slim laptop or small desktop | standalone 1.2 kg mini-PC |
| OS | Windows / Linux | **Windows 11 on Arm** | **DGX OS (Ubuntu 24.04)** |
| Memory | 8–32 GB GDDR7 (high bandwidth) | up to 128 GB LPDDR5x unified | 128 GB LPDDR5x unified |
| Memory bandwidth | 320–1,792 GB/s | lower (273 GB/s class) | 273 GB/s |
| AI throughput | 1,801–3,352 INT8/FP8 TOPS | 1 PFLOP FP4 (chip-level, ~RTX 5070 laptop equivalent graphics) | 1 PFLOP FP4 |
| Power | 130–575 W (card) | 80 W (laptop) / 100 W (desktop) | 240 W (whole box) |
| Sweet spot | gaming, on-device 8B–13B LLMs, SD/Flux | local 70B-class LLMs, agentic AI, slim Windows laptop | 200B inference, 70B fine-tuning, edge / robotics |
| Price | $249 (5050) → $1,999+ (5090) | TBA — expected $2,000–$5,000+ | $3,999 launch, ~$5,000 in 2026 |
| Shipped | Jan 2025 | Fall 2026 | Oct 2025 |

They're complementary, not competing. Pick the right tool for the
job:

- **Gaming / mainstream creator** → GeForce RTX 50 series
- **Slim AI-first Windows laptop** with massive unified memory →
  RTX Spark laptop
- **Linux dev workstation for serious local model work** → DGX Spark
- **Gaming + light AI dev on one machine** → RTX 5090 + 5090
  laptops are still the best mix

---

## 6. The rest of the 2026 RTX stack

- **GeForce NOW** — cloud gaming, still positioned as the "any
  device" RTX experience
- **G-SYNC displays** — G-SYNC Pulsar is the current top tier
- **NVIDIA Studio** — RTX-accelerated creative suite
- **NVIDIA Broadcast** — AI webcam/mic for streamers (v2.2 in
  2026)
- **RTX Video** — RTX Video Super Resolution + HDR, browser/VLC
- **RTX Remix** — modders' tool to remaster classic games with
  full path tracing + DLSS
- **Project G-Assist** — local AI assistant for tuning/optimizing
  the PC
- **DLSS 4.5** — Dynamic MFG + 2nd-gen transformer, available
  across the 50 series
- **Reflex 2 / Frame Warp** — competitive latency reduction

---

## 7. TL;DR

- The "new NVIDIA RTX platform" in 2026 is **three** things, not
  two:
  1. **GeForce RTX 50 series** (Blackwell consumer GPUs) —
     launched January 2025, 7 SKUs from RTX 5050 ($249) to
     RTX 5090 ($1,999 MSRP, real-world $3k–$5k in 2026).
     Headline features: 5th-gen Tensor Cores with FP4, 4th-gen
     RT Cores, DLSS 4 Multi Frame Generation, GDDR7, PCIe 5.0,
     12V-2x6 power.
  2. **NVIDIA RTX Spark** — **brand-new** at Computex 2026, ships
     fall 2026. A consumer Windows-on-Arm laptop and small-desktop
     platform built on the "RTX Spark Superchip" (Blackwell GPU +
     Grace Arm CPU + up to 128 GB unified memory + 1 PFLOP FP4 AI).
     Laptops as thin as 14 mm. From ASUS, Dell, HP, Lenovo,
     Microsoft Surface (Laptop Ultra), MSI. Built around Windows
     11 on Arm + NVIDIA OpenShell for on-device agents.
  3. **NVIDIA DGX Spark** — the Linux AI dev workstation cousin of
     RTX Spark, shipped since October 2025. Same GB10 superchip
     silicon, 128 GB unified memory, ConnectX-7 200 Gbps
     networking for linking two units, runs DGX OS. $3,999 launch
     (~$5,000 in 2026). For running 200B inference and 70B
     fine-tuning locally.
- All three share the **Blackwell** architecture and the **RTX**
  brand, but they target very different users.
- The strategic 2026 story is RTX Spark as NVIDIA's direct
  answer to Apple Silicon and Qualcomm Snapdragon X in the
  Windows-on-Arm AI PC category — and the first time the entire
  CUDA + RTX stack has been on a single Windows-on-Arm SoC.
