"""Read a list file: one name per line, '#' starts a comment, blank lines ignored.

Used for dev/rtl_sources.txt (which RTL files to build) and verif/test_lists/*.txt
(which directed tests to run), so both kinds of list follow exactly the same rules.
"""


def read_list(path):
    """Every entry in the file as [(line_number, name), ...], in file order."""
    entries = []
    with open(path) as f:
        for n, line in enumerate(f, 1):
            name = line.split("#", 1)[0].strip()
            if name:
                entries.append((n, name))
    return entries
