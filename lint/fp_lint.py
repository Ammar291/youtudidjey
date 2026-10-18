"""Static checks for the generated solution.py (embedded in yuotudidjey; run as `python -I - FILE`).

Functional style: no while loops, no global/nonlocal, no in-place mutation, only immutable classes,
and real use of lambdas, map/filter, functools.reduce and itertools.
Safety: no LLM, network or UI-automation libraries; every subprocess goes through YUO_B4 (blindly4).
Prints {"ok": bool, "violations": [{"line": n, "rule": text}]}.
"""
import ast
import json
import sys

MUTATORS = {"append", "extend", "insert", "pop", "remove", "clear", "update", "setdefault", "popitem",
            "add", "discard", "sort", "reverse"}
BANNED_MODULES = {"anthropic", "openai", "requests", "urllib", "http", "socket", "httpx", "aiohttp", "ctypes",
                  "comtypes", "pywinauto", "uiautomation", "win32api", "win32gui", "win32con", "selenium",
                  "playwright", "webbrowser"}
BANNED_TEXT = ("claude", "codex", "blindly4.exe")
SPAWNERS = {"run", "Popen", "call", "check_call", "check_output", "getoutput", "getstatusoutput"}
IMMUTABLE_BASES = {"NamedTuple", "Enum", "IntEnum", "StrEnum", "Exception", "ValueError", "RuntimeError"}


def name_of(node):
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return node.attr
    return None


def frozen_dataclass(decorator):
    return (isinstance(decorator, ast.Call) and name_of(decorator.func) == "dataclass"
            and any(k.arg == "frozen" and isinstance(k.value, ast.Constant) and k.value.value is True
                    for k in decorator.keywords))


def mentions_yuo_b4(node):
    return any(isinstance(n, ast.Constant) and n.value == "YUO_B4" for n in ast.walk(node))


def lint(source):
    tree = ast.parse(source)
    found = []

    def bad(node, rule):
        found.append({"line": getattr(node, "lineno", 0), "rule": rule})

    b4_names = {t.id for n in ast.walk(tree) if isinstance(n, ast.Assign) and mentions_yuo_b4(n.value)
                for t in n.targets if isinstance(t, ast.Name)}
    lambdas = 0
    uses = set()
    for n in ast.walk(tree):
        if isinstance(n, ast.While):
            bad(n, "while loop: iterate lazily with itertools instead")
        elif isinstance(n, (ast.Global, ast.Nonlocal)):
            bad(n, "global/nonlocal: pass values instead of rebinding shared names")
        elif isinstance(n, ast.AugAssign):
            bad(n, "augmented assignment (+= etc.) mutates a binding; build a new value")
        elif isinstance(n, ast.Delete):
            bad(n, "del mutates; build a new value")
        elif isinstance(n, (ast.Assign, ast.AnnAssign)):
            targets = n.targets if isinstance(n, ast.Assign) else [n.target]
            if any(isinstance(t, (ast.Subscript, ast.Attribute)) for t in targets):
                bad(n, "item/attribute assignment mutates; build a new value")
        elif isinstance(n, ast.ClassDef):
            bases = {name_of(b) for b in n.bases}
            if not (any(frozen_dataclass(d) for d in n.decorator_list) or bases & IMMUTABLE_BASES):
                bad(n, f"class {n.name} must be a frozen dataclass, NamedTuple or Enum")
        elif isinstance(n, ast.Lambda):
            lambdas += 1
        elif isinstance(n, (ast.Import, ast.ImportFrom)):
            modules = [a.name for a in n.names] if isinstance(n, ast.Import) else [n.module or ""]
            for m in modules:
                top = m.split(".")[0]
                uses.add(top)
                if top in BANNED_MODULES:
                    bad(n, f"import {m}: no LLM, network or UI-automation libraries (only blindly4 via YUO_B4)")
        elif isinstance(n, ast.Constant) and isinstance(n.value, str):
            lowered = n.value.lower()
            for word in BANNED_TEXT:
                if word in lowered:
                    bad(n, f"string mentions {word}: no LLM CLIs and no direct blindly4 path")
        elif isinstance(n, ast.Call):
            callee = name_of(n.func)
            owner = name_of(n.func.value) if isinstance(n.func, ast.Attribute) else None
            if isinstance(n.func, ast.Attribute) and callee in MUTATORS:
                bad(n, f"mutating call .{callee}(): build a new value")
            if callee in ("map", "filter"):
                uses.add("map/filter")
            if callee == "reduce":
                uses.add("reduce")
            if owner == "os" and (callee == "system" or callee in ("popen",) or (callee or "").startswith(("spawn", "exec"))):
                bad(n, f"os.{callee}: processes only through YUO_B4")
            if owner == "subprocess" and callee in SPAWNERS:
                command = n.args[0] if n.args else next((k.value for k in n.keywords if k.arg == "args"), None)
                refs = {x.id for x in ast.walk(command) if isinstance(x, ast.Name)} if command is not None else set()
                if not (refs & b4_names):
                    bad(n, "subprocess call not built from YUO_B4: every UI action must go through blindly4")
    if lambdas < 5:
        found.append({"line": 0, "rule": f"only {lambdas} lambdas: use lambdas for small transformations (at least 5)"})
    for need, why in (("functools", "import functools"), ("itertools", "import itertools"),
                      ("map/filter", "call map( or filter("), ("reduce", "call functools.reduce(")):
        if need not in uses:
            found.append({"line": 0, "rule": f"functional style: {why}"})
    return found


def main(path):
    with open(path, encoding="utf-8") as handle:
        source = handle.read()
    try:
        compile(source, path, "exec")
        violations = lint(source)
    except SyntaxError as e:
        violations = [{"line": e.lineno or 0, "rule": f"syntax error: {e.msg}"}]
    print(json.dumps({"ok": not violations, "violations": violations}))


main(sys.argv[1])
