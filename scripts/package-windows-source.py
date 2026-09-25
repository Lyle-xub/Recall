#!/usr/bin/env python3
"""Bundle the Windows build inputs, not an unvalidated executable release."""
from pathlib import Path
import hashlib
import zipfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "release" / "Recall-Windows-source.zip"
files: set[Path] = set()

for folder in ("Recall.WinUI", "Recall.Ocr", "Rewind.Tests", "Installer"):
    for path in (ROOT / "Windows" / folder).rglob("*"):
        if path.is_file() and not {"bin", "obj", "TestResults"}.intersection(path.parts) and path.name != ".DS_Store":
            files.add(path)

# Include only the shared C# services actually compiled by these projects.
for project in ("Recall.WinUI/Recall.WinUI.csproj", "Rewind.Tests/Rewind.Tests.csproj"):
    path = ROOT / "Windows" / project
    for node in ET.parse(path).iter("Compile"):
        for name in node.attrib.get("Include", "").split(";"):
            if name:
                files.add((path.parent / name).resolve())

for relative in (
    "Windows/.editorconfig", "Windows/README.md", "Windows/Rewind/app.manifest",
    "scripts/build-windows.ps1", "scripts/prepare-windows.ps1",
    "scripts/test-windows-smoke.ps1", "scripts/prepare-native-runtimes.py",
    "scripts/package-windows-source.py", "scripts/ocr-models.json",
    "scripts/neural-ocr/sources.json", "docs/windows-parity-plan.md",
    "docs/windows-0.4.25-validation.md", "docs/local-models.md",
):
    files.add(ROOT / relative)
for folder in ("shared/models", "shared/licenses"):
    files.update(p for p in (ROOT / folder).rglob("*") if p.is_file() and p.name != ".DS_Store")

OUTPUT.parent.mkdir(exist_ok=True)
hashes = []
with zipfile.ZipFile(OUTPUT, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path in sorted(files):
        name = path.relative_to(ROOT).as_posix()
        data = path.read_bytes()
        archive.writestr("Recall-Windows/" + name, data)
        hashes.append(hashlib.sha256(data).hexdigest() + "  " + name)
    readme = (ROOT / "Windows/README.md").read_text().replace("(../docs/", "(docs/")
    archive.writestr("Recall-Windows/README.md", readme)
    hashes.append(hashlib.sha256(readme.encode()).hexdigest() + "  README.md")
    archive.writestr("Recall-Windows/MANIFEST.sha256", "\n".join(hashes) + "\n")
with zipfile.ZipFile(OUTPUT) as archive:
    assert archive.testzip() is None
    assert not any("/bin/" in n or "/obj/" in n or "/DemoData.cs" in n for n in archive.namelist())
digest = hashlib.sha256(OUTPUT.read_bytes()).hexdigest()
OUTPUT.with_suffix(".sha256").write_text(digest + "  " + OUTPUT.name + "\n")
print(f"Windows source bundle: {len(files) + 2} files, {OUTPUT.stat().st_size / 1e6:.2f} MB")
print(OUTPUT)
print("SHA256:", digest)
