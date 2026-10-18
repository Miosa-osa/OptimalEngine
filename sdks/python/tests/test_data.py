"""Mock-based tests for the app data client (``client.data``)."""

from __future__ import annotations

import json

import httpx
import pytest
import respx

from optimal_engine import AsyncOptimalEngine, ConflictError, OptimalEngine

BASE = "http://engine.test"


def _record(rid: str, version: int = 1) -> dict[str, object]:
    return {"id": rid, "version": version, "data": {"title": "t", "owner": "user-a"}}


@respx.mock
def test_create_and_query_send_workspace_and_key() -> None:
    create = respx.post(f"{BASE}/api/data/collections/tasks/records").mock(
        return_value=httpx.Response(201, json=_record("r1"))
    )
    query = respx.post(f"{BASE}/api/data/collections/tasks/query").mock(
        return_value=httpx.Response(200, json={"records": [_record("r1")], "next_cursor": None, "has_more": False, "count": 1})
    )

    with OptimalEngine(base_url=BASE, workspace="default:todo", api_key="oe_test") as client:
        tasks = client.data.collection("tasks")
        assert tasks.create({"title": "t"})["id"] == "r1"
        page = tasks.query(where={"owner": "user-a", "done": False}, sort=["due"], limit=10, count=True)

    assert page["count"] == 1
    assert json.loads(create.calls[0].request.content) == {"data": {"title": "t"}, "workspace": "default:todo"}
    assert create.calls[0].request.headers["authorization"] == "Bearer oe_test"
    assert json.loads(query.calls[0].request.content) == {
        "where": {"owner": "user-a", "done": False},
        "sort": ["due"],
        "limit": 10,
        "count": True,
        "workspace": "default:todo",
    }


@respx.mock
def test_stale_version_raises_conflict_with_details() -> None:
    respx.patch(f"{BASE}/api/data/collections/tasks/records/r1").mock(
        return_value=httpx.Response(409, json={"error": "version_conflict", "current_version": 3})
    )
    with OptimalEngine(base_url=BASE, workspace="w") as client, pytest.raises(ConflictError) as exc:
        client.data.collection("tasks").update("r1", {"done": True}, version=2)

    assert exc.value.status_code == 409
    assert exc.value.body["error"] == "version_conflict"
    assert exc.value.body["current_version"] == 3


@respx.mock
def test_iterate_follows_cursors_and_delete_uses_query_params() -> None:
    route = respx.post(f"{BASE}/api/data/collections/tasks/query").mock(
        side_effect=[
            httpx.Response(200, json={"records": [_record("a"), _record("b")], "next_cursor": "c1"}),
            httpx.Response(200, json={"records": [_record("c")], "next_cursor": None}),
        ]
    )
    delete = respx.delete(f"{BASE}/api/data/collections/tasks/records/a").mock(
        return_value=httpx.Response(200, json={"id": "a", "version": 2, "deleted": True})
    )

    with OptimalEngine(base_url=BASE, workspace="w") as client:
        tasks = client.data.collection("tasks")
        ids = [r["id"] for r in tasks.iterate(where={"done": False}, limit=2)]
        tasks.delete("a", version=1)

    assert ids == ["a", "b", "c"]
    assert json.loads(route.calls[1].request.content)["cursor"] == "c1"
    assert delete.calls[0].request.url.params["version"] == "1"
    assert delete.calls[0].request.url.params["workspace"] == "w"


@respx.mock
def test_transaction_files_and_keys() -> None:
    txn = respx.post(f"{BASE}/api/data/transactions").mock(
        return_value=httpx.Response(200, json={"committed": True, "results": [], "txn_id": "txn_1", "last_seq": 9})
    )
    upload = respx.post(f"{BASE}/api/data/collections/tasks/records/r1/files").mock(
        return_value=httpx.Response(201, json={"id": "file_1"})
    )
    download = respx.get(f"{BASE}/api/data/collections/tasks/records/r1/files/file_1").mock(
        return_value=httpx.Response(206, content=b"ell", headers={"content-range": "bytes 1-3/5"})
    )
    keys = respx.post(f"{BASE}/api/data/keys").mock(return_value=httpx.Response(201, json={"id": "k", "key": "oe_x"}))

    with OptimalEngine(base_url=BASE, workspace="w") as client:
        data = client.data
        assert data.transaction([{"op": "create", "collection": "tasks", "data": {"title": "a"}}])["committed"]
        data.collection("tasks").upload_file("r1", "a.txt", b"hello", content_type="text/plain")
        part = data.collection("tasks").download_file("r1", "file_1", range="bytes=1-3")
        data.mint_key(name="session", owner="user-a", operations=["read"])

    assert json.loads(txn.calls[0].request.content)["operations"][0]["op"] == "create"
    assert json.loads(upload.calls[0].request.content)["content_base64"] == "aGVsbG8="
    assert download.calls[0].request.headers["range"] == "bytes=1-3"
    assert (part.status, part.content, part.content_range) == (206, b"ell", "bytes 1-3/5")
    assert json.loads(keys.calls[0].request.content) == {"name": "session", "owner": "user-a", "operations": ["read"], "workspace": "w"}


@respx.mock
async def test_async_client_queries() -> None:
    respx.post(f"{BASE}/api/data/collections/tasks/query").mock(
        return_value=httpx.Response(200, json={"records": [_record("a")], "next_cursor": None})
    )
    async with AsyncOptimalEngine(base_url=BASE, workspace="w") as client:
        ids = [r["id"] async for r in client.data.collection("tasks").iterate(where={"done": False})]
    assert ids == ["a"]
