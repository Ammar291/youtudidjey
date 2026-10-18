"""Lint fixture: reaching a process spawner through a module alias, reflection or a raw OS module."""
import functools
import itertools
import json
import os
import subprocess
import sys
import _winapi
import nt
import pyautogui
import win32com.client

B4 = tuple(json.loads(os.environ["YUO_B4"]))
p = subprocess


def bypasses():
    p.run(["cmd.exe"])
    getattr(subprocess, "run")(["cmd.exe"])
    vars(os)["system"]("cmd")
    subprocess.__dict__["run"](["cmd.exe"])
    sys.modules["subprocess"].run(["cmd.exe"])
    globals()["subprocess"].run(["cmd.exe"])
    __builtins__.__import__("subprocess")
    return tuple(map(lambda f: f, itertools.islice(itertools.count(), functools.reduce(lambda a, b: a + b, (1, 2)))))
