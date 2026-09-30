"""Read the design's source list from <dev>/rtl_sources.txt.

Shared by the test runners (through harness.py) and quartus/bench.py, so the
list of RTL files lives in exactly one place.
"""
import os

from listfile import read_list

LIST_NAME = "rtl_sources.txt"


def rtl_sources(dev_dir):
    """Paths of every RTL file listed in <dev_dir>/rtl_sources.txt.

    Fails loudly on a missing list or a listed file that does not exist: a
    silently skipped module would compile into a different design -- or, worse,
    one that still compiles because an old copy of the module is picked up
    from somewhere else.
    """
    list_path = dev_dir + "/" + LIST_NAME
    if not os.path.isfile(list_path):
        raise SystemExit("missing source list: %s" % list_path)

    files, missing = [], []
    for n, name in read_list(list_path):
        path = dev_dir + "/src/" + name
        if os.path.isfile(path):
            files.append(path)
        else:
            missing.append("%s (line %d)" % (name, n))

    if missing:
        raise SystemExit("%s lists files that do not exist under %s/src:\n  %s"
                         % (list_path, dev_dir, "\n  ".join(missing)))
    if not files:
        raise SystemExit("%s lists no source files" % list_path)
    return files
