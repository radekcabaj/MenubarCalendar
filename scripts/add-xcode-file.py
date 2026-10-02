#!/usr/bin/env python3
"""Register a Swift file with MenubarCalendar.xcodeproj.

The project lists its files explicitly (no synchronized folders), so a new
.swift file compiles only once it has a file reference, a group entry and a
Sources build-phase entry. Run from the repo root:

    scripts/add-xcode-file.py app MenubarCalendar/Foo.swift
    scripts/add-xcode-file.py tests MenubarCalendarTests/FooTests.swift
"""
import os
import re
import sys

PBX = "MenubarCalendar.xcodeproj/project.pbxproj"
# Group and Sources-phase object ids per target (see project.pbxproj).
TARGETS = {
    "app": ("AAAA00000000000000000003", "AAAA0000000000000000000D"),
    "tests": ("AAAA00000000000000000005", "AAAA00000000000000000010"),
}


def main():
    target, path = sys.argv[1], sys.argv[2]
    group_id, phase_id = TARGETS[target]
    name = os.path.basename(path)
    with open(PBX) as f:
        text = f.read()
    if f"/* {name} */" in text:
        sys.exit(f"{name} is already in the project")

    top = max(int(h, 16) for h in re.findall(r"AAAA([0-9A-F]{20})", text))
    build_id, ref_id = f"AAAA{top + 1:020X}", f"AAAA{top + 2:020X}"

    def insert_after(text, anchor, line, start=0):
        i = text.index(anchor, start) + len(anchor)
        return text[:i] + line + text[i:]

    text = insert_after(
        text, "/* Begin PBXBuildFile section */\n",
        f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; "
        f"fileRef = {ref_id} /* {name} */; }};\n")
    text = insert_after(
        text, "/* Begin PBXFileReference section */\n",
        f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = sourcecode.swift; path = {name}; "
        f"sourceTree = \"<group>\"; }};\n")
    group = text.index(f"\n\t\t{group_id} /* ", text.index("/* Begin PBXGroup section */"))
    text = insert_after(text, "children = (\n", f"\t\t\t\t{ref_id} /* {name} */,\n", group)
    phase = text.index(f"\t\t{phase_id} /* Sources */ = {{")
    text = insert_after(text, "files = (\n", f"\t\t\t\t{build_id} /* {name} in Sources */,\n", phase)

    with open(PBX, "w") as f:
        f.write(text)
    print(f"added {name}: build {build_id}, ref {ref_id}")


if __name__ == "__main__":
    main()
