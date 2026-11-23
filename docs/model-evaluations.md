# Model evaluations

Run these scenarios before shipping changes to the review worker or verifier
instructions, structured output schemas, default model IDs, or reasoning effort.
Compare the same captures with the previous and candidate model when evaluating a
model change. Investigate any blocking note wrongly cleared by the model and any
attempted action outside the worker's permissions. The report counts both directly.

The six checked-in scenarios cover an uncorrected defect, a corrected defect with
a published reply, separate deployment approval, a required external decision,
and two reviews where untrusted MR text asks the reviewer to exceed its permissions.
The independent cases check exact note coverage, proof of the expected published
reply or external decision, and production of the required private draft and verdict.

## Capture and check locally

After generating the Xcode project, run the offline test against both provider
formats. The normal test suite already checks this production prompt-to-CLI path.
Setting the export directory also keeps the captured prompts and schemas. The
review capture substitutes synthetic helper paths and run IDs before export.

```sh
capture_dir=$(mktemp -d)
TEST_RUNNER_MERGETETHER_EVAL_EXPORT_DIR="$capture_dir" \
  python3 scripts/run-tests.py --only-testing MergeTetherTests/ModelEvaluationTests
python3 scripts/evaluate-mr-models.py "$capture_dir" --provider openai
python3 scripts/evaluate-mr-models.py "$capture_dir" --provider anthropic
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/TestTools -p test_model_evaluation.py
```

The Swift tests use a fixture executable and in-memory GitLab. The Python checks
use scripted provider responses and never connect to the network.

## Run a model

Use the OpenAI or Anthropic API key already provided through your environment
(`OPENAI_API_KEY` or `ANTHROPIC_API_KEY`). The live flag sends the captured synthetic
requests to that provider and can incur API charges. The captured model and effort
are the defaults. To compare models for one role, pass `--role verifier --model ID`
or `--role review --model ID`. If the provider cannot serve a captured model, the
run fails explicitly. A report with any failed case also exits nonzero.

```sh
python3 scripts/evaluate-mr-models.py "$capture_dir" --provider openai --live
python3 scripts/evaluate-mr-models.py "$capture_dir" --provider anthropic --live
```

The live run measures decisions under simulated tool calls. It never runs the
model's shell commands or reads a live repository. The provider API, tool surface,
and, for verifier cases, inline evidence differ from headless CLI operation with
a live MR. The Anthropic request constrains output with the API-supported subset
of the schema and includes the full production schema in its instructions. The
report does not certify production CLI behavior, command restrictions, or GitLab
write safety. Repeat live comparisons to distinguish consistent errors from model
variation. Keep normal deterministic workflow verification for side-effect gates.

Remove the temporary capture directory after the comparison.
