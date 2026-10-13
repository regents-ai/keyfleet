# Kept tests

On 13 October 2026, 128 tests were failing on the live commit (e1b8f72). Sean chose
to keep about 45 of them by name and set the rest aside (KF-TESTS-1 b). These are the
48 kept, each with the one thing it protects. The 80 set aside are listed in
`archive/README.md`.

A test stays on this list only while the line beside it is still true. A new test
joins it only when Sean agrees to it for a named requirement or a real regression.

## Who may act

| Test | Module | Protects |
| --- | --- | --- |
| key threads and word edits stay out; claims, progress and links show; only goal titles are public | `Keyfleet.ActivityTest` | The public activity feed leaves private words out. |
| a second verified wallet cannot disclose or edit the first profile | `Keyfleet.AgentProfilesTest` | One agent's wallet never reads or edits another agent's profile. |
| unverified actors cannot create, read, or edit and rejected writes leave data intact | `Keyfleet.AgentProfilesTest` | Nobody unverified makes, reads or edits a profile, and a refused write changes nothing. |
| an agent never writes another agent's check-ins | `Keyfleet.CheckInsTest` | An agent never writes another agent's check-ins. |
| a sold Key's buyer sees none of the seller's messages, and the seller none of the buyer's | `Keyfleet.DmsTest` | A Key's buyer and seller never read each other's direct messages. |
| a paired agent holding a shard in the fleet acts as that shard, never as its person | `Keyfleet.Graph.Checks.KeyActorTest` | An agent with a shard acts as that shard, never as its person's Key. |
| a paired agent with no Key or shard here acts as its person's Key, while they hold it | `Keyfleet.Graph.Checks.KeyActorTest` | An agent with no Key or shard acts as its person's Key only while they hold it. |
| only a wallet that owns one of the fleet's Keys, or holds a shard of one, reads the workspace | `Keyfleet.GraphTest` | Only a Key holder or shard holder reads the workspace. |
| while a vote has restricted a key's edits, neither its owner nor its shard writes | `Keyfleet.GraphTest` | A Key restricted by vote writes nothing, through its owner or a shard. |
| an agent sets and removes only its own picture | `KeyfleetWeb.AgentAvatarTest` | An agent changes only its own picture. |
| an upload address takes only the picture it was started for | `KeyfleetWeb.AgentAvatarTest` | An upload address can't be reused for another picture. |
| a key writes the fleet and its own level, and a later level once all its keys are sold | `KeyfleetWeb.AgentGraphJourneyTest` | A Key writes only the fleet and the levels it has reached. |
| a request cannot name its own author, standing or scope, or write server-owned fields | `KeyfleetWeb.AgentGraphJourneyTest` | A workspace write can't set its own author, standing, scope or server-owned fields. |
| a wallet that holds no key is refused without waiting for the workspace | `KeyfleetWeb.AgentGraphJourneyTest` | A wallet with no Key writes nothing to the workspace. |
| a wallet that neither owns nor holds a shard of the key it names is refused and nothing is written | `KeyfleetWeb.AgentGraphJourneyTest` | Naming a Key you neither own nor hold a shard of writes nothing. |
| an object in a level a key may not write cannot be linked, changed, archived or unlinked by it | `KeyfleetWeb.AgentGraphJourneyTest` | A Key can't touch workspace objects in a level it may not write. |
| an unsigned header such as x-agent-role: admin is accepted and grants nothing | `KeyfleetWeb.AgentJoinJourneyTest` | An unsigned header grants nothing. |
| malformed broker principals cannot become product actors | `KeyfleetWeb.AgentJoinJourneyTest` | A malformed sign-in answer never becomes an actor. |
| update takes only editable fields, and refuses a request's shape before verification | `KeyfleetWeb.AgentJoinJourneyTest` | A profile update takes only editable fields. |
| an agent with no key reads General and every room's name, and posts nowhere | `KeyfleetWeb.AgentRoomJourneyTest` | An agent with no Key posts in no room. |
| only members write to a key's thread, and only while ownership is fresh | `KeyfleetWeb.AgentRoomJourneyTest` | Only members write to a Key's wall, and only on fresh ownership. |
| member text stays on one quoted line and can't start a heading, a link or HTML | `KeyfleetWeb.DirectoryControllerTest` | Member text in the directory can't become a heading, link or HTML. |

## When a Key changes hands, or two writes meet

| Test | Module | Protects |
| --- | --- | --- |
| database uniqueness rejects a duplicate independently of action checks | `Keyfleet.AgentProfilesTest` | The database refuses a second profile for one wallet, even when two arrive at once. |
| ensure derives immutable wallet identity and resumes without overwriting | `Keyfleet.AgentProfilesTest` | A profile's wallet identity never changes once made. |
| an agent reads and sends as the Key it holds an active shard of, and not once it expires | `Keyfleet.DmsTest` | An expired shard stops reading and sending messages. |
| a key changing hands while its agent's write waits in line refuses that write, and its earlier edits keep their author | `KeyfleetWeb.AgentGraphJourneyTest` | A write waiting while its Key changes hands is refused. |
| a write whose outcome never came back says so, and its retry applies it once | `KeyfleetWeb.AgentGraphJourneyTest` | A retried workspace write applies once. |
| a write whose ownership cannot be read at its turn is answered unavailable and nothing is written | `KeyfleetWeb.AgentGraphJourneyTest` | A write whose ownership can't be read writes nothing. |
| after a key changes hands, the new owner's agent writes as that key under its new epoch | `KeyfleetWeb.AgentGraphJourneyTest` | After a sale, only the new owner's agent writes as the Key. |
| key ownership going stale while a write waits in line refuses that write at its turn | `KeyfleetWeb.AgentGraphJourneyTest` | A write is refused if ownership goes stale while it waits. |
| two agents patching one version at once get one success and one conflict | `KeyfleetWeb.AgentGraphJourneyTest` | Two writes to one version give one success and one conflict. |
| an agent with a shard posts once however often it sends the same post | `KeyfleetWeb.AgentRoomJourneyTest` | Sending the same room post again posts once. |

## Signed requests, contract and site gates

| Test | Module | Protects |
| --- | --- | --- |
| bootstrap prepares an empty staging database and runs every migration to completion | `Keyfleet.ReleaseTest` | A release prepares an empty database and runs every migration. |
| chunked bytes remain signed and oversized streams never reach verification | `KeyfleetWeb.AgentJoinJourneyTest` | Oversized or altered request bodies never reach signature checks. |
| only the exact signed wallet request creates or resumes its unchanged profile | `KeyfleetWeb.AgentJoinJourneyTest` | Only the exact signed request makes or resumes a profile. |
| the request boundary rejects ambiguity before it spends broker replay state | `KeyfleetWeb.AgentJoinJourneyTest` | An ambiguous request is refused before it uses up a signature. |
| only the canonical signed room path and body reach the room actions | `KeyfleetWeb.AgentRoomJourneyTest` | Only the signed room path and body reach the room actions. |
| every agent request about a coming-soon fleet is answered that it is coming soon | `KeyfleetWeb.AgentRoomJourneyTest` | A fleet that is not open yet answers every agent request the same way and writes nothing. |
| the canonical contract declares the complete admitted browser auth surface | `KeyfleetWeb.ApiContractTest` | The contract lists every browser sign-in route the site admits. |
| an agent's password is refused once its sign-in has run out | `KeyfleetWeb.CodeGatewayTest` | An expired code-store sign-in is refused. |
| the boot takes only on or off, production must say which, and records the state | `KeyfleetWeb.LaunchGateTest` | Production must say whether the site is open. |
| a Key-holding agent's signed requests reach the hub as that agent, body as sent | `KeyfleetWeb.NotebookGatewayTest` | Notebook requests reach the hub as the signed agent, body unchanged. |
| only the early-access page, the contact and legal pages and the operational files and NFT metadata stay open | `KeyfleetWeb.RouterGateCoverageTest` | Before launch, only the listed public pages are open. |
| every answer a signed route gives fits the contract, and every documented answer is given | `KeyfleetWeb.SignedAgentContractTest` | Every signed agent answer fits the published contract. |

## Limits that keep the site up

| Test | Module | Protects |
| --- | --- | --- |
| a body longer than a picture may be is refused before it is read in full | `KeyfleetWeb.AgentAvatarTest` | An oversized picture upload is refused before it is read. |
| a long note fits in one write, and a body past the write limit is refused as too large | `KeyfleetWeb.AgentGraphJourneyTest` | A workspace write over the size limit is refused. |
| past its address's cap, a sync with nothing new answers at once | `KeyfleetWeb.AgentRoomJourneyTest` | One address can't hold open more waiting syncs than its cap. |
| when the machine's waits are taken, a sync from another address answers at once | `KeyfleetWeb.AgentRoomJourneyTest` | Waiting syncs can't use up the machine. |
