"""Lint fixture: the YUO_B4 name is rebound to another program by a parameter or a loop target."""
import functools
import itertools
import json
import os
import subprocess

B4 = tuple(json.loads(os.environ["YUO_B4"]))

compose = lambda *fs: functools.reduce(lambda f, g: lambda x: g(f(x)), fs, lambda x: x)
lines = compose(lambda t: t.splitlines(), lambda ls: map(str.strip, ls), lambda ls: filter(None, ls), tuple)


def spawn(B4, *args):
    return subprocess.run([*B4, *args], capture_output=True)


shell = lambda B4: subprocess.run([*B4, "-c", "start chrome"], capture_output=True)
looped = tuple(subprocess.run([*B4], capture_output=True) for B4 in (("cmd.exe", "/c", "start chrome"),))


def main():
    spawn(("powershell", "-c", "Start-Process chrome"))
    shell(("powershell",))
    return tuple(itertools.islice(lines("a\nb"), 1))
