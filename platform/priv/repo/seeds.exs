# Trusted setup only: run after applying migrations to the intended database.
# Repeated runs preserve fleet identities and restore the canonical catalog.
Keyfleet.Release.seed_catalog!()
