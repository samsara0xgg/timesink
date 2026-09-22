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


@pytest.fixture
def cloud():
    with mock_aws():
        handler._table = handler._cognito = None
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
        yield {"sub": sub, "username": "allen@example.com", "idp": idp, "pool": pool, "table": ddb.Table("Spans")}


def call(cloud, route, body=None, query=None):
    event = {
        "routeKey": route,
        "requestContext": {"authorizer": {"jwt": {"claims": {"sub": cloud["sub"], "username": cloud["username"]}}}},
        "body": json.dumps(body) if body is not None else None,
        "queryStringParameters": query,
    }
    resp = handler.handler(event, None)
    return resp["statusCode"], (json.loads(resp["body"]) if resp.get("body") else None)


def span(i):
    return {"originId": i, "start": f"2026-09-22T10:00:{i:02d}.000Z", "end": f"2026-09-22T10:01:{i:02d}.000Z",
            "appBundleID": "com.test", "appName": "Test", "title": f"t{i}", "url": None}


def test_push_then_pull_from_other_device(cloud):
    status, acked = call(cloud, "POST /spans", {"deviceId": A, "spans": [span(i) for i in range(3)]})
    assert status == 200
    assert [a["originId"] for a in acked["acked"]] == [0, 1, 2]
    assert acked["acked"][0]["seq"] < acked["acked"][2]["seq"]

    status, page = call(cloud, "GET /spans", query={"deviceId": B})
    assert status == 200
    assert [s["originId"] for s in page["spans"]] == [0, 1, 2]
    assert page["spans"][0]["deviceId"] == A and page["spans"][0]["title"] == "t0"
    assert "url" not in page["spans"][0]  # None is dropped, not stored
    assert page["cursor"] == acked["acked"][2]["seq"] and page["more"] is False

    # The pushing device never gets its own rows back.
    _, own = call(cloud, "GET /spans", query={"deviceId": A})
    assert own["spans"] == [] and own["cursor"] is None


def test_retried_push_overwrites_instead_of_duplicating(cloud):
    call(cloud, "POST /spans", {"deviceId": A, "spans": [span(7)]})
    call(cloud, "POST /spans", {"deviceId": A, "spans": [span(7)]})
    assert cloud["table"].scan()["Count"] == 1


def test_after_pages_exactly_and_since_overlaps(cloud):
    _, acked = call(cloud, "POST /spans", {"deviceId": A, "spans": [span(i) for i in range(4)]})
    seqs = [a["seq"] for a in acked["acked"]]
    _, page = call(cloud, "GET /spans", query={"deviceId": B, "after": seqs[1]})
    assert [s["originId"] for s in page["spans"]] == [2, 3]
    # `since` is widened by 60 s, so a fresh pull from the last cursor re-reads
    # everything written in the last minute: that is the point of it.
    _, page = call(cloud, "GET /spans", query={"deviceId": B, "since": seqs[3]})
    assert [s["originId"] for s in page["spans"]] == [0, 1, 2, 3]


def test_delete_account_empties_table_and_pool(cloud):
    call(cloud, "POST /spans", {"deviceId": A, "spans": [span(i) for i in range(30)]})
    status, _ = call(cloud, "DELETE /account")
    assert status == 204
    assert cloud["table"].scan()["Count"] == 0
    with pytest.raises(cloud["idp"].exceptions.UserNotFoundException):
        cloud["idp"].admin_get_user(UserPoolId=cloud["pool"], Username=cloud["username"])


@pytest.mark.parametrize("body", [
    {"deviceId": "x", "spans": []},
    {"deviceId": A, "spans": [{"originId": -1}]},
    {"deviceId": A, "spans": [{"originId": 1, "start": "s", "end": "e", "appBundleID": "b"}]},
    {"deviceId": A, "spans": [{"originId": 1, "start": "s", "end": "e", "appBundleID": "b", "appName": "a", "title": "x" * 5000}]},
])
def test_bad_push_is_400(cloud, body):
    status, err = call(cloud, "POST /spans", body)
    assert status == 400 and "error" in err
    assert cloud["table"].scan()["Count"] == 0
