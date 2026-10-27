#!/usr/bin/env python3
"""Validate the Router v3.1 fleet schema and anchored runtime paths."""
import os
import sys
import tempfile
import unittest

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import refill_lib_v2 as R


FLEET = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../config/fleet.yaml"))
EXAMPLE = os.path.abspath(os.path.join(os.path.dirname(__file__), "fleet.yaml.example"))
REQUIRED_TOP_LEVEL = {"models", "bindings", "roles", "pools", "bans", "catalogs", "routing_state"}
REQUIRED_ROLES = {"build", "manager", "review", "plan", "t3", "gate-step", "closure", "cloud"}


class FleetSchema(unittest.TestCase):
    def assert_v31_shape(self, cfg):
        self.assertLessEqual(set(cfg), REQUIRED_TOP_LEVEL)
        self.assertTrue(REQUIRED_TOP_LEVEL <= set(cfg))
        self.assertTrue(REQUIRED_ROLES <= set(cfg["roles"]))
        for name, model in cfg["models"].items():
            self.assertIsInstance(model.get("id"), str, name)
            self.assertTrue(model["id"], name)
        for role, row in cfg["roles"].items():
            self.assertEqual(set(row), {"models"}, role)
            self.assertIsInstance(row["models"], list, role)
            self.assertTrue(row["models"], role)
            for binding_id in row["models"]:
                self.assertRegex(binding_id, r"^[^@]+@[^@]+$")
                self.assertIn(binding_id, cfg["bindings"])
                self.assertIn(cfg["bindings"][binding_id]["model"], cfg["models"])

    def test_schema_and_paths(self):
        with open(FLEET) as f:
            cfg = yaml.safe_load(f)
        self.assert_v31_shape(cfg)
        self.assertEqual(cfg["roles"]["plan"]["models"],
                         ["sol-plan@pi", "muse-wonder-plan@muse", "kimi-k3-plan@pi"])
        self.assertEqual(cfg["models"]["sol-plan"]["id"], "openai-codex/gpt-6.1-sol")
        self.assertEqual(cfg["models"]["muse-wonder-plan"]["id"], "muse-wonder")
        self.assertEqual(cfg["models"]["kimi-k3-plan"]["id"], "kimi-code/k3")
        self.assertNotIn("grok-plan", cfg["models"])
        self.assertNotIn("opus-plan", cfg["models"])
        self.assertEqual(cfg["models"]["sonnet-cloud"]["id"], "claude-sonnet-5-5")
        with tempfile.TemporaryDirectory() as home:
            for row in cfg["catalogs"].values():
                self.assertTrue(R.fm_path(row["path"], home).startswith(home + os.sep))
            self.assertTrue(R.fm_path(cfg["routing_state"]["bench"], home).startswith(home + os.sep))

    def test_example_is_copyable_v31_schema(self):
        with open(EXAMPLE) as f:
            cfg = yaml.safe_load(f)
        self.assert_v31_shape(cfg)
        cloud = cfg["bindings"][cfg["roles"]["cloud"]["models"][0]]
        self.assertTrue(cloud.get("cloud_capable"))
        self.assertTrue(cloud.get("effort"))

    def test_legacy_free_flat_role_shape_is_rejected(self):
        legacy = yaml.safe_load("""
models:
  legacy: {id: legacy, family: legacy, billing: flat, pool: legacy}
bindings:
  legacy@pi: {model: legacy, provider: legacy, harness: pi, pool: legacy}
roles:
  build: {free: [legacy@pi], flat: [legacy@pi]}
  manager: {models: [legacy@pi]}
  review: {models: [legacy@pi]}
  plan: {models: [legacy@pi]}
  t3: {models: [legacy@pi]}
  gate-step: {models: [legacy@pi]}
  closure: {models: [legacy@pi]}
  cloud: {models: [legacy@pi]}
pools: {legacy: {period_days: 7, scarce: false}}
bans: []
catalogs: {netcup: {path: state/catalog-netcup.json, max_age_seconds: 86400}}
routing_state: {bench: state/route-bench.json}
""")
        with self.assertRaises(AssertionError):
            self.assert_v31_shape(legacy)


if __name__ == "__main__":
    unittest.main()
