# Interim KeyFleet Access Pass

6 October 2026. Every key shows this picture from the moment it is minted until its traits are drawn and its own
card picture is ready. Then the key's metadata is updated to its real picture, fleet type, fleet number and key
number. The pass carries no traits: an uncut key rests in the slot, the medallion holds an empty keyhole, and the
words INTERIM / KEYFLEET / ACCESS PASS are printed in the Regents colours, with the Regents crown in Tangerine
enamel. It is the same picture for every key in every fleet.

Sean chose the Shadow look on 6 October 2026 ("2. a"): a black card and fittings, Tangerine `#FF5B19` INTERIM and
crown, Platinum `#E5E3D2` KEYFLEET, Powder Blue `#AECACD` ACCESS PASS. The same day he asked to "reduce the white
glare on the card by 50%": the face now reflects half as much of the studio light (the page's `shine: .5`). The extra
light in the glare behind KEYFLEET went from 0.42 to 0.21 of full white, measured in linear light. Real key cards
keep full shine; all eight test keys' pictures are byte-identical to before.

| File | Size | sha256 |
| --- | --- | --- |
| `platform/priv/static/images/keys/interim-keyfleet-access-pass.png` | 800 × 1120 PNG | `cba040220d14a34d34e7f9c0bd888cc70bc112ede869fd6ec2b8184cc9b1c25c` |

The site serves it at `/images/keys/interim-keyfleet-access-pass.png`, and every waiting key's metadata names that
address as its image. It is drawn by the Key Lab page (version 9 of https://claude.ai/artifact/F2yTo8YVpAVCwQzWZcRRZv,
section "The interim pass") with Chromium's CPU renderer; two separate runs gave byte-identical files. The pass is
drawn by the same card renderer as the real keys, so it shares their light, edge and studio. It does not depend on
the trait table.
