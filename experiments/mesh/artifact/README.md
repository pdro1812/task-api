# Artifact: Sidecars, Ambient, or eBPF? Measuring the Tail-Latency and Resource Cost of Kubernetes Service Meshes

This package contains everything needed to rebuild the testbed, rerun the experiments, and regenerate every table
and figure of the paper from the aggregated results included here.

Six data-plane configurations are compared on the same cluster:

| ID | Configuration |
| --- | --- |
| B | no mesh (Cilium as CNI) |
| IS | Istio sidecar (Envoy per pod, mTLS STRICT) |
| IA4 | Istio Ambient, ztunnel only (L4) |
| IA7 | Istio Ambient with one waypoint per namespace (L7) |
| LK | Linkerd (`linkerd2-proxy` per pod, `all-authenticated`) |
| CI | Cilium service mesh (WireGuard between nodes, L7 policy through the per-node Envoy) |

Workloads: an echo chain (two Fortio servers), Online Boutique, and DeathStarBench Hotel Reservation, driven by k6
in open loop.

> Script comments and log messages are in Portuguese; this README and the paper are in English.

## Layout

| Path | Content |
| --- | --- |
| `00-host.sh` … `09-saltos.sh`, `99-pipeline.sh` | experiment scripts (order below) |
| `lib/` | shared shell functions: VM snapshots, application deployment, mesh installation, measurement |
| `k6/` | load scripts (one per application) |
| `versions.env` | pinned versions (empty = latest stable at install time; actual versions in `data/installed-versions.txt`) |
| `analysis/` | Python analysis: aggregation, statistics, figures, model, profiling, energy |
| `paper/` | LaTeX source, generated tables and figures (`make` builds `main.pdf`) |
| `data/` | aggregated results used in the paper (raw per-request data is not included; see below) |

## Testbed

- Host: Intel Core i7-12700K (8 P-cores with SMT, 4 E-cores), 64 GB RAM, Ubuntu 26.04, kernel 7.0.0-43.
- Four KVM VMs managed by libvirt (Ubuntu 24.04, kernel 6.8.0-149): one control-plane VM (2 vCPUs, 6 GB) and three
  workers (4 vCPUs, 14 GB each). vCPUs are pinned 1:1 to P-core threads; QEMU emulator threads to P-core pair 0;
  k6 to the E-cores.
- Kubernetes k3s v1.37.2, Cilium 1.20.3 (CNI in every configuration), Istio 1.32.0, Linkerd edge-26.11.1,
  Prometheus (5 s scrape). Container images are preloaded in a VM snapshot, which is restored before every
  configuration.
- The scripts assume a hybrid Intel CPU (`/sys/devices/cpu_core`, `/sys/devices/cpu_atom`), libvirt, and sudo for
  `00-host.sh`. Generated state (VM disks, kubeconfig) goes to `.state/`; results go to `results/` unless another
  directory is given.

## How to run

```bash
sudo apt install -y qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virtinst cloud-image-utils jq
sudo usermod -aG libvirt,kvm $USER        # then log in again
./00-host.sh          # host tuning: performance governor, no turbo, no deep C-states, RAPL readable (after every reboot)
./01-vms.sh           # creates the four VMs
./02-cluster.sh       # k3s + Cilium + Prometheus, preloads images (02b), records the "base" snapshot
CONFIGS="B IS IA4 IA7 LK CI" ./04-saturacao.sh            # max SLO-compliant throughput per configuration
CONFIGS="B IS IA4 IA7 LK CI" REFINAR=1 ./04-saturacao.sh  # bisection refinement (values used in the paper)
./05-bateria.sh results/main                               # main run: 6 configs x 3 apps x 30/60/90% x 10 reps (~37 h)
echo 0 | sudo tee /sys/module/kvm/parameters/halt_poll_ns
./05b-energia.sh results/energy-hp0                        # energy run without KVM halt-polling (108 runs, ~8 h)
./06-perfil.sh results/profiling                           # perf + bpftrace profiling at 60% load (RQ2)
./07-meshinsight.sh results/meshinsight                    # validation against MeshInsight (B vs IS on OB)
./08-energia-intercalada.sh                                # interleaved B/IS energy control
./09-saltos.sh results/hops.json                           # call graph per application from Istio telemetry (RQ3)
```

`./03-config.sh <B|IS|IA4|IA7|LK|CI>` prepares a single configuration (restores the snapshot, installs the mesh,
deploys the three applications and runs a smoke test). `99-pipeline.sh` chains the analysis steps after a run.

Analysis environment:

```bash
cd analysis && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
```

## From data to the paper

| Paper element | Produced by | Input in `data/` |
| --- | --- | --- |
| Table I (configurations), Table VII (decision guide) | written by hand | — |
| Table II (max throughput) | `04-saturacao.sh` with `REFINAR=1` | `saturation/saturacao.env` (`SATF_<app>_<cfg>`) |
| Table III (p99 latency) | `analysis/20_estatistica.py` | `main-cells.csv` |
| Fig. 1 (p99 vs load), Fig. 2 (CPU and memory per component) | `analysis/30_figuras.py` | `main-cells.csv` |
| Table IV (energy per request) | `analysis/60_energia.py` | `main-cells-summary.csv`, `energy-hp0-cells.csv` |
| Fig. 3 and Table V (profiling) | `analysis/50_perfil.py` | raw profiles (not included); summary in `profiling.csv` |
| Table VI (model) | `analysis/40_modelo.py` | `main-cells-summary.csv`, `hops.json` |
| Statistics in the text (Kruskal–Wallis, Mann–Whitney with Holm, Cliff's δ, CV) | `analysis/20_estatistica.py` | `main-statistics.csv` |

Examples, from the artifact root:

```bash
P=analysis/.venv/bin/python
$P analysis/20_estatistica.py data/main-cells.csv --tabelas paper/tables
$P analysis/40_modelo.py data/main-cells-summary.csv data/hops.json --saida paper/tables/modelo.tex
$P analysis/60_energia.py data/main-cells-summary.csv data/energy-hp0-cells.csv --saida paper/tables/energia.tex
```

`30_figuras.py` expects a run directory containing `cells.csv` (and `cdf/` for the CDF figures): extract
`data/main-cdf.tar.gz` into a directory, copy `data/main-cells.csv` there as `cells.csv`, and pass that directory.

## Data files

| File | Content |
| --- | --- |
| `main-cells.csv` | one row per run of the main experiment (540): latency percentiles computed from every request, error rate, throughput, energy, CPU and memory per component |
| `main-cells-summary.csv` | same runs, percentiles from the k6 summaries, plus mean latency and the utilization of the busiest worker |
| `main-statistics.csv` | medians with bootstrap CIs, Kruskal–Wallis, Mann–Whitney (Holm within each application and load), Cliff's δ |
| `main-cdf.tar.gz` | 1001 latency quantiles per run (for the CDF figures) |
| `energy-hp0-cells.csv`, `energy-comparison.csv` | energy run with KVM halt-polling disabled, and its comparison with the main run |
| `hops.json` | internal calls per external request, per edge, same-node vs cross-node |
| `profiling.csv` | data-plane CPU per request by category, context switches and syscalls per request |
| `saturation/` | saturation searches (step logs and final values) |
| `installed-versions.txt`, `images.txt` | versions recorded at install time and the digests of the preloaded images |

The raw per-run files (`k6-reqs.csv.gz` with every request, Prometheus series, RAPL readings; about 4 GB) are not
included for size; `05-bateria.sh` regenerates them, and `analysis/10_agregar.py` turns them into `main-cells.csv`.
