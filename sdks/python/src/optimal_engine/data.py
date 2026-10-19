"""App data — use the Engine as an app's database (``/api/data``).

Collections with typed fields, records with versions, filter and search
queries with cursors, transactions, files, a resumable change feed,
versioned schema migrations, and data keys for end users.

Usage::

    from optimal_engine import OptimalEngine

    with OptimalEngine(base_url="http://localhost:4200", api_key="oe_...",
                       workspace="default:todo") as client:
        tasks = client.data.collection("tasks")
        task = tasks.create({"title": "write the report", "owner": "user-a"})
        page = tasks.query(where={"owner": "user-a", "done": False}, sort=["due"])
        tasks.update(task["id"], {"done": True}, version=task["version"])

Every non-2xx response raises the SDK's usual exception for its status
(``ConflictError`` for a stale version, ``ValidationError`` for invalid
data, ...); ``exc.body["error"]`` holds the server's error code.

Request shapes are built once (``_Request``) and executed by the sync and
async resources, so both stay identical.
"""

from __future__ import annotations

import base64
from collections.abc import AsyncIterator, Iterator, Mapping, Sequence
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any, Literal, TypedDict
from urllib.parse import quote

from ._transport import build_url, merge_query, raise_for_status, translate_httpx_error

if TYPE_CHECKING:
    from ._async_client import AsyncOptimalEngine
    from ._client import OptimalEngine

FieldType = Literal["string", "text", "integer", "float", "boolean", "datetime", "json", "reference"]
OperationName = Literal["read", "create", "update", "delete"]


class DataRecord(TypedDict, total=False):
    """One record as the API returns it."""

    id: str
    version: int
    created_at: str
    updated_at: str
    created_by: str | None
    updated_by: str | None
    data: dict[str, Any]
    included: dict[str, Any]
    score: float
    seq: int
    op: str


class QueryResult(TypedDict, total=False):
    """A page of records."""

    records: list[DataRecord]
    next_cursor: str | None
    has_more: bool
    count: int
    model: str


@dataclass(frozen=True)
class FileRange:
    """Bytes of a file download, with the range the server sent."""

    status: int
    content: bytes
    content_range: str | None


@dataclass
class _Request:
    method: str
    path: str
    params: dict[str, Any] = field(default_factory=dict)
    body: dict[str, Any] | None = None


def _seg(value: str) -> str:
    return quote(value, safe="")


def _query_body(
    where: Mapping[str, Any] | None,
    sort: Sequence[str | Mapping[str, str]] | None,
    limit: int | None,
    cursor: str | None,
    fields: Sequence[str] | None,
    count: bool | None,
    include: Sequence[str] | None,
    search: str | Mapping[str, Any] | None,
    semantic: str | Mapping[str, Any] | None,
) -> dict[str, Any]:
    spec: dict[str, Any] = {
        "where": dict(where) if where is not None else None,
        "sort": list(sort) if sort is not None else None,
        "limit": limit,
        "cursor": cursor,
        "fields": list(fields) if fields is not None else None,
        "count": count,
        "include": list(include) if include is not None else None,
        "search": search,
        "semantic": semantic,
    }
    return {k: v for k, v in spec.items() if v is not None}


class _Collection:
    """Request builders for one collection."""

    def __init__(self, name: str) -> None:
        self.name = name

    def _path(self, suffix: str = "") -> str:
        return f"/collections/{_seg(self.name)}{suffix}"

    def create(self, data: Mapping[str, Any], id: str | None) -> _Request:
        body: dict[str, Any] = {"data": dict(data)}
        if id is not None:
            body["id"] = id
        return _Request("POST", self._path("/records"), body=body)

    def get(self, id: str, fields: Sequence[str] | None, include: Sequence[str] | None) -> _Request:
        params = {
            "fields": ",".join(fields) if fields else None,
            "include": ",".join(include) if include else None,
        }
        return _Request("GET", self._path(f"/records/{_seg(id)}"), params=params)

    def update(self, id: str, data: Mapping[str, Any], version: int | None) -> _Request:
        body: dict[str, Any] = {"data": dict(data)}
        if version is not None:
            body["version"] = version
        return _Request("PATCH", self._path(f"/records/{_seg(id)}"), body=body)

    def delete(self, id: str, version: int | None) -> _Request:
        return _Request("DELETE", self._path(f"/records/{_seg(id)}"), params={"version": version})

    def upsert(self, key: str | Sequence[str], data: Mapping[str, Any], id: str | None, version: int | None) -> _Request:
        body: dict[str, Any] = {"key": key if isinstance(key, str) else list(key), "data": dict(data)}
        if id is not None:
            body["id"] = id
        if version is not None:
            body["version"] = version
        return _Request("POST", self._path("/upsert"), body=body)

    def bulk_create(self, records: Sequence[Mapping[str, Any]]) -> _Request:
        return _Request("POST", self._path("/records/bulk"), body={"records": [dict(r) for r in records]})

    def query(self, spec: dict[str, Any]) -> _Request:
        return _Request("POST", self._path("/query"), body=spec)

    def upload_file(self, id: str, filename: str, content: bytes, content_type: str | None) -> _Request:
        body: dict[str, Any] = {
            "filename": filename,
            "content_base64": base64.b64encode(content).decode("ascii"),
        }
        if content_type is not None:
            body["content_type"] = content_type
        return _Request("POST", self._path(f"/records/{_seg(id)}/files"), body=body)

    def list_files(self, id: str) -> _Request:
        return _Request("GET", self._path(f"/records/{_seg(id)}/files"))

    def rebuild_embeddings(self) -> _Request:
        return _Request("POST", self._path("/embeddings/rebuild"), body={})

    def file(self, id: str, file_id: str) -> _Request:
        return _Request("GET", self._path(f"/records/{_seg(id)}/files/{_seg(file_id)}"))


# ---------------------------------------------------------------------------
# Sync
# ---------------------------------------------------------------------------


class DataResource:
    """Sync handler for ``/api/data`` in one workspace."""

    def __init__(self, client: OptimalEngine, workspace: str | None = None) -> None:
        self._client = client
        self._workspace = workspace

    @property
    def workspace(self) -> str:
        return self._workspace or self._client.workspace

    def in_workspace(self, workspace: str) -> DataResource:
        """The same API bound to another workspace."""
        return DataResource(self._client, workspace)

    def _run(self, request: _Request) -> Any:
        if request.method in ("GET", "DELETE"):
            params = {**request.params, "workspace": self.workspace}
            return self._client._request(request.method, "/api/data" + request.path, params=params)
        body = {**(request.body or {}), "workspace": self.workspace}
        return self._client._request(request.method, "/api/data" + request.path, json_body=body)

    # -- collections --------------------------------------------------------

    def collection(self, name: str) -> Collection:
        return Collection(self, name)

    def list_collections(self) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = self._run(_Request("GET", "/collections"))["collections"]
        return result

    def create_collection(self, definition: Mapping[str, Any]) -> dict[str, Any]:
        result: dict[str, Any] = self._run(_Request("POST", "/collections", body=dict(definition)))
        return result

    def describe_collection(self, name: str) -> dict[str, Any]:
        result: dict[str, Any] = self._run(_Request("GET", f"/collections/{_seg(name)}"))
        return result

    def alter_collection(self, name: str, operations: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
        body = {"operations": [dict(op) for op in operations]}
        result: dict[str, Any] = self._run(_Request("PATCH", f"/collections/{_seg(name)}", body=body))
        return result

    def drop_collection(self, name: str) -> None:
        self._run(_Request("DELETE", f"/collections/{_seg(name)}", params={"confirm": name}))

    # -- writes, feed, migrations, keys -----------------------------------------

    def transaction(self, operations: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
        """Writes that commit or roll back together."""
        body = {"operations": [dict(op) for op in operations]}
        result: dict[str, Any] = self._run(_Request("POST", "/transactions", body=body))
        return result

    def changes(self, *, since: int | Literal["latest"] = 0, collection: str | None = None, limit: int | None = None) -> dict[str, Any]:
        params = {"since": since, "collection": collection, "limit": limit}
        result: dict[str, Any] = self._run(_Request("GET", "/changes", params=params))
        return result

    def migrate(self, app: str, migrations: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
        body = {"app": app, "migrations": [dict(m) for m in migrations]}
        result: dict[str, Any] = self._run(_Request("POST", "/migrations", body=body))
        return result

    def migrations(self, app: str) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = self._run(_Request("GET", "/migrations", params={"app": app}))["migrations"]
        return result

    def mint_key(
        self,
        *,
        name: str,
        owner: str | None = None,
        collections: Sequence[str] | None = None,
        operations: Sequence[OperationName] | None = None,
        expires_in: int | None = None,
    ) -> dict[str, Any]:
        """Mints a data key (needs data:admin). The ``key`` is returned once."""
        body: dict[str, Any] = {"name": name}
        for k, v in (("owner", owner), ("expires_in", expires_in)):
            if v is not None:
                body[k] = v
        if collections is not None:
            body["collections"] = list(collections)
        if operations is not None:
            body["operations"] = list(operations)
        result: dict[str, Any] = self._run(_Request("POST", "/keys", body=body))
        return result

    def revoke_key(self, key_id: str) -> None:
        self._run(_Request("DELETE", f"/keys/{_seg(key_id)}"))

    def capabilities(self) -> dict[str, Any]:
        result: dict[str, Any] = self._run(_Request("GET", "/capabilities"))
        return result

    def _download(self, request: _Request, range: str | None) -> FileRange:
        import httpx

        url = build_url(self._client.base_url, "/api/data" + request.path)
        headers = {"Range": range} if range is not None else {}
        try:
            response = self._client._http.get(url, params=merge_query({"workspace": self.workspace}), headers=headers)
        except httpx.HTTPError as e:
            raise translate_httpx_error(e) from e
        raise_for_status(response)
        return FileRange(response.status_code, response.content, response.headers.get("content-range"))


class Collection:
    """Sync handle to one collection's records."""

    def __init__(self, data: DataResource, name: str) -> None:
        self._data = data
        self._c = _Collection(name)
        self.name = name

    def create(self, data: Mapping[str, Any], *, id: str | None = None) -> DataRecord:
        result: DataRecord = self._data._run(self._c.create(data, id))
        return result

    def get(self, id: str, *, fields: Sequence[str] | None = None, include: Sequence[str] | None = None) -> DataRecord:
        result: DataRecord = self._data._run(self._c.get(id, fields, include))
        return result

    def update(self, id: str, data: Mapping[str, Any], *, version: int | None = None) -> DataRecord:
        """Partial update; with ``version`` a stale write raises ``ConflictError``."""
        result: DataRecord = self._data._run(self._c.update(id, data, version))
        return result

    def delete(self, id: str, *, version: int | None = None) -> dict[str, Any]:
        result: dict[str, Any] = self._data._run(self._c.delete(id, version))
        return result

    def upsert(self, key: str | Sequence[str], data: Mapping[str, Any], *, id: str | None = None, version: int | None = None) -> DataRecord:
        result: DataRecord = self._data._run(self._c.upsert(key, data, id, version))
        return result

    def bulk_create(self, records: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
        """Inserts every record or none. Items are data maps or ``{"id", "data"}``."""
        result: dict[str, Any] = self._data._run(self._c.bulk_create(records))
        return result

    def query(
        self,
        *,
        where: Mapping[str, Any] | None = None,
        sort: Sequence[str | Mapping[str, str]] | None = None,
        limit: int | None = None,
        cursor: str | None = None,
        fields: Sequence[str] | None = None,
        count: bool | None = None,
        include: Sequence[str] | None = None,
        search: str | Mapping[str, Any] | None = None,
        semantic: str | Mapping[str, Any] | None = None,
    ) -> QueryResult:
        spec = _query_body(where, sort, limit, cursor, fields, count, include, search, semantic)
        result: QueryResult = self._data._run(self._c.query(spec))
        return result

    def iterate(self, **query: Any) -> Iterator[DataRecord]:
        """Every record matching the query, following cursors."""
        while True:
            page = self.query(**query)
            yield from page.get("records", [])
            cursor = page.get("next_cursor")
            if not cursor:
                return
            query["cursor"] = cursor

    def upload_file(self, id: str, filename: str, content: bytes, *, content_type: str | None = None) -> dict[str, Any]:
        result: dict[str, Any] = self._data._run(self._c.upload_file(id, filename, content, content_type))
        return result

    def rebuild_embeddings(self) -> dict[str, Any]:
        """Re-embeds every record's semantic fields now (synchronous)."""
        result: dict[str, Any] = self._data._run(self._c.rebuild_embeddings())
        return result

    def list_files(self, id: str) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = self._data._run(self._c.list_files(id))["files"]
        return result

    def download_file(self, id: str, file_id: str, *, range: str | None = None) -> FileRange:
        """Downloads a file; ``range`` is an HTTP byte range such as ``bytes=0-1023``."""
        return self._data._download(self._c.file(id, file_id), range)


# ---------------------------------------------------------------------------
# Async
# ---------------------------------------------------------------------------


class AsyncDataResource:
    """Async handler for ``/api/data`` in one workspace."""

    def __init__(self, client: AsyncOptimalEngine, workspace: str | None = None) -> None:
        self._client = client
        self._workspace = workspace

    @property
    def workspace(self) -> str:
        return self._workspace or self._client.workspace

    def in_workspace(self, workspace: str) -> AsyncDataResource:
        return AsyncDataResource(self._client, workspace)

    async def _run(self, request: _Request) -> Any:
        if request.method in ("GET", "DELETE"):
            params = {**request.params, "workspace": self.workspace}
            return await self._client._request(request.method, "/api/data" + request.path, params=params)
        body = {**(request.body or {}), "workspace": self.workspace}
        return await self._client._request(request.method, "/api/data" + request.path, json_body=body)

    def collection(self, name: str) -> AsyncCollection:
        return AsyncCollection(self, name)

    async def list_collections(self) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = (await self._run(_Request("GET", "/collections")))["collections"]
        return result

    async def create_collection(self, definition: Mapping[str, Any]) -> dict[str, Any]:
        result: dict[str, Any] = await self._run(_Request("POST", "/collections", body=dict(definition)))
        return result

    async def transaction(self, operations: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
        body = {"operations": [dict(op) for op in operations]}
        result: dict[str, Any] = await self._run(_Request("POST", "/transactions", body=body))
        return result

    async def changes(self, *, since: int | Literal["latest"] = 0, collection: str | None = None, limit: int | None = None) -> dict[str, Any]:
        params = {"since": since, "collection": collection, "limit": limit}
        result: dict[str, Any] = await self._run(_Request("GET", "/changes", params=params))
        return result

    async def migrate(self, app: str, migrations: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
        body = {"app": app, "migrations": [dict(m) for m in migrations]}
        result: dict[str, Any] = await self._run(_Request("POST", "/migrations", body=body))
        return result


class AsyncCollection:
    """Async handle to one collection's records."""

    def __init__(self, data: AsyncDataResource, name: str) -> None:
        self._data = data
        self._c = _Collection(name)
        self.name = name

    async def create(self, data: Mapping[str, Any], *, id: str | None = None) -> DataRecord:
        result: DataRecord = await self._data._run(self._c.create(data, id))
        return result

    async def get(self, id: str, *, fields: Sequence[str] | None = None, include: Sequence[str] | None = None) -> DataRecord:
        result: DataRecord = await self._data._run(self._c.get(id, fields, include))
        return result

    async def update(self, id: str, data: Mapping[str, Any], *, version: int | None = None) -> DataRecord:
        result: DataRecord = await self._data._run(self._c.update(id, data, version))
        return result

    async def delete(self, id: str, *, version: int | None = None) -> dict[str, Any]:
        result: dict[str, Any] = await self._data._run(self._c.delete(id, version))
        return result

    async def upsert(self, key: str | Sequence[str], data: Mapping[str, Any], *, id: str | None = None, version: int | None = None) -> DataRecord:
        result: DataRecord = await self._data._run(self._c.upsert(key, data, id, version))
        return result

    async def bulk_create(self, records: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = await self._data._run(self._c.bulk_create(records))
        return result

    async def query(self, **query: Any) -> QueryResult:
        spec = _query_body(
            query.get("where"),
            query.get("sort"),
            query.get("limit"),
            query.get("cursor"),
            query.get("fields"),
            query.get("count"),
            query.get("include"),
            query.get("search"),
            query.get("semantic"),
        )
        result: QueryResult = await self._data._run(self._c.query(spec))
        return result

    async def iterate(self, **query: Any) -> AsyncIterator[DataRecord]:
        while True:
            page = await self.query(**query)
            for record in page.get("records", []):
                yield record
            cursor = page.get("next_cursor")
            if not cursor:
                return
            query["cursor"] = cursor


__all__ = [
    "AsyncCollection",
    "AsyncDataResource",
    "Collection",
    "DataRecord",
    "DataResource",
    "FieldType",
    "FileRange",
    "QueryResult",
]
