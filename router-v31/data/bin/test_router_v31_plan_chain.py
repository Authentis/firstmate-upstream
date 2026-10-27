#!/usr/bin/env python3
"""Offline proof for chief 4894/4895's immutable planning route."""
import copy
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import refill_lib_v2 as R


NOW = 2_000_000_000


def config():
    return {
        "models": {
            "sol-plan": {"id": "openai-codex/gpt-6.1-sol", "family": "codex", "billing": "flat"},
            "muse-wonder-plan": {"id": "muse-wonder", "family": "muse", "billing": "flat"},
            "kimi-k3-plan": {"id": "kimi-code/k3", "family": "kimi", "billing": "flat"},
            "grok-plan": {"id": "xai/grok-4.7", "family": "grok", "billing": "flat"},
            "opus-plan": {"id": "claude-opus-5-5", "family": "claude", "billing": "flat"},
            "free-plan": {"id": "vendor/free", "family": "free", "billing": "free"},
        },
        "bindings": {
            "sol-plan@pi": {"model": "sol-plan", "provider": "openai-codex", "harness": "pi", "pool": "codex", "effort": "high"},
            "muse-wonder-plan@muse": {"model": "muse-wonder-plan", "provider": "muse", "harness": "muse", "pool": "muse", "effort": "high"},
            "kimi-k3-plan@pi": {"model": "kimi-k3-plan", "provider": "kimi-code", "harness": "pi", "pool": "kimi", "effort": "high"},
            "grok-plan@pi": {"model": "grok-plan", "provider": "xai", "harness": "pi", "pool": "grok", "effort": "high"},
            "opus-plan@claude": {"model": "opus-plan", "provider": "anthropic", "harness": "claude", "pool": "claude", "effort": "high"},
            "free-plan@pi": {"model": "free-plan", "provider": "vendor", "harness": "pi", "pool": "free", "effort": "high"},
        },
        "roles": {"plan": {"models": ["sol-plan@pi", "muse-wonder-plan@muse", "kimi-k3-plan@pi"]}},
        "pools": {name: {"period_days": 7, "scarce": False} for name in ("codex", "muse", "kimi", "grok", "claude", "free")},
        "bans": [{"billing": "free", "live_data": True}, {"family": "kimi", "live_data": True}],
    }


def quota(cfg):
    return {"pools": {name: {"used_pct": 0, "reset_at": NOW + 86400,
                              "observed_at": NOW, "source": "test", "manual": False}
                      for name in cfg["pools"]}}


def catalog(cfg, host):
    rows = {}
    for row in cfg["bindings"].values():
        model = cfg["models"][row["model"]]["id"]
        key = model if "/" in model else row["provider"] + "/" + model
        rows[key] = {"cost": {"input": 1, "output": 1}}
    return {host: {"host": host, "observed_at": NOW, "models": rows}}


class PlanChain(unittest.TestCase):
    def test_production_fleet_declares_the_canonical_chain(self):
        fleet = R._load_fleet(str(Path(__file__).resolve().parents[2] / "config" / "fleet.yaml"))
        self.assertEqual(fleet["roles"]["plan"]["models"], list(R.ROUTE_PLAN_BINDINGS))
        self.assertNotIn("grok-plan", fleet["models"])
        self.assertNotIn("opus-plan", fleet["models"])
        for binding, model, model_id, family, provider, harness, _host in R.ROUTE_PLAN_CHAIN:
            self.assertEqual(fleet["bindings"][binding]["model"], model)
            self.assertEqual(fleet["models"][model]["id"], model_id)
            self.assertEqual(fleet["models"][model]["family"], family)
            self.assertEqual(fleet["bindings"][binding]["provider"], provider)
            self.assertEqual(fleet["bindings"][binding]["harness"], harness)

    def test_canonical_ids_and_host_bindings_are_the_only_plan_picks(self):
        cfg = config(); q = quota(cfg)
        self.assertEqual(R.route_pick("plan", "netcup", "", False, NOW, cfg, q, {},
                                      catalogs=catalog(cfg, "netcup"), only_binding="sol-plan@pi")[0], "sol-plan@pi")
        self.assertEqual(R.route_pick("plan", "bosgame", "", False, NOW, cfg, q, {},
                                      catalogs=catalog(cfg, "bosgame"), only_binding="muse-wonder-plan@muse")[0], "muse-wonder-plan@muse")
        self.assertEqual(R.route_pick("plan", "netcup", "", False, NOW, cfg, q, {},
                                      catalogs=catalog(cfg, "netcup"), only_binding="kimi-k3-plan@pi")[0], "kimi-k3-plan@pi")
        for binding, host in (("sol-plan@pi", "bosgame"), ("muse-wonder-plan@muse", "netcup"),
                              ("kimi-k3-plan@pi", "bosgame")):
            self.assertIsNone(R.route_pick("plan", host, "", False, NOW, cfg, q, {},
                                            catalogs=catalog(cfg, host), only_binding=binding)[0])

    def test_malicious_role_order_or_injected_grok_claude_free_never_selects(self):
        cfg = config(); q = quota(cfg)
        cfg["roles"]["plan"]["models"] = ["grok-plan@pi", "opus-plan@claude", "free-plan@pi",
                                              "kimi-k3-plan@pi", "muse-wonder-plan@muse", "sol-plan@pi"]
        self.assertEqual(R.route_pick("plan", "netcup", "", False, NOW, cfg, q, {},
                                      catalogs=catalog(cfg, "netcup"))[0], "sol-plan@pi")
        cfg2 = copy.deepcopy(cfg)
        cfg2["bindings"]["sol-plan@pi"]["provider"] = "evil"
        # A broken Sol row falls through only to the next canonical same-host binding,
        # never to the injected Grok/Claude/free rows.
        self.assertEqual(R.route_pick("plan", "netcup", "", False, NOW, cfg2, quota(cfg2), {},
                                      catalogs=catalog(cfg2, "netcup"))[0], "kimi-k3-plan@pi")

    def test_k3_is_only_permitted_for_its_canonical_noncredential_plan_binding(self):
        cfg = config(); q = quota(cfg)
        self.assertIsNone(R.route_pick("plan", "netcup", "", True, NOW, cfg, q, {},
                                        catalogs=catalog(cfg, "netcup"), only_binding="kimi-k3-plan@pi")[0])
        cfg["roles"]["build"] = {"models": ["kimi-k3-plan@pi"]}
        self.assertIsNone(R.route_pick("build", "netcup", "", False, NOW, cfg, q, {},
                                        catalogs=catalog(cfg, "netcup"))[0])


if __name__ == "__main__":
    unittest.main()
