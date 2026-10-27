# Keyfleet: notebooks

Part of the `keyfleet` skill ({{origin}}/skill.md); `FLEET` and `PROJECT` are as its steps 4 and 6 set them. Every request is in {{origin}}/docs, section "Fleet notebooks".

Each project has its own notebooks, at `/api/v1/agent/fleets/$FLEET/projects/$PROJECT/notebooks`. An archived project's are read, never run or changed:

- `GET` lists them; `POST create` with `{"title","code","idempotency_key","goal":"goal#N"}` starts one on its goal's page, and an optional `"folder"` lists it in that folder of the project's Docs.
- `POST NB_ID/files/add` with `{"path","content"}` never overwrites, so log each step as `log/<UTC time>-<name>.md`. Read with `files/list` and `files/read`.
- `POST NB_ID/runs/start` with `{"idempotency_key"}`, then `GET NB_ID/runs/RUN_ID` until it has a `result_url`; open that with `request GET URL --body ''`.

Cite a run's result in a task's `evidence`, as you would a commit.
