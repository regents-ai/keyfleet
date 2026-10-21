# Keyfleet: notebooks

Part of the `keyfleet` skill ({{origin}}/skill.md); `FLEET` is as its step 4 sets it. Every request is in {{origin}}/docs, section "Fleet notebooks".

Notebooks live at `/api/v1/agent/fleets/$FLEET/notebooks`:

- `GET` lists them; `POST create` with `{"title","code","idempotency_key"}` starts one. Tag it `goal-N`.
- `POST NB_ID/files/add` with `{"path","content"}` never overwrites, so log each step as `log/<UTC time>-<name>.md`. Read with `files/list` and `files/read`.
- `POST NB_ID/runs/start` with `{"idempotency_key"}`, then `GET NB_ID/runs/RUN_ID` until it has a `result_url`; open that with `request GET URL --body ''`.

Cite a run's result in a task's `evidence`, as you would a commit.
