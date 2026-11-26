"""Rebuild the bundled Mac illustrations from receiver-models.svg on macOS.

Run python3 artwork/export-receiver-models.py from any working directory.
The mobile builds use the checked-in PNGs and do not require this exporter.
"""
import copy
import json
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "artwork/receiver-models.svg"
SVG = "http://www.w3.org/2000/svg"
XLINK = "http://www.w3.org/1999/xlink"
ET.register_namespace("", SVG)
ET.register_namespace("xlink", XLINK)


def tag(name):
    return f"{{{SVG}}}{name}"


def artwork(node, definitions, inherited):
    # Flatten shared geometry and its local palette for native SVG renderers.
    # Core Graphics and web engines differ in their handling of nested symbols.
    palette = inherited.copy()
    for item in node.get("style", "").split(";"):
        if item:
            name, value = item.split(":", 1)
            palette[name] = value
    attrs = {key: val for key, val in node.attrib.items()
             if key not in ("id", "style", f"{{{XLINK}}}href")}
    for key, val in attrs.items():
        if val.startswith("var("):
            name, fallback = val[4:-1].split(",", 1)
            attrs[key] = palette.get(name, fallback)
        elif val == "currentColor":
            attrs[key] = palette.get("color", "#152826")
    if node.tag == tag("use"):
        reference = node.attrib[f"{{{XLINK}}}href"][1:]
        result = ET.Element(tag("g"), attrs)
        result.append(artwork(definitions[reference], definitions, palette))
        return result
    result = ET.Element(node.tag, attrs)
    for child in node:
        result.append(artwork(child, definitions, palette))
    return result


def standalone(symbol, library):
    image = ET.Element(tag("svg"), {"viewBox": symbol.attrib["viewBox"], "width": "384", "height": "240"})
    defs = ET.SubElement(image, tag("defs"))
    source_defs = library.find(tag("defs"))
    for asset in source_defs:
        if asset.tag != tag("g"):
            defs.append(copy.deepcopy(asset))
    definitions = {node.get("id"): node for node in source_defs if node.get("id")}
    for element in symbol:
        image.append(artwork(element, definitions, {}))
    return ET.tostring(image, encoding="utf-8")


def update_prototype():
    path = ROOT / "docs/design/mobile-glass/prototype.html"
    start = "<!-- receiver-art:start -->"
    end = "<!-- receiver-art:end -->"
    html = path.read_text()
    lib = SOURCE.read_text().replace('<svg ', '<svg aria-hidden="true" style="position:absolute;width:0;height:0;overflow:hidden" ', 1)
    before, remaining = html.split(start, 1)
    _, after = remaining.split(end, 1)
    path.write_text(before + start + "\n" + lib + end + after)


def main():
    library = ET.parse(SOURCE).getroot()
    android = ROOT / "android/app/src/main/res/drawable-nodpi"
    harmony = ROOT / "harmonyos/entry/src/main/resources/base/media"
    ios = ROOT / "ios/ShotSync/Assets.xcassets"
    harmony.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temp:
        for symbol in library.findall(tag("symbol")):
            name = "receiver_" + symbol.get("id").removeprefix("rm-").replace("-", "_")
            svg = Path(temp) / (name + ".svg")
            png = svg.with_suffix(".png")
            svg.write_bytes(standalone(symbol, library))
            subprocess.run(["sips", "-s", "format", "png", str(svg), "--out", str(png)],
                           check=True, stdout=subprocess.DEVNULL)
            imageset = ios / (name + ".imageset")
            imageset.mkdir(exist_ok=True)
            for destination in [android, harmony, imageset]:
                shutil.copyfile(png, destination / png.name)
            metadata = {"images": [{"filename": png.name, "idiom": "universal"}],
                        "info": {"author": "xcode", "version": 1}}
            (imageset / "Contents.json").write_text(json.dumps(metadata, indent=2) + "\n")
    update_prototype()


if __name__ == "__main__":
    main()
