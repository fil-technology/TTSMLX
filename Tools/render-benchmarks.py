#!/usr/bin/env python3
"""Render Benchmarks/results/*.json (written by TTSBenchmarkRunner) into
Docs/benchmarks.md: one table per device with the latest report per model.

    python3 Tools/render-benchmarks.py            # writes Docs/benchmarks.md
    python3 Tools/render-benchmarks.py --stdout   # prints instead
"""
import glob
import json
import os
import statistics
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(ROOT, "Benchmarks", "results")
OUT = os.path.join(ROOT, "Docs", "benchmarks.md")

DEVICE_NAMES = {
    "iPhone18,3": "iPhone 17",
    "iPhone18,1": "iPhone 17 Pro",
    "iPhone18,2": "iPhone 17 Pro Max",
    "MacBookPro18,3": "MacBook Pro 14-inch 2021",
    "MacBookPro18,4": "MacBook Pro 14-inch 2021",
    "MacBookPro18,1": "MacBook Pro 16-inch 2021",
    "MacBookPro18,2": "MacBook Pro 16-inch 2021",
}


def median(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def fmt(value, unit="", digits=2):
    if value is None:
        return "–"
    return f"{value:.{digits}f}{unit}"


def summary(trials, fixture, mode):
    rows = [t for t in trials if t["fixtureID"] == fixture and t["mode"] == mode]
    warm = [t for t in rows if not t["includesLoad"]] or rows
    if not warm:
        return None
    return {
        "firstAudio": median([t["firstAudioSeconds"] for t in warm]),
        "rtf": median([t["audioSeconds"] / t["wallSeconds"] for t in warm if t["wallSeconds"]]),
        "mlxPeak": max(t["mlxPeakMB"] for t in warm),
        "resident": max(t["residentMB"] for t in warm),
        "stalls": sum(t["stallCount"] for t in warm),
        "preroll": median([t.get("stallFreePrerollSeconds") for t in warm]),
        "overruns": sum(t["overrunChunks"] for t in warm),
        "cpu": median([t["cpuUtilization"] for t in warm]),
        "thermal": sorted({t["thermalState"] for t in warm}),
        "audio": median([t["audioSeconds"] for t in warm]),
        "trials": len(warm),
    }


def os_label(env):
    version = env["osVersion"].replace("Version ", "").replace("(Build ", "(")
    platform = "iOS" if env["device"].startswith(("iPhone", "iPad")) else "macOS"
    return f"{platform} {version}"


def device_label(env):
    name = DEVICE_NAMES.get(env["device"], env["device"])
    chip = env.get("chip")
    if chip and chip != env["device"]:
        name = f"{name} ({chip})"
    return name


def main():
    reports = []
    for path in sorted(glob.glob(os.path.join(RESULTS, "*.json"))):
        with open(path) as f:
            reports.append(json.load(f))
    if not reports:
        sys.exit("no reports in Benchmarks/results")

    # Latest report per (device, model).
    latest = {}
    for report in reports:
        key = (report["environment"]["device"], report["environment"]["buildConfiguration"], report["modelID"])
        if key not in latest or report["startedAt"] > latest[key]["startedAt"]:
            latest[key] = report

    lines = []
    lines.append("# Benchmarks")
    lines.append("")
    lines.append("Measured with the shared harness in `Source/TTSBenchmark.swift` (`Tools/bench.sh`). "
                 "Every number comes from this repository's own runs; nothing here is an upstream claim.")
    lines.append("")
    lines.append("Definitions: **first audio** is the wall time from the synthesize call to the first "
                 "non-padding buffer with the model already loaded; **RTF** is seconds of audio per wall "
                 "second for the whole request (above 1 means faster than playback); **stalls** count the "
                 "moments a player that started at first audio would have run dry, and **pre-roll** the seconds "
                 "of audio it would have had to buffer before starting to avoid every stall; **MLX peak** is the "
                 "runtime's active-memory high-water mark during the trial and **resident** the process's "
                 "physical footprint afterwards. `narration` is `synthesizeLong` (the chunked article "
                 "path); `stream` is `synthesizeStream`, one take through the model's own streaming path "
                 "with a short interval. Medians over the warm trials; the cold trial is excluded.")
    lines.append("")
    lines.append("Fixtures: `sentence` (12 words), `paragraph` (51 words), `longForm` (275 words, six paragraphs).")
    lines.append("")

    groups = {}
    for (device, build, model), report in latest.items():
        groups.setdefault((device, build), []).append(report)

    for (device, build), group in sorted(groups.items(), key=lambda item: (item[0][1] != "release", item[0][0])):
        env = group[0]["environment"]
        lines.append(f"## {device_label(env)} — {os_label(env)}, {build} build, {round(env['physicalMemoryMB'] / 1024)} GB")
        lines.append("")
        lines.append("| Model | Revision | Size | Cold: load / first audio | Warm load | Resident after load | "
                     "sentence/stream first audio | paragraph/narration first audio | paragraph RTF | "
                     "longForm RTF | longForm stalls | longForm pre-roll | MLX peak | Resident peak | CPU | Thermal |")
        lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for report in sorted(group, key=lambda r: r["modelID"]):
            trials = report["trials"]
            load = report.get("load") or {}
            s_stream = summary(trials, "sentence", "stream")
            p_narr = summary(trials, "paragraph", "narration")
            l_narr = summary(trials, "longForm", "narration")
            all_warm = [t for t in trials if not t["includesLoad"]] or trials
            mlx_peak = max((t["mlxPeakMB"] for t in all_warm), default=None)
            resident = max((t["residentMB"] for t in all_warm), default=None)
            cpu = median([t["cpuUtilization"] for t in all_warm])
            thermal = "/".join(sorted({t["thermalState"] for t in all_warm}))
            lines.append("| {model} | `{rev}` | {size} MB | {cold} / {coldfa} | {warm} | {resl} | {sfa} | {pfa} | {prtf} | {lrtf} | {stalls} | {preroll} | {peak} | {res} | {cpu} | {thermal} |".format(
                model=report["modelID"].split("/")[-1],
                rev=(report.get("modelRevision") or "?")[:8],
                size=report["modelSizeMB"],
                cold=fmt(load.get("coldLoadSeconds"), "s"),
                coldfa=fmt(load.get("coldFirstAudioSeconds"), "s"),
                warm=fmt(load.get("warmLoadSeconds"), "s"),
                resl=fmt(load.get("residentAfterLoadMB"), " MB", 0),
                sfa=fmt(s_stream and s_stream["firstAudio"], "s"),
                pfa=fmt(p_narr and p_narr["firstAudio"], "s"),
                prtf=fmt(p_narr and p_narr["rtf"], "x"),
                lrtf=fmt(l_narr and l_narr["rtf"], "x"),
                stalls="–" if l_narr is None else f"{l_narr['stalls']} ({l_narr['overruns']} overruns)",
                preroll=fmt(l_narr and l_narr["preroll"], "s", 1),
                peak=fmt(mlx_peak, " MB", 0),
                res=fmt(resident, " MB", 0),
                cpu=fmt(cpu, "", 2),
                thermal=thermal or "–",
            ))
        lines.append("")
        notes = [(r["modelID"].split("/")[-1], n) for r in group for n in r.get("notes", [])]
        if notes:
            for model, note in notes:
                lines.append(f"- {model}: {note}")
            lines.append("")

    findings = os.path.join(ROOT, "Benchmarks", "findings.md")
    if os.path.exists(findings):
        with open(findings) as f:
            lines.append(f.read().rstrip("\n"))
        lines.append("")

    lines.append("## Per-trial detail")
    lines.append("")
    lines.append("Raw reports with every trial live in `Benchmarks/results/*.json`. The paragraph clip of every "
                 "run is in `Benchmarks/samples/<device>/<model>.m4a` (AAC, `Tools/bench-samples.sh`); the full "
                 "float32 WAVs stay local in `Benchmarks/results/audio/`.")
    lines.append("")

    text = "\n".join(lines) + "\n"
    if "--stdout" in sys.argv:
        sys.stdout.write(text)
    else:
        with open(OUT, "w") as f:
            f.write(text)
        print(f"wrote {OUT} ({len(latest)} reports)")


if __name__ == "__main__":
    main()
