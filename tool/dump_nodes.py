#!/usr/bin/env python
"""Print uiautomator dump nodes that carry text or content-desc, with bounds."""
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1] if len(sys.argv) > 1 else 'dump.xml'
tree = ET.parse(path)

for node in tree.iter('node'):
    text = (node.get('text') or '').strip()
    desc = (node.get('content-desc') or '').strip()
    if not text and not desc:
        continue
    label = text if text else desc
    cls = (node.get('class') or '').split('.')[-1]
    bounds = node.get('bounds', '')
    clickable = node.get('clickable') == 'true'
    print(f'{cls:14s} click={int(clickable)} {bounds:22s} {label}')
