#!/usr/bin/env python3
"""Generates docs/commands.md from the `{.cmd.}` declarations, so the command
reference can never drift from the code. Run: python3 tools/gen_api.py"""
import re, sys, pathlib
root = pathlib.Path(__file__).resolve().parent.parent
files = ["commands", "extras", "streams", "scripting"]
out = ["# Command reference\n",
       "_Generated from the `{.cmd.}` declarations in `src/redwater/` by `tools/gen_api.py` - do not edit by hand._\n",
       "Every command below exists in **four forms** with the same arguments:\n",
       "| form | call | what it does |", "|---|---|---|",
       "| connection | `c.get(\"k\")` | `{.flow.}` proc: sends, waits for the reply, returns the typed result |",
       "| batch | `p.get(\"k\")` | queues the command, returns the index of its reply in `p.exec()` |",
       "| pool | `pool.get(\"k\")` | runs on the pool's next shared connection, retried when safe |",
       "| cluster | `cl.get(\"k\")` | routed to the master owning the key's slot; MOVED/ASK followed (except per-node commands: dbsize, flushdb, flushall, keys, scan, randomkey, select, watch) |\n",
       "Optional arguments are shown with their defaults; `noArg` means \"not sent\". A boolean option sends just its keyword (`nx = true` sends `NX`).\n"]
total = 0
for f in files:
    src = (root / "src/redwater" / f"{f}.nim").read_text().split("\n")
    i = 0
    section = None
    rows = []
    def flush():
        global total
        if rows:
            out.append(f"\n## {section or f}\n")
            out.append("| signature | returns | sends | description |")
            out.append("|---|---|---|---|")
            for r in rows: out.append(r)
            total += len(rows)
        rows.clear()
    while i < len(src):
        line = src[i]
        m = re.match(r"# ={10,}", line)
        if m and i + 1 < len(src) and src[i+1].startswith("# ") and not src[i+1].startswith("# ="):
            flush(); section = src[i+1][2:].strip().capitalize(); i += 2; continue
        m = re.match(r"# -{3,} ?(.*?) -{3,}", line) or re.match(r"# ---- (.*?) -+", line)
        if m: flush(); section = m.group(1).strip().capitalize()
        if re.match(r"proc \w+\*\(", line) and "{.cmd:" in "\n".join(src[i:i+4]):
            j = i; text = ""
            while True:
                text += src[j].strip() + " "
                if src[j].rstrip().endswith("="): break
                j += 1
            sm = re.match(r"proc (\w+)\*\((.*)\)(?:: (.*?))? \{\.cmd: \"(.*?)\"\.\} =", text.strip())
            if sm:
                name, params, ret, spec = sm.groups()
                params = params.replace(";", ",").replace("  ", " ")
                doc = []
                k = j + 1
                while k < len(src) and src[k].strip().startswith("##"):
                    doc.append(src[k].strip()[2:].strip()); k += 1
                words = [w for w in spec.split() if w[0] not in "+@#%$"]
                sends = "`" + " ".join(words) + "`"
                rows.append(f"| `{name}({params})` | `{ret or 'void'}` | {sends} | {' '.join(doc).replace('|','\\|')} |")
                i = k; continue
        i += 1
    flush()
out.append(f"\n---\n{total} commands, each in up to four forms.\n")
(root / "docs/commands.md").write_text("\n".join(out))
print("wrote docs/commands.md:", total, "commands")
