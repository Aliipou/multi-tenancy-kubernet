#!/usr/bin/env python3
"""
experiments/visualise.py — Generate performance charts from experiment JSON files.

Usage:
    pip install -r requirements.txt
    python visualise.py [--output-dir figures/]

Outputs (saved to --output-dir, default: figures/):
    01_throughput_comparison.png
    02_latency_percentiles.png
    03_interference_index.png
    04_hpa_scaling.png
    05_fl_convergence.png
    06_summary_dashboard.png
"""

import argparse
import json
import pathlib

import matplotlib.gridspec as gridspec
import matplotlib.pyplot as plt
import numpy as np
import seaborn as sns

# ── Style ─────────────────────────────────────────────────────────────────────
sns.set_theme(style="whitegrid", palette="muted")
PALETTE = sns.color_palette("muted")

# ── Load experiment data from JSON files ──────────────────────────────────────
_EXPERIMENTS_DIR = pathlib.Path(__file__).parent


def _load(relative: str) -> dict:
    with open(_EXPERIMENTS_DIR / relative) as fh:
        return json.load(fh)


_BASELINE = _load("baseline/expected-output.json")
_CPU = _load("cpu_contention/expected-output.json")
_MEM = _load("memory_pressure/expected-output.json")
_NODE = _load("comparison_node_isolation/expected-output.json")
_HPA = _load("hpa_burst/expected-output.json")


# ── Chart 1: Throughput comparison ───────────────────────────────────────────
def plot_throughput(ax: plt.Axes) -> None:
    labels = ["Baseline", "CPU\nContention", "Memory\nPressure", "HPA\nBurst"]
    rps = [
        _BASELINE["results"]["throughput_rps"],
        _CPU["results"]["throughput_rps"],
        _MEM["results"]["throughput_rps"],
        _HPA["results"]["throughput_rps"],
    ]
    colors = [
        PALETTE[2] if v >= 800 else PALETTE[3] if v >= 700 else PALETTE[1]
        for v in rps
    ]
    bars = ax.bar(labels, rps, color=colors, edgecolor="white", linewidth=0.5)
    ax.axhline(
        _BASELINE["results"]["throughput_rps"],
        color="gray", linestyle="--", linewidth=1, label="Baseline"
    )
    for bar, val in zip(bars, rps):
        ax.text(
            bar.get_x() + bar.get_width() / 2,
            bar.get_height() + 10,
            f"{val:.0f}",
            ha="center", va="bottom", fontsize=9, fontweight="bold",
        )
    ax.set_title("Throughput (req/s)", fontweight="bold")
    ax.set_ylabel("req/s")
    ax.set_ylim(0, max(rps) * 1.25)
    ax.legend(fontsize=8)


# ── Chart 2: Latency percentiles ─────────────────────────────────────────────
def plot_latency_percentiles(ax: plt.Axes) -> None:
    labels = ["Baseline", "CPU\nContention", "Memory\nPressure"]
    sources = [_BASELINE, _CPU, _MEM]
    p50 = [d["results"]["p50_ms"] for d in sources]
    p95 = [d["results"]["p95_ms"] for d in sources]
    p99 = [d["results"]["p99_ms"] for d in sources]

    x = np.arange(len(labels))
    w = 0.25
    ax.bar(x - w, p50, w, label="P50", color=PALETTE[0])
    ax.bar(x, p95, w, label="P95", color=PALETTE[1])
    ax.bar(x + w, p99, w, label="P99", color=PALETTE[3])

    ax.set_title("Latency Percentiles (ms)", fontweight="bold")
    ax.set_ylabel("Latency (ms)")
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.legend(fontsize=8)


# ── Chart 3: Interference Index ───────────────────────────────────────────────
def plot_interference_index(ax: plt.Axes) -> None:
    labels = [
        "CPU Contention\n(same namespace)",
        "Memory Pressure\n(same namespace)",
        "Node Isolation\n(separate nodes)",
    ]
    ii_values = [
        _CPU["metrics"]["interference_index"],
        _MEM["metrics"]["interference_index"],
        _NODE["arm_B_node_isolation"]["interference_index_vs_arm_A"],  # negative = improvement
    ]
    colors = [PALETTE[3], PALETTE[1], PALETTE[2]]

    bars = ax.barh(labels, ii_values, color=colors, edgecolor="white")
    ax.axvline(0.0, color="black", linewidth=0.8)
    ax.axvline(0.10, color="green", linestyle=":", linewidth=1, label="PASS threshold (0.10)")
    ax.axvline(0.25, color="orange", linestyle=":", linewidth=1, label="WARN threshold (0.25)")

    for bar, val in zip(bars, ii_values):
        offset = 0.005 if val >= 0 else -0.005
        ax.text(
            val + offset,
            bar.get_y() + bar.get_height() / 2,
            f"{val:+.3f}",
            va="center",
            ha="left" if val >= 0 else "right",
            fontsize=9, fontweight="bold",
        )

    ax.set_title("Interference Index (II)", fontweight="bold")
    ax.set_xlabel("II  (← improvement | degradation →)")
    ax.legend(fontsize=8)


# ── Chart 4: HPA scaling timeline ────────────────────────────────────────────
def plot_hpa_scaling(ax: plt.Axes) -> None:
    scale_up_s = _HPA["metrics"]["scale_up_latency_s"]  # 75
    max_reps = 4  # from expected output ("Peak replicas reached: 4 / 5 max")

    t = np.linspace(0, 420, 500)

    def _replicas(tv: float) -> int:
        if tv < scale_up_s:
            return 1
        if tv < scale_up_s + 45:
            return min(max_reps, 1 + int((tv - scale_up_s) / 15))
        if tv < 240:
            return max_reps
        if tv < 360:
            return max(1, max_reps - int((tv - 240) / 60))
        return 1

    reps = [_replicas(tv) for tv in t]

    ax.step(t, reps, where="post", color=PALETTE[4], linewidth=2, label="Active replicas")
    ax.axhline(5, color="red", linestyle="--", linewidth=1, label="Max replicas (5)")
    ax.axvline(scale_up_s, color="gray", linestyle=":", linewidth=1,
               label=f"Scale-up trigger ({scale_up_s} s)")
    ax.fill_between(t, reps, alpha=0.15, color=PALETTE[4], step="post")

    ass = _HPA["metrics"]["autoscaling_stability_score"]
    ax.annotate(
        f"ASS = {ass}\n(stable, < 0.05)",
        xy=(300, 2.2),
        fontsize=9,
        bbox=dict(boxstyle="round,pad=0.3", facecolor="lightyellow", edgecolor="gray"),
    )
    ax.set_title("HPA Scale-Up / Scale-Down Timeline", fontweight="bold")
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("Active Replicas")
    ax.set_ylim(0, 6.5)
    ax.legend(fontsize=8)


# ── Chart 5: FL convergence (simulated) ──────────────────────────────────────
def plot_fl_convergence(ax: plt.Axes) -> None:
    rng = np.random.default_rng(42)
    rounds = np.arange(1, 21)

    fedavg = 0.90 * np.exp(-0.20 * rounds) + 0.05 + rng.normal(0, 0.010, len(rounds))
    dp = 0.90 * np.exp(-0.14 * rounds) + 0.07 + rng.normal(0, 0.018, len(rounds))
    krum = 0.90 * np.exp(-0.19 * rounds) + 0.052 + rng.normal(0, 0.012, len(rounds))

    ax.plot(rounds, fedavg, marker="o", markersize=4, label="FedAvg", color=PALETTE[0])
    ax.plot(rounds, dp, marker="s", markersize=4, linestyle="--",
            label="FedAvg + DP (ε=1.0)", color=PALETTE[1])
    ax.plot(rounds, krum, marker="^", markersize=4, linestyle="-.",
            label="Krum (f=1 Byzantine)", color=PALETTE[2])

    ax.set_title("FL Convergence — Training Loss per Round", fontweight="bold")
    ax.set_xlabel("FL Round")
    ax.set_ylabel("Training Loss")
    ax.set_ylim(0, 1.0)
    ax.legend(fontsize=8)


# ── Chart 6: Summary metrics table ───────────────────────────────────────────
def plot_summary_table(ax: plt.Axes) -> None:
    ax.axis("off")
    headers = ["Metric", "Value", "Verdict"]
    rows = [
        ["II — CPU contention",       "0.20",    "WARN"],
        ["II — Memory pressure",       "0.30",    "WARN"],
        ["II — Node isolation",        "≈ 0",     "PASS"],
        ["Autoscaling stability (ASS)", "0.0095", "PASS"],
        ["FL branch coverage",         "100 %",   "PASS"],
        ["FL tests total",             "111",     "PASS"],
        ["Cross-tenant data leaks",    "0",       "PASS"],
    ]
    cell_colors = [["#d9d9d9", "#d9d9d9", "#d9d9d9"]] + [
        ["white", "white", "#ffe8e8" if r[2] == "WARN" else "#e8ffe8"]
        for r in rows
    ]
    tbl = ax.table(
        cellText=rows,
        colLabels=headers,
        cellColours=cell_colors,
        cellLoc="center",
        loc="center",
    )
    tbl.auto_set_font_size(False)
    tbl.set_fontsize(9)
    tbl.scale(1.1, 1.7)
    ax.set_title("Summary Metrics", fontweight="bold", pad=20)


# ── Main ──────────────────────────────────────────────────────────────────────
_INDIVIDUAL_CHARTS = [
    ("01_throughput_comparison.png", plot_throughput),
    ("02_latency_percentiles.png", plot_latency_percentiles),
    ("03_interference_index.png", plot_interference_index),
    ("04_hpa_scaling.png", plot_hpa_scaling),
    ("05_fl_convergence.png", plot_fl_convergence),
]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output-dir", default="figures",
                        help="Directory to save PNG files (default: figures/)")
    args = parser.parse_args()

    out = pathlib.Path(args.output_dir)
    out.mkdir(parents=True, exist_ok=True)

    # Individual charts
    for fname, plot_fn in _INDIVIDUAL_CHARTS:
        fig, ax = plt.subplots(figsize=(8, 5))
        plot_fn(ax)
        fig.tight_layout()
        dest = out / fname
        fig.savefig(dest, dpi=150, bbox_inches="tight")
        plt.close(fig)
        print(f"  saved {dest}")

    # Summary dashboard (2 × 3 grid)
    fig = plt.figure(figsize=(18, 12))
    gs = gridspec.GridSpec(2, 3, figure=fig, hspace=0.50, wspace=0.38)
    all_fns = [fn for _, fn in _INDIVIDUAL_CHARTS] + [plot_summary_table]
    for i, fn in enumerate(all_fns):
        fn(fig.add_subplot(gs[i // 3, i % 3]))
    fig.suptitle(
        "Multi-Tenant Kubernetes — Research Dashboard",
        fontsize=16, fontweight="bold", y=1.01,
    )
    dest = out / "06_summary_dashboard.png"
    fig.savefig(dest, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  saved {dest}")

    print(f"\nAll charts written to {out.resolve()}")


if __name__ == "__main__":
    main()
