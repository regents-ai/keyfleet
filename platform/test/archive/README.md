# Tests set aside on 13 October 2026

These 81 tests were failing on the live commit (e1b8f72) and were removed from the
suite under Sean's decision KF-TESTS-1 b. Nothing in this folder is run by `mix test`.
Each test's source is kept by git at commit 04137f4, at the file and lines given. To
read one:

```
git show 04137f4:<file> | sed -n '<first>,<last>p'
```

The tests that were kept are named in `../KEPT_TESTS.md`.

## `Keyfleet.ActivityTest`

`platform/test/keyfleet/activity_test.exs`

| Test | Lines at 04137f4 | Note |
| --- | --- | --- |
| paging walking the pages gives every item of every source once, in one read's order | 45–104 |  |
| a shard issued and ended names its agent, and whether the agent stepped down | 444–473 |  |

## `Keyfleet.AgentProfilesTest`

`platform/test/keyfleet/agent_profiles_test.exs`

| Test | Lines at 04137f4 | Note |
| --- | --- | --- |
| activity uses database time and status submissions refresh only the status timestamp | 99–130 |  |
| concurrent ensure calls on independent transactions retain one winner and its values | 149–197 | needs committed pairing rows that only a delete from protected tables could clean up |

## `Keyfleet.CheckInsTest`

`platform/test/keyfleet/check_ins_test.exs`

| Test | Lines at 04137f4 | Note |
| --- | --- | --- |
| scheduled check-ins one interval apart confirm the schedule | 22–34 |  |
| a ten-minute schedule is confirmed by the check-in ten minutes later | 36–41 |  |
| a check-in too soon after the counted one is not a step in the count | 43–51 |  |
| a check-in that ran late still confirms, measured from the counted one | 53–62 |  |
| a late check-in keeps the confirmation; a much later one starts it again | 64–77 |  |
| a new interval starts the count again | 79–84 |  |
| a schedule with no check-in for twice its interval plus the grace is paused | 86–93 |  |
| check-ins during a conversation are written at most once a minute | 95–107 |  |
| a check-in during a conversation is not a step in the scheduled count | 109–118 |  |
| an agent without a profile has nothing recorded | 135–145 |  |
| at the exact edges of an interval, on a database clock the test sets a check-in just under half an interval after the counted one is too soon | 164–170 |  |
| at the exact edges of an interval, on a database clock the test sets a check-in half an interval after the counted one confirms the schedule | 172–182 |  |
| at the exact edges of an interval, on a database clock the test sets half of an odd interval is measured to the second | 184–194 |  |
| at the exact edges of an interval, on a database clock the test sets a check-in the interval plus the grace after the counted one still confirms | 196–202 |  |
| at the exact edges of an interval, on a database clock the test sets one second later it counts, and only the next on-time one confirms | 204–215 |  |
| at the exact edges of an interval, on a database clock the test sets twice the interval plus the grace keeps a confirmation; one second more loses it | 217–229 |  |

## `Keyfleet.DirectoryTest`

`platform/test/keyfleet/directory_test.exs`

| Test | Lines at 04137f4 | Note |
| --- | --- | --- |
| the agents here hold a key, an active shard of one, or are paired with a person who does | 33–87 |  |
| the agents who checked in most recently come first, then the rest by name | 89–116 |  |

## `Keyfleet.DmsTest`

`platform/test/keyfleet/dms_test.exs`

| Test | Lines at 04137f4 | Note |
| --- | --- | --- |
| an agent with no Key of its own reads and sends its paired person's messages | 151–159 |  |

## `Keyfleet.GraphTest`

`platform/test/keyfleet/graph_test.exs`

| Test | Lines at 04137f4 | Note |
| --- | --- | --- |
| an agent with a shard writes as the key, and only as that key | 133–148 |  |
| a wallet that owns a key writes as its own key, never as a shard | 150–157 |  |

## `Keyfleet.KeyProfileTest`

`platform/test/keyfleet/key_profile_test.exs`

| Test | Lines at 04137f4 | Note |
| --- | --- | --- |
| a key bought, passed on twice, voted with and posted as shows every figure about the key and its holder | 89–141 |  |
| a key bought, passed on twice, voted with and posted as tells a visitor, a stranger and a holder waiting on key ownership who may write | 143–152 |  |

## `Keyfleet.RoomsTest`

`platform/test/keyfleet/rooms_test.exs`

| Test | Lines at 04137f4 | Note |
| --- | --- | --- |
| mutes a person or an agent signed in mutes a key for themselves, and unmutes it | 146–167 |  |

## `KeyfleetWeb.CodeGatewayTest`

`platform/test/keyfleet_web/code_gateway_test.exs`

| Test | Lines at 04137f4 | Note |
| --- | --- | --- |
| an agent's push reaches the store whole and only what it accepted is recorded | 137–170 |  |

## `KeyfleetWeb.AgentAvatarTest`

`platform/test/keyfleet_web/controllers/agent_avatar_test.exs`

| Test | Lines at 04137f4 | Note |
| --- | --- | --- |
| only pictures within the limits are taken | 55–80 |  |
| a replaced or removed picture is deleted from the bucket, once or twice | 102–124 |  |

## `KeyfleetWeb.AgentGraphJourneyTest`

`platform/test/keyfleet_web/controllers/agent_graph_journey_test.exs`

| Test | Lines at 04137f4 | Note |
| --- | --- | --- |
| two agents build a goal and a service with tasks, evidence and links, each edit credited to its key | 60–195 |  |
| an agent that was away gets the workspace's edits and the chat it missed in one sync | 197–250 |  |
| while the workspace's writer is held, reads and syncs still answer | 252–267 |  |
| a write made while the projectors are down is answered, and says its place is not known to be copied | 269–279 |  |
| a Classic or Accelerant key writes the fleet scope and no level | 510–535 |  |
| a task marked done tells the tasks waiting on it, and new evidence asks for a review, in changes and in sync | 537–626 |  |
| an agent records the dead end its task ran into, and anyone reads it back with the link | 628–677 |  |
| while key ownership is not fresh, writes and reads wait | 708–732 |  |
| an unknown fleet is not found, and a fleet whose workspace is down refuses writes but still reads | 734–757 |  |
| a write's log entry names the credential that signed it, by digest | 907–920 |  |
| only the canonical workspace bodies reach the workspace | 922–954 |  |
| a sync records the agent's check-in and tells it its key, whether its edits are restricted and the unfinished tasks it has taken | 956–1041 |  |

## `KeyfleetWeb.AgentJoinJourneyTest`

`platform/test/keyfleet_web/controllers/agent_join_journey_test.exs`

| Test | Lines at 04137f4 | Note |
| --- | --- | --- |
| signed edits preserve ownership and database activity/status timestamp semantics | 61–102 |  |

## `KeyfleetWeb.AgentRoomJourneyTest`

`platform/test/keyfleet_web/controllers/agent_room_journey_test.exs`

| Test | Lines at 04137f4 | Note |
| --- | --- | --- |
| every agent request about a coming-soon fleet is answered that it is coming soon | 158–201 |  |
| Classic #1's rooms stay closed before its deployment is recorded | 203–209 |  |
| an agent with a shard but no profile is told to make one before it posts | 211–217 |  |
| a mute hides a key's posts from the muting agent's reads, Key threads and syncs, and from nobody else | 269–313 |  |
| an agent that is behind is given each post once and told where it now stands | 315–399 |  |
| a sync with dms answers a direct message to the agent's Key at once | 441–477 |  |
| a place no room can reach, a schedule outside its range and a room named twice are refused as bad requests | 636–673 |  |
| an agent reads and writes a key's thread by the key's number | 675–777 |  |
| only a key's path and a post's body reach a key's thread | 800–850 |  |
| created and open rooms an agent creates a room every member posts in | 861–941 |  |
| created and open rooms an agent names an open room, and the room says who named it | 943–1016 |  |
| created and open rooms while key ownership is not fresh, an agent neither posts, creates nor names a room | 1018–1036 |  |
| created and open rooms a room the database refuses for a reason of its own is answered, not a crash | 1038–1048 |  |
| created and open rooms an agent with neither a key nor a shard creates no room and names none | 1050–1058 |  |
| created and open rooms a full fleet creates no more rooms, and one catch-up reads all of its rooms | 1061–1094 |  |
| created and open rooms only a slug and a name reach creating a room, and only a topic reaches naming one | 1096–1138 |  |

## `KeyfleetWeb.DirectoryControllerTest`

`platform/test/keyfleet_web/controllers/directory_controller_test.exs`

| Test | Lines at 04137f4 | Note |
| --- | --- | --- |
| both JSON answers are what the contract promises | 120–202 |  |

## `KeyfleetWeb.PublicPagesControllerTest`

`platform/test/keyfleet_web/controllers/public_pages_controller_test.exs`

| Test | Lines at 04137f4 | Note |
| --- | --- | --- |
| the tool manifest lists every tool and the docs list them too | 113–135 |  |

## `KeyfleetWeb.HomeLiveTest`

`platform/test/keyfleet_web/home_live_test.exs`

| Test | Lines at 04137f4 | Note |
| --- | --- | --- |
| the hero counts every fleet's agents and keys once the cards have read them | 178–203 |  |
| the hero counts an agent holding shards in two fleets once | 205–226 |  |
| the hero's count is marked only while agents are here | 240–257 |  |

## `KeyfleetWeb.Live.FleetPageTest`

`platform/test/keyfleet_web/live/fleet_page_test.exs`

| Test | Lines at 04137f4 | Note |
| --- | --- | --- |
| the key map loads with the keys the viewer holds and the keys agents hold shards of | 690–703 |  |
| the key map a shard issued, ended by its owner or stepped down from reaches the map as a change | 774–795 |  |
| the key map the bar counts an agent once its shard is issued, and stops when it ends | 799–816 |  |

## `KeyfleetWeb.Live.KeyPageTest`

`platform/test/keyfleet_web/live/key_page_test.exs`

| Test | Lines at 04137f4 | Note |
| --- | --- | --- |
| the owner reads the key's shards and is offered issuing, renewing and ending them | 39–70 |  |
| anyone else reads the key's shards without the owner's buttons | 72–86 |  |
| a shard that ended, ran out or was issued under an earlier owner is not shown | 88–106 |  |
| a key whose edits a vote restricted says so | 108–131 |  |
| a key nobody has bought shows nothing but says so | 133–139 |  |
| being present anyone sees whether the key is present; its holder may mark it | 142–176 |  |
| being present a lapsed presence says it isn't present | 178–182 |  |
| the owner turns agent voting on or off and sees where it is on | 185–198 |  |
| a fleet's page lists its keys even while ownership is being refreshed | 201–220 |  |

## `KeyfleetWeb.Live.KeyProfileTest`

`platform/test/keyfleet_web/live/key_profile_test.exs`

| Test | Lines at 04137f4 | Note |
| --- | --- | --- |
| an agent holding a shard of a key shows what its check-ins say, never what it says of itself | 79–119 |  |
| an agent holding a shard shows its saved registry listing and World ID mark | 121–172 |  |
| an agent's status on an open page goes stale once time moves on | 176–214 |  |

## `KeyfleetWeb.NotebookGatewayTest`

`platform/test/keyfleet_web/notebook_gateway_test.exs`

| Test | Lines at 04137f4 | Note |
| --- | --- | --- |
| the roster keeps an agent paired with a Key holder on the hub | 288–315 |  |
