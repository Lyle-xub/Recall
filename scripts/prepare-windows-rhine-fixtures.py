"""Expand an existing synthetic visual-parity fixture to five 48-record days.

Usage: python prepare-windows-rhine-fixtures.py SOURCE_FIXTURES OUTPUT_SESSION
Only synthetic parity-* fixtures are accepted; existing recordings are not read.
"""
from pathlib import Path
import datetime
import json
import shutil
import sys

source = Path(sys.argv[1]).resolve()
destination = Path(sys.argv[2]).resolve() / "fixtures"
if source == destination:
    raise ValueError("Use a separate output session")
manifest = json.loads((source / "fixture.json").read_text(encoding="utf-8-sig"))
original = manifest["frames"]
if not original or any(not f["id"].startswith("parity-") for f in original):
    raise ValueError("Only synthetic parity fixtures are accepted")
(destination / "frames").mkdir(parents=True, exist_ok=True)
frames = []
for lane in range(5):
    group = [f for f in original if f["id"].startswith(f"parity-{lane}-")]
    if not group:
        raise ValueError(f"Missing synthetic lane {lane}")
    anchor = max(datetime.datetime.fromisoformat(f["timestamp"].replace("Z", "+00:00")) for f in group)
    for row in range(48):
        template = group[row % len(group)]
        frame = dict(template)
        # Synthetic scenes use real application labels so the app filter is
        # not mistaken for a topic/category menu during visual acceptance.
        sample_apps = {"Research": ("File Explorer", "explorer"), "Notes": ("Notepad", "notepad"), "Design": ("Recall", "Recall")}
        if frame.get("appName") in sample_apps:
            frame["appName"], frame["processName"] = sample_apps[frame["appName"]]
        frame["id"] = f"parity-{lane}-{row}"
        frame["imagePath"] = "frames/" + frame["id"] + ".png"
        frame["timestamp"] = (anchor - datetime.timedelta(minutes=7 * row)).isoformat()
        image = (source / template["imagePath"]).resolve()
        if not image.is_relative_to(source):
            raise ValueError("Fixture image must remain within the source directory")
        shutil.copy2(image, destination / frame["imagePath"])
        frames.append(frame)
manifest["frames"] = frames
(destination / "fixture.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
print("Prepared 240 synthetic records: five days, 48 records per column.")
