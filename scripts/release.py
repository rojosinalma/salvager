#!/usr/bin/env python3
"""Builds the addon zip and uploads it to CurseForge.

  release.py package   dist/Salvager-<version>.zip (the Salvager folder and LICENSE)
  release.py release   package, upload to CurseForge, tag v<version>, push the tag to GitHub

release reads from the environment (the Makefile loads .env):
  CURSEFORGE_TOKEN       API token (CurseForge Authors > API Tokens)
  CURSEFORGE_PROJECT_ID  the project's ID (its page, About Project)
  RELEASE_TYPE           alpha, beta or release (default beta)
  CURSEFORGE_GAME_VERSION_TYPE  only when the game version name matches more than one type
  CURSEFORGE_API         default https://wow.curseforge.com/api
"""
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
import zipfile

ADDON = "Salvager"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(ROOT, "dist")
RELEASE_TYPES = ("alpha", "beta", "release")


def fail(msg):
    sys.exit(f"release: {msg}")


def toc():
    path = os.path.join(ROOT, ADDON, f"{ADDON}.toc")
    with open(path, encoding="utf-8") as f:
        fields = dict(re.findall(r"^## ([\w-]+): *(.*?)\s*$", f.read(), re.M))
    for key in ("Version", "Interface"):
        if not fields.get(key):
            fail(f"{path} has no '## {key}:' line")
    return fields


def game_version_name(interface):
    """16001 -> 1.60.1"""
    n = int(interface)
    return f"{n // 10000}.{n // 100 % 100}.{n % 100}"


def package(version):
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, f"{ADDON}-{version}.zip")
    src = os.path.join(ROOT, ADDON)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for name in sorted(os.listdir(src)):
            if name.startswith("."):
                continue
            z.write(os.path.join(src, name), f"{ADDON}/{name}")
        z.write(os.path.join(ROOT, "LICENSE"), f"{ADDON}/LICENSE")
    print(f"packaged: {os.path.relpath(out, ROOT)}")
    return out


def git(*args):
    r = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


def changelog():
    code, last = git("describe", "--tags", "--match", "v*", "--abbrev=0")
    if code != 0:
        return "First public release."
    _, log = git("log", "--format=- %s", f"{last}..HEAD")
    return log or "No changes."


def api(method, path, token, body=None, content_type=None):
    base = os.environ.get("CURSEFORGE_API", "https://wow.curseforge.com/api")
    req = urllib.request.Request(f"{base}{path}", data=body, method=method)
    req.add_header("X-Api-Token", token)
    if content_type:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        fail(f"{method} {path}: HTTP {e.code} {e.read().decode(errors='replace')[:500]}")


def game_version_id(token, name):
    found = [v for v in api("GET", "/game/versions", token) if v.get("name") == name]
    want_type = os.environ.get("CURSEFORGE_GAME_VERSION_TYPE")
    if want_type:
        found = [v for v in found if str(v.get("gameVersionTypeID")) == want_type]
    if len(found) != 1:
        types = ", ".join(str(v.get("gameVersionTypeID")) for v in found) or "none"
        fail(f"game version {name}: {len(found)} matches (types: {types}); "
             "set CURSEFORGE_GAME_VERSION_TYPE in .env")
    return found[0]["id"]


def multipart(fields, file_field, file_path):
    boundary = uuid.uuid4().hex
    parts = []
    for key, value in fields.items():
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode())
    with open(file_path, "rb") as f:
        data = f.read()
    parts.append((f'--{boundary}\r\nContent-Disposition: form-data; name="{file_field}"; '
                  f'filename="{os.path.basename(file_path)}"\r\n'
                  'Content-Type: application/zip\r\n\r\n').encode() + data + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def release(fields):
    token = os.environ.get("CURSEFORGE_TOKEN")
    project = os.environ.get("CURSEFORGE_PROJECT_ID")
    kind = os.environ.get("RELEASE_TYPE") or "beta"
    if not token or not project:
        fail("set CURSEFORGE_TOKEN and CURSEFORGE_PROJECT_ID in .env")
    if not project.isdigit():
        fail(f"CURSEFORGE_PROJECT_ID is not a number: {project}")
    if kind not in RELEASE_TYPES:
        fail(f"RELEASE_TYPE must be one of {', '.join(RELEASE_TYPES)}")
    version = fields["Version"]
    tag = f"v{version}"
    _, dirty = git("status", "--porcelain")
    if dirty:
        fail("the working tree has changes; commit them first")
    if git("rev-parse", "-q", "--verify", f"refs/tags/{tag}")[0] == 0:
        fail(f"{tag} is already released; raise '## Version:' in the TOC")

    zip_path = package(version)
    metadata = {
        "changelog": changelog(),
        "changelogType": "markdown",
        "displayName": f"{ADDON} {version}",
        "gameVersions": [game_version_id(token, game_version_name(fields["Interface"]))],
        "releaseType": kind,
    }
    body, ctype = multipart({"metadata": json.dumps(metadata)}, "file", zip_path)
    result = api("POST", f"/projects/{project}/upload-file", token, body, ctype)
    print(f"uploaded: {ADDON} {version} ({kind}), file id {result.get('id')}")
    code, _ = git("tag", tag)
    if code != 0:
        fail(f"uploaded, but could not create tag {tag}")
    print(f"tagged: {tag}")
    code, _ = git("push", "origin", tag)
    if code != 0:
        fail(f"uploaded and tagged {tag}, but the push failed; push it by hand: git push origin {tag}")
    print(f"pushed: {tag}")


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("package", "release"):
        fail("usage: release.py package|release")
    fields = toc()
    if sys.argv[1] == "package":
        package(fields["Version"])
    else:
        release(fields)


if __name__ == "__main__":
    main()
