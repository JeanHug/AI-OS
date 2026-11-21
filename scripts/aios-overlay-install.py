#!/usr/bin/env python3
"""Installe la surcouche AI OS dans la page noVNC (idempotent, sans doublon)."""
import re

js = open("/usr/share/novnc/aios-overlay.js").read()
p = "/usr/share/novnc/vnc.html"
h = open(p).read()
h = re.sub(r"<!--aios-overlay-->.*?<!--/aios-overlay-->", "", h, flags=re.S)
h = h.replace("<script src=aios-overlay.js></script>", "")
h = h.replace(
    "</body>",
    "<!--aios-overlay-->\n<script type=\"module\">import UI from \"./app/ui.js\";"
    " import { clientToElement } from \"./core/util/element.js\";"
    " window.__aiosUI = UI; window.__aiosC2E = clientToElement;</script>\n<script>\n"
    + js + "\n</script>\n<!--/aios-overlay-->\n</body>",
)
open(p, "w").write(h)
print("surcouche injectée dans", p)
