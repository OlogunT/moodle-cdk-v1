#!/usr/bin/env python3
"""
Remove debugging() calls from the menutopic reentrancy guard in lib.php.
Uses exact string replacement -- no regex -- to avoid greedy-match corruption.
"""
import sys

LIB = '/app/moodle/course/format/menutopic/lib.php'

with open(LIB, 'r') as f:
    content = f.read()

# ---- Block 1: debugging() inside the catch block ----
# Replace the 5-line debugging() call with a single silent comment.
old1 = (
    "                        debugging(\n"
    "                            'format_menutopic: set_sectionnum skipped during modinfo cache rebuild ' .\n"
    "                            '(lock contention avoided): ' . $e->getMessage(),\n"
    "                            DEBUG_DEVELOPER\n"
    "                        );\n"
)
new1 = (
    "                        // Silently ignore exception during recursive modinfo rebuild.\n"
)

# ---- Block 2: debugging() inside the else block ----
# Replace the entire else { debugging(...); } with just }
old2 = (
    "                } else {\n"
    "                    debugging(\n"
    "                        'format_menutopic: set_sectionnum skipped (recursive constructor during modinfo rebuild)',\n"
    "                        DEBUG_DEVELOPER\n"
    "                    );\n"
    "                }\n"
)
new2 = "                }\n"

changed = False

if old1 in content:
    content = content.replace(old1, new1, 1)
    print("OK: Removed catch debugging()")
    changed = True
else:
    print("SKIP: catch debugging() block not found (may already be removed)")

if old2 in content:
    content = content.replace(old2, new2, 1)
    print("OK: Removed else debugging()")
    changed = True
else:
    print("SKIP: else debugging() block not found (may already be removed)")

if changed:
    with open(LIB, 'w') as f:
        f.write(content)
    print("File written.")
else:
    print("No changes needed.")

