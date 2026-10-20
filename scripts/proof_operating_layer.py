#!/usr/bin/env python3
"""The checks behind scripts/proof-operating-layer.sh.

Proves the operating layer (WO-41), the Engine side of the Engine without
BusinessOS (WO-44), and Signal Theory and viability (WO-45) against a
running Engine, one CHECK line per acceptance criterion.

Modes:
  full       Creates its own workspaces, principals and keys and exercises
             every route the criteria name. For a disposable Engine or a
             managed QA Engine, with an admin key.
  read-only  Sends GET requests only, enforced in the client below. Every
             line names the tenant and the workspace it read; the rest is
             counts, dates, metric values, booleans and Engine-defined
             labels, never content, titles, names, emails or keys. For an
             owner's private Engine. Boot is read only with BOOT=1, and
             then with generate=false, so the run writes nothing.

Environment:
  ENGINE_URL        the Engine
  PROOF_ENGINE_KEY  the key (optional in read-only mode); never printed
  WORKSPACE         the workspace read-only mode reports on
  PROOF_FRESH       1 when the wrapper started this Engine on an empty store
  CLASSIFY_PLAN     0 skips the re-run classification plan in read-only mode
  BOOT              1 adds GET /api/boot?generate=false in read-only mode
  KEEP              1 leaves the proof's workspaces active and its keys valid

Exit: 0 when every check passed or was skipped, 1 when one failed, 2 when
the Engine could not be reached or refused the key.
"""

import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, "apps", "cli", "optimal")
REFERENCE = os.environ.get("API_REFERENCE") or os.path.join(ROOT, "docs", "reference", "api.md")

SIX_METRICS = [
    "action_completion_rate",
    "re_encoding_frequency",
    "time_to_decode_hours",
    "signal_bounce_rate",
    "genre_recognition_rate",
    "feedback_loop_closure_rate",
]

# Engine routes the BusinessOS client calls, by path, from its optimal proxy
# allowlist (handlers/optimal_proxy.go), its typed client
# (optimalengine/client.go), and the Engine fake its tests run against
# (optimalengine/enginetest). Kept equal to test/api/reference_test.exs.
BUSINESSOS_ROUTES = [
    ("GET", "/api/health"),
    ("POST", "/api/memory"),
    ("GET", "/api/memory"),
    ("POST", "/api/memory/:id/forget"),
    ("POST", "/api/rag"),
    ("GET", "/api/recall/actions"),
    ("GET", "/api/recall/who"),
    ("GET", "/api/recall/when"),
    ("GET", "/api/recall/where"),
    ("GET", "/api/recall/owns"),
    ("GET", "/api/search"),
    ("GET", "/api/workspaces"),
    ("POST", "/api/workspaces"),
    ("GET", "/api/optimal/nodes"),
    ("GET", "/api/optimal/nodes/:slug/files"),
    ("POST", "/api/ingest"),
    ("GET", "/api/auth/whoami"),
]
# Paths the proxy passes for any method, and the prefixes it passes.
BUSINESSOS_PATHS = [
    "/api/health",
    "/api/status",
    "/api/version",
    "/api/search",
    "/api/grep",
    "/api/graph",
    "/api/rag",
    "/api/rag/stream",
    "/api/wiki",
    "/api/memory",
    "/api/assemble",
    "/api/boot",
    "/api/brief",
    "/api/loops",
]
BUSINESSOS_PREFIXES = ["/api/memory/", "/api/recall/", "/api/wiki/", "/api/graph/", "/api/loops/"]


class Unreachable(Exception):
    """The Engine did not answer, or refused the proof's own key."""


class Engine:
    """A minimal JSON client. In read-only mode it refuses anything but GET."""

    def __init__(self, url, key, read_only):
        self.url = url.rstrip("/")
        self.key = key or None
        self.read_only = read_only
        self.sent = {}

    def call(self, method, path, body=None, query=None, key="own", timeout=120):
        if self.read_only and method != "GET":
            raise RuntimeError("read-only mode refuses %s" % method)

        if query:
            pairs = {k: v for k, v in query.items() if v is not None}
            path = path + "?" + urllib.parse.urlencode(pairs)

        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(self.url + path, data=data, method=method)
        token = self.key if key == "own" else key

        if token:
            request.add_header("Authorization", "Bearer " + token)
        if data is not None:
            request.add_header("Content-Type", "application/json")

        self.sent[method] = self.sent.get(method, 0) + 1

        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                status, raw = response.status, response.read()
        except urllib.error.HTTPError as err:
            status, raw = err.code, err.read()
        except (urllib.error.URLError, OSError) as err:
            raise Unreachable("%s %s: %s" % (method, path.split("?")[0], type(err).__name__))

        try:
            payload = json.loads(raw) if raw else None
        except ValueError:
            payload = raw.decode("utf-8", "replace")

        return status, payload


RESULTS = []


def report(check_id, outcome, facts):
    """outcome: True passed, False failed, None skipped."""
    status = {True: "PASS", False: "FAIL", None: "SKIP"}[outcome]
    RESULTS.append((check_id, status, facts))
    shown = " ".join("%s=%s" % (k, render(v)) for k, v in facts.items())
    print(("CHECK %s %s %s" % (check_id, status, shown)).rstrip(), flush=True)


def render(value):
    if isinstance(value, (dict, list, bool)) or value is None:
        return json.dumps(value, sort_keys=True, separators=(",", ":"))
    return str(value)


def expect(condition, message):
    if not condition:
        raise AssertionError(message)


def guarded(check_id, fn, private=False):
    """Runs one criterion; an exception is that criterion failing, with its reason.

    On a private Engine only this script's own assertion messages (statuses
    and counts) are printed; any other exception shows its type only, since
    its message could quote data.
    """
    try:
        fn()
    except Unreachable:
        raise
    except Exception as err:  # noqa: BLE001 - every crash is a failed criterion
        shown = not private or isinstance(err, AssertionError)
        reason = "%s: %s" % (type(err).__name__, err) if shown else type(err).__name__
        report(check_id, False, {"error": reason[:300]})


def local_today(tz_name):
    try:
        from zoneinfo import ZoneInfo

        return datetime.now(ZoneInfo(tz_name)).date().isoformat()
    except Exception:  # noqa: BLE001 - no tz database: fall back to UTC
        return datetime.now(timezone.utc).date().isoformat()


def words(text):
    return len(re.findall(r"\S+", text or ""))


# ---------------------------------------------------------------------------
# Full mode
# ---------------------------------------------------------------------------


class Full:
    def __init__(self, engine, fresh):
        self.e = engine
        self.fresh = fresh
        self.sfx = secrets.token_hex(3)
        self.minted = []
        self.created = []
        # An empty config home, so no local profile changes what the CLI calls.
        self.config_home = tempfile.mkdtemp()

    # -- helpers ---------------------------------------------------------------

    def ok(self, status, payload, expected, what):
        expect(status in expected, "%s answered %s: %s" % (what, status, str(payload)[:200]))
        return payload

    def workspace(self, slug, name):
        status, body = self.e.call("POST", "/api/workspaces", {"slug": slug, "name": name})
        body = self.ok(status, body, (201,), "creating workspace " + slug)
        self.created.append(body["id"])
        return body["id"]

    def principal(self, principal_id, kind, name):
        status, body = self.e.call(
            "POST", "/api/principals", {"id": principal_id, "kind": kind, "display_name": name}
        )
        return self.ok(status, body, (200, 201), "registering " + principal_id)

    def mint(self, principal_id, kind, scopes, workspaces):
        self.principal(principal_id, kind, principal_id.split(":", 1)[-1])
        status, body = self.e.call(
            "POST",
            "/api/auth/keys",
            {
                "name": "proof " + principal_id,
                "principal_id": principal_id,
                "scopes": scopes,
                "workspace_scope": workspaces,
            },
        )
        body = self.ok(status, body, (201,), "minting a key for " + principal_id)
        self.minted.append(body["id"])
        return body["key"]

    def cli(self, *args):
        env = {k: v for k, v in os.environ.items() if not k.startswith("OPTIMAL_")}
        env["OPTIMAL_ENGINE_URL"] = self.e.url
        env["XDG_CONFIG_HOME"] = self.config_home
        if self.e.key:
            env["OPTIMAL_ENGINE_API_KEY"] = self.e.key
        proc = subprocess.run(
            [CLI, "--raw", *args], env=env, capture_output=True, text=True, timeout=180
        )
        expect(proc.returncode == 0, "optimal %s exited %d" % (args[0], proc.returncode))
        return json.loads(proc.stdout)

    def curl(self, path):
        cmd = ["curl", "-sS", "--max-time", "60", "-w", "\n%{http_code}"]
        stdin = None
        if self.e.key:
            cmd += ["-H", "@-"]
            stdin = "Authorization: Bearer %s\n" % self.e.key
        proc = subprocess.run(
            cmd + [self.e.url + path], input=stdin, capture_output=True, text=True, timeout=90
        )
        expect(proc.returncode == 0, "curl %s exited %d" % (path, proc.returncode))
        body, _, code = proc.stdout.rpartition("\n")
        expect(code == "200", "curl %s answered %s" % (path, code))
        return json.loads(body)

    def list_workspaces(self):
        found, offset = [], 0
        while True:
            status, body = self.e.call(
                "GET", "/api/workspaces", query={"status": "all", "offset": offset, "limit": 100}
            )
            body = self.ok(status, body, (200,), "listing workspaces")
            found += body["workspaces"]
            offset += len(body["workspaces"])
            if not body.get("pagination", {}).get("has_more") or not body["workspaces"]:
                return found

    # -- run -------------------------------------------------------------------

    def run(self):
        status, me = self.e.call("GET", "/api/auth/whoami")
        if status != 200:
            raise Unreachable("the key was refused (%s)" % status)
        scopes = me.get("scopes") or []
        if not ({"*", "admin"} & set(scopes)) or "*" not in (me.get("workspace_scope") or []):
            raise Unreachable("full mode needs an admin key for every workspace")
        self.tenant = me.get("tenant_id") or "default"

        # On a fresh Engine the empty state is the Engine's own; on an
        # existing one it is a workspace nobody has written to yet.
        empty = "default" if self.fresh else self.workspace("proof-empty-" + self.sfx, "Proof Empty")
        guarded("WO-41.1", lambda: self.empty_state(empty))
        # Before anything else creates organizations or principals, so a fresh
        # Engine's export is the imported document and nothing else.
        guarded("WO-41.4", self.topology)

        self.ops = self.workspace("proof-ops-" + self.sfx, "Proof Ops")
        self.other = self.workspace("proof-other-" + self.sfx, "Proof Other")

        guarded("WO-41.3", self.claim_principal)
        guarded("WO-44.1", self.mirror_contract)
        guarded("WO-44.2", self.rename_keeps_links)
        report(
            "WO-44.3",
            None,
            {"proven_by": "scripts/proof-engine-only.sh", "bound_seconds": 900},
        )
        guarded("WO-45.1", self.classification)
        guarded("WO-45.2", self.system_four)
        guarded("WO-45.3", self.metrics_history)
        guarded("WO-45.4", self.bandwidth)
        guarded("WO-45.5", self.action_chain)
        guarded("WO-41.2", self.open_loops_and_brief)
        guarded("READ-ONLY", self.read_only_smoke)
        guarded("WO-44.4", self.endpoint_audit)
        self.cleanup()

    # -- WO-41 -----------------------------------------------------------------

    def empty_state(self, ws):
        boot = self.cli("boot", ws)
        rhythm = self.cli("today", ws)
        loops = self.cli("loops", ws)
        fires = self.cli("fires", ws)
        brief = self.curl("/api/brief?" + urllib.parse.urlencode({"workspace": ws}))
        status, memory = self.e.call("GET", "/api/memory", query={"workspace": ws, "limit": 1})
        memory = self.ok(status, memory, (200,), "listing memories")
        status, signals = self.e.call("GET", "/api/signals/classification", query={"workspace": ws})
        signals = self.ok(status, signals, (200,), "counting signals")

        stale = boot["stale"]
        counts = {
            "boot_fires": len(boot["fires"]),
            "boot_open_loops": boot["open_loops"]["total"],
            "boot_loop_kinds": len(boot["open_loops"]["by_kind"]),
            "boot_recent_decisions": len(boot["recent_decisions"]),
            "boot_stale_loops": stale["loops_untouched_14_days"],
            "boot_stale_contexts": stale["contexts_past_valid_until"],
            "boot_brief_items": len(boot["brief"]["items"]),
            "loops": loops["count"],
            "loops_listed": len(loops["loops"]),
            "fires": len(fires),
            "brief_items": len(brief["items"]),
            "brief_open_loops": brief["open_loops"],
            "brief_categories": len(brief["counts"]),
            "memories": memory["pagination"].get("total", memory["count"])
            if isinstance(memory.get("pagination"), dict)
            else memory["count"],
            "signals": signals["signals"],
        }
        seeded = {name: n for name, n in counts.items() if n != 0}
        today = local_today(boot["timezone"])

        expect(not seeded, "the fresh workspace is not empty: %s" % seeded)
        expect(boot["date"] == today, "boot date %s is not today %s" % (boot["date"], today))
        expect(boot["rhythm"]["period"] == boot["date"], "the rhythm note is not today's")
        expect(rhythm["period"] == boot["date"], "optimal today is not today's note")
        expect(boot["protocol"]["content"], "no operating protocol is served")

        report(
            "WO-41.1",
            True,
            dict(
                counts,
                date=boot["date"],
                date_is_today=True,
                rhythm_period=rhythm["period"],
                protocol_source=boot["protocol"]["source"],
                workspace=ws,
                commands="optimal boot, optimal today, optimal loops, optimal fires, curl /api/brief",
            ),
        )

    def topology(self):
        s = self.sfx
        sent = {
            "schema_version": 1,
            "organizations": [
                {
                    "slug": "example-co-" + s,
                    "name": "Example Co",
                    "status": "active",
                    "role": "Operating company",
                    "workspaces": ["delivery-" + s, "sales-" + s],
                }
            ],
            "people": [
                {
                    "id": "user:jane-" + s,
                    "kind": "user",
                    "display_name": "Jane Example",
                    "workspaces": ["sales-" + s],
                }
            ],
        }
        # The same document as a topology/organizations.yaml file.
        yaml = "\n".join(
            [
                "schema_version: 1",
                "organizations:",
                "  - slug: example-co-%s" % s,
                "    name: Example Co",
                "    status: active",
                "    role: Operating company",
                "    workspaces: [delivery-%s, sales-%s]" % (s, s),
                "people:",
                '  - id: "user:jane-%s"' % s,
                "    kind: user",
                "    display_name: Jane Example",
                "    workspaces: [sales-%s]" % s,
                "",
            ]
        )

        status, body = self.e.call("POST", "/api/topology/import", {"yaml": yaml})
        self.ok(status, body, (200,), "importing the topology file")
        status, back = self.e.call("GET", "/api/topology/export")
        back = self.ok(status, back, (200,), "exporting the topology")

        def clean(value):
            if isinstance(value, dict):
                return {k: clean(v) for k, v in value.items() if v is not None}
            if isinstance(value, list):
                return [clean(v) for v in value]
            return value

        sent_c, back_c = clean(sent), clean(back)
        # Every tenant has a compatibility organization (slug "default") for
        # workspaces created before organizations were first-class.
        compat = [o for o in back_c.get("organizations", []) if o.get("slug") == "default"]
        orgs = [o for o in back_c.get("organizations", []) if o.get("slug") != "default"]

        if self.fresh:
            same = (
                orgs == sent_c["organizations"]
                and back_c.get("people") == sent_c["people"]
                and back_c.get("schema_version") == 1
            )
        else:
            same = all(o in orgs for o in sent_c["organizations"]) and all(
                p in back_c.get("people", []) for p in sent_c["people"]
            )

        if not same:
            print("sent: " + json.dumps(sent_c, sort_keys=True))
            print("back: " + json.dumps({"organizations": orgs, "people": back_c.get("people")}, sort_keys=True))
        expect(same, "the exported topology differs from the imported file")

        # Export as YAML, import that file again: the Engine's own file round trips.
        status, text = self.e.call("GET", "/api/topology/export", query={"format": "yaml"})
        expect(status == 200 and isinstance(text, str), "the YAML export failed")
        status, body = self.e.call("POST", "/api/topology/import", {"yaml": text})
        self.ok(status, body, (200,), "importing the exported YAML")
        status, again = self.e.call("GET", "/api/topology/export")
        expect(clean(again) == back_c, "importing the exported YAML changed the topology")

        # The import created these workspaces; they are this proof's to remove.
        for slug in sent["organizations"][0]["workspaces"]:
            ws_id = "%s:%s" % (self.tenant, slug)
            status, _ = self.e.call("GET", "/api/workspaces/" + urllib.parse.quote(ws_id, safe=":"))
            if status == 200:
                self.created.append(ws_id)

        report(
            "WO-41.4",
            True,
            {
                "topology_match": True,
                "compared": "exact" if self.fresh else "imported entries present verbatim",
                "organizations_sent": len(sent_c["organizations"]),
                "organizations_back": len(orgs),
                "people_sent": len(sent_c["people"]),
                "people_back": len(back_c.get("people", [])),
                "workspaces_sent": sum(len(o["workspaces"]) for o in sent_c["organizations"]),
                "compatibility_orgs": len(compat),
                "yaml_round_trip": True,
            },
        )

    def claim_principal(self):
        writer_id = "agent:proof-writer-" + self.sfx
        reviewer_id = "agent:proof-reviewer-" + self.sfx
        writer = self.mint(writer_id, "agent", ["read", "write"], [self.ops])
        reviewer = self.mint(reviewer_id, "agent", ["read", "claims:review"], [self.ops])

        def claim_for(content):
            status, body = self.e.call(
                "POST", "/api/memory", {"content": content, "workspace": self.ops}, key=writer
            )
            self.ok(status, body, (201,), "writing a memory")
            status, body = self.e.call(
                "GET",
                "/api/memory-core/claims",
                query={"workspace": self.ops, "limit": 200},
                key=reviewer,
            )
            body = self.ok(status, body, (200,), "listing claims")
            matches = [c for c in body["claims"] if c.get("claim_text") == content]
            expect(matches, "the memory left no pending claim")
            return matches[0]["id"]

        claim = claim_for("The supplier renewal moved to the 14th (%s)." % self.sfx)
        path = "/api/memory-core/claims/%s/promote" % claim

        impersonation, _ = self.e.call(
            "POST", path, {"workspace": self.ops, "verifier_id": "user:someone-else"}, key=reviewer
        )
        expect(impersonation == 403, "a reviewer named someone else as verifier (%s)" % impersonation)
        by_writer, _ = self.e.call("POST", path, {"workspace": self.ops}, key=writer)
        expect(by_writer == 403, "a writer key promoted a claim (%s)" % by_writer)

        status, body = self.e.call("POST", path, {"workspace": self.ops}, key=reviewer)
        body = self.ok(status, body, (200,), "promoting the claim")
        verifier = body["fact"]["verifier_id"]
        expect(verifier == reviewer_id, "the fact records %s, not the key's principal" % verifier)

        # Governed recall now holds the reviewed Fact.
        status, ctx = self.e.call(
            "POST", "/api/assemble", {"query": "supplier renewal", "workspace": self.ops}, key=reviewer
        )
        ctx = self.ok(status, ctx, (200,), "assembling context after the promotion")

        report(
            "WO-41.3",
            True,
            {
                "verifier_recorded": verifier,
                "key_principal": reviewer_id,
                "recorded_equals_key_principal": verifier == reviewer_id,
                "client_named_verifier_status": impersonation,
                "writer_key_promote_status": by_writer,
                "assemble_facts_after_promotion": bool((ctx.get("l1") or "").strip()),
                "assemble_sources_after_promotion": len(ctx.get("sources") or []),
            },
        )

    def open_loops_and_brief(self):
        # The live criterion runs on an owner's Engine (read-only mode); here
        # the same reads run on loops this proof creates, with sources.
        due = date.fromordinal(date.today().toordinal() + 2).isoformat()
        for n in range(2):
            status, body = self.e.call(
                "POST",
                "/api/loops",
                {
                    "workspace": self.ops,
                    "title": "Reply about the renewal terms %d" % n,
                    "kind": "owed_reply",
                    "counterparty": "user:jane-" + self.sfx,
                    "due_at": due,
                    "source_uri": "optimal://inbox/proof-%s-%d.md" % (self.sfx, n),
                },
            )
            self.ok(status, body, (201,), "creating an owed reply")

        facts = boot_and_brief(self.e, self.ops)
        expect(facts["date_is_today"], "boot is not on today's date")
        expect(facts["open_loops"] >= 2, "boot does not show the open loops")
        expect(facts["owed_replies_in_brief"] >= 2, "the brief does not list the owed replies")
        expect(
            facts["owed_replies_with_sources"] == facts["owed_replies_in_brief"],
            "an owed reply in the brief has no source",
        )
        report("WO-41.2", True, dict(facts, scope="loops this proof created"))

    # -- WO-44 -----------------------------------------------------------------

    def mirror_contract(self):
        slug = "proof-mirror-" + self.sfx
        started = time.time()
        self.mirror = self.workspace(slug, "Proof Mirror")
        row = next((w for w in self.list_workspaces() if w.get("slug") == slug), None)
        visible_ms = int((time.time() - started) * 1000)
        expect(row and row["id"] == self.mirror, "the workspace is not listed under its slug")
        expect(row["name"] == "Proof Mirror", "the listed name differs")

        member = "user:proof-member-" + self.sfx
        first = self.principal(member, "user", "Proof Member")
        second = self.principal(member, "user", "Proof Member")
        expect(first.get("id") == second.get("id") == member, "the principal upsert is not stable")
        status, got = self.e.call("GET", "/api/principals/" + urllib.parse.quote(member, safe=":"))
        self.ok(status, got, (200,), "reading the principal")

        status, listed = self.e.call("GET", "/api/principals", query={"kind": "user"})
        listed = self.ok(status, listed, (200,), "listing principals")
        expect(
            any(p.get("id") == member for p in listed["principals"]),
            "the member is not listed among the Engine's principals",
        )

        # Membership travels as the people section of a topology document.
        status, body = self.e.call(
            "POST",
            "/api/topology/import",
            {
                "schema_version": 1,
                "people": [
                    {"id": member, "kind": "user", "display_name": "Proof Member", "workspaces": [slug]}
                ],
            },
        )
        self.ok(status, body, (200,), "importing the member's workspaces")
        status, exported = self.e.call("GET", "/api/topology/export")
        exported = self.ok(status, exported, (200,), "exporting the topology")
        entry = next((p for p in exported.get("people", []) if p.get("id") == member), {})
        expect(entry.get("workspaces") == [slug], "the member is not a member of the workspace")

        key = self.mint(member, "user", ["read", "write"], [self.mirror])
        status, me = self.e.call("GET", "/api/auth/whoami", key=key)
        me = self.ok(status, me, (200,), "whoami")
        expect(me["principal_id"] == member, "the key acts as %s" % me["principal_id"])
        expect(me["workspace_scope"] == [self.mirror], "the key's workspace scope differs")

        own, _ = self.e.call("GET", "/api/boot", query={"workspace": self.mirror}, key=key)
        foreign, _ = self.e.call("GET", "/api/boot", query={"workspace": self.ops}, key=key)
        expect(own == 200, "the member cannot boot its workspace (%s)" % own)
        expect(foreign == 403, "the member reached another workspace (%s)" % foreign)

        text = (
            "Renewal call with the supplier moved to the 14th; the contract review is "
            "still open and legal owes the redline by Friday."
        )
        status, ingested = self.e.call(
            "POST",
            "/api/ingest",
            {"text": text, "workspace": self.mirror, "title": "Supplier renewal call"},
            key=key,
        )
        ingested = self.ok(status, ingested, (200,), "capturing a source")
        self.mirror_signal = ingested["signal_id"]
        self.mirror_key = key

        # An agent asks for workspace context: /api/rag cites the captured
        # source itself; /api/assemble is governed recall and cites only
        # reviewed Facts and Memory Objects, so a fresh source shows up there
        # once its claims are promoted.
        status, rag = self.e.call(
            "POST",
            "/api/rag",
            {"query": "supplier renewal", "workspace": self.mirror, "skip_intent": True},
            key=key,
        )
        rag = self.ok(status, rag, (200,), "asking for workspace context")
        cited = (rag.get("envelope") or {}).get("sources") or []
        expect(cited, "the answer cites no source")
        expect(
            all(isinstance(u, str) and u.startswith("optimal://") for u in cited),
            "a citation is not an optimal:// link",
        )
        status, ctx = self.e.call(
            "POST", "/api/assemble", {"query": "supplier renewal", "workspace": self.mirror}, key=key
        )
        ctx = self.ok(status, ctx, (200,), "assembling context")

        report(
            "WO-44.1",
            True,
            {
                "workspace_listed_ms": visible_ms,
                "slug_kept": True,
                "principal_upsert_idempotent": True,
                "member_listed_as_principal": True,
                "principals_listed": len(listed["principals"]),
                "member_workspaces": entry["workspaces"],
                "key_principal": member,
                "key_workspace_scope": me["workspace_scope"],
                "own_workspace_status": own,
                "other_workspace_status": foreign,
                "rag_source": rag.get("source"),
                "rag_citations": len(cited),
                "assemble_governed_sources": len(ctx.get("sources") or []),
            },
        )

    def rename_keeps_links(self):
        status, read = self.e.call(
            "GET", "/api/read", query={"id": self.mirror_signal, "workspace": self.mirror}
        )
        read = self.ok(status, read, (200,), "reading the source by id")
        uri = read["uri"]
        expect(uri and uri.startswith("optimal://"), "the source has no optimal:// URI")
        old_slug = "proof-mirror-" + self.sfx
        new_slug = "proof-mirror-renamed-" + self.sfx
        # The workspace-qualified form of the source's link, written before the rename.
        old_link = "optimal://%s/%s" % (self.mirror, uri[len("optimal://"):])

        status, body = self.e.call(
            "PATCH",
            "/api/workspaces/" + urllib.parse.quote(self.mirror, safe=":"),
            {"name": "Proof Mirror Renamed", "slug": new_slug},
        )
        body = self.ok(status, body, (200,), "renaming the workspace")
        row = next(w for w in self.list_workspaces() if w["id"] == self.mirror)
        expect(row["slug"] == new_slug, "the slug is %s after the rename" % row["slug"])
        expect(row["name"] == "Proof Mirror Renamed", "the name did not change")
        expect(row["id"] == self.mirror, "the id changed on rename")

        status, again = self.e.call("GET", "/api/read", query={"uri": uri, "workspace": self.mirror})
        again = self.ok(status, again, (200,), "reading the old link after the rename")
        expect(again["id"] == self.mirror_signal, "the old link resolves to another context")

        resolved = {}
        for name, link in [
            ("old_link", old_link),
            ("new_slug_link", "optimal://%s:%s/%s" % (self.tenant, new_slug, uri[len("optimal://"):])),
        ]:
            status, out = self.e.call("GET", "/api/resolve", query={"uri": link})
            out = self.ok(status, out, (200,), "resolving the %s" % name)
            expect(out.get("status") == "local" and out.get("uri") == old_link, "%s resolves to %s" % (name, out))
            resolved[name] = out["status"]

        # A request that builds an id from the new slug is told the real id.
        status, told = self.e.call(
            "GET", "/api/boot", query={"workspace": "%s:%s" % (self.tenant, new_slug)}, key=self.mirror_key
        )
        expect(
            status == 409 and (told or {}).get("workspace_id") == self.mirror,
            "naming the new slug as a workspace answered %s" % status,
        )
        status, taken = self.e.call("POST", "/api/workspaces", {"slug": old_slug, "name": "Taken"})
        expect(status == 409, "the old slug was given to another workspace (%s)" % status)

        report(
            "WO-44.2",
            True,
            {
                "slug_before": old_slug,
                "slug_after": row["slug"],
                "id_kept": True,
                "name_updated": True,
                "old_link_reads": True,
                "resolve_old_link": resolved["old_link"],
                "resolve_new_slug_link": resolved["new_slug_link"],
                "new_slug_as_workspace_status": 409,
                "old_slug_reuse_status": status,
            },
        )

    def endpoint_audit(self):
        rows = reference_rows()
        unclassified = [r for r in rows if not r["grant"] or r["workspace"] not in ("workspace", "tenant")]
        documented = {(m, r["path"]) for r in rows for m in r["methods"]}
        paths = {r["path"] for r in rows}
        missing = [m + " " + p for m, p in BUSINESSOS_ROUTES if (m, p) not in documented]
        missing += [p for p in BUSINESSOS_PATHS if p not in paths]
        missing += [
            p + "*" for p in BUSINESSOS_PREFIXES if not any(x.startswith(p) for x in paths)
        ]
        businessos_total = len(BUSINESSOS_ROUTES) + len(BUSINESSOS_PATHS) + len(BUSINESSOS_PREFIXES)

        # Never send an unauthenticated mutation to an Engine that is open.
        guard, _ = self.e.call("GET", "/api/health", key=None)
        expect(guard in (401, 429), "the Engine answers without a key (%s); auth is not required" % guard)

        answered, refused = [], {}
        for row in rows:
            path = re.sub(r":[a-z_]+", "proof", row["path"])
            for method in row["methods"]:
                body = None if method == "GET" else {}
                status, _ = self.e.call(method, path, body, key=None, timeout=30)
                refused[status] = refused.get(status, 0) + 1
                if status not in (401, 429):
                    answered.append("%s %s=%s" % (method, row["path"], status))

        forged = 0
        for row in rows:
            if "GET" in row["methods"]:
                path = re.sub(r":[a-z_]+", "proof", row["path"])
                status, _ = self.e.call("GET", path, key="oe_proof_invalid", timeout=30)
                forged += 1
                if status not in (401, 429):
                    answered.append("GET %s with an invalid key=%s" % (row["path"], status))

        facts = {
            "documented_routes": sum(len(r["methods"]) for r in rows),
            "unclassified": len(unclassified),
            "businessos_documented": "%d/%d" % (businessos_total - len(missing), businessos_total),
            "businessos_missing": missing,
            "no_key_statuses": refused,
            "invalid_key_requests": forged,
            "answered_without_a_valid_key": answered[:20],
        }
        ok = not unclassified and not missing and not answered
        report("WO-44.4", ok, facts)

    # -- WO-45 -----------------------------------------------------------------

    def classification(self):
        writer = self.mint("agent:proof-intake-" + self.sfx, "agent", ["read", "write"], [self.ops])
        samples = [
            (
                "transcript",
                "Speaker 1: Thanks for joining, we review the import plan today.\n"
                "Speaker 2: Staging is done and the dry run passed.\n"
                "Speaker 1: Then we schedule production for Thursday.",
            ),
            (
                "transcript",
                "Host: Let us start with the renewal.\nGuest: The supplier wants two more weeks.\n"
                "Host: Fine, we confirm on Monday.",
            ),
            ("message", "hey, can you send the deck before friday? thanks a lot"),
        ]
        for genre, text in samples:
            status, body = self.e.call(
                "POST",
                "/api/ingest",
                {"text": text, "workspace": self.ops, "genre": genre, "title": "Proof " + genre},
                key=writer,
            )
            self.ok(status, body, (200,), "capturing a %s" % genre)

        facts = classification_facts(self.e, self.ops, plan=True)
        expect(facts["status"] == 200, "GET /api/signals/classification answered %s" % facts["status"])
        expect(facts["transcript_signals"] >= 2, "the transcripts were not stored as transcripts")
        expect(facts["transcript_linguistic_planned"] >= 0.95, "transcripts do not read as linguistic")
        expect(facts["transcript_linguistic_stored"] >= 0.95, "intake did not store transcripts as linguistic")
        if facts["chat_signals"]:
            expect(facts["chat_linguistic_planned"] >= 0.95, "chats do not read as linguistic")
        report("WO-45.1", True, dict(facts, evaluation_set="mix test test/signal/mode_genre_eval_test.exs"))

    def system_four(self):
        status, before = self.e.call("GET", "/api/viability", query={"workspace": self.other})
        before = self.ok(status, before, (200,), "the viability report")
        s4 = system(before, "s4")
        expect(s4["status"] == "missing", "System 4 is %s with no outward Signals" % s4["status"])
        failure = (s4.get("predicted_failure") or {}).get("failure")
        expect(failure == "Blindsided by change.", "the predicted failure is %r" % failure)

        status, body = self.e.call(
            "POST", "/api/signal-events", {"workspace": self.other, "kind": "outward", "topic": "market"}
        )
        self.ok(status, body, (201,), "tagging an outward Signal")
        status, after = self.e.call("GET", "/api/viability", query={"workspace": self.other})
        after = self.ok(status, after, (200,), "the viability report")
        expect(system(after, "s4")["status"] == "present", "an outward Signal did not make System 4 present")

        report(
            "WO-45.2",
            True,
            {
                "s4_without_outward_signals": "missing",
                "predicted_failure": failure,
                "s4_after_one_outward_signal": "present",
                "verdict": after["summary"]["verdict"],
                "note": "the dated diagnosis on an owner's Engine is the read-only run",
            },
        )

    def metrics_history(self):
        status, body = self.e.call(
            "PUT",
            "/api/protocol",
            {
                "workspace": self.ops,
                "kind": "repertoire",
                "content": "- note\n- message\n- email\n- transcript/linguistic",
            },
        )
        self.ok(status, body, (200,), "declaring a repertoire")
        status, body = self.e.call("POST", "/api/viability/snapshot", {"workspace": self.ops, "days": 30})
        self.ok(status, body, (200,), "snapshotting 30 days")

        facts = metrics_facts(self.e, self.ops)
        expect(facts["metrics_returned"] == 6, "the report has %s metrics" % facts["metrics_returned"])
        expect(facts["r"] is not None, "R is not measured (%s)" % facts["r_status"])
        expect(facts["history_days"] == 30 and facts["history_missing_days"] == 0, "the history is not 30 days")
        expect(facts["history_days_with_six_metrics_and_r"] == 30, "a stored day lacks a metric or R")
        report("WO-45.3", True, facts)

    def bandwidth(self):
        sentence = "We reviewed the renewal terms, the delivery dates and the open invoice in detail. "
        text = "Can you confirm the renewal by Friday? " + sentence * 150
        draft = " ".join(text.split()[:2000])
        status, body = self.e.call(
            "POST",
            "/api/signals/check",
            {"workspace": self.ops, "draft": draft, "receiver": {"channel": "whatsapp"}, "type": "direct"},
        )
        body = self.ok(status, body, (200,), "the pre-send check")
        flag = next((f for f in body["flags"] if f["code"] == "bandwidth_overload"), None)
        expect(flag, "a %d-word WhatsApp draft was not flagged" % words(draft))
        shorter = words(flag.get("shorter"))
        expect(0 < shorter <= 150, "the shorter version has %d words" % shorter)

        report(
            "WO-45.4",
            True,
            {
                "draft_words": body["words"],
                "receiver": "whatsapp",
                "flag": flag["code"],
                "constraint": flag["constraint"],
                "shorter_words": shorter,
            },
        )

    def action_chain(self):
        agent = self.mint("agent:proof-mailer-" + self.sfx, "agent", ["read", "write"], [self.ops])
        approver = self.mint(
            "service:proof-approvals-" + self.sfx, "service", ["read", "write", "authority:enforce"], [self.ops]
        )

        def step(key, body):
            status, out = self.e.call("POST", "/api/agent-actions", dict(body, workspace=self.ops), key=key)
            return status, out

        status, request = step(
            agent,
            {
                "stage": "request",
                "agent": "agent:proof-mailer-" + self.sfx,
                "action": "email.send",
                "resource": "optimal://outbox/proof-%s" % self.sfx,
                "summary": "Send the renewal reply.",
            },
        )
        request = self.ok(status, request, (201,), "recording the request")
        corr = request["correlation_id"]

        denied, _ = step(agent, {"stage": "approval", "correlation_id": corr})
        expect(denied == 403, "an agent key recorded its own approval (%s)" % denied)

        for key, stage in [(approver, "approval"), (agent, "action"), (agent, "result"), (agent, "reply")]:
            status, out = step(key, {"stage": stage, "correlation_id": corr})
            self.ok(status, out, (201,), "recording the " + stage)

        status, chain = self.e.call("GET", "/api/agent-actions/" + corr, query={"workspace": self.ops})
        chain = self.ok(status, chain, (200,), "tracing the chain")
        steps = [s for s in chain["steps"] if s.get("source") == "reported"]
        stages = [s["stage"] for s in steps]
        expect(stages == ["request", "approval", "action", "result", "reply"], "stages are %s" % stages)
        linked = all(steps[i]["causation_id"] == steps[i - 1]["id"] for i in range(1, len(steps)))
        expect(linked, "a step does not point at the step before it")
        expect(chain["complete"] is True, "the chain is not complete")

        signals = 0
        for s in steps:
            status, ctx = self.e.call("GET", "/api/read", query={"id": s["context_id"], "workspace": self.ops})
            if status == 200:
                signals += 1
        expect(signals == len(steps), "only %d of %d steps are Engine Signals" % (signals, len(steps)))

        report(
            "WO-45.5",
            True,
            {
                "stages": stages,
                "linked_by_causation": linked,
                "complete": chain["complete"],
                "verified": chain.get("verified"),
                "steps_as_signals": signals,
                "agent_self_approval_status": denied,
            },
        )

    # -- read-only mode, exercised on this Engine ----------------------------

    def read_only_smoke(self):
        ro = Engine(self.e.url, self.e.key, read_only=True)
        before = len(RESULTS)
        read_only_checks(ro, self.ops, prefix="smoke:", plan=True, tenant=self.tenant)
        smoke = RESULTS[before:]
        del RESULTS[before:]
        crashed = [cid for cid, _status, facts in smoke if "error" in facts]
        others = sum(n for m, n in ro.sent.items() if m != "GET")
        expect(not crashed and others == 0, "read-only checks crashed: %s" % crashed)
        report(
            "READ-ONLY",
            True,
            {"checks_run": len(smoke), "get_requests": ro.sent.get("GET", 0), "other_requests": others},
        )

    def cleanup(self):
        """On a shared Engine, remove exactly what this run created, by the ids it recorded.

        The Engine's workspace delete is the archive (rows and files stay
        until a retention sweep); keys are revoked. Principals have no
        removal route, so they are counted.
        """
        if os.environ.get("KEEP") == "1" or self.fresh:
            return
        revoked = 0
        for key_id in self.minted:
            status, _ = self.e.call("POST", "/api/auth/keys/%s/revoke" % key_id, {})
            revoked += status == 204
        archived = 0
        for ws in self.created:
            path = "/api/workspaces/%s" % urllib.parse.quote(ws, safe=":")
            self.e.call("POST", path + "/archive", {})
            status, row = self.e.call("GET", path)
            archived += status == 200 and (row or {}).get("status") == "archived"
        print(
            "CLEANUP keys_revoked=%d/%d workspaces_archived_by_id=%d/%d workspace_ids=%s"
            % (revoked, len(self.minted), archived, len(self.created), json.dumps(self.created)),
            flush=True,
        )


# ---------------------------------------------------------------------------
# Shared readers (every one sends GET requests only)
# ---------------------------------------------------------------------------


def system(report_body, system_id):
    return next(s for s in report_body["systems"] if s["id"] == system_id)


# The outward topics the Engine names; a writer's own topic counts as "other".
OUTWARD_TOPICS = {"market", "customers", "competitors", "technology", "risk", "regulation", "partners"}


def topics(counts):
    shown = {}
    for topic, n in counts.items():
        name = topic if topic in OUTWARD_TOPICS else "other"
        shown[name] = shown.get(name, 0) + n
    return shown


def share(modes, mode):
    total = sum(modes.values())
    return round(modes.get(mode, 0) / total, 4) if total else None


def boot_and_brief(engine, ws, boot=True):
    """Today's date, open loops, and the owed replies the brief lists.

    With `boot`, the date is the workspace's own (time zone) and comes from
    GET /api/boot?generate=false, which reads today's rhythm note without
    writing it on an Engine that knows the option. Without it, the date is
    the brief's (UTC) and the loops come from GET /api/loops.
    """
    status, brief = engine.call("GET", "/api/brief", query={"workspace": ws, "limit": 200})
    expect(status == 200, "GET /api/brief answered %s" % status)

    if boot:
        status, body = engine.call(
            "GET", "/api/boot", query={"workspace": ws, "generate": "false"}
        )
        expect(status == 200, "GET /api/boot answered %s" % status)
        day = {
            "date": body["date"],
            "date_basis": "workspace time zone (boot)",
            "date_is_today": body["date"] == local_today(body["timezone"]),
            "open_loops": body["open_loops"]["total"],
            "open_loops_by_kind": body["open_loops"]["by_kind"],
            "fires": len(body["fires"]),
            "recent_decisions": len(body["recent_decisions"]),
            "rhythm_note_stored_before": body["rhythm"].get("stored"),
        }
    else:
        status, loops = engine.call(
            "GET", "/api/loops", query={"workspace": ws, "state": "open", "limit": 1000}
        )
        expect(status == 200, "GET /api/loops answered %s" % status)
        by_kind = {}
        for loop in loops["loops"]:
            by_kind[loop.get("kind")] = by_kind.get(loop.get("kind"), 0) + 1
        day = {
            "date": brief["date"],
            "date_basis": "UTC (brief; BOOT=1 reads boot)",
            "date_is_today": brief["date"] == datetime.now(timezone.utc).date().isoformat(),
            "open_loops": loops["count"],
            "open_loops_by_kind": by_kind,
        }

    owed = [i for i in brief["items"] if i.get("kind") == "owed_reply"]
    with_sources = [i for i in owed if i.get("sources")]
    cited = all(
        isinstance(src, str) and src.startswith("optimal://") for i in with_sources for src in i["sources"]
    )
    day.update(
        {
            "brief_items": len(brief["items"]),
            "brief_by_category": brief["counts"],
            "owed_replies_in_brief": len(owed),
            "owed_replies_with_sources": len(with_sources),
            "sources_are_optimal_uris": cited,
        }
    )
    return day


def classification_facts(engine, ws, plan):
    status, body = engine.call(
        "GET", "/api/signals/classification", query={"workspace": ws, "plan": "true" if plan else None}
    )
    if status != 200:
        return {"status": status}

    stored = body["stored"]
    by_stored = (body.get("plan") or {}).get("planned_modes_by_stored_genre") or {}
    chats = {}
    planned_chats = {}
    for genre in ("chat", "message"):
        for mode, n in stored.get(genre, {}).items():
            chats[mode] = chats.get(mode, 0) + n
        for mode, n in by_stored.get(genre, {}).items():
            planned_chats[mode] = planned_chats.get(mode, 0) + n

    facts = {
        "status": 200,
        "signals": body["signals"],
        "transcript_signals": sum(stored.get("transcript", {}).values()),
        "transcript_linguistic_stored": share(stored.get("transcript", {}), "linguistic"),
        "chat_signals": sum(chats.values()),
        "chat_linguistic_stored": share(chats, "linguistic"),
    }
    for genre in ("email", "note"):
        facts[genre + "_linguistic_stored"] = share(stored.get(genre, {}), "linguistic")
    if plan and body.get("plan"):
        facts.update(
            {
                "transcript_linguistic_planned": share(by_stored.get("transcript", {}), "linguistic"),
                "chat_linguistic_planned": share(planned_chats, "linguistic"),
                "reclassify_would_change": body["plan"]["changes"],
            }
        )
    return facts


def metrics_facts(engine, ws):
    status, rep = engine.call("GET", "/api/viability", query={"workspace": ws})
    expect(status == 200, "GET /api/viability answered %s" % status)
    status, hist = engine.call("GET", "/api/viability/history", query={"workspace": ws, "days": 30})
    expect(status == 200, "GET /api/viability/history answered %s" % status)

    metrics = {m["name"]: m.get("value") for m in rep["metrics"]}
    snapshots = hist["snapshots"]
    complete = [
        s
        for s in snapshots
        if set(SIX_METRICS) <= set((s.get("metrics") or {}).keys()) and "r" in s
    ]
    variety = rep["variety"]
    return {
        "metrics_returned": len([n for n in SIX_METRICS if n in metrics]),
        "metrics": {n: metrics.get(n) for n in SIX_METRICS},
        "r": variety.get("r"),
        "r_band": variety.get("band"),
        "r_status": variety.get("status"),
        "v_system": variety.get("v_system"),
        "v_disturbance": variety.get("v_disturbance"),
        "coverage": variety.get("coverage"),
        "history_days": len(snapshots),
        "history_missing_days": len(hist["missing"]),
        "history_backfilled_days": len([s for s in snapshots if s.get("backfilled")]),
        "history_days_with_six_metrics_and_r": len(complete),
        "history_days_with_measured_r": len([s for s in snapshots if s.get("r") is not None]),
    }


def chain_facts(engine, ws):
    status, body = engine.call("GET", "/api/agent-actions", query={"workspace": ws, "limit": 50})
    expect(status == 200, "GET /api/agent-actions answered %s" % status)
    chains = body["chains"]
    full_chains = 0
    linked_full = 0
    for chain in chains[:20]:
        status, trace = engine.call(
            "GET",
            "/api/agent-actions/" + urllib.parse.quote(chain["correlation_id"], safe=":"),
            query={"workspace": ws},
        )
        if status != 200:
            continue
        steps = [s for s in trace["steps"] if s.get("source") == "reported"]
        stages = {s["stage"] for s in steps}
        if {"request", "approval", "action", "result", "reply"} <= stages:
            full_chains += 1
            if all(steps[i].get("causation_id") == steps[i - 1].get("id") for i in range(1, len(steps))):
                linked_full += 1
    return {
        "chains": len(chains),
        "complete_chains": len([c for c in chains if c.get("complete")]),
        "chains_with_request_approval_send_reply": full_chains,
        "of_those_linked_step_to_step": linked_full,
    }


def read_only_checks(engine, ws, prefix="", plan=True, tenant=None):
    """The read-only criteria for one workspace. Every line names the tenant
    and the workspace it read, and carries only counts, dates, metric values,
    booleans, and Engine-defined labels."""
    private = not prefix

    def say(check_id, outcome, facts):
        report(prefix + check_id, outcome, dict({"tenant": tenant, "workspace": ws}, **facts))

    def wo41_2():
        facts = boot_and_brief(engine, ws, boot=os.environ.get("BOOT") == "1")
        ok = (
            facts["date_is_today"]
            and facts["open_loops"] > 0
            and facts["owed_replies_in_brief"] > 0
            and facts["owed_replies_with_sources"] == facts["owed_replies_in_brief"]
            and facts["sources_are_optimal_uris"]
        )
        say("WO-41.2", ok, facts)

    def wo45_1():
        facts = classification_facts(engine, ws, plan)
        if facts["status"] == 404:
            say("WO-45.1", None, {"status": 404, "reason": "this Engine has no GET /api/signals/classification yet"})
            return
        expect(facts["status"] == 200, "classification answered %s" % facts["status"])
        key = "_planned" if plan else "_stored"
        shares = [facts.get("transcript_linguistic" + key), facts.get("chat_linguistic" + key)]
        measured = [s for s in shares if s is not None]
        ok = bool(measured) and all(s >= 0.95 for s in measured)
        say("WO-45.1", ok, dict(facts, evaluation_set="CI: test/signal/mode_genre_eval_test.exs"))

    def wo45_2():
        status, rep = engine.call("GET", "/api/viability", query={"workspace": ws})
        expect(status == 200, "GET /api/viability answered %s" % status)
        s4 = system(rep, "s4")
        evidence = " ".join(str(e) for e in s4.get("evidence") or [])
        last = re.search(r"last: (\d{4}-\d{2}-\d{2})", evidence)
        never = "last: never" in evidence
        alerts = rep["trajectory"]["alerts"]
        failure = (s4.get("predicted_failure") or {}).get("failure")
        facts = {
            "verdict": rep["summary"]["verdict"],
            "systems": {s["id"]: s["status"] for s in rep["systems"]},
            "s4_status": s4["status"],
            "s4_predicted_failure": failure,
            "s4_last_outward_signal": last.group(1) if last else ("never" if never else None),
            "s4_topics": topics(s4.get("topics") or {}),
            "signals_received_7_days": rep.get("signals_received"),
            "trajectory_alerts": len(alerts),
            "trajectory_metric_and_flow_alerts": sorted(
                a["subject"] for a in alerts if a.get("kind") in ("metric", "flow")
            ),
            "trajectory_unit_alerts": len([a for a in alerts if a.get("kind") not in ("metric", "flow")]),
        }
        say("WO-45.2", s4["status"] == "missing" and failure == "Blindsided by change.", facts)

    def wo45_3():
        facts = metrics_facts(engine, ws)
        ok = (
            facts["metrics_returned"] == 6
            and facts["history_days"] == 30
            and facts["history_days_with_six_metrics_and_r"] == 30
        )
        say("WO-45.3", ok, facts)

    def wo45_5():
        facts = chain_facts(engine, ws)
        say("WO-45.5", facts["of_those_linked_step_to_step"] > 0, facts)

    guarded(prefix + "WO-41.2", wo41_2, private)
    guarded(prefix + "WO-45.1", wo45_1, private)
    guarded(prefix + "WO-45.2", wo45_2, private)
    guarded(prefix + "WO-45.3", wo45_3, private)
    say("WO-45.4", None, {"reason": "the pre-send check is a POST; full mode proves it"})
    guarded(prefix + "WO-45.5", wo45_5, private)


def reference_rows():
    rows = []
    with open(REFERENCE) as handle:
        for line in handle:
            if not line.startswith("| ") or line.startswith("| Method") or line.startswith("| ---"):
                continue
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) < 3:
                continue
            rows.append(
                {
                    "methods": [m.strip() for m in cells[0].split(",")],
                    "path": cells[1].strip("`"),
                    "grant": cells[3] if len(cells) > 3 else "",
                    "workspace": cells[4] if len(cells) > 4 else "",
                }
            )
    return rows


# ---------------------------------------------------------------------------


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "full"
    url = os.environ.get("ENGINE_URL", "")
    key = os.environ.get("PROOF_ENGINE_KEY", "")
    started = time.time()

    try:
        if mode == "read-only":
            ws = os.environ.get("WORKSPACE") or "default"
            engine = Engine(url, key, read_only=True)
            status, version = engine.call("GET", "/api/version")
            if status in (401, 403):
                raise Unreachable("the Engine refused the key (%s)" % status)
            status, me = engine.call("GET", "/api/auth/whoami")
            tenant = (me or {}).get("tenant_id") if status == 200 else "unknown"
            print(
                "ENGINE version=%s mode=read-only tenant=%s workspace=%s"
                % ((version or {}).get("version"), tenant, ws),
                flush=True,
            )
            read_only_checks(
                engine, ws, plan=os.environ.get("CLASSIFY_PLAN", "1") != "0", tenant=tenant
            )
            print("REQUESTS GET=%d other=%d" % (engine.sent.get("GET", 0), sum(n for m, n in engine.sent.items() if m != "GET")))
        else:
            engine = Engine(url, key, read_only=False)
            status, version = engine.call("GET", "/api/version")
            if status in (401, 403):
                raise Unreachable("the Engine refused the key (%s)" % status)
            print("ENGINE version=%s mode=full fresh=%s" % ((version or {}).get("version"), os.environ.get("PROOF_FRESH") == "1"), flush=True)
            Full(engine, fresh=os.environ.get("PROOF_FRESH") == "1").run()
    except Unreachable as err:
        print("UNREACHABLE %s" % err, flush=True)
        return 2
    except Exception as err:  # noqa: BLE001 - setup failed before the checks could run
        reason = type(err).__name__ if mode == "read-only" else "%s: %s" % (type(err).__name__, err)
        print("ERROR %s" % reason[:300], flush=True)
        return 1

    failed = [cid for cid, status, _facts in RESULTS if status == "FAIL"]
    passed = len([1 for _cid, status, _facts in RESULTS if status == "PASS"])
    skipped = len([1 for _cid, status, _facts in RESULTS if status == "SKIP"])
    print("SUMMARY passed=%d failed=%d skipped=%d seconds=%d" % (passed, len(failed), skipped, time.time() - started))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
