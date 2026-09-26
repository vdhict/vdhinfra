"""Open WebUI chat retention for family-ai (chg-2026-09-26-001 v3, Sander: 30 days).

Deletes every chat whose LAST ACTIVITY (chat.updated_at) is older than
RETENTION_DAYS, through Open WebUI's OWN model layer - the same calls the
admin path of DELETE /api/v1/chats/{id} makes (routers/chats.py v0.11.4):
  Chats.delete_orphan_tags_for_user(tags, owner, threshold=1)
  internal child chats -> Chats.delete_chat_by_id_and_user_id(child, owner)
  Chats.delete_chat_by_id(id)  -> automation_run.chat_id=NULL, chat_message
                                   rows, the chat, its shared copy
The two router-only steps are skipped on purpose: stop_item_tasks (no Redis
here, and a chat idle for 30 days has no in-flight task) and the
CHAT_DELETED event publish (no subscribers in this deployment).

Why not the HTTP API: an admin can only enumerate OTHER users' chats with
ENABLE_ADMIN_CHAT_ACCESS or ENABLE_ADMIN_EXPORT, which family-ai keeps off
for privacy. Why not raw SQL: it would have to re-implement the cascade and
silently drift on every Open WebUI upgrade.

Concurrency with the running app: SQLite in WAL mode (Open WebUI default).
This pod mounts the same RWO PVC on the SAME node (required pod affinity -
WAL's shared-memory index only works between processes on one host; on
another node the RWO attach fails and the Job never starts). Each chat is
its own short transaction; busy_timeout 30 s here, and the app's 5 s
default is far above the few milliseconds one delete holds the write lock.

Output: COUNTS ONLY. Never a chat id, title, user id or content.
Env: RETENTION_DAYS (int >= 1), RETENTION_DRY_RUN (true|false),
     RETENTION_ONLY_USER_ID (test runs only: limit to one account).
"""
import asyncio
import json
import os
import sys
import time

os.environ["ENABLE_DB_MIGRATIONS"] = "false"   # never migrate from a side job

from sqlalchemy import func, select  # noqa: E402

from open_webui.internal.db import get_async_db_context  # noqa: E402
from open_webui.models.chats import Chat, Chats  # noqa: E402


def out(**kw):
    print(json.dumps({"job": "chat-retention", **kw}), flush=True)


async def main() -> int:
    days = int(os.environ.get("RETENTION_DAYS", "30"))
    if days < 1:
        out(error="RETENTION_DAYS must be >= 1")
        return 2
    dry = os.environ.get("RETENTION_DRY_RUN", "false").lower() == "true"
    only = os.environ.get("RETENTION_ONLY_USER_ID", "")
    cutoff = int(time.time()) - days * 86400

    async with get_async_db_context() as s:
        total_before = (await s.execute(select(func.count()).select_from(Chat))).scalar_one()
        q = select(Chat.id, Chat.user_id, Chat.meta).where(Chat.updated_at < cutoff)
        # shared copies are removed together with their source chat
        q = q.where(~Chat.user_id.like("shared-%"))
        if only:
            q = q.where(Chat.user_id == only)
        rows = (await s.execute(q)).all()

    deleted = failed = children = 0
    if not dry:
        for cid, owner, meta in rows:
            await Chats.delete_orphan_tags_for_user((meta or {}).get("tags", []), owner, threshold=1)
            for child in await Chats.get_internal_chat_ids_by_parent_id(cid, owner):
                if await Chats.delete_chat_by_id_and_user_id(child, owner):
                    children += 1
            if await Chats.delete_chat_by_id(cid):
                deleted += 1
            else:
                failed += 1

    async with get_async_db_context() as s:
        total_after = (await s.execute(select(func.count()).select_from(Chat))).scalar_one()
    out(days=days, dry_run=dry, scoped=bool(only), candidates=len(rows), deleted=deleted,
        children_deleted=children, failed=failed, chats_before=total_before, chats_after=total_after)
    return 1 if failed else 0


sys.exit(asyncio.run(main()))
