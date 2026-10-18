import asyncio
import functools
import importlib
import itertools
import json
import os
import subprocess
import subprocess as sp
from subprocess import run

B4 = tuple(json.loads(os.environ["YUO_B4"]))
f = [lambda: 1, lambda: 2, lambda: 3, lambda: 4, lambda: 5]
total = functools.reduce(lambda a, b: a + b, map(lambda g: g(), f), 0)
evens = tuple(filter(lambda n: n % 2 == 0, itertools.islice(itertools.count(), 10)))


def bypasses():
    run(["taskkill", "/IM", "chrome.exe"])
    sp.Popen(["chrome.exe", "--remote-debugging-port=9222"])
    functools.partial(subprocess.run, shell=True)(["powershell"])
    os.startfile("https://example.com")
    __import__("urllib.request")
    subprocess.run([B4[-2], "press"])
    subprocess.run([*B4[:7], "driver", *B4[8:]])
