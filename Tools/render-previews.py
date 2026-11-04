#!/usr/bin/env python3
"""Render Docs/previews from a TTSMLXPreviews output directory.

    python3 Tools/render-previews.py <generator-output-dir>

Encodes every WAV to MP3 (ffmpeg; AAC .m4a via afconvert as fallback) under Docs/previews/audio, writes
Docs/previews/index.html (a page with one player per clip; open it through
GitHub Pages or https://htmlpreview.github.io) and Docs/model-previews.md (the
same information as a Markdown table with raw links GitHub can open), and
refreshes the block between the PREVIEWS markers in README.md.
"""
import html
import json
import pathlib
import shutil
import subprocess
import sys

REPO = "fil-technology/TTSMLX"
RAW = f"https://raw.githubusercontent.com/{REPO}/main/Docs/previews/audio"
PAGE = f"https://{REPO.split('/')[0]}.github.io/{REPO.split('/')[1]}/"

src = pathlib.Path(sys.argv[1])
root = pathlib.Path(__file__).resolve().parent.parent
out = root / "Docs" / "previews"
audio = out / "audio"
audio.mkdir(parents=True, exist_ok=True)

manifest = json.loads((src / "manifest.json").read_text())

STAGE = {"validated": "✅ validated", "implemented": "🧪 implemented", "planned": "📋 discovery-only"}


def encode(wav: pathlib.Path) -> str:
    """WAV -> MP3 (mono VBR ~100 kbps) with ffmpeg; AAC .m4a via afconvert when ffmpeg is absent."""
    if shutil.which("ffmpeg"):
        mp3 = audio / (wav.stem + ".mp3")
        if not mp3.exists() or mp3.stat().st_mtime < wav.stat().st_mtime:
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(wav), "-ac", "1", "-codec:a", "libmp3lame", "-q:a", "5", str(mp3)], check=True)
        return mp3.name
    m4a = audio / (wav.stem + ".m4a")
    if not m4a.exists() or m4a.stat().st_mtime < wav.stat().st_mtime:
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-s", "3", "-u", "vbrq", "64", str(wav), str(m4a)], check=True)
    return m4a.name


def features(e):
    f = []
    if e.get("supportsReferenceAudio"):
        f.append("reference-audio cloning")
    if e.get("supportsStreaming", True) and e.get("voices") is not None:
        f.append("streaming")
    if len(e.get("languages", [])) > 1:
        f.append(f"{len(e['languages'])} languages")
    notes = e.get("runtimeNotes", "")
    if "[laugh]" in notes or "event tags" in notes or "`[laughter]`" in notes:
        f.append("inline event tags")
    if "instruction" in notes.lower() or "style" in notes.lower():
        f.append("style instructions")
    return f


rows_md, cards = [], []
for e in manifest:
    clips = [c for c in e.get("clips", []) if "file" in c and (src / c["file"]).exists()]
    stage = STAGE.get(e["supportStage"], e["supportStage"])
    langs = ", ".join(e.get("languages", [])) or "—"
    voices = e.get("voices")
    voices_s = (", ".join(voices[:8]) + (f", … ({len(voices)} total)" if len(voices) > 8 else "")) if voices else ("— (discovery-only)" if voices is None else "default")
    feats = ", ".join(features(e)) or "—"
    mem = f'{e["peakMemoryMB"]} MB' if e.get("peakMemoryMB") else "—"
    links = []
    players = []
    for c in clips:
        name = encode(src / c["file"])
        title = c["label"] + (f' · {c["language"]}' if c.get("language") else "")
        links.append(f'[{title}]({RAW}/{name})')
        players.append(
            f'<div class="clip"><div class="meta">{html.escape(title)}'
            f'<span>{c.get("seconds", 0):.1f}s</span></div>'
            f'<audio controls preload="none" src="audio/{html.escape(name)}"></audio>'
            f'<p class="text">{html.escape(c["text"])}</p></div>'
        )
    clip_md = " · ".join(links) if links else "_no clip yet_"
    rows_md.append(f'| [{e["displayName"]}]({e["modelURL"]}) | {stage} | {langs} | {voices_s} | {feats} | {mem} | {clip_md} |')
    cards.append(
        f'<section class="model"><h2>{html.escape(e["displayName"])} <small>{html.escape(stage)}</small></h2>'
        f'<p class="id"><a href="{html.escape(e["modelURL"])}">{html.escape(e["id"])}</a></p>'
        f'<p>{html.escape(e["summary"])}</p>'
        f'<dl><dt>Languages</dt><dd>{html.escape(langs)}</dd><dt>Voices</dt><dd>{html.escape(voices_s)}</dd>'
        f'<dt>Features</dt><dd>{html.escape(feats)}</dd><dt>Peak memory (catalog)</dt><dd>{html.escape(mem)}</dd></dl>'
        + ("".join(players) if players else '<p class="none">No preview clip yet.</p>')
        + "</section>"
    )

page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>TTSMLX model previews</title>
<style>
:root{{--bg:#fff;--fg:#1d1d1f;--muted:#6e6e73;--card:#f5f5f7;--accent:#0a84ff}}
@media (prefers-color-scheme:dark){{:root{{--bg:#111;--fg:#f5f5f7;--muted:#a1a1a6;--card:#1c1c1e}}}}
body{{margin:0;padding:24px 16px;background:var(--bg);color:var(--fg);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;max-width:960px;margin-inline:auto}}
h1{{font-size:28px;margin:0 0 4px}} .lead{{color:var(--muted);margin:0 0 24px}}
.model{{background:var(--card);border-radius:14px;padding:16px 18px;margin:0 0 18px}}
.model h2{{font-size:20px;margin:0}} .model h2 small{{font-size:13px;color:var(--muted);margin-left:8px;font-weight:500}}
.id{{margin:2px 0 8px;font-size:13px}} .id a{{color:var(--accent);text-decoration:none}}
dl{{display:grid;grid-template-columns:max-content 1fr;gap:2px 14px;font-size:14px;margin:8px 0 12px}} dt{{color:var(--muted)}} dd{{margin:0}}
.clip{{border-top:1px solid rgba(128,128,128,.25);padding:10px 0 4px}} .meta{{display:flex;justify-content:space-between;font-weight:600;font-size:14px}}
.meta span{{color:var(--muted);font-weight:400}} audio{{width:100%;margin:6px 0}} .text{{font-size:13px;color:var(--muted);margin:0}}
.none{{color:var(--muted);font-size:14px}}
</style></head><body>
<h1>TTSMLX model previews</h1>
<p class="lead">One short clip per model and voice, generated on an Apple-silicon Mac with <code>Tools/previews</code> at the catalog's default generation profile. Same sentence everywhere so the voices compare directly. Full support matrix: <code>Docs/model-support.md</code>.</p>
{''.join(cards)}
</body></html>
"""
(out / "index.html").write_text(page)

md = "\n".join([
    "# Model previews",
    "",
    f"Playable page (same clips, inline players): [{PAGE}]({PAGE})",
    "",
    "Clips are mono MP3 files under `Docs/previews/audio`, generated with `Tools/previews` + `Tools/render-previews.py` on an Apple-silicon Mac at each model's default generation profile. Each link opens in the browser's native player. Languages, voices and features come straight from the catalog in `Source/TTSMLX.swift`.",
    "",
    "| Model | Status | Languages | Voices | Features | Peak memory | Clips |",
    "|---|---|---|---|---|---|---|",
    *rows_md,
    "",
])
(root / "Docs" / "model-previews.md").write_text(md)

readme = root / "README.md"
text = readme.read_text()
start, end = "<!-- PREVIEWS:START -->", "<!-- PREVIEWS:END -->"
block = "\n".join([
    start,
    "Hear every catalogued model before you pick one: [Docs/model-previews.md](Docs/model-previews.md) lists languages, voices, features and a short clip per voice (same sentence for all), and the [playable page](%s) has inline players." % PAGE,
    end,
])
if start in text and end in text:
    text = text[: text.index(start)] + block + text[text.index(end) + len(end):]
    readme.write_text(text)
print(f"rendered {len(manifest)} models, {sum(len([c for c in e.get('clips', []) if 'file' in c]) for e in manifest)} clips -> {out}")
