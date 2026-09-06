#!/usr/bin/env python3
"""Wire (or re-wire) the PatentReader target into mlx-swift-examples.xcodeproj.

Idempotent: it strips any PatentReader blocks it previously wrote and puts them back
from the files currently on disk, so adding a source file is a re-run rather than a
hand edit. The ids are synthetic and hand-written, `E5B2D1B0000000000000….`, chosen to
sort next to ShakespeareReader's `E5B2D1AF…` so the two targets read as siblings in the
file — which they are.
"""

import os
import re
import sys

ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
PBX = os.path.join(ROOT, "mlx-swift-examples.xcodeproj", "project.pbxproj")
APP = os.path.join(ROOT, "Applications", "PatentReader")

P = "E5B2D1B00000000000000"
TARGET, SOURCES, FRAMEWORKS, RESOURCES = P + "A01", P + "A02", P + "A03", P + "A04"
PRODUCT, CONFIGLIST, DEBUG, RELEASE = P + "A05", P + "A06", P + "A07", P + "A08"
EXCEPTIONS = P + "A09"
# Package products. The six mlx ones carry no `package =` line, which is the repo idiom
# ShakespeareReader follows: Xcode resolves them from mlx-swift-lm. `HuggingFace` and
# `Tokenizers` name their remote package because they come from different ones.
PRODUCTS = [
    (P + "B01", "MLXLLM", None),
    (P + "B02", "MLXVLM", None),
    (P + "B03", "MLXLMCommon", None),
    (P + "B04", "MLXHuggingFace", None),
    (P + "B05", "MLX", None),
    (P + "B06", "MLXEmbedders", None),
    (P + "B07", "HuggingFace", "C3EA7F522F8431BE0054AEA3"),
    (P + "B08", "Tokenizers", "C3EA7F532F8432080054AEA3"),
]

# Directories copied whole rather than compiled. `Resources/Fixtures` has to be an
# explicit folder for the same reason `Resources/Plays` does next door: the golden HTML
# is found by enumerating a directory, and a flattened copy leaves nothing to enumerate.
EXPLICIT_FOLDERS = ["PatentReader/Resources/Fixtures"]


def members():
    """Every path the target compiles or copies, as the exception set lists them."""
    out = []
    for dirpath, dirnames, filenames in os.walk(APP):
        rel = os.path.relpath(dirpath, os.path.dirname(APP))
        # Bundles and explicit folders are named as a unit, never recursed into.
        if rel.endswith(".xcassets") or rel in EXPLICIT_FOLDERS:
            dirnames[:] = []
            filenames = []
            out.append(rel)
            continue
        if any(rel.startswith(f + os.sep) for f in EXPLICIT_FOLDERS + ["PatentReader/tools"]):
            continue
        if rel == "PatentReader/tools":
            dirnames[:] = []
            continue
        for name in filenames:
            if name.endswith(".swift"):
                out.append(os.path.join(rel, name))
    return sorted(set(out))


def strip(text):
    """Remove everything a previous run added, so this can be re-run.

    Three shapes, and getting any of them wrong silently destroys the project file — so
    each pattern is anchored rather than trusted to stop where it should.

    * A **multi-line object** opens `^\\t\\tID /* name */ = {` and closes `^\\t\\t};`.
      The comment must not be matched with a newline-crossing `.*?`: an id also appears
      as a bare list entry (`\\t\\t\\t\\tID /* name */,`), and there `.*?\\*/ = \\{` finds
      no `= {` on its own line and runs forward to the *next* object's opening, deleting
      everything in between. That removed a whole `PBXResourcesBuildPhase` section the
      first time this ran. `[^\\n]*?` keeps the comment on its line.
    * A **one-line object** — `PBXFileReference` — closes with `; };` on the same line,
      so the multi-line pattern would run past it to the next object's close.
    * A **list reference** is a line of its own, or an inline `id /* name */, ` inside a
      single-line list.
    """
    ids = [TARGET, SOURCES, FRAMEWORKS, RESOURCES, CONFIGLIST, DEBUG, RELEASE,
           EXCEPTIONS] + [p[0] for p in PRODUCTS]

    # One-liners first, so a multi-line pattern cannot reach across one.
    text = re.sub(
        r"^\t\t" + PRODUCT + r" /\*[^\n]*?\*/ = \{[^\n]*\};\n", "", text, flags=re.M)
    for marker in ids:
        text = re.sub(
            r"^\t\t" + marker + r" /\*[^\n]*?\*/ = \{.*?^\t\t\};\n", "", text,
            flags=re.S | re.M)
    for marker in ids + [PRODUCT]:
        text = re.sub(r"^\t+" + marker + r" /\*[^\n]*?\*/,\n", "", text, flags=re.M)
        text = re.sub(marker + r" /\*[^\n]*?\*/, ", "", text)
    text = text.replace(", PatentReader/Resources/Fixtures, ", ", ")
    return text


def main():
    text = open(PBX, encoding="utf-8").read()
    text = strip(text)

    files = members()
    if not any(f.endswith("PatentReaderApp.swift") for f in files):
        sys.exit("PatentReaderApp.swift not found — run this from a checkout with the app in it")

    def insert_after(anchor, block):
        nonlocal text
        at = text.index(anchor) + len(anchor)
        text = text[:at] + block + text[at:]

    # 1. The product reference, and its Products group entry.
    insert_after(
        "/* Begin PBXFileReference section */\n",
        f"\t\t{PRODUCT} /* PatentReader.app */ = {{isa = PBXFileReference; "
        "explicitFileType = wrapper.application; includeInIndex = 0; "
        "path = PatentReader.app; sourceTree = BUILT_PRODUCTS_DIR; };\n")
    text = text.replace(
        "\t\t\t\tE5B2D1AF0000000000000A05 /* ShakespeareReader.app */,\n",
        "\t\t\t\tE5B2D1AF0000000000000A05 /* ShakespeareReader.app */,\n"
        f"\t\t\t\t{PRODUCT} /* PatentReader.app */,\n")

    # 2. The exception set naming every file, and its registration on the Applications
    #    synchronized root group.
    listing = "".join(f"\t\t\t\t{f},\n" for f in files)
    insert_after(
        "/* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */\n",
        f"\t\t{EXCEPTIONS} /* PBXFileSystemSynchronizedBuildFileExceptionSet */ = {{\n"
        "\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;\n"
        "\t\t\tmembershipExceptions = (\n" + listing + "\t\t\t);\n"
        f"\t\t\ttarget = {TARGET} /* PatentReader */;\n\t\t}};\n")

    text = text.replace(
        "E5B2D1AF0000000000000A09 /* PBXFileSystemSynchronizedBuildFileExceptionSet */, ); "
        "explicitFileTypes = {}; explicitFolders = (ShakespeareReader/Resources/Plays, );",
        "E5B2D1AF0000000000000A09 /* PBXFileSystemSynchronizedBuildFileExceptionSet */, "
        f"{EXCEPTIONS} /* PBXFileSystemSynchronizedBuildFileExceptionSet */, ); "
        "explicitFileTypes = {}; explicitFolders = (ShakespeareReader/Resources/Plays, "
        "PatentReader/Resources/Fixtures, );")

    # 3. Three empty build phases. Empty on purpose: a synchronized group supplies the
    #    files, and the package products link from `packageProductDependencies`.
    insert_after(
        "/* Begin PBXFrameworksBuildPhase section */\n",
        f"\t\t{FRAMEWORKS} /* Frameworks */ = {{\n"
        "\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n")
    insert_after(
        "/* Begin PBXResourcesBuildPhase section */\n",
        f"\t\t{RESOURCES} /* Resources */ = {{\n"
        "\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n")
    insert_after(
        "/* Begin PBXSourcesBuildPhase section */\n",
        f"\t\t{SOURCES} /* Sources */ = {{\n"
        "\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n")

    # 4. The target.
    deps = "".join(f"\t\t\t\t{i} /* {n} */,\n" for i, n, _ in PRODUCTS)
    insert_after(
        "/* Begin PBXNativeTarget section */\n",
        f"\t\t{TARGET} /* PatentReader */ = {{\n\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {CONFIGLIST} /* Build configuration list for "
        "PBXNativeTarget \"PatentReader\" */;\n"
        f"\t\t\tbuildPhases = (\n\t\t\t\t{SOURCES} /* Sources */,\n"
        f"\t\t\t\t{FRAMEWORKS} /* Frameworks */,\n"
        f"\t\t\t\t{RESOURCES} /* Resources */,\n\t\t\t);\n"
        "\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n"
        "\t\t\tname = PatentReader;\n"
        f"\t\t\tpackageProductDependencies = (\n{deps}\t\t\t);\n"
        "\t\t\tproductName = PatentReader;\n"
        f"\t\t\tproductReference = {PRODUCT} /* PatentReader.app */;\n"
        "\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t};\n")

    text = text.replace(
        "\t\t\t\tE5B2D1AF0000000000000A01 /* ShakespeareReader */,\n",
        "\t\t\t\tE5B2D1AF0000000000000A01 /* ShakespeareReader */,\n"
        f"\t\t\t\t{TARGET} /* PatentReader */,\n")

    # 5. Build configurations, copied field for field from ShakespeareReader's and
    #    changed only where they must be: the bundle id, the two Info.plist paths and the
    #    two entitlements paths.
    for src, dst, name in [("E5B2D1AF0000000000000A07", DEBUG, "Debug"),
                           ("E5B2D1AF0000000000000A08", RELEASE, "Release")]:
        match = re.search(
            r"\t\t" + src + r" /\* " + name + r" \*/ = \{.*?\n\t\t\};\n", text, re.S)
        block = match.group(0)
        block = (block
                 .replace(src, dst)
                 .replace("Applications/ShakespeareReader/ShakespeareReader-",
                          "Applications/PatentReader/PatentReader-")
                 .replace("Applications/ShakespeareReader/Info-",
                          "Applications/PatentReader/Info-")
                 .replace("mlx.ShakespeareReader${DISAMBIGUATOR}",
                          "mlx.PatentReader${DISAMBIGUATOR}"))
        insert_after("/* Begin XCBuildConfiguration section */\n", block)

    insert_after(
        "/* Begin XCConfigurationList section */\n",
        f"\t\t{CONFIGLIST} /* Build configuration list for PBXNativeTarget "
        "\"PatentReader\" */ = {\n\t\t\tisa = XCConfigurationList;\n"
        f"\t\t\tbuildConfigurations = (\n\t\t\t\t{DEBUG} /* Debug */,\n"
        f"\t\t\t\t{RELEASE} /* Release */,\n\t\t\t);\n"
        "\t\t\tdefaultConfigurationIsVisible = 0;\n"
        "\t\t\tdefaultConfigurationName = Release;\n\t\t};\n")

    # 6. The package product dependencies.
    blocks = ""
    for ident, name, package in PRODUCTS:
        blocks += f"\t\t{ident} /* {name} */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n"
        if package:
            blocks += f"\t\t\tpackage = {package} /* XCRemoteSwiftPackageReference */;\n"
        blocks += f"\t\t\tproductName = {name};\n\t\t}};\n"
    insert_after("/* Begin XCSwiftPackageProductDependency section */\n", blocks)

    open(PBX, "w", encoding="utf-8").write(text)
    print(f"wired PatentReader: {len(files)} membership exceptions")


if __name__ == "__main__":
    main()
