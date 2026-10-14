"""Handler round trips against moto's DynamoDB and Cognito.

Run: uv run --python .venv/bin/python -m pytest  (from cloud/api)
"""

import json
import os

import boto3
import pytest
from moto import mock_aws

os.environ.setdefault("AWS_DEFAULT_REGION", "us-west-2")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "testing")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
os.environ["TABLE_NAME"] = "Spans"

import handler  # noqa: E402  (env first)

A, B = "aaaaaaaa-1111", "bbbbbbbb-2222"
# Mid-minute, mid-day, so a test never straddles a rate window.
NOW = 1_790_000_010.0


@pytest.fixture
def cloud(monkeypatch):
    with mock_aws():
        handler._table = handler._cognito = handler._lambda = None
        monkeypatch.setattr(handler, "_now", lambda: NOW)
        jobs = []
        monkeypatch.setattr(handler, "_invoke_self", jobs.append)
        ddb = boto3.resource("dynamodb")
        ddb.create_table(
            TableName="Spans",
            KeySchema=[{"AttributeName": "userId", "KeyType": "HASH"}, {"AttributeName": "sk", "KeyType": "RANGE"}],
            AttributeDefinitions=[
                {"AttributeName": "userId", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"},
                {"AttributeName": "seq", "AttributeType": "S"},
            ],
            GlobalSecondaryIndexes=[{
                "IndexName": "bySeq",
                "KeySchema": [{"AttributeName": "userId", "KeyType": "HASH"}, {"AttributeName": "seq", "KeyType": "RANGE"}],
                "Projection": {"ProjectionType": "ALL"},
            }],
            BillingMode="PAY_PER_REQUEST",
        )
        idp = boto3.client("cognito-idp")
        pool = idp.create_user_pool(PoolName="t")["UserPool"]["Id"]
        os.environ["USER_POOL_ID"] = pool
        user = idp.admin_create_user(UserPoolId=pool, Username="allen@example.com")["User"]
        sub = next(a["Value"] for a in user["Attributes"] if a["Name"] == "sub")
        yield {"sub": sub, "username": "allen@example.com", "idp": idp, "pool": pool, "table": ddb.Table("Spans"),
               "jobs": jobs}


class Context:
    """The one thing the delete job asks of a Lambda context."""

    def __init__(self, remaining_ms):
        self.remaining_ms = remaining_ms

    def get_remaining_time_in_millis(self):
        return self.remaining_ms


def raw_call(cloud, route, body=None, query=None):
    event = {
        "routeKey": route,
        "requestContext": {"authorizer": {"jwt": {"claims": {"sub": cloud["sub"], "username": cloud["username"]}}}},
        "body": json.dumps(body) if body is not None else None,
        "queryStringParameters": query,
    }
    return handler.handler(event, None)


def call(cloud, route, body=None, query=None):
    resp = raw_call(cloud, route, body, query)
    return resp["statusCode"], (json.loads(resp["body"]) if resp.get("body") else None)


def span(i):
    return {"originId": i, "start": f"2026-09-22T10:00:{i % 60:02d}.000Z", "end": f"2026-09-22T10:01:{i % 60:02d}.000Z",
            "appBundleID": "com.test", "appName": "Test", "title": f"t{i}", "url": None}


def spans_in_table(cloud):
    return [i for i in cloud["table"].scan()["Items"] if not i["sk"].startswith("#")]


def test_push_then_pull_from_other_device(cloud):
    status, acked = call(cloud, "POST /spans", {"deviceId": A, "spans": [span(i) for i in range(3)]})
    assert status == 200
    assert [a["originId"] for a in acked["acked"]] == [0, 1, 2]
    assert acked["acked"][0]["seq"] < acked["acked"][2]["seq"]
    assert acked["rejected"] == []

    status, page = call(cloud, "GET /spans", query={"deviceId": B})
    assert status == 200
    assert [s["originId"] for s in page["spans"]] == [0, 1, 2]
    assert page["spans"][0]["deviceId"] == A and page["spans"][0]["title"] == "t0"
    assert "url" not in page["spans"][0]  # None is dropped, not stored
    assert page["cursor"] == acked["acked"][2]["seq"] and page["more"] is False

    # The pushing device never gets its own rows back, but its cursor moves
    # past them, so a device alone on its account stops re-reading them.
    _, own = call(cloud, "GET /spans", query={"deviceId": A})
    assert own["spans"] == [] and own["cursor"] == acked["acked"][2]["seq"]
    _, again = call(cloud, "GET /spans", query={"deviceId": A, "after": own["cursor"]})
    assert again["spans"] == [] and again["cursor"] == own["cursor"]


def test_own_rows_advance_the_cursor_across_pages(cloud, monkeypatch):
    monkeypatch.setattr(handler, "PAGE", 2)
    _, acked = call(cloud, "POST /spans", {"deviceId": A, "spans": [span(i) for i in range(3)]})
    call(cloud, "POST /spans", {"deviceId": B, "spans": [span(9)]})
    _, first = call(cloud, "GET /spans", query={"deviceId": A})
    assert first["spans"] == [] and first["more"] is True and first["cursor"] == acked["acked"][1]["seq"]
    _, second = call(cloud, "GET /spans", query={"deviceId": A, "after": first["cursor"]})
    assert [s["originId"] for s in second["spans"]] == [9] and second["cursor"] > acked["acked"][2]["seq"]


def test_retried_push_overwrites_instead_of_duplicating(cloud):
    call(cloud, "POST /spans", {"deviceId": A, "spans": [span(7)]})
    call(cloud, "POST /spans", {"deviceId": A, "spans": [span(7)]})
    assert len(spans_in_table(cloud)) == 1


def test_after_pages_exactly_and_since_overlaps(cloud):
    _, acked = call(cloud, "POST /spans", {"deviceId": A, "spans": [span(i) for i in range(4)]})
    seqs = [a["seq"] for a in acked["acked"]]
    _, page = call(cloud, "GET /spans", query={"deviceId": B, "after": seqs[1]})
    assert [s["originId"] for s in page["spans"]] == [2, 3]
    # `since` is widened by 60 s, so a fresh pull from the last cursor re-reads
    # everything written in the last minute: that is the point of it.
    _, page = call(cloud, "GET /spans", query={"deviceId": B, "since": seqs[3]})
    assert [s["originId"] for s in page["spans"]] == [0, 1, 2, 3]


def test_impossible_times_are_acknowledged_but_not_stored(cloud):
    backwards = span(1) | {"start": "2026-09-22T10:05:00.000Z", "end": "2026-09-22T10:00:00.000Z"}
    status, reply = call(cloud, "POST /spans", {"deviceId": A, "spans": [
        span(0),
        backwards,
        span(2) | {"start": "yesterday"},
        span(3) | {"end": "2026-13-01T00:00:00.000Z"},
        span(4) | {"start": "2026-09-22T18:00:04+08:00"},  # 10:00:04Z, before its end
        span(5) | {"start": "2026-09-22T10:00:05Z", "end": "2026-09-22T10:00:05Z"},  # no fraction, zero length: fine
        span(6) | {"end": "2026-09-22 10:01:06"},  # no offset
    ]})
    assert status == 200
    assert sorted(a["originId"] for a in reply["acked"]) == [0, 1, 2, 3, 4, 5, 6]
    assert sorted(r["originId"] for r in reply["rejected"]) == [1, 2, 3, 6]
    assert sorted(int(i["originId"]) for i in spans_in_table(cloud)) == [0, 4, 5]


def test_long_fields_are_cut_not_refused(cloud):
    long = span(0) | {"title": "標" * 5000, "url": "u" * 4096, "appName": "a" * 300}
    status, reply = call(cloud, "POST /spans", {"deviceId": A, "spans": [long]})
    assert status == 200 and reply["rejected"] == []
    (item,) = spans_in_table(cloud)
    assert len(item["title"]) == 1024 and len(item["url"]) == 2048 and len(item["appName"]) == 255


@pytest.mark.parametrize("body", [
    {"deviceId": "x", "spans": []},
    {"deviceId": A, "spans": [{"originId": -1}]},
    {"deviceId": A, "spans": [{"originId": 1, "start": "s", "end": "e", "appBundleID": "b"}]},
    {"deviceId": A, "spans": [span(1) | {"title": 5}]},
    {"deviceId": A, "spans": [span(i) for i in range(501)]},
])
def test_bad_push_is_400(cloud, body):
    status, err = call(cloud, "POST /spans", body)
    assert status == 400 and "error" in err
    assert spans_in_table(cloud) == []


def test_requests_past_the_per_minute_limit_get_429(cloud, monkeypatch):
    monkeypatch.setattr(handler, "RATE_PER_MINUTE", 3)
    for _ in range(3):
        assert call(cloud, "GET /spans", query={"deviceId": B})[0] == 200
    resp = raw_call(cloud, "POST /spans", {"deviceId": A, "spans": [span(0)]})
    assert resp["statusCode"] == 429
    assert resp["headers"]["Retry-After"] == "30"  # NOW is 30 s into its minute
    assert spans_in_table(cloud) == []
    # The next minute starts afresh.
    monkeypatch.setattr(handler, "_now", lambda: NOW + 60)
    assert call(cloud, "GET /spans", query={"deviceId": B})[0] == 200


def test_rows_past_the_daily_cap_get_429_until_midnight(cloud, monkeypatch):
    monkeypatch.setattr(handler, "DAILY_ITEMS", 5)
    assert call(cloud, "POST /spans", {"deviceId": A, "spans": [span(i) for i in range(3)]})[0] == 200
    resp = raw_call(cloud, "POST /spans", {"deviceId": A, "spans": [span(i) for i in range(3, 6)]})
    assert resp["statusCode"] == 429
    assert int(resp["headers"]["Retry-After"]) == 86400 - int(NOW) % 86400
    # A batch that fits is still taken; rejected rows do not count.
    status, reply = call(cloud, "POST /spans", {"deviceId": A, "spans": [span(3), span(4), span(5) | {"start": "x"}]})
    assert status == 200 and len(reply["acked"]) == 3
    assert len(spans_in_table(cloud)) == 5
    assert raw_call(cloud, "POST /spans", {"deviceId": A, "spans": [span(6)]})["statusCode"] == 429


def test_delete_account_turns_devices_away_then_empties_table_and_pool(cloud):
    call(cloud, "POST /spans", {"deviceId": A, "spans": [span(i) for i in range(30)]})
    status, _ = call(cloud, "DELETE /account")
    assert status == 202
    user = cloud["idp"].admin_get_user(UserPoolId=cloud["pool"], Username=cloud["username"])
    assert user["Enabled"] is False
    assert cloud["jobs"] == [{"deleteJob": {"userId": cloud["sub"], "username": cloud["username"]}}]

    # Another Mac's access token still passes the authorizer for up to an hour.
    assert call(cloud, "POST /spans", {"deviceId": B, "spans": [span(40)]})[0] == 410
    assert call(cloud, "GET /spans", query={"deviceId": B})[0] == 410

    result = handler.handler(cloud["jobs"][0], Context(remaining_ms=25_000))
    assert result == {"done": True}
    left = cloud["table"].scan()["Items"]
    assert [i["sk"] for i in left] == ["#deleted"] and "expiresAt" in left[0]
    with pytest.raises(cloud["idp"].exceptions.UserNotFoundException):
        cloud["idp"].admin_get_user(UserPoolId=cloud["pool"], Username=cloud["username"])
    # A repeat (a retry, or the job's own retry) is harmless.
    assert call(cloud, "DELETE /account")[0] == 202
    assert handler.handler(cloud["jobs"][-1], Context(remaining_ms=25_000)) == {"done": True}


def test_delete_job_pages_and_hands_over_before_timeout(cloud, monkeypatch):
    monkeypatch.setattr(handler, "DELETE_PAGE", 10)
    call(cloud, "POST /spans", {"deviceId": A, "spans": [span(i) for i in range(35)]})
    call(cloud, "DELETE /account")
    job = cloud["jobs"].pop()

    # Nearly out of time: one page, then a fresh invocation takes over.
    assert handler.handler(job, Context(remaining_ms=5_000)) == {"handedOver": True}
    assert cloud["jobs"] == [job]
    remaining = len(spans_in_table(cloud))
    assert 0 < remaining < 35
    cloud["idp"].admin_get_user(UserPoolId=cloud["pool"], Username=cloud["username"])  # not yet deleted

    assert handler.handler(cloud["jobs"].pop(), Context(remaining_ms=25_000)) == {"done": True}
    assert spans_in_table(cloud) == []
    with pytest.raises(cloud["idp"].exceptions.UserNotFoundException):
        cloud["idp"].admin_get_user(UserPoolId=cloud["pool"], Username=cloud["username"])


def test_delete_job_without_marker_does_nothing(cloud):
    call(cloud, "POST /spans", {"deviceId": A, "spans": [span(0)]})
    job = {"deleteJob": {"userId": cloud["sub"], "username": cloud["username"]}}
    assert handler.handler(job, Context(remaining_ms=25_000)) == {"skipped": "no deletion marker"}
    assert len(spans_in_table(cloud)) == 1


def test_push_that_races_a_deletion_removes_what_it_wrote(cloud, monkeypatch):
    # The marker lands between the push's first check and its writes.
    answers = iter([False, True])
    monkeypatch.setattr(handler, "_deleted", lambda _user: next(answers))
    assert call(cloud, "POST /spans", {"deviceId": A, "spans": [span(i) for i in range(3)]})[0] == 410
    assert spans_in_table(cloud) == []
