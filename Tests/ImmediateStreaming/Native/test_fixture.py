"""Verify the video replay's payload and absolute schedule without wall-clock waits."""
import hashlib
import json
import types
import unittest
from unittest.mock import patch
import fixture


class ReplayTests(unittest.IsolatedAsyncioTestCase):
    async def test_task_registry_matches_client_protocol(self):
        request = types.SimpleNamespace(path="/api/tasks/chat/chat", method="GET", can_read_body=False)
        for tasks, expected in [(set(), []), ({object()}, ["synthetic-task"])]:
            with patch.object(fixture, "RUNNING", tasks):
                response = await fixture.handle(request)
                self.assertEqual(json.loads(response.body), {"task_ids": expected})

    async def replay(self, mode, emit_cost):
        now = 0.0
        deliveries = []

        async def sleep(delay):
            nonlocal now
            now += delay

        async def emit(event, envelope):
            nonlocal now
            deliveries.append((now, envelope["data"]))
            now += emit_cost

        fixture.CHATS.clear()
        fixture.METRICS.clear()
        fixture.CHATS["chat"] = {"title": "Synthetic replay", "chat": {}}
        clock = types.SimpleNamespace(monotonic=lambda: now, time=lambda: now)
        with patch.object(fixture, "time", clock), patch.object(fixture.asyncio, "sleep", sleep), \
                patch.object(fixture.sio, "emit", emit), patch("builtins.print"):
            await fixture.generate({"chat_id": "chat", "id": "answer"}, "video-" + mode)
        start = next(item for item in fixture.METRICS if item["event"] == "answer_start")
        chunks = [(when, event["data"]["delta"]) for when, event in deliveries
                  if event["type"] == "response:completion"
                  and event["data"]["type"] == "response.output_text.delta"]
        text = "".join(delta for _, delta in chunks)
        self.assertEqual(hashlib.sha256(text.encode()).hexdigest(), start["sha256"])
        self.assertEqual(len(text), start["answer_chars"])
        for index, (when, _) in enumerate(chunks):
            self.assertAlmostEqual(when - start["time"], index * start["interval"], places=7)
        statuses = [event["data"]["description"] for _, event in deliveries if event["type"] == "status"]
        self.assertEqual(statuses[-3:], ["Replay ready", "Replay running", "Replay complete"])
        final = next(event["data"] for _, event in deliveries if event["type"] == "chat:completion")
        self.assertEqual(final["output"][-1]["content"][0]["text"], text)
        self.assertTrue(final["done"])
        return text

    async def test_identical_payload_and_deadlines_despite_emit_overhead(self):
        for mode in ["slow-thinking", "mixed", "long"]:
            with self.subTest(mode=mode):
                self.assertEqual(await self.replay(mode, 0), await self.replay(mode, 0.005))


if __name__ == "__main__":
    unittest.main()
