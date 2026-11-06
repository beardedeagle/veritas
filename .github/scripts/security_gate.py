#!/usr/bin/env python3
"""The dependency advisory gate for Veritas.

The project's own dependencies are checked against more than one advisory
database, and a known advisory refuses the build. The only way past a refusal
is a **dated exception**, recorded in `.github/security-exceptions.json` with
the advisory it covers, the package it was granted for, a reason, who
accepted it and an expiry date. An exception covers one advisory on one
package; the same advisory on another package needs its own exception.

Three collectors, one policy:

  hex       Hex's own advisory database, through `mix hex.audit`. It is the
            authoritative source for the packages that come from Hex.
  osv       The OSV database, through `osv-scanner` over `mix.lock`. A second
            opinion over the same packages, and the one that reads the
            lockfile.
  git-deps  The advisory databases for the dependencies that are **not** on
            Hex and are therefore invisible to `mix hex.audit`: each git
            dependency, queried by repository and by package name.

Usage:
    security_gate.py hex
    security_gate.py osv
    security_gate.py git-deps
    security_gate.py all

Exit status is 0 when every finding is covered by a live exception, and 1
otherwise. A finding that cannot be parsed out of a tool's output is a
failure, never a pass: a gate that cannot read its own input must not
report success.
"""

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import date
from pathlib import Path
from urllib.parse import urlsplit

REPO_ROOT = Path(__file__).resolve().parents[2]
EXCEPTIONS_FILE = REPO_ROOT / ".github" / "security-exceptions.json"
LOCKFILE = REPO_ROOT / "mix.lock"
# The application the Mix task is run from. An umbrella shares one lockfile,
# so one application audits the whole product.
AUDIT_APP = REPO_ROOT / "apps" / "veritas_core"

GITHUB_API = "https://api.github.com"
OSV_API = "https://api.osv.dev/v1/query"

# "  bandit 1.13.1 - EEF-CVE-2026-108525 (HIGH)"
HEX_FINDING = re.compile(r"^ {2}(\S+) (\S+) - (\S+) \((\w+)\)\s*$")
# The same line without the severity, so a Hex release that changes how the
# severity is printed does not stop the gate from reading the finding.
HEX_FINDING_LOOSE = re.compile(r"^ {2}(\S+) (\S+) - (\S+)\s*$")
# "    aka: CVE-2026-108525, GHSA-c3g7-2pg5-qvwh"
HEX_AKA = re.compile(r"^ {4}aka: (.+)$")
# '  "daisyui": {:git, "https://github.com/saadeghi/daisyui.git", "<sha>", [tag: "v5.5.20", ...]},'
GIT_LOCK = re.compile(
    r'"(?P<name>[^"]+)":\s*\{:git,\s*"(?P<url>[^"]+)",\s*"(?P<sha>[0-9a-f]{40})"'
)
# '<https://api.github.com/repos/o/r/security-advisories?page=2>; rel="next"'
LINK_NEXT = re.compile(r"<([^>]+)>\s*;\s*rel\s*=\s*\"?next\"?", re.IGNORECASE)


class GateError(Exception):
    """Something that stops the gate from reaching a verdict."""


def finding(source, package, version, identifier, aliases=(), severity="UNKNOWN"):
    """Builds one finding in the shape the policy and the report expect."""
    return {
        "source": source,
        "package": package,
        "version": version,
        "id": identifier,
        "aliases": sorted(set(aliases)),
        "severity": severity,
    }


# ── collectors ─────────────────────────────────────────────────────────────


def collect_hex():
    """Runs `mix hex.audit` and reads the findings out of its output.

    The task is invoked with `loadpaths --no-deps-check` because the audit
    reads the lockfile and the registry, and needs no compiled dependency.
    """
    cmd = ["mix", "do", "loadpaths", "--no-deps-check", "+", "hex.audit"]
    proc = subprocess.run(
        cmd, check=False, cwd=AUDIT_APP, capture_output=True, text=True
    )
    output = proc.stdout + proc.stderr

    findings = []
    for line in output.splitlines():
        match = HEX_FINDING.match(line)
        if match:
            package, version, identifier, severity = match.groups()
            findings.append(
                finding("hex", package, version, identifier, severity=severity)
            )
            continue
        loose = HEX_FINDING_LOOSE.match(line)
        if loose:
            package, version, identifier = loose.groups()
            findings.append(finding("hex", package, version, identifier))
            continue
        aka = HEX_AKA.match(line)
        if aka and findings:
            aliases = [a.strip() for a in aka.group(1).split(",")]
            findings[-1]["aliases"].extend(
                a for a in aliases if a not in findings[-1]["aliases"]
            )

    if proc.returncode != 0 and not findings:
        # The tool failed, or reported something this gate cannot read.
        raise GateError(
            f"`mix hex.audit` exited {proc.returncode} and its output could not be "
            "parsed. The gate refuses to pass on output it cannot read:\n"
            f"{output.strip()}"
        )
    if "Advisories:" in output and not findings:
        raise GateError(
            "`mix hex.audit` reported advisories and this gate could not read "
            "them. The gate refuses to pass on output it cannot read:\n"
            f"{output.strip()}"
        )

    return findings


def collect_osv():
    """Runs `osv-scanner` over the lockfile and reads the findings it reports."""
    try:
        proc = subprocess.run(
            ["osv-scanner", "scan", "source", "-L", str(LOCKFILE), "--format", "json"],
            check=False,
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        raise GateError(
            "osv-scanner is not on PATH. Install it (the pinned release, "
            "checksum-verified) before running this gate."
        )

    raw = proc.stdout.strip()
    if not raw:
        raise GateError(f"osv-scanner produced no output:\n{proc.stderr.strip()}")

    try:
        document = json.loads(raw)
    except json.JSONDecodeError as error:
        raise GateError(f"osv-scanner produced output this gate cannot read: {error}")

    findings = []
    for result in document.get("results", []):
        for package in result.get("packages", []) or []:
            for vulnerability in package.get("vulnerabilities", []) or []:
                severity = (vulnerability.get("database_specific") or {}).get(
                    "severity"
                ) or "UNKNOWN"
                findings.append(
                    finding(
                        "osv",
                        (package.get("package") or {}).get("name", "?"),
                        (package.get("package") or {}).get("version", "?"),
                        vulnerability.get("id", "?"),
                        aliases=vulnerability.get("aliases", []),
                        severity=severity,
                    )
                )
    return findings


def git_dependencies():
    """The dependencies in the lockfile that are not on Hex."""
    dependencies = []
    for line in LOCKFILE.read_text().splitlines():
        match = GIT_LOCK.search(line)
        if not match:
            continue
        url = match.group("url")
        # https://github.com/owner/repo.git -> owner/repo
        parts = url.rstrip("/").removesuffix(".git").split("/")
        if len(parts) < 2:
            continue
        tag = ""
        tag_match = re.search(r'tag:\s*"([^"]+)"', line)
        if tag_match:
            tag = tag_match.group(1)
        dependencies.append(
            {
                "name": match.group("name"),
                "repo": "/".join(parts[-2:]),
                "sha": match.group("sha"),
                "tag": tag,
            }
        )
    if not dependencies:
        raise GateError(f"no git dependencies found in {LOCKFILE}")
    return dependencies


def http_response(url, payload=None):
    """Fetches JSON over https, returning the body and the response headers.

    The headers are kept because they carry the pagination: GitHub says what
    comes next with its `Link` header, and a gate that throws the headers
    away can only ever see the first page of the database.
    """
    if not url.startswith("https://"):
        raise GateError(f"the gate only fetches https URLs; refusing {url}")
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    data = None
    if payload is not None:
        data = json.dumps(payload).encode()
        request = urllib.request.Request(
            url,
            data=data,
            headers={"Accept": "application/json", "Content-Type": "application/json"},
        )
    token = os.environ.get("GITHUB_TOKEN")
    if token and url.startswith(GITHUB_API):
        request.add_header("Authorization", f"Bearer {token}")
    # The scheme check above is what makes this safe, and B310 cannot see it.
    with urllib.request.urlopen(request, timeout=60) as response:  # nosec B310
        body = json.loads(response.read().decode())
        # Header names are lowercased so the lookup does not depend on the
        # casing the server happened to use.
        headers = {key.lower(): value for key, value in response.headers.items()}
    return body, headers


def http_json(url, payload=None):
    """Fetches JSON over https, with the token attached when the URL is GitHub's."""
    body, _ = http_response(url, payload)
    return body


def same_origin(url, other):
    """Whether two URLs share a scheme and a host."""
    left = urlsplit(url)
    right = urlsplit(other)
    return (left.scheme, left.netloc) == (right.scheme, right.netloc)


def next_page_url(headers, origin):
    """The URL of the next page, if the API says that there is one.

    GitHub's REST API names its pages in the `Link` header, and `rel="next"`
    is the one the gate follows. `rel="last"` and `rel="prev"` are navigation
    for a reader, not a count of pages to fetch, so they are not used to
    guess how many pages there are.
    """
    link = headers.get("link")
    if not link:
        return None
    for url in LINK_NEXT.findall(link):
        if not same_origin(origin, url):
            # A next page on another host would carry the token somewhere
            # this gate did not intend to send it.
            raise GateError(
                f"the advisory API pointed at another host ({url}); refusing to "
                "follow it"
            )
        return url
    return None


def http_json_pages(url, payload=None):
    """Fetches every page of a paginated endpoint.

    The API says what comes next with its `Link` header, so the gate follows
    that until the API says there is no next page. An advisory on page 37 is
    an advisory: the first page is not the whole database.
    """
    body, headers = http_response(url, payload)
    pages = [body]
    seen = {url}
    while True:
        next_url = next_page_url(headers, url)
        if next_url is None:
            return pages
        if next_url in seen:
            raise GateError(f"the advisory API paginated in a loop at {next_url}")
        seen.add(next_url)
        body, headers = http_response(next_url)
        pages.append(body)


def collect_git_deps():
    """The advisory databases for the dependencies that Hex does not cover.

    Two sources per dependency: the advisories published against the
    repository, and the advisories against its package name in the global
    database. A finding is a failure whatever the severity: the sweep exists
    to make a vulnerability **visible**, and a human decides whether the
    pinned commit is affected.
    """
    findings = []
    for dependency in git_dependencies():
        name = dependency["name"]
        repo = dependency["repo"]
        version = dependency["tag"] or dependency["sha"][:12]

        try:
            repo_pages = http_json_pages(
                f"{GITHUB_API}/repos/{repo}/security-advisories"
            )
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise GateError(
                    f"the GitHub advisory API failed for {repo}: HTTP {error.code}"
                )
            repo_pages = []

        for advisories in repo_pages:
            for advisory in advisories or []:
                findings.append(
                    finding(
                        "git-deps",
                        name,
                        version,
                        advisory.get("ghsa_id") or advisory.get("cve_id") or "unknown",
                        aliases=[a for a in [advisory.get("cve_id")] if a],
                        severity=(advisory.get("severity") or "unknown").upper(),
                    )
                )

        try:
            global_pages = http_json_pages(
                f"{GITHUB_API}/advisories?ecosystem=npm&affects={name}&per_page=100"
            )
        except urllib.error.HTTPError as error:
            raise GateError(
                f"the GitHub advisory database failed for {name}: HTTP {error.code}"
            )
        for advisories in global_pages:
            for advisory in advisories or []:
                findings.append(
                    finding(
                        "git-deps",
                        name,
                        version,
                        advisory.get("ghsa_id") or advisory.get("cve_id") or "unknown",
                        aliases=[a for a in [advisory.get("cve_id")] if a],
                        severity=(advisory.get("severity") or "unknown").upper(),
                    )
                )

        try:
            osv = http_json(
                OSV_API, payload={"package": {"name": name, "ecosystem": "npm"}}
            )
        except urllib.error.HTTPError as error:
            raise GateError(f"OSV failed for {name}: HTTP {error.code}")
        for vulnerability in osv.get("vulns", []) or []:
            findings.append(
                finding(
                    "git-deps",
                    name,
                    version,
                    vulnerability.get("id", "unknown"),
                    aliases=vulnerability.get("aliases", []),
                    severity=(
                        (vulnerability.get("database_specific") or {}).get("severity")
                        or "UNKNOWN"
                    ),
                )
            )

    return findings


# ── the exception policy ───────────────────────────────────────────────────

REQUIRED_EXCEPTION_FIELDS = ("id", "package", "reason", "accepted_by", "expires_on")


def load_exceptions():
    """Reads the exception file and checks that every entry is complete."""
    if not EXCEPTIONS_FILE.exists():
        raise GateError(f"the exception file {EXCEPTIONS_FILE} does not exist")
    try:
        document = json.loads(EXCEPTIONS_FILE.read_text())
    except json.JSONDecodeError as error:
        raise GateError(f"the exception file is not valid JSON: {error}")
    exceptions = document.get("exceptions")
    if not isinstance(exceptions, list):
        raise GateError('the exception file must hold an "exceptions" list')
    for exception in exceptions:
        missing = [
            field for field in REQUIRED_EXCEPTION_FIELDS if not exception.get(field)
        ]
        if missing:
            raise GateError(
                f"an exception is missing {', '.join(missing)}: {json.dumps(exception)}"
            )
    return exceptions


def package_key(package):
    """The comparison form of a package name.

    Two spellings of the same package name are one package: the lockfile
    writes `daisyui` and a human writes `DaisyUI`. Nothing else is folded
    together, because the package is half of what an exception is about.
    """
    return package.strip().casefold()


def decide(findings, exceptions, today):
    """Matches findings against the exceptions.

    A finding with no matching exception is REFUSED. A match whose date has
    passed is EXPIRED, and one that has not is ACCEPTED. An exception that no
    finding needs is STALE: it is doing nothing, so it should go.

    An exception is granted for one advisory **and** one package. The same
    advisory id against a different package is a different finding, and it
    needs its own exception: an id is not a blanket amnesty.
    """
    by_key = {}
    for exception in exceptions:
        key = (exception["id"].upper(), package_key(exception["package"]))
        by_key.setdefault(key, exception)

    verdicts = []
    reported = set()

    for item in findings:
        identifiers = {item["id"].upper()} | {
            alias.upper() for alias in item["aliases"]
        }
        package = package_key(item["package"])
        reported |= {(identifier, package) for identifier in identifiers}
        exception = None
        for identifier in identifiers:
            candidate = by_key.get((identifier, package))
            if candidate is not None:
                exception = candidate
                break
        if exception is None:
            verdicts.append((item, None, "REFUSED"))
            continue
        expires = date.fromisoformat(exception["expires_on"])
        if expires < today:
            verdicts.append((item, exception, "EXPIRED"))
        else:
            verdicts.append((item, exception, "ACCEPTED"))

    for key, exception in by_key.items():
        if key not in reported:
            verdicts.append((None, exception, "STALE"))

    return verdicts


# ── reporting ──────────────────────────────────────────────────────────────


def report(mode, verdicts):
    """Prints the verdicts and returns the exit status."""
    print()
    print(f"dependency advisory gate ({mode})")
    print("=" * (28 + len(mode)))
    if not verdicts:
        print("no advisories reported")
        return 0

    refused = [v for v in verdicts if v[2] == "REFUSED"]
    expired = [v for v in verdicts if v[2] == "EXPIRED"]
    stale = [v for v in verdicts if v[2] == "STALE"]
    accepted = [v for v in verdicts if v[2] == "ACCEPTED"]

    for item, exception, verdict in refused + expired:
        print()
        print(f"  {verdict}  {item['package']} {item['version']}  [{item['severity']}]")
        print(f"    {item['id']}")
        if item["aliases"]:
            print(f"    aka: {', '.join(item['aliases'])}")
        if exception:
            print(f"    exception expired on {exception['expires_on']}")
            print(f"    reason: {exception['reason']}")
            print(f"    accepted by: {exception['accepted_by']}")

    for item, exception, verdict in accepted:
        print()
        print(f"  ACCEPTED  {item['package']} {item['version']}  {item['id']}")
        print(f"    reason: {exception['reason']}")
        print(
            f"    accepted by: {exception['accepted_by']}, "
            f"expires {exception['expires_on']}"
        )

    for item, exception, verdict in stale:
        print()
        print(
            f"  STALE  the exception for {exception['id']} is no longer needed; "
            "remove it"
        )
        print(f"    reason: {exception['reason']}")

    print()
    if refused or expired:
        print(
            f"the gate refuses the build: {len(refused) + len(expired)} "
            "advisory(ies) without a live, dated exception"
        )
        return 1
    print(
        f"the gate passes: {len(accepted)} finding(s), all covered by live exceptions"
    )
    return 0


def main(argv):
    """Runs the selected collectors, applies the policy, reports the verdict."""
    mode = argv[1] if len(argv) > 1 else "all"
    if mode not in ("hex", "osv", "git-deps", "all"):
        print("usage: security_gate.py [hex|osv|git-deps|all]", file=sys.stderr)
        return 2

    collectors = {
        "hex": collect_hex,
        "osv": collect_osv,
        "git-deps": collect_git_deps,
    }
    selected = collectors if mode == "all" else {mode: collectors[mode]}

    findings = []
    for name, collector in selected.items():
        try:
            findings.extend(collector())
        except GateError as error:
            print(f"gate error in {name}: {error}", file=sys.stderr)
            return 2

    exceptions = load_exceptions()
    verdicts = decide(findings, exceptions, date.today())
    return report(mode, verdicts)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
