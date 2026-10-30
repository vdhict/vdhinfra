#!/usr/bin/env python3
"""chg-2026-10-20-010 W2c gates on the family-cloud Router itself (Argus 08:29:01Z M2/M3), offline, synthetic.

    FC_PLUGIN=<family-ai>/plugin/model-providers/family-cloud/__init__.py <python with httpx> -I hack/family-ai/test_cloud_router_w2c.py

The real Router with the real cloud transport stack (cloud_client + cloud_headers + messages_request/response) on an
httpx.MockTransport: no network. Only the Hermes runtime gates (interactive_reply, _dispatch_agent, runtime_pinned,
private_context, cloud_request) are stubbed to "public admitted turn", because they are tested elsewhere (a10, M4).
  M3 fallback: billing refusal (HTTP 400 credit balance too low), 429/529 overload, timeout, connect error, garbage
     -> the turn answers from the Studio, the cloud is called exactly once (no retry loop), rule cloud_failed, the
     reservation stays on the shared ledger (never a negative/unknown spend).
  M2 cap: one ledger for profiel-1/2/3 (three Routers, one month.json): every person's spend counts in usd; the cap
     stops BEFORE the total passes budget_usd; across the 2026-10-31T23:59Z -> 2026-11-01T00:00Z rollover the total
     spend with budget_usd 99 never passes 200 (interim: the month reset can at most double 99 -> 198).
"""
import importlib.util
import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

PLUGIN = Path(os.environ["FC_PLUGIN"])
PRICE = {"input": 3.0, "output": 15.0, "cache_read": 0.3, "cache_write": 3.75}


def load():
    providers = types.ModuleType("providers")
    providers.register_provider = lambda cls: None
    base = types.ModuleType("providers.base")
    base.ProviderProfile = type("ProviderProfile", (), {"__init__": lambda self, **kw: self.__dict__.update(kw)})
    with patch.dict("sys.modules", {"providers": providers, "providers.base": base}):
        spec = importlib.util.spec_from_file_location("fc_w2c", PLUGIN)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
    return m


class Agent:
    session_id = "synthetic-session"
    _memory_store = object()
    _memory_manager = None


def settings(person, budget=99):
    return {"provider": "anthropic", "endpoint": "https://api.anthropic.com/v1", "model": "m", "price_confirmed": True,
            "budget_usd": budget, "soft_fraction": 0.8, "timeout_seconds": 5, "input_token_ceiling": 65536,
            "output_token_ceiling": 4096, "context_tokens": 65536, "vision": True, "person": person,
            "prices_usd_per_million": {"m": PRICE}, "workspace_id": "wrkspc_synthetic0000"}


def body():
    return {"model": "m", "max_tokens": 512, "messages": [{"role": "system", "content": "s"},
                                                          {"role": "user", "content": "synthetic public question"}]}


OK_RESPONSE = {"id": "msg_x", "type": "message", "role": "assistant", "model": "m", "stop_reason": "end_turn",
               "content": [{"type": "text", "text": "synthetic answer"}],
               "usage": {"input_tokens": 7500, "output_tokens": 300, "cache_read_input_tokens": 0,
                         "cache_creation_input_tokens": 0}}


class W2c(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        os.environ["FAMILY_CLOUD_ROUTE_FILE"] = str(Path(cls.tmp.name) / "route.jsonl")
        os.environ["CLOUD_API_KEY"] = "sk-ant-synthetic-" + "x" * 40
        cls.m = load()
        import httpx
        cls.httpx = httpx

    def setUp(self):
        self.d = Path(tempfile.mkdtemp(dir=self.tmp.name))
        self.state = self.d / "month.json"
        self.state.write_text(json.dumps({"month": "2026-10", "usd": 0, "input_tokens": 0, "output_tokens": 0,
                                          "cache_read_tokens": 0, "cache_write_tokens": 0,
                                          "person_usd": {"profiel-1": 0, "profiel-2": 0, "profiel-3": 0}}))
        self.route = Path(os.environ["FAMILY_CLOUD_ROUTE_FILE"])
        self.route.write_text("")
        m = self.m
        for name, value in (("interactive_reply", lambda: True), ("_dispatch_agent", lambda: Agent()),
                            ("runtime_pinned", lambda: True), ("private_context", lambda b: False),
                            ("owui_task_request", lambda b: False),
                            ("cloud_request", lambda b, a, s, **k: dict(b))):
            p = patch.object(m, name, value)
            p.start()
            self.addCleanup(p.stop)
        self.calls = {"cloud": 0, "studio": 0}

    def router(self, person, handler, month="2026-10", budget=99):
        m, httpx = self.m, self.httpx
        s = settings(person, budget)
        client = m.cloud_client(s["timeout_seconds"], transport=httpx.MockTransport(handler))

        def cloud(b):   # the same steps as CloudProfile.create_client's cloud()
            self.calls["cloud"] += 1
            r = client.post(s["endpoint"] + "/messages", json=m.messages_request(b), headers=m.cloud_headers(s))
            r.raise_for_status()
            return m.messages_response(r.json())

        def studio(b):
            self.calls["studio"] += 1
            return {"id": "chatcmpl-studio", "choices": [{"index": 0, "finish_reason": "stop",
                                                          "message": {"role": "assistant", "content": "studio answer"}}],
                    "usage": {"prompt_tokens": 1, "completion_tokens": 1}}

        r = m.Router(s, self.state, cloud, studio, clock=lambda: month, sticky=self.d / f"sticky-{person}.json",
                     cloud_soul="pinned")
        r.sticky.history_is_cloud = lambda sid, b: True   # fresh public conversation (C1 tested elsewhere)
        return r

    def ledger(self):
        return json.loads(self.state.read_text())

    def rules(self):
        return [json.loads(l)["route"] + "/" + json.loads(l)["rule"] for l in self.route.read_text().splitlines() if l]

    def reserve(self):
        s = settings("profiel-2")
        return (s["input_token_ceiling"] * max(PRICE["input"], PRICE["cache_write"]) + s["output_token_ceiling"] * PRICE["output"]) / 1e6

    # --- M3: provider refusals fall back to the Studio, no retry loop -------------------------------------------
    def fallback(self, handler, rule="cloud_failed"):
        r = self.router("profiel-2", handler)
        out = r.route(body())
        self.assertEqual(out["choices"][0]["message"]["content"], "studio answer")
        self.assertEqual(self.calls, {"cloud": 1, "studio": 1}, "cloud tried exactly once, Studio answered once")
        self.assertEqual(self.rules(), ["studio/" + rule])
        led = self.ledger()
        self.assertAlmostEqual(led["usd"], self.reserve(), places=9)   # reservation kept: unknown usage never undercounts
        self.assertAlmostEqual(led["person_usd"]["profiel-2"], self.reserve(), places=9)
        return out

    def test_billing_refusal_insufficient_credit(self):
        body_400 = {"type": "error", "error": {"type": "invalid_request_error",
                                               "message": "Your credit balance is too low to access the Anthropic API."}}
        self.fallback(lambda req: self.httpx.Response(400, json=body_400))

    def test_rate_limit_and_overload(self):
        for code in (429, 529, 500):
            with self.subTest(code=code):
                self.setUp()
                self.fallback(lambda req, c=code: self.httpx.Response(c, json={"type": "error"}))

    def test_timeout_and_connect_error(self):
        for exc in (self.httpx.ReadTimeout("t"), self.httpx.ConnectError("c")):
            with self.subTest(exc=type(exc).__name__):
                self.setUp()

                def h(req, e=exc):
                    raise e
                self.fallback(h)

    def test_unparseable_success_body(self):
        self.setUp()
        r = self.router("profiel-2", lambda req: self.httpx.Response(200, content=b"not json"))
        out = r.route(body())
        self.assertEqual(out["choices"][0]["message"]["content"], "studio answer")
        self.assertEqual(self.calls["cloud"], 1)
        self.assertTrue(self.rules()[0].startswith("studio/"))

    def test_ten_failing_turns_never_retry_within_a_turn(self):
        r = self.router("profiel-2", lambda req: self.httpx.Response(400, json={"type": "error"}))
        for i in range(10):
            r.route(body())
        self.assertEqual(self.calls, {"cloud": 10, "studio": 10})

    # --- M2: one shared cap ------------------------------------------------------------------------------------
    def test_three_profiles_one_ledger(self):
        ok = lambda req: self.httpx.Response(200, json=OK_RESPONSE)
        for person in ("profiel-1", "profiel-2", "profiel-3"):
            self.router(person, ok).route(body())
        led = self.ledger()
        cost = (7500 * PRICE["input"] + 300 * PRICE["output"]) / 1e6
        self.assertAlmostEqual(led["usd"], 3 * cost, places=9)
        for person in ("profiel-1", "profiel-2", "profiel-3"):
            self.assertAlmostEqual(led["person_usd"][person], cost, places=9)
        self.assertEqual(led["input_tokens"], 3 * 7500)

    def test_cap_stops_before_the_total_passes_budget(self):
        led = self.ledger()
        led["usd"] = 99 - self.reserve() / 2   # less than one reservation left
        led["person_usd"]["profiel-3"] = led["usd"]
        self.state.write_text(json.dumps(led))
        for person in ("profiel-1", "profiel-2"):
            out = self.router(person, lambda req: self.httpx.Response(200, json=OK_RESPONSE)).route(body())
            self.assertEqual(out["choices"][0]["message"]["content"], "studio answer")
        self.assertEqual(self.calls["cloud"], 0, "no cloud call once a reservation would pass the cap")
        self.assertEqual(self.rules(), ["studio/guard_budget", "studio/guard_budget"])
        self.assertLessEqual(self.ledger()["usd"], 99)

    def spend_until_refused(self, month, persons=("profiel-1", "profiel-2", "profiel-3")):
        big = dict(OK_RESPONSE, usage={"input_tokens": 60000, "output_tokens": 4000, "cache_read_input_tokens": 0,
                                       "cache_creation_input_tokens": 0})
        spent, turns = 0.0, 0
        while turns < 5000:
            before = self.ledger()["usd"] if self.ledger()["month"] == month else 0.0
            n0 = self.calls["cloud"]
            self.router(persons[turns % 3], lambda req: self.httpx.Response(200, json=big), month=month).route(body())
            turns += 1
            if self.calls["cloud"] == n0:
                return spent
            spent += self.ledger()["usd"] - before
        self.fail("cap never stopped")

    def test_rollover_31_10_to_1_11_total_stays_below_200(self):
        """2026-10-31T23:59Z -> 2026-11-01T00:00Z with budget 99: worst case spend both months <= 198 < 200."""
        october = self.spend_until_refused("2026-10")
        self.assertLessEqual(october, 99)
        november = self.spend_until_refused("2026-11")   # the plugin's month reset happens here
        self.assertLessEqual(november, 99)
        total = october + november
        self.assertLess(total, 200, f"total {total:.2f} across the rollover")
        self.assertLessEqual(self.ledger()["usd"], 99)
        print(f"\n  rollover: october {october:.2f} + november {november:.2f} = {total:.2f} USD (< 200)", file=sys.stderr)


if __name__ == "__main__":
    unittest.main()
