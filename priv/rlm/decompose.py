#!/usr/bin/env python3
"""DSPy RLM sidecar for lossless atomic document decomposition."""

import json
import os
import sys


def fail(message: str) -> None:
    print(json.dumps({"error": message}))
    raise SystemExit(1)


try:
    import dspy
except ImportError:
    fail("dspy is not installed; install the optional Optimal RLM environment")


class DecomposeSource(dspy.Signature):
    """Split a source into atomic units while preserving factual content.

    Never invent facts. Each atom must include a title, body, tags, links, and
    verbatim evidence copied from the source.
    """

    title: str = dspy.InputField()
    content: str = dspy.InputField()
    related_titles: str = dspy.InputField()
    atoms_json: str = dspy.OutputField(
        desc="JSON array of {title, body, tags, links, evidence} objects"
    )


request = json.load(sys.stdin)
model_id = request.get("model") or os.getenv("OPTIMAL_RLM_MODEL")
if not model_id:
    fail("OPTIMAL_RLM_MODEL is required")

lm = dspy.LM(model_id)
dspy.configure(lm=lm)

kwargs = {
    "max_iterations": int(request.get("max_iterations", 15)),
    "max_llm_calls": int(request.get("max_llm_calls", 30)),
    "max_output_chars": int(request.get("max_output_chars", 15000)),
    "verbose": False,
}

sub_model = request.get("sub_model") or os.getenv("OPTIMAL_RLM_SUB_MODEL")
if sub_model:
    kwargs["sub_lm"] = dspy.LM(sub_model)

decomposer = dspy.RLM(DecomposeSource, **kwargs)
result = decomposer(
    title=request.get("title", "Untitled source"),
    content=request.get("content", ""),
    related_titles=", ".join(request.get("related_titles", [])),
)

try:
    atoms = json.loads(result.atoms_json)
except (AttributeError, json.JSONDecodeError) as exc:
    fail(f"RLM returned invalid atoms JSON: {exc}")

if not isinstance(atoms, list) or not atoms:
    fail("RLM returned no atoms")

trajectory = getattr(result, "trajectory", [])
sub_calls = sum(
    str(step.get("code", "")).count("llm_query(")
    + str(step.get("code", "")).count("llm_query_batched(")
    for step in trajectory
    if isinstance(step, dict)
)

print(
    json.dumps(
        {
            "strategy": "rlm",
            "atoms": atoms,
            "iterations": len(trajectory),
            "sub_model_calls": sub_calls,
        }
    )
)
