#!/usr/bin/env python3
"""Writes tools/devcheck/checkmod/removed-keys.lua: every prototype key that Factorio removed between two versions
(issue #487, the port to 2.1), from the API definitions of both (`prototype-api.json`).

Factorio 2.1 refuses a few removed keys with an error (a recipe's `category`, a product's `probability`, an item's
`fuel_category`, a fluid box's temperatures) and ignores the others when it loads prototypes, so those fail silently (a
crafting machine's `forced_symmetry`, a graphics set's `circuit_connector_layer`, a fluid box's `hide_connection_info`,
a generator's `horizontal_animation`, ...). checkmod/data-final-fixes.lua walks data.raw with this table and devcheck
fails for every key it finds.

The table has, per prototype type (`recipe`, `item`, ...), the keys removed from its class or a parent class, and the
fields that lead to nested types with removed keys (a recipe's `results` -> ItemProductPrototype's `probability`, a
machine's `fluid_boxes` -> FluidBox's `minimum_temperature`, ...), resolved through arrays, unions and aliases.

    python tools/devcheck/removed_keys.py                         # 2.0.77 -> the installed version (its doc-html)
    python tools/devcheck/removed_keys.py --old 2.0.77 --new 2.1.23
    python tools/devcheck/removed_keys.py --new-json path/to/prototype-api.json

A version's JSON is downloaded from https://lua-api.factorio.com/<version>/prototype-api.json; `--new` without a
version takes the doc-html of the Factorio of .devcheck/factorio (or of the Steam install).
"""
import argparse, json, sys, urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "checkmod" / "removed-keys.lua"


def load(version=None, path=None):
    if path:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    url = f"https://lua-api.factorio.com/{version}/prototype-api.json"
    req = urllib.request.Request(url, headers={"User-Agent": "me-network-devcheck/1.0"})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read().decode("utf-8"))


def installed_json():
    for d in (HERE.parents[1] / ".devcheck" / "factorio",):
        p = d / "doc-html" / "prototype-api.json"
        if p.exists():
            return p
        data = d / "data"
        if data.exists():       # (a copied bin/ with a linked data/: the doc-html is next to the linked data)
            p = data.resolve().parent / "doc-html" / "prototype-api.json"
            if p.exists():
                return p
    return None


class Api:
    def __init__(self, api):
        self.version = api["application_version"]
        self.items = {x["name"]: x for x in api["prototypes"] + api["types"]}
        self.typenames = {x["typename"]: x["name"] for x in api["prototypes"] if x.get("typename")}
        self._full = {}

    def props(self, name):
        """the properties of a struct with its parents' (name -> type expression)"""
        if name in self._full:
            return self._full[name]
        x = self.items.get(name)
        out = {}
        if x:
            if x.get("parent"):
                out.update(self.props(x["parent"]))
            for p in x.get("properties") or []:
                out[p["name"]] = p["type"]
        self._full[name] = out
        return out

    def is_struct(self, name):
        x = self.items.get(name)
        return x is not None and (x.get("properties") is not None or "typename" in x
                                  or (isinstance(x.get("type"), dict) and x["type"].get("complex_type") == "struct"))

    def refs(self, expr, seen=None):
        """the named types a type expression stands for (arrays, unions, aliases, dictionaries' values: their elements)"""
        seen = set() if seen is None else seen
        if isinstance(expr, str):
            x = self.items.get(expr)
            if x is None:
                return set()
            if self.is_struct(expr):
                return {expr}
            if expr in seen:                    # (a recursive alias, e.g. a trigger that holds triggers)
                return set()
            seen.add(expr)
            return self.refs(x.get("type"), seen)     # an alias or a union type
        if not isinstance(expr, dict):
            return set()
        ct = expr.get("complex_type")
        if ct in ("array", "type", "dictionary"):
            return self.refs(expr["value"], seen)
        out = set()
        for o in expr.get("options", []) if ct == "union" else expr.get("values", []) if ct == "tuple" else []:
            out |= self.refs(o, seen)
        return out


def build(old, new):
    removed = {}
    for name in old.items:
        if name not in new.items or not old.is_struct(name):
            continue
        gone = sorted(set(old.props(name)) - set(new.props(name)))
        if gone:
            removed[name] = gone
    # the structs of the new version that lead to removed keys (fixpoint over their fields)
    structs = [n for n in new.items if new.is_struct(n)]
    fields = {n: {k: new.refs(t) for k, t in new.props(n).items()} for n in structs}
    relevant = set(removed)
    changed = True
    while changed:
        changed = False
        for n in structs:
            if n in relevant:
                continue
            if any(refs & relevant for refs in fields[n].values()):
                relevant.add(n)
                changed = True
    nodes = {}
    for n in sorted(relevant):
        f = {k: sorted(refs & relevant) for k, refs in fields.get(n, {}).items() if refs & relevant}
        t = new.props(n).get("type")      # a union's option is told apart by its `type` (a trigger, a product, ...)
        tag = t.get("value") if isinstance(t, dict) and t.get("complex_type") == "literal" else None
        nodes[n] = {"removed": [k for k in removed.get(n, []) if k not in new.props(n)], "fields": f, "tag": tag}
    protos = {t: c for t, c in sorted(new.typenames.items()) if c in relevant}
    return removed, nodes, protos


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write(old, new, nodes, protos):
    lines = [
        f"--- Generated by tools/devcheck/removed_keys.py from the prototype API of {old.version} and {new.version}: do not edit.",
        "--- nodes[<type>] = { removed = { key = true }, fields = { key = { <nested type>, ... } }, tag = <its `type`, if fixed> };",
        "--- prototypes[<data.raw type>] = <type>",
        "return {",
        f"\told = {lua_str(old.version)}, new = {lua_str(new.version)},",
        "\tnodes = {",
    ]
    for n, spec in nodes.items():
        rem = ", ".join(f"[{lua_str(k)}] = true" for k in spec["removed"])
        fl = ", ".join(f"[{lua_str(k)}] = {{ {', '.join(lua_str(x) for x in v)} }}" for k, v in sorted(spec["fields"].items()))
        tag = f", tag = {lua_str(spec['tag'])}" if spec["tag"] else ""
        lines.append(f"\t\t[{lua_str(n)}] = {{ removed = {{ {rem} }}, fields = {{ {fl} }}{tag} }},")
    lines.append("\t},")
    lines.append("\tprototypes = {")
    for t, c in protos.items():
        lines.append(f"\t\t[{lua_str(t)}] = {lua_str(c)},")
    lines.append("\t},")
    lines.append("}")
    OUT.write_bytes(("\n".join(lines) + "\n").encode("utf-8"))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--old", default="2.0.77", help="the version ported from (default 2.0.77)")
    ap.add_argument("--new", help="the version ported to (default: the doc-html of the installed Factorio)")
    ap.add_argument("--old-json", help="prototype-api.json of the old version instead of downloading it")
    ap.add_argument("--new-json", help="prototype-api.json of the new version")
    a = ap.parse_args()
    new_path = a.new_json or (None if a.new else installed_json())
    if not new_path and not a.new:
        sys.exit("no installed doc-html/prototype-api.json found: pass --new <version> or --new-json <file>")
    old = Api(load(a.old, a.old_json))
    new = Api(load(a.new, new_path))
    removed, nodes, protos = build(old, new)
    write(old, new, nodes, protos)
    print(f"{OUT.relative_to(HERE.parents[1])}: {old.version} -> {new.version}, {sum(len(v) for v in removed.values())} "
          f"removed keys in {len(removed)} types, {len(nodes)} types to walk, {len(protos)} prototype types")
    for n, keys in sorted(removed.items()):
        print(f"  {n}: {', '.join(keys)}")


if __name__ == "__main__":
    main()
