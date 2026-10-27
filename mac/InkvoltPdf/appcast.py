#!/usr/bin/env python3
"""Adds one release to Inkvolt PDF's Sparkle appcast (release.sh --appcast runs it).

    python3 appcast.py <appcast.xml> --version 1.0 --url <dmg url> --length <bytes> --signature <edSignature>
                       --notes <file.md|file.html|file.txt> [--minimum-system 15.0]

Creates the appcast if it doesn't exist; an item with the same version is replaced, the new one goes first. The notes are
embedded in the item: Markdown (.md, Sparkle 2.9+), HTML (.html) or plain text (anything else).
"""
import argparse
import email.utils
import os
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", DC)


def s(name):
    return "{%s}%s" % (SPARKLE, name)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("appcast")
    p.add_argument("--version", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--length", required=True, type=int)
    p.add_argument("--signature", required=True)
    p.add_argument("--notes", required=True)
    p.add_argument("--minimum-system", default="15.0")
    a = p.parse_args()

    if os.path.exists(a.appcast):
        tree = ET.parse(a.appcast)
        rss = tree.getroot()
        channel = rss.find("channel")
    else:
        rss = ET.Element("rss", {"version": "2.0"})
        tree = ET.ElementTree(rss)
        channel = ET.SubElement(rss, "channel")
        ET.SubElement(channel, "title").text = "Inkvolt PDF"
        ET.SubElement(channel, "link").text = "https://github.com/gabandres/inkvolt"
        ET.SubElement(channel, "description").text = "Inkvolt PDF for macOS updates"
        ET.SubElement(channel, "language").text = "en"

    for old in channel.findall("item"):
        if old.findtext(s("version")) == a.version:
            channel.remove(old)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = "Inkvolt PDF %s" % a.version
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    ET.SubElement(item, s("version")).text = a.version
    ET.SubElement(item, s("shortVersionString")).text = a.version
    ET.SubElement(item, s("minimumSystemVersion")).text = a.minimum_system
    with open(a.notes, encoding="utf-8") as f:
        notes = f.read().strip()
    ext = os.path.splitext(a.notes)[1].lower()
    fmt = {".md": "markdown", ".html": None, ".htm": None}.get(ext, "plain-text")
    description = ET.SubElement(item, "description", {s("format"): fmt} if fmt else {})
    description.text = notes
    ET.SubElement(item, "enclosure", {
        "url": a.url,
        "length": str(a.length),
        "type": "application/octet-stream",
        s("edSignature"): a.signature,
    })

    first = next((i for i, e in enumerate(channel) if e.tag == "item"), len(channel))
    channel.insert(first, item)
    ET.indent(tree, space="  ")
    tmp = a.appcast + ".tmp"
    tree.write(tmp, encoding="utf-8", xml_declaration=True)
    os.replace(tmp, a.appcast)


if __name__ == "__main__":
    main()
