#!/usr/bin/env python3
"""Writes the SBOM of a dist.sh archive: an SPDX 2.3 JSON document (--out)
and the same as a CycloneDX 1.6 JSON BOM (--cyclonedx).

  sbom.py --out FILE [--cyclonedx FILE] --name NAME
          --rx-clang COMMIT --llvm COMMIT --clang-version TEXT
          [--rx-rust-sbom FILE]

scripts/dist.sh calls it. The archive holds the programs of the
llvm-project fork (clang, lld, llvm-mc, llc, the LLVM binary tools and
clang's resource headers), built by this repository's scripts, and LLDB
and qemu-system-rx with their libraries, taken from an rx-rust release
archive. The SPDX SBOM of that archive (--rx-rust-sbom) describes those:
its packages for QEMU, libxml2 (in LLDB), the libraries QEMU needs and
rx-rust itself are copied, with their relationships. The libraries the
programs link from the system (glibc, libstdc++, libgcc_s, zlib on Linux)
are not in the archive, so they are not listed; on Windows the MSVC runtime
is linked statically.

It follows rx-rust's scripts/sbom.py (the same layout of packages,
relationships and CycloneDX mapping), without rustc and its crates.
"""
import argparse
import datetime
import json
import re
import uuid

ORG = "Organization: CDEF-inc"
GH = "https://github.com/CDEF-inc"


def spdx_id(*parts):
    return "SPDXRef-" + "-".join(re.sub(r"[^A-Za-z0-9.]+", ".", p) for p in parts)


def package(name, spdxid, version, supplier, download, license_declared,
            purl=None, comment=None, purpose=None):
    p = {
        "name": name,
        "SPDXID": spdxid,
        "versionInfo": version or "NOASSERTION",
        "supplier": supplier,
        "downloadLocation": download,
        "filesAnalyzed": False,
        "licenseConcluded": "NOASSERTION",
        "licenseDeclared": license_declared,
        "copyrightText": "NOASSERTION",
    }
    if purpose:
        p["primaryPackagePurpose"] = purpose
    if purl:
        p["externalRefs"] = [{"referenceCategory": "PACKAGE-MANAGER",
                              "referenceType": "purl", "referenceLocator": purl}]
    if comment:
        p["comment"] = comment
    return p


def cyclonedx(doc):
    """The SPDX document `doc` as a CycloneDX 1.6 BOM: the archive is the
    metadata's component, every other package a component (bom-ref = its
    SPDX id), and what the archive contains its dependencies."""
    top = doc["documentDescribes"][0]
    pkgs = {p["SPDXID"]: p for p in doc["packages"]}

    def component(p):
        c = {"type": "application", "bom-ref": p["SPDXID"], "name": p["name"]}
        if p["versionInfo"] != "NOASSERTION":
            c["version"] = p["versionInfo"]
        if p["supplier"].startswith("Organization: "):
            c["supplier"] = {"name": p["supplier"][len("Organization: "):]}
        if p.get("comment"):
            c["description"] = p["comment"]
        if p["licenseDeclared"] != "NOASSERTION":
            c["licenses"] = [{"expression": p["licenseDeclared"]}]
        for r in p.get("externalRefs", []):
            if r["referenceType"] == "purl":
                c["purl"] = r["referenceLocator"]
        dl = p["downloadLocation"]
        if dl != "NOASSERTION":
            vcs = dl.startswith("git+")
            if vcs:  # git+URL@REV -> URL#REV
                url, _, rev = dl[4:].rpartition("@")
                dl = f"{url}#{rev}"
            c["externalReferences"] = [{"type": "vcs" if vcs else "distribution",
                                        "url": dl}]
        return c

    deps = {}
    for r in doc["relationships"]:
        a, t, b = r["spdxElementId"], r["relationshipType"], r["relatedSpdxElement"]
        if t == "DEPENDS_ON" or (t == "CONTAINS" and a == top):
            deps.setdefault(a, []).append(b)
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": f"urn:uuid:{uuid.uuid4()}",
        "version": 1,
        "metadata": {
            "timestamp": doc["creationInfo"]["created"],
            "tools": {"components": [{"type": "application", "name": "rx-clang scripts/sbom.py"}]},
            "component": component(pkgs[top]),
            "supplier": {"name": ORG[len("Organization: "):]},
        },
        "components": [component(p) for sid, p in pkgs.items() if sid != top],
        "dependencies": [{"ref": sid, "dependsOn": deps.get(sid, [])} for sid in pkgs],
    }


LLVM = spdx_id("Package", "llvm-project")


def add_from_rx_rust(path, top, pkgs, rels):
    """Copies from rx-rust's SPDX SBOM at `path` the packages of what this
    archive takes from it: QEMU, what QEMU and LLVM (LLDB) depend on (QEMU's
    shared libraries, libxml2), and rx-rust (which built them). The archive
    `top` contains all but rx-rust, which it is partly generated from."""
    with open(path, encoding="utf-8") as f:
        src = json.load(f)
    by_id = {p["SPDXID"]: p for p in src["packages"]}
    qemu = spdx_id("Package", "qemu")
    rx_rust = spdx_id("Package", "rx-rust")
    if qemu not in by_id or rx_rust not in by_id:
        raise SystemExit(f"{path}: no qemu or rx-rust package")
    deps = [r for r in src["relationships"] if r["relationshipType"] == "DEPENDS_ON"
            and r["spdxElementId"] in (qemu, LLVM)]
    take = [qemu] + [r["relatedSpdxElement"] for r in deps
                     if r["relatedSpdxElement"] in by_id]
    for sid in dict.fromkeys(take):
        pkgs.append(by_id[sid])
        rels.append({"spdxElementId": top, "relationshipType": "CONTAINS",
                     "relatedSpdxElement": sid})
    rels.extend(deps)
    p = dict(by_id[rx_rust])
    p["comment"] = ("The rx-rust release whose archive LLDB and qemu-system-rx "
                    "(with their libraries) are taken from.")
    pkgs.append(p)
    rels.append({"spdxElementId": top, "relationshipType": "GENERATED_FROM",
                 "relatedSpdxElement": rx_rust})


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    for a in ("out", "name", "rx-clang", "llvm", "clang-version"):
        ap.add_argument("--" + a, required=True)
    ap.add_argument("--cyclonedx", help="also write a CycloneDX 1.6 JSON BOM here")
    ap.add_argument("--rx-rust-sbom",
                    help="the SPDX SBOM of the rx-rust archive LLDB and QEMU come from")
    a = ap.parse_args()

    pkgs, rels = [], []
    top = spdx_id("Package", a.name)
    pkgs.append(package(
        a.name, top, a.rx_clang, ORG, "NOASSERTION", "NOASSERTION",
        purpose="ARCHIVE",
        comment="The prebuilt RX C / C++ / assembler toolchain archive "
                "(rx-clang's scripts/dist.sh)."))

    def add(p, rel="CONTAINS"):
        pkgs.append(p)
        rels.append({"spdxElementId": top, "relationshipType": rel,
                     "relatedSpdxElement": p["SPDXID"]})

    add(package("rx-clang", spdx_id("Package", "rx-clang"), a.rx_clang, ORG,
                f"git+{GH}/rx-clang.git@{a.rx_clang}", "MIT OR Apache-2.0",
                purl=f"pkg:github/CDEF-inc/rx-clang@{a.rx_clang}",
                comment="The scripts that build and pack the toolchain."),
        rel="GENERATED_FROM")
    add(package(
        "llvm-project", spdx_id("Package", "llvm-project"), a.llvm, ORG,
        f"git+{GH}/llvm-project.git@{a.llvm}", "Apache-2.0 WITH LLVM-exception",
        purl=f"pkg:github/CDEF-inc/llvm-project@{a.llvm}",
        comment=f"The LLVM fork with the RX backend ({a.clang_version}): clang, "
                "clang's resource headers, compiler-rt's builtins, lld (ld.lld), "
                "llvm-mc, llc and the LLVM binary tools"
                + (", and LLDB (built by rx-rust from the same commit)."
                   if a.rx_rust_sbom else ".")))
    if a.rx_rust_sbom:
        add_from_rx_rust(a.rx_rust_sbom, top, pkgs, rels)

    doc = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": a.name,
        "documentNamespace": f"{GH}/rx-clang/sbom/{a.name}-{a.rx_clang}-{uuid.uuid4()}",
        "creationInfo": {
            "created": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "creators": ["Tool: rx-clang-scripts-sbom.py", ORG],
        },
        "documentDescribes": [top],
        "packages": pkgs,
        "relationships": [{"spdxElementId": "SPDXRef-DOCUMENT",
                           "relationshipType": "DESCRIBES",
                           "relatedSpdxElement": top}] + rels,
    }
    with open(a.out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, indent=1)
        f.write("\n")
    print(f"{a.out}: {len(pkgs)} packages")
    if a.cyclonedx:
        bom = cyclonedx(doc)
        with open(a.cyclonedx, "w", encoding="utf-8", newline="\n") as f:
            json.dump(bom, f, indent=1)
            f.write("\n")
        print(f"{a.cyclonedx}: {len(bom['components'])} components")


if __name__ == "__main__":
    main()
