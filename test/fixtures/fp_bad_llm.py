import functools
import itertools
import subprocess

import requests

f = [lambda: 1, lambda: 2, lambda: 3, lambda: 4, lambda: 5]
total = functools.reduce(lambda a, b: a + b, map(lambda g: g(), f), 0)
evens = tuple(filter(lambda n: n % 2 == 0, itertools.islice(itertools.count(), 10)))


def think(prompt):
    return subprocess.run(["claude", "-p", prompt], capture_output=True, text=True).stdout
