"""Static checks for the generated solution.py (embedded in yuotudidjey; run as `python -I - FILE`).

Functional style: no while loops, no global/nonlocal, no in-place mutation, only immutable classes,
and real use of lambdas, map/filter, functools.reduce and itertools.
Safety: no LLM, network, process-spawning or UI-automation libraries besides subprocess; every
subprocess call is a direct call whose command is exactly the YUO_B4 prefix followed by arguments.
Prints {"ok": bool, "violations": [{"line": n, "rule": text}]}.
"""
import ast
import json
import sys

MUTATORS = {"append", "extend", "insert", "pop", "remove", "clear", "update", "setdefault", "popitem",
            "add", "discard", "sort", "reverse"}
BANNED_MODULES = {"anthropic", "openai", "requests", "urllib", "urllib3", "http", "socket", "httpx", "aiohttp",
                  "ctypes", "comtypes", "pywinauto", "uiautomation", "win32api", "win32gui", "win32con",
                  "win32process", "selenium", "playwright", "webbrowser", "asyncio", "importlib",
                  "multiprocessing", "ssl", "ftplib", "smtplib", "poplib", "imaplib", "telnetlib", "xmlrpc",
                  "socketserver", "pty", "runpy", "code", "concurrent.futures.process"}
BANNED_BUILTINS = {"__import__", "eval", "exec", "compile", "breakpoint"}
BANNED_TEXT = ("claude", "codex", "blindly4.exe")
SPAWNERS = {"run", "Popen", "call", "check_call", "check_output", "getoutput", "getstatusoutput"}
OS_SPAWNERS = {"system", "popen", "startfile", "posix_spawn", "posix_spawnp"}
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


def aliases(tree):
    """Names bound to the subprocess/os modules, and names bound directly to spawning functions."""
    sub_names = {"subprocess"}
    os_names = {"os"}
    fn_names = set()
    for n in ast.walk(tree):
        if isinstance(n, ast.Import):
            for a in n.names:
                if a.name == "subprocess":
                    sub_names = sub_names | {a.asname or a.name}
                if a.name == "os":
                    os_names = os_names | {a.asname or a.name}
        elif isinstance(n, ast.ImportFrom) and n.module in ("subprocess", "os"):
            spawning = SPAWNERS if n.module == "subprocess" else OS_SPAWNERS
            for a in n.names:
                if a.name in spawning or a.name == "*" or a.name.startswith(("spawn", "exec")):
                    fn_names = fn_names | {a.asname or a.name}
    return sub_names, os_names, fn_names


def is_spawner(node, sub_names, os_names, fn_names):
    """Does this expression denote a process-spawning function?"""
    if isinstance(node, ast.Name):
        return node.id in fn_names
    if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
        owner, attr = node.value.id, node.attr
        if owner in sub_names:
            return attr in SPAWNERS
        if owner in os_names:
            return attr in OS_SPAWNERS or attr.startswith(("spawn", "exec"))
    return False


def built_from_prefix(command, b4_names):
    """Only [*PREFIX, ...], (*PREFIX, ...) or PREFIX + ... are accepted as a command."""
    def prefix(n):
        return isinstance(n, ast.Name) and n.id in b4_names
    if isinstance(command, (ast.List, ast.Tuple)) and command.elts:
        first = command.elts[0]
        return isinstance(first, ast.Starred) and prefix(first.value)
    if isinstance(command, ast.BinOp) and isinstance(command.op, ast.Add):
        return prefix(command.left) or built_from_prefix(command.left, b4_names)
    return False


def lint(source):
    tree = ast.parse(source)
    found = []

    def bad(node, rule):
        found.append({"line": getattr(node, "lineno", 0), "rule": rule})

    b4_names = {t.id for n in ast.walk(tree) if isinstance(n, ast.Assign) and mentions_yuo_b4(n.value)
                for t in n.targets if isinstance(t, ast.Name)}
    sub_names, os_names, fn_names = aliases(tree)
    called = {id(n.func) for n in ast.walk(tree) if isinstance(n, ast.Call)}
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
                if top in BANNED_MODULES or m in BANNED_MODULES:
                    bad(n, f"import {m}: only subprocess through YUO_B4 may reach other programs")
        elif isinstance(n, ast.Constant) and isinstance(n.value, str):
            lowered = n.value.lower()
            for word in BANNED_TEXT:
                if word in lowered:
                    bad(n, f"string mentions {word}: no LLM CLIs and no direct blindly4 path")
        elif isinstance(n, ast.Subscript) and isinstance(n.value, ast.Name) and n.value.id in b4_names:
            bad(n, "indexing or slicing the YUO_B4 prefix: use it whole, as [*prefix, *args]")
        elif isinstance(n, (ast.Name, ast.Attribute)) and is_spawner(n, sub_names, os_names, fn_names):
            if id(n) not in called:
                bad(n, "process-spawning function used indirectly (e.g. partial): call subprocess directly with the YUO_B4 prefix")
        if isinstance(n, ast.Call):
            callee = name_of(n.func)
            if isinstance(n.func, ast.Attribute) and callee in MUTATORS:
                bad(n, f"mutating call .{callee}(): build a new value")
            if callee in ("map", "filter"):
                uses.add("map/filter")
            if callee == "reduce":
                uses.add("reduce")
            if isinstance(n.func, ast.Name) and n.func.id in BANNED_BUILTINS:
                bad(n, f"{n.func.id}(): no dynamic imports or code execution")
            if is_spawner(n.func, sub_names, os_names, fn_names):
                owner = n.func.value.id if isinstance(n.func, ast.Attribute) and isinstance(n.func.value, ast.Name) else None
                if owner in os_names:
                    bad(n, f"os.{callee}: processes only through subprocess with the YUO_B4 prefix")
                else:
                    command = n.args[0] if n.args else next((k.value for k in n.keywords if k.arg == "args"), None)
                    if command is None or not built_from_prefix(command, b4_names):
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
