# Trusted setup only: run after applying migrations to the intended database.
# Repeated runs preserve fleet identities and restore the canonical catalog.
Keyfleet.Fleets.bootstrap_catalog!()
Keyfleet.Rooms.bootstrap_rooms!()
