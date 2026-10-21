#!/usr/bin/env python3
"""Checks for scripts/proof-relay-client.sh (WO-43, WO-46). Standard library only.

  run [--stand-in]   run the checks against the Engines the shell script started
  redact SECRETS     copy stdin to stdout with every key replaced; exit 3 if one appeared
  mint-key           print the key from `mix optimal.auth mint --json` output on stdin

The laptop Engine reaches the relay only through a local gate that forwards
every request unchanged. Stopping the gate is how the relay becomes
unreachable, its request log (method, path, workspace, body, never headers) is
the evidence of what left the laptop, and its skew switch makes the relay
report another schema migration so the client's pause can be observed.

In --stand-in mode a relay stand-in in front of the second (cloud) Engine
implements the MIOSA relay contract, so the checks run with no MIOSA account.
"""

import datetime
import hashlib
import http.server
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

SECRET_ENV = ("MIOSA_API_KEY", "CLOUD_ENGINE_KEY", "LAPTOP_KEY", "CONNECTOR_KEY", "OPTIMAL_AUTHORITY_KEY")
FORWARDED_HEADERS = ("authorization", "content-type", "accept", "x-optimal-replica")
LAG_LIMIT = 60
OFFLINE_WRITES = 100
PING_PONG_ROUNDS = 3


# -- HTTP ---------------------------------------------------------------------


def call(method, url, body=None, headers=None, timeout=30):
    """Returns (status, decoded body). Status 0 means the connection failed."""
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("accept", "application/json")
    if data is not None:
        request.add_header("content-type", "application/json")
    for name, value in (headers or {}).items():
        request.add_header(name, value)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, decode(response.read())
    except urllib.error.HTTPError as error:
        return error.code, decode(error.read())
    except (urllib.error.URLError, OSError) as error:
        return 0, {"error": str(getattr(error, "reason", error))}


def decode(raw):
    try:
        return json.loads(raw or b"null")
    except ValueError:
        return raw.decode(errors="replace")[:300]


def forward(method, url, body, headers, timeout=60):
    """Returns (status, raw body, content type) for the gate and the stand-in."""
    request = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read(), response.headers.get("content-type", "application/json")
    except urllib.error.HTTPError as error:
        return error.code, error.read(), error.headers.get("content-type", "application/json")
    except (urllib.error.URLError, OSError) as error:
        raw = json.dumps({"error": {"code": "UNREACHABLE", "message": str(getattr(error, "reason", error))}})
        return 502, raw.encode(), "application/json"


class Engine:
    """An Engine's own API (the laptop, or the cloud Engine when reachable)."""

    def __init__(self, url, key):
        self.url, self.key = url.rstrip("/"), key

    def request(self, method, path, body=None, headers=None, **query):
        url = self.url + path + ("?" + urllib.parse.urlencode(query) if query else "")
        return call(method, url, body, {"authorization": "Bearer " + self.key, **(headers or {})})

    def memory_ids(self, workspace, marker):
        status, body = self.request("GET", "/api/memory", workspace=workspace, q=marker, limit=200)
        return [m["id"] for m in body.get("memories", [])] if status == 200 else []

    def peer(self, workspace):
        status, body = self.request("GET", "/api/sync/status", workspace=workspace)
        peers = body.get("peers", []) if status == 200 else []
        return peers[0] if peers else {}


class Relay:
    """The relay contract, called directly (not through the gate)."""

    def __init__(self, base, key, workspace):
        self.base, self.key, self.workspace = base.rstrip("/"), key, workspace

    def request(self, method, route, body=None, **query):
        query = {"workspace": self.workspace, **query}
        url = "%s/%s?%s" % (self.base, route, urllib.parse.urlencode(query))
        status, reply = call(method, url, body, {"authorization": "Bearer " + self.key}, timeout=60)
        if status == 200 and isinstance(reply, dict) and isinstance(reply.get("data"), dict):
            return status, reply["data"]
        return status, reply

    def ledger(self, since):
        """Every mutation after `since` on the cloud Engine, paging on `more`."""
        mutations = []
        while True:
            status, page = self.request("GET", "pull", since=since, limit=2000)
            if status != 200:
                return mutations, status
            mutations += page["mutations"]
            if not page.get("more") or page["cursor"] <= since:
                return mutations, status
            since = page["cursor"]


def error_code(body):
    error = body.get("error") if isinstance(body, dict) else None
    code = error.get("code") if isinstance(error, dict) else error
    return str(code or "").lower()


# -- the gate -----------------------------------------------------------------


class Gate:
    """Forwards the laptop's relay calls unchanged and records what left."""

    def __init__(self, port, upstream):
        parts = urllib.parse.urlsplit(upstream)
        self.port, self.origin, self.path = port, "%s://%s" % (parts.scheme, parts.netloc), parts.path
        self.skew = False
        self.log = []
        self.lock = threading.Lock()
        self.server = None

    @property
    def peer_url(self):
        return "relay+http://127.0.0.1:%d%s" % (self.port, self.path)

    def start(self):
        gate = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                gate.handle(self, "GET")

            def do_POST(self):
                gate.handle(self, "POST")

            def log_message(self, *_args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", self.port), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.server = None

    def handle(self, handler, method):
        length = int(handler.headers.get("content-length") or 0)
        body = handler.rfile.read(length) if length else None
        headers = {k: v for k, v in handler.headers.items() if k.lower() in FORWARDED_HEADERS}
        status, raw, content_type = forward(method, self.origin + handler.path, body, headers)
        if self.skew:
            raw = skew_migration(raw)
        path, _, query = handler.path.partition("?")
        with self.lock:
            self.log.append(
                {
                    "t": time.time(),
                    "method": method,
                    "route": path.rsplit("/", 1)[-1],
                    "workspace": urllib.parse.parse_qs(query).get("workspace", [""])[0],
                    "status": status,
                    "body": (body or b"").decode(errors="replace"),
                }
            )
        reply(handler, status, raw, content_type)

    def entries(self, since=0.0):
        with self.lock:
            return [entry for entry in self.log if entry["t"] >= since]


def skew_migration(raw):
    """The relay's answer as if the cloud Engine ran another migration."""
    try:
        body = json.loads(raw)
    except ValueError:
        return raw
    data = body.get("data") if isinstance(body, dict) else None
    for holder in (data, (data or {}).get("engine") if isinstance(data, dict) else None):
        if isinstance(holder, dict) and isinstance(holder.get("migration"), int):
            holder["migration"] += 1000
    return json.dumps(body).encode()


def reply(handler, status, raw, content_type="application/json"):
    handler.send_response(status)
    handler.send_header("content-type", content_type)
    handler.send_header("content-length", str(len(raw)))
    handler.end_headers()
    handler.wfile.write(raw)


# -- the relay stand-in -------------------------------------------------------


class StandIn:
    """The MIOSA relay contract in front of the cloud Engine (WO-46).

    Bearer key with engine:sync (403 otherwise), routes
    /api/v1/engines/<id>/sync/{enable,status,pull,push}?workspace=, the Engine
    called with its own key (the admin door), {"data": ...} on success, the
    Engine's refusal as {"error": {"code", "message"}} with its status, 502 when
    the Engine cannot be reached. Like the live relay it does not forward
    x-optimal-replica, and status carries the Engine's migration and version.
    """

    ROUTES = {"enable": "POST", "push": "POST", "pull": "GET", "status": "GET"}

    def __init__(self, port, engine, relay_key):
        self.port, self.engine, self.relay_key = port, engine, relay_key
        self.engine_id = str(uuid.uuid4())

    @property
    def base(self):
        return "http://127.0.0.1:%d/api/v1/engines/%s/sync" % (self.port, self.engine_id)

    def start(self):
        stand_in = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                stand_in.handle(self, "GET")

            def do_POST(self):
                stand_in.handle(self, "POST")

            def log_message(self, *_args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", self.port), Handler)
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()

    def handle(self, handler, method):
        length = int(handler.headers.get("content-length") or 0)
        body = decode(handler.rfile.read(length)) if length else None
        path, _, query = handler.path.partition("?")
        query = {k: v[0] for k, v in urllib.parse.parse_qs(query).items()}
        status, data = self.route(method, path, query, body, handler.headers.get("authorization", ""))
        reply(handler, status, json.dumps(data).encode())

    def route(self, method, path, query, body, authorization):
        if authorization != "Bearer " + self.relay_key:
            return refused(403, "FORBIDDEN", "this key does not carry the engine:sync scope")
        match = re.fullmatch(r"/api/v1/engines/([^/]+)/sync/(\w+)", path)
        if not match or match.group(1) != self.engine_id or self.ROUTES.get(match.group(2)) != method:
            return refused(404, "NOT_FOUND")
        route, workspace = match.group(2), (query.get("workspace") or "").strip()
        if not workspace:
            return refused(400, "WORKSPACE_REQUIRED")

        status, listed = self.engine.request("GET", "/api/workspaces", status="all", limit=100)
        if status != 200:
            return refused(502, "ENGINE_UNAVAILABLE")
        if not any(workspace in (w.get("id"), w.get("slug")) for w in listed.get("workspaces", [])):
            return refused(404, "WORKSPACE_NOT_FOUND", "the Engine has no workspace with that id")

        if route == "enable":
            status, result = self.engine.request("POST", "/api/sync/enable", {"workspace": workspace})
        elif route == "status":
            status, result = self.engine.request("GET", "/api/sync/status", workspace=workspace)
            _, version = self.engine.request("GET", "/api/version")
            if status == 200 and isinstance(version, dict):
                migration = version.get("expected_migration") or version.get("migration")
                result.update({k: v for k, v in {"migration": migration, "version": version.get("version")}.items() if v is not None})
        elif route == "pull":
            extra = {k: query[k] for k in ("since", "limit") if query.get(k)}
            status, result = self.engine.request("GET", "/api/sync/changes", workspace=workspace, **extra)
        else:
            # Forwarded unchanged (base_seq included); only the workspace is the query's.
            sent = dict(body) if isinstance(body, dict) else {}
            sent["workspace"] = workspace
            status, result = self.engine.request("POST", "/api/sync/changes", sent)

        if status == 200:
            return 200, {"data": result}
        if 400 <= status < 500:
            code = result.get("error") if isinstance(result, dict) and isinstance(result.get("error"), str) else "ENGINE_REJECTED"
            message = result.get("message") if isinstance(result, dict) and isinstance(result.get("message"), str) else code
            return refused(status, code.upper(), message)
        return refused(502, "ENGINE_UNAVAILABLE")


def refused(status, code, message=None):
    error = {"code": code} if message is None else {"code": code, "message": message}
    return status, {"error": error}


# -- the checks ---------------------------------------------------------------


def now_iso():
    """UTC with milliseconds, the format the Engine's change capture records."""
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3]


def wait_for(probe, timeout, step=1.0):
    """Polls `probe` until it returns something truthy; returns (value, seconds)."""
    started = time.time()
    while True:
        value = probe()
        elapsed = time.time() - started
        if value or elapsed > timeout:
            return value, elapsed
        time.sleep(step)


class Proof:
    def __init__(self, stand_in):
        env = os.environ
        self.stand_in = stand_in
        self.workspace = env.get("WORKSPACE", "default")
        self.interval = int(env.get("SYNC_INTERVAL_MS", "20000")) / 1000
        self.run = uuid.uuid4().hex[:8]
        self.laptop = Engine(env["LAPTOP_URL"], env["LAPTOP_KEY"])
        self.cloud = Engine(env["CLOUD_ENGINE_URL"], env["CLOUD_ENGINE_KEY"]) if env.get("CLOUD_ENGINE_URL") and env.get("CLOUD_ENGINE_KEY") else None
        if stand_in:
            relay = StandIn(int(env.get("RELAY_PORT", "4323")), self.cloud, env["MIOSA_API_KEY"])
            relay.start()
            base = relay.base
        else:
            base = env["RELAY_BASE"]
        self.relay = Relay(base, env["MIOSA_API_KEY"], self.workspace)
        self.gate = Gate(int(env.get("GATE_PORT", "4324")), base)
        self.results = []
        self.agent = "rep_proof_agent_" + self.run
        self.agent_seq = 0

    def check(self, name, ok, detail):
        print("%s %s: %s" % ("PASS" if ok else "FAIL", name, detail), flush=True)
        self.results.append(bool(ok))
        return ok

    def info(self, text):
        print("INFO " + text, flush=True)

    # -- steps

    def main(self):
        if not self.preflight():
            return self.summary()
        self.register()
        self.lag_both_ways()
        self.sequential_edit()
        self.ping_pong()
        self.offline_exactly_once_and_conflict()
        self.policy_none()
        self.version_pause()
        self.no_dial_out()
        return self.summary()

    def preflight(self):
        status, cloud = self.relay.request("GET", "status")
        _, version = self.laptop.request("GET", "/api/version")
        local = version.get("expected_migration") if isinstance(version, dict) else None
        _, replica = self.laptop.request("GET", "/api/sync/status", workspace=self.workspace)
        self.laptop_replica = replica.get("replica_id") if isinstance(replica, dict) else None
        if status != 200:
            return self.check("preflight", False, "relay status answered %s %s" % (status, error_code(cloud) or cloud))
        self.cloud_replica = cloud.get("replica_id")
        self.cloud_migration = cloud.get("migration")
        self.cloud_version = cloud.get("version", "")
        self.cloud_start = cloud.get("ledger_sequence", 0)
        self.cloud_conflicts_start = cloud.get("conflicts_by_table")
        self.local_migration = local
        self.info(
            "relay status: workspace %s on the cloud Engine, replica %s, version %s, enabled %s, ledger %s, %d peer(s)"
            % (self.workspace, self.cloud_replica, self.cloud_version or "unreported", cloud.get("enabled"), self.cloud_start, len(cloud.get("peers") or []))
        )
        # Fails closed, as the client does: a status without the other Engine's
        # migration is not a match.
        reported = isinstance(self.cloud_migration, int)
        same = reported and self.cloud_migration == local
        if not reported:
            why = ": the relay's status carries no migration, so the client pauses"
        elif not same:
            why = ": run this proof from an Engine checkout on the cloud Engine's migration"
        else:
            why = ""
        return self.check(
            "preflight",
            same,
            "relay status 200 reports the cloud Engine on migration %s, the laptop runs %s%s" % (self.cloud_migration, local, why),
        )

    def register(self):
        self.gate.start()
        status, peer = self.laptop.request(
            "POST", "/api/sync/peers", {"workspace": self.workspace, "url": self.gate.peer_url, "api_key": os.environ["MIOSA_API_KEY"], "policy": "both"}
        )
        _, listed = self.laptop.request("GET", "/api/sync/status", workspace=self.workspace)
        urls = [p.get("url") for p in (listed or {}).get("peers", [])] if isinstance(listed, dict) else []
        engine_address = urllib.parse.urlsplit(os.environ.get("CLOUD_ENGINE_URL", "")).netloc
        stored_engine = [u for u in urls if not str(u).startswith("relay+") or (engine_address and engine_address in str(u))]
        self.check(
            "relay peer",
            status == 201 and urls == [self.gate.peer_url] and not stored_engine,
            "registered %s policy both on the laptop (HTTP %s); its peers are %s, %d of them an Engine address"
            % (self.gate.peer_url, status, urls, len(stored_engine)),
        )

        # A workspace with sync policy none: captured on the laptop, never sent.
        _, ws = self.laptop.request("POST", "/api/workspaces", {"slug": "relay-none-" + self.run, "name": "Relay proof, policy none"})
        self.none_ws = ws.get("id") if isinstance(ws, dict) else None
        status, _ = self.laptop.request(
            "POST", "/api/sync/peers", {"workspace": self.none_ws, "url": self.gate.peer_url, "api_key": os.environ["MIOSA_API_KEY"], "policy": "none"}
        )
        self.none_marker = "relaynone" + self.run
        self.laptop.request("POST", "/api/memory", {"content": "Kept on this device " + self.none_marker, "workspace": self.none_ws})
        self.info("workspace %s registered with policy none (HTTP %s) and written to" % (self.none_ws, status))

        # The entity both sides will edit while apart.
        self.period = "relay-proof-" + self.run
        self.laptop.request("PUT", "/api/rhythm/notes/daily/" + self.period, {"workspace": self.workspace, "content": "Plan agreed before the trip"})

    def lag_both_ways(self):
        up = "relayup" + self.run
        status, memory = self.laptop.request("POST", "/api/memory", {"content": "Captured on the laptop " + up, "workspace": self.workspace})
        memory_id = memory.get("id") if isinstance(memory, dict) else None
        found, seconds = wait_for(lambda: self.on_cloud(memory_id, up), LAG_LIMIT + 30)
        laptop, cloud = self.counts(up, [memory_id])
        self.check(
            "laptop to cloud",
            bool(found) and seconds <= LAG_LIMIT and (laptop, cloud) == (1, 1),
            "capture %s %s on the cloud after %.0f s (limit %d s); laptop holds %d, cloud holds %d (%s)"
            % (memory_id, "found" if found else "NOT found", seconds, LAG_LIMIT, laptop, cloud, self.cloud_evidence()),
        )

        down = "relaydown" + self.run
        written, memory_id = self.cloud_write_memory("Captured by a cloud agent " + down)
        found, seconds = wait_for(lambda: self.laptop.memory_ids(self.workspace, down), LAG_LIMIT + 30)
        laptop, cloud = self.counts(down, [memory_id])
        self.check(
            "cloud to laptop",
            bool(found) and seconds <= LAG_LIMIT and (laptop, cloud) == (1, 1),
            "cloud capture %s %s in laptop search after %.0f s (limit %d s); cloud holds %d, laptop holds %d (written %s)"
            % (memory_id, "found" if found else "NOT found", seconds, LAG_LIMIT, cloud, laptop, written),
        )

    def sequential_edit(self):
        """A note the cloud wrote and the laptop then edited after pulling it:
        one edit after the other, so neither side records a conflict. The push
        carries base_seq; without it the cloud took its own earlier write for a
        concurrent edit."""
        if not self.cloud:
            self.info("sequential edit not checked: it needs the cloud Engine's own write (CLOUD_ENGINE_URL)")
            return
        period = "relay-sequential-" + self.run
        first, second = "Agenda written on the cloud " + self.run, "Agenda edited on the laptop " + self.run
        status, _ = self.cloud.request("PUT", "/api/rhythm/notes/daily/" + period, {"workspace": self.workspace, "content": first})
        pulled, pulled_after = wait_for(lambda: self.note_content(self.laptop, period) == first, LAG_LIMIT + 30)
        self.laptop.request("PUT", "/api/rhythm/notes/daily/" + period, {"workspace": self.workspace, "content": second})
        pushed, pushed_after = wait_for(lambda: self.note_content(self.cloud, period) == second, LAG_LIMIT + 30)
        on_laptop, on_cloud = (self.note_conflicts(engine, period) for engine in (self.laptop, self.cloud))
        self.check(
            "sequential edit is no conflict",
            status == 200 and pulled and pushed and not on_laptop and not on_cloud,
            "daily note %s written on the cloud (HTTP %s), on the laptop after %.0f s, edited there and back on the cloud after %.0f s; open conflicts for it: laptop %d, cloud %d"
            % (period, status, pulled_after, pushed_after, len(on_laptop), len(on_cloud)),
        )

    def ping_pong(self):
        """One note edited by each side in turn, every edit made after the other
        side's arrived: after each hand-off both Engines hold that edit, and
        neither records a conflict. An edit that loses to an older one, a hand-off
        that does not settle, or a conflict between edits made one after the
        other shows here."""
        if not self.cloud:
            self.info("ping-pong not checked: it needs the cloud Engine's own write (CLOUD_ENGINE_URL)")
            return
        period = "relay-pingpong-" + self.run
        sides = [("cloud", self.cloud), ("laptop", self.laptop)]
        handoffs, waited, stuck = 0, 0.0, None
        for round_number in range(1, PING_PONG_ROUNDS + 1):
            for index, (name, writer) in enumerate(sides):
                other_name, other = sides[1 - index]
                text = "Round %d written on the %s %s" % (round_number, name, self.run)
                status, _ = writer.request("PUT", "/api/rhythm/notes/daily/" + period, {"workspace": self.workspace, "content": text})
                arrived, after = wait_for(lambda: self.note_content(other, period) == text, LAG_LIMIT + 30)
                waited += after
                if status != 200 or not arrived:
                    stuck = "round %d: the %s's edit (HTTP %s) did not reach the %s within %.0f s" % (round_number, name, status, other_name, after)
                    break
                handoffs += 1
            if stuck:
                break
        finals = [self.note_content(engine, period) for engine in (self.laptop, self.cloud)]
        conflicts = [self.note_conflicts(engine, period) for engine in (self.laptop, self.cloud)]
        self.check(
            "ping-pong converges",
            not stuck and handoffs == 2 * PING_PONG_ROUNDS and finals[0] == finals[1] and finals[0] is not None and not conflicts[0] and not conflicts[1],
            "daily note %s passed back and forth %d times (%.0f s waiting in all); laptop reads %r, cloud reads %r; open conflicts for it: laptop %d, cloud %d%s"
            % (period, handoffs, waited, finals[0], finals[1], len(conflicts[0]), len(conflicts[1]), "; " + stuck if stuck else ""),
        )

    def offline_exactly_once_and_conflict(self):
        laptop_start = self.laptop.request("GET", "/api/sync/status", workspace=self.workspace)[1].get("ledger_sequence", 0)
        _, cloud_status = self.relay.request("GET", "status")
        cloud_start = cloud_status.get("ledger_sequence", 0) if isinstance(cloud_status, dict) else 0

        self.gate.stop()
        peer, seconds = wait_for(lambda: (lambda p: p if p.get("status") == "error" else None)(self.laptop.peer(self.workspace)), 3 * self.interval + 15)
        self.check("relay unreachable", bool(peer), "gate stopped; the laptop's next cycle failed after %.0f s (peer status %s: %s)" % (seconds, (peer or {}).get("status"), (peer or {}).get("message")))

        # The same note edited on both sides while apart: the cloud first, then the laptop.
        cloud_edit = self.cloud_edit_note("Plan changed by a cloud agent")
        time.sleep(2)
        self.laptop.request("PUT", "/api/rhythm/notes/daily/" + self.period, {"workspace": self.workspace, "content": "Plan changed on the laptop offline"})

        marker = "relayoffline" + self.run
        ids = []
        for i in range(OFFLINE_WRITES):
            status, memory = self.laptop.request("POST", "/api/memory", {"content": "Offline note %s number %d" % (marker, i), "workspace": self.workspace})
            if status == 201:
                ids.append(memory["id"])
        pending = self.laptop.peer(self.workspace).get("pending_push")
        self.info("%d of %d offline writes accepted by the laptop, %s changes pending for the relay; cloud note edit: %s" % (len(ids), OFFLINE_WRITES, pending, cloud_edit))

        self.gate.start()
        back = time.time()
        arrived, seconds = wait_for(lambda: self.all_on_cloud(ids, marker), 6 * self.interval + 60, step=2)

        def drained():
            left = self.laptop.peer(self.workspace).get("pending_push")
            return ("drained", left) if left == 0 else None

        drained_after, _ = wait_for(drained, 2 * self.interval + 10)
        pending_after = drained_after[1] if drained_after else self.laptop.peer(self.workspace).get("pending_push")
        mutations, _ = self.relay.ledger(cloud_start)
        from_laptop = [m for m in mutations if m["device_id"] == self.laptop_replica]
        laptop_ids = {m["id"] for m in from_laptop}
        creates = [m for m in mutations if m["entity_type"] == "memories" and m["operation"] == "create" and ((m.get("payload") or {}).get("row") or {}).get("id") in set(ids)]
        per_id = {}
        for m in creates:
            per_id[m["payload"]["row"]["id"]] = per_id.get(m["payload"]["row"]["id"], 0) + 1
        keys = {m["idempotency_key"] for m in creates}
        once = len(ids) == OFFLINE_WRITES and set(per_id) == set(ids) and all(n == 1 for n in per_id.values()) and len(keys) == len(creates)
        laptop_hits = self.laptop.memory_ids(self.workspace, marker)
        once = once and sorted(laptop_hits) == sorted(ids)
        # Everything that was pending arrived, each change once, nothing left behind.
        sent_all = isinstance(pending, int) and pending > 0 and len(from_laptop) >= pending and len(laptop_ids) == len(from_laptop) and pending_after == 0
        search = ""
        if self.cloud:
            hits = self.cloud.memory_ids(self.workspace, marker)
            once = once and sorted(hits) == sorted(ids)
            search = "; cloud search finds %d, %d distinct" % (len(hits), len(set(hits)))
        self.check(
            "offline writes exactly once",
            bool(arrived) and once and sent_all,
            "%d/%d arrived %.0f s after the relay returned; laptop search finds %d; cloud ledger has %d creates for them, %d distinct ids, %d distinct idempotency keys%s; "
            "sent: %s laptop changes were pending, the cloud ledger now holds %d changes from the laptop since the outage began (%d distinct), %s pending after"
            % (len(per_id), len(ids), seconds, len(laptop_hits), len(creates), len(per_id), len(keys), search, pending, len(from_laptop), len(laptop_ids), pending_after),
        )

        # Replay: the laptop's ledger since before the outage, pushed again as is.
        headers = {"x-optimal-replica": self.cloud_replica or ""}
        _, page = self.laptop.request("GET", "/api/sync/changes", headers=headers, workspace=self.workspace, since=laptop_start, limit=2000)
        sent, totals = 0, {"applied": 0, "duplicate": 0, "conflicts": 0, "failed": 0, "refused": 0}
        mutations = page.get("mutations", []) if isinstance(page, dict) else []
        for start in range(0, len(mutations), 500):
            chunk = mutations[start : start + 500]
            status, result = self.relay.request("POST", "push", {"workspace": self.workspace, "replica_id": self.laptop_replica, "engine": page["engine"], "mutations": chunk})
            sent += len(chunk)
            if status != 200:
                totals["refused"] += len(chunk)
                continue
            skipped = result.get("skipped") or {}
            totals["applied"] += result.get("applied", 0)
            totals["duplicate"] += skipped.get("duplicate", 0)
            totals["conflicts"] += result.get("conflicts", 0)
            totals["failed"] += len(result.get("failed") or [])
        self.check(
            "replay applies nothing",
            sent > 0 and totals["applied"] == 0 and totals["conflicts"] == 0 and totals["failed"] == 0 and totals["refused"] == 0 and totals["duplicate"] == sent,
            "the laptop's %d changes since before the outage pushed again: applied %d, skipped duplicate %d, conflicts %d, failed %d, refused %d"
            % (sent, totals["applied"], totals["duplicate"], totals["conflicts"], totals["failed"], totals["refused"]),
        )

        conflicts, _ = wait_for(lambda: self.note_conflicts(self.laptop, self.period, "concurrent_edit"), 2 * self.interval + 10)
        resolutions = ", ".join(sorted({c.get("resolution") for c in conflicts or []}))
        tables = self.conflict_tables()
        if not self.cloud:
            self.check(
                "conflict queue",
                bool(conflicts) and tables[0] == {"rhythm_notes": 1} and tables[1] == {},
                "the daily note %s edited on both sides: %d open conflict(s) on the laptop (%s); new open conflicts by table: laptop %s, cloud %s"
                % (self.period, len(conflicts or []), resolutions, tables[0], tables[1]),
            )
            self.info("the cloud's conflict list and the note's final text are not readable through the relay; set CLOUD_ENGINE_URL to check them")
            return

        def converged():
            notes = [self.note_content(engine) for engine in (self.laptop, self.cloud)]
            return notes if notes[0] is not None and notes[0] == notes[1] else None

        notes, _ = wait_for(converged, 2 * self.interval + 10)
        final = notes or [self.note_content(engine) for engine in (self.laptop, self.cloud)]
        on_cloud = self.note_conflicts(self.cloud, self.period)
        tables = self.conflict_tables()
        # The note is the only row both sides changed while apart. The laptop
        # pulled the cloud's edit before it pushed its own, so the laptop records
        # the conflict and its push carries a base_seq that covers the cloud's
        # edit: the cloud keeps the newer version without a second record.
        # Nothing else is in either queue.
        self.check(
            "conflict queue",
            bool(conflicts) and not on_cloud and bool(notes) and tables == ({"rhythm_notes": 1}, {}),
            "the daily note %s edited on both sides: %d open conflict(s) on the laptop (%s), %d on the cloud; laptop reads %r, cloud reads %r; new open conflicts by table: laptop %s, cloud %s"
            % (self.period, len(conflicts or []), resolutions, len(on_cloud), final[0], final[1], tables[0], tables[1]),
        )

    def policy_none(self):
        _, page = self.laptop.request("GET", "/api/sync/changes", workspace=self.none_ws, since=0, limit=2000)
        captured = [m for m in (page or {}).get("mutations", []) if self.none_marker in json.dumps(m)]
        log = self.gate.entries()
        named = [e for e in log if e["workspace"] == self.none_ws]
        carried = [e for e in log if self.none_marker in e["body"]]
        synced = [e for e in log if e["workspace"] == self.workspace]
        self.check(
            "policy none stays home",
            len(captured) > 0 and len(synced) > 0 and not named and not carried,
            "workspace %s: %d change(s) captured on the laptop; of %d relay requests (%d for workspace %s), %d named it and %d carried its marker"
            % (self.none_ws, len(captured), len(log), len(synced), self.workspace, len(named), len(carried)),
        )

    def version_pause(self):
        older = (self.local_migration or 1) - 1
        probe = self.synthetic_mutation("memories", "create", {"id": "mem_relay_%s_version" % self.run, "content": "Never applied relayversion" + self.run, "root_memory_id": None, "metadata": "{}"})
        status, body = self.relay.request("POST", "push", {"workspace": self.workspace, "replica_id": "rep_proof_old_" + self.run, "engine": {"replica_id": "rep_proof_old_" + self.run, "migration": older, "version": "0.0.0"}, "mutations": [probe]})
        error = body.get("error") if isinstance(body, dict) else None
        message = error.get("message") if isinstance(error, dict) else None
        expected = "runs schema %s" % older
        self.check(
            "relay refuses another migration",
            status == 409 and error_code(body) == "version_mismatch" and expected in str(message) and "same Engine version" in str(message),
            "a push on migration %s answered %s %s: %s" % (older, status, error_code(body).upper(), message),
        )

        self.gate.skew = True
        peer, seconds = wait_for(lambda: (lambda p: p if p.get("status") == "paused_version" else None)(self.laptop.peer(self.workspace)), 3 * self.interval + 15)
        paused_at = time.time()
        time.sleep(self.interval + 5)
        during = [e for e in self.gate.entries(paused_at) if e["workspace"] == self.workspace]
        only_status = bool(during) and all(e["method"] == "GET" and e["route"] == "status" for e in during)
        self.gate.skew = False
        resumed, resume_seconds = wait_for(lambda: (lambda p: p if p.get("status") == "active" else None)(self.laptop.peer(self.workspace)), 3 * self.interval + 15)
        message = str((peer or {}).get("message"))
        skewed = "runs schema %s" % ((self.cloud_migration or 0) + 1000)
        self.check(
            "client pauses on another migration",
            bool(peer) and skewed in message and "same Engine version" in message and only_status and bool(resumed),
            "relay reporting migration +1000: peer paused_version after %.0f s (%s); while paused it sent %d request(s), %s; resumed active %.0f s after the versions matched"
            % (seconds, (peer or {}).get("message"), len(during), "all GET status" if only_status else [(e["method"], e["route"]) for e in during], resume_seconds),
        )

    def no_dial_out(self):
        if self.stand_in:
            _, status = self.cloud.request("GET", "/api/sync/status", workspace=self.workspace)
            peers = status.get("peers", []) if isinstance(status, dict) else None
            self.check("cloud Engine dials nobody", peers == [], "the cloud Engine has %s peer(s) registered" % (len(peers) if peers is not None else "unknown"))
        else:
            self.info("the managed Engine is reached only through the relay; its own peers (from status): %d" % len(self.relay.request("GET", "status")[1].get("peers") or []))

    def summary(self):
        passed = sum(self.results)
        print("RESULT %s %d/%d checks passed (run %s)" % ("PASS" if passed == len(self.results) else "FAIL", passed, len(self.results), self.run), flush=True)
        return 0 if passed == len(self.results) else 1

    # -- the cloud side

    def cloud_evidence(self):
        return "checked in cloud search" if self.cloud else "checked in the cloud ledger through the relay"

    def on_cloud(self, memory_id, marker):
        if self.cloud:
            return memory_id in self.cloud.memory_ids(self.workspace, marker)
        mutations, _ = self.relay.ledger(self.cloud_start)
        return any(m["entity_type"] == "memories" and ((m.get("payload") or {}).get("row") or {}).get("id") == memory_id for m in mutations)

    def all_on_cloud(self, ids, marker):
        if self.cloud:
            return len(set(self.cloud.memory_ids(self.workspace, marker)) & set(ids)) == len(ids)
        mutations, _ = self.relay.ledger(self.cloud_start)
        seen = {((m.get("payload") or {}).get("row") or {}).get("id") for m in mutations if m["entity_type"] == "memories"}
        return set(ids) <= seen

    def cloud_write_memory(self, content):
        """A capture on the cloud: on the cloud Engine itself when it is reachable,
        otherwise by a second device through the relay. Returns (how, memory id)."""
        if self.cloud:
            status, memory = self.cloud.request("POST", "/api/memory", {"content": content, "workspace": self.workspace})
            return "on the cloud Engine (HTTP %s)" % status, memory.get("id") if isinstance(memory, dict) else None
        memory_id = "mem_relay_%s_down" % self.run
        mutation = self.synthetic_mutation("memories", "create", {"id": memory_id, "content": content, "root_memory_id": memory_id, "metadata": "{}"})
        status, result = self.push_as_agent([mutation])
        applied = result.get("applied") if isinstance(result, dict) else result
        return "by device %s through the relay (HTTP %s, applied %s)" % (self.agent, status, applied), memory_id

    def counts(self, marker, ids):
        """How many of `ids` each side holds: laptop search, and cloud search or the cloud ledger."""
        wanted = set(ids)
        laptop = len(set(self.laptop.memory_ids(self.workspace, marker)) & wanted)
        if self.cloud:
            cloud = len(set(self.cloud.memory_ids(self.workspace, marker)) & wanted)
        else:
            mutations, _ = self.relay.ledger(self.cloud_start)
            cloud = len({((m.get("payload") or {}).get("row") or {}).get("id") for m in mutations if m["entity_type"] == "memories"} & wanted)
        return laptop, cloud

    def cloud_edit_note(self, content):
        if self.cloud:
            status, _ = self.cloud.request("PUT", "/api/rhythm/notes/daily/" + self.period, {"workspace": self.workspace, "content": content})
            return "on the cloud Engine (HTTP %s)" % status
        _, page = self.laptop.request("GET", "/api/sync/changes", workspace=self.workspace, since=0, limit=2000)
        mine = [m for m in page.get("mutations", []) if m["entity_type"] == "rhythm_notes" and m["payload"]["row"].get("period") == self.period]
        if not mine:
            return "not made: the laptop's note was not found in its ledger"
        row = dict(mine[-1]["payload"]["row"], content=content, updated_by="agent:relay-proof")
        mutation = self.synthetic_mutation("rhythm_notes", "update", row, entity_id=mine[-1]["entity_id"])
        status, result = self.push_as_agent([mutation])
        return "by device %s through the relay (HTTP %s, applied %s)" % (self.agent, status, (result or {}).get("applied") if isinstance(result, dict) else result)

    def note_content(self, engine, period=None):
        _, body = engine.request("GET", "/api/rhythm/notes", workspace=self.workspace, cadence="daily", limit=100)
        notes = [n for n in (body or {}).get("notes", []) if n.get("period") == (period or self.period)]
        return notes[0].get("content") if notes else None

    def note_conflicts(self, engine, period, kind=None):
        """Open conflicts on a daily note (its key ends with the period)."""
        _, body = engine.request("GET", "/api/sync/conflicts", workspace=self.workspace)
        rows = (body or {}).get("conflicts", []) if isinstance(body, dict) else []
        return [c for c in rows if c.get("table") == "rhythm_notes" and period in str(c.get("entity_key")) and (kind is None or c.get("kind") == kind)]

    def conflict_tables(self):
        """Open conflicts per table added during this run: (laptop, cloud).
        The laptop starts empty; the cloud's are counted from its status at
        preflight, read through the relay."""
        _, laptop = self.laptop.request("GET", "/api/sync/status", workspace=self.workspace)
        _, cloud = self.relay.request("GET", "status")
        before = self.cloud_conflicts_start or {}

        def by_table(status):
            return status.get("conflicts_by_table") if isinstance(status, dict) else None

        laptop_tables, cloud_tables = by_table(laptop), by_table(cloud)
        if not isinstance(cloud_tables, dict) or not isinstance(self.cloud_conflicts_start, dict):
            return laptop_tables, "unreported (an Engine without conflicts_by_table)"
        added = {t: n - before.get(t, 0) for t, n in cloud_tables.items() if n - before.get(t, 0) != 0}
        return laptop_tables, added

    def synthetic_mutation(self, table, operation, row, entity_id=None):
        self.agent_seq += 1
        row = dict({"tenant_id": "default", "workspace_id": self.workspace}, **row)
        payload = {"row": row, "blobs": {}}
        return {
            "sequence": self.agent_seq,
            "id": "mut_%s_%d" % (self.agent, self.agent_seq),
            "device_id": self.agent,
            "entity_type": table,
            "entity_id": entity_id or row.get("id"),
            "operation": operation,
            "payload": payload,
            "payload_hash": hashlib.sha256(json.dumps(payload).encode()).hexdigest(),
            "idempotency_key": "%s:%d" % (self.agent, self.agent_seq),
            "occurred_at": now_iso(),
        }

    def push_as_agent(self, mutations):
        engine = {"replica_id": self.agent, "migration": self.cloud_migration, "version": self.cloud_version}
        # The agent pulls nothing from the cloud, so it has seen none of its ledger.
        body = {"workspace": self.workspace, "replica_id": self.agent, "engine": engine, "base_seq": 0, "mutations": mutations}
        return self.relay.request("POST", "push", body)


# -- secrets ------------------------------------------------------------------


def redact(secrets_path):
    secrets, seen, hits = set(), None, 0

    def load():
        found = {os.environ[name] for name in SECRET_ENV if len(os.environ.get(name, "")) >= 8}
        try:
            with open(secrets_path) as handle:
                found |= {line.strip() for line in handle if len(line.strip()) >= 8}
        except OSError:
            pass
        return found

    for line in sys.stdin:
        try:
            stat = os.stat(secrets_path)
            current = (stat.st_size, stat.st_mtime_ns)
        except OSError:
            current = None
        if current != seen or not secrets:
            secrets, seen = load(), current
        for secret in secrets:
            if secret in line:
                hits += line.count(secret)
                line = line.replace(secret, "[REDACTED]")
        sys.stdout.write(line)
        sys.stdout.flush()
    if hits:
        print("FAIL secret scan: %d key occurrence(s) reached the output and were redacted" % hits)
        return 3
    print("PASS secret scan: no key appeared in this output")
    return 0


def mint_key():
    text = sys.stdin.read()
    try:
        print(json.loads(text[text.index("{") :])["key"])
        return 0
    except (ValueError, KeyError):
        return 1


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "run":
        sys.exit(Proof("--stand-in" in sys.argv[2:]).main())
    if command == "redact" and len(sys.argv) == 3:
        sys.exit(redact(sys.argv[2]))
    if command == "mint-key":
        sys.exit(mint_key())
    print(__doc__)
    sys.exit(2)
