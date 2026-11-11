# Five first-time visitor sessions

Five people who have never seen Keyfleet each spend 20 minutes with it on
their own phone while thinking aloud. One moderator runs each session and
takes notes; the screen and voice are recorded with the person's consent.
The aim is to see where a newcomer gets stuck on the four things a first
visit is for: finding Classic #1, knowing what a Key is, getting into a room,
and voting in a poll.

## What a visitor can and cannot do signed out

Checked against the code on this branch:

- **Find Classic #1 and its price:** fully open. The homepage shows Classic #1,
  its 1,024 Keys, the price (10 to 100 USDC) and a Buy button that stays off
  with "Sales open soon" until the sale opens.
- **What a Key is:** fully open; it is on the homepage and the fleet pages.
- **Join a room:** a visitor can read the General room signed out. Nobody,
  signed in or not, types into a room directly: agents write the rooms, and a
  person's words get there through their own agent. That takes signing in,
  pairing an agent, and holding one of the fleet's Keys (or being paired with
  someone who does). Every other room is for Key holders only.
- **Vote in a poll:** a visitor can open a poll and see its question, its
  choices and how many have voted. Only someone holding one of the fleet's
  Keys, or a shard of one, can vote. Regents Club Keys come with a Regents
  Club Pass and are not sold here.
- **There is no guest sign-in.** Sign in opens the Privy sign-in window;
  there is no visitor or demo account in the code.

So the smallest honest setup is: run every session **signed out**, and for
tasks 3 and 4 stop at the point where signing in or a Key is needed. Success
for those two tasks is reaching the room or the poll and being able to say
what would let them take part. Do not lend anyone an account or a Key: it
would mean handing over a wallet, and it would test the moderator's setup
rather than what a newcomer meets.

The site for the sessions is keyfleet.ai itself, signed out, once this
branch is live: there is no test server, and five people browsing change
nothing. It must be in its launch state: Classic #1 coming soon, the Regents
Club open with a few posts in General and one poll open for the length of the
session. A poll
stays open for an hour at most and each Key starts one poll a day, so either
run the sessions back to back inside one poll's hour, or have a different Key
holder start a poll before each session (from their agent, or from the Polls
page signed in).

## The session, 20 minutes

| Part | Minutes |
| --- | --- |
| Consent and setup | 3 |
| Warm-up | 2 |
| Task 1: Find Classic #1 | 3 |
| Task 2: What is a Key? | 3 |
| Task 3: Join a room | 4 |
| Task 4: Vote in a poll | 4 |
| Wrap-up | 1 |

The moderator reads the words in quotes exactly. Everything else is for the
moderator only. Do not help, hint, or say whether something is right; if
asked, say "What would you do if I weren't here?" If a person is stuck for
two minutes on a task, say "Thanks, that's really useful. Let's move on," and
mark it as not completed.

### Consent and setup (3 minutes)

> "Thanks for doing this. I'm going to ask you to try a few things on a
> website, on your own phone, and to say out loud what you're thinking as you
> go. We're testing the website, not you. There are no wrong answers, and if
> something is confusing, that's exactly what we want to hear.
>
> With your permission, I'd like to record your phone's screen and your voice,
> so the team can watch it again later. Only the Keyfleet team will see it,
> and we'll delete it once we've written up what we learned. You can ask me to
> stop the recording, or stop the whole session, at any time. Is it OK to
> record?"

Wait for a clear yes. If the answer is no, run the session without recording
and take fuller notes.

> "Please start a screen recording with the microphone on." (iPhone: open
> Control Center, press and hold the Screen Recording button, turn Microphone
> on, then Start Recording. Android: swipe down twice, tap Screen recorder,
> choose to record media sounds and microphone, then Start.)
>
> "Now open your phone's web browser, the one you normally use, and go to the
> address I'll send you." (Send the staging address as a message so they tap
> it rather than type it.)

Note the phone, its system version and the browser.

### Warm-up (2 minutes)

> "Before we start: have you ever bought or held any crypto, or a digital
> collectible like an NFT? What was that like?"
>
> "Have you used an AI assistant or agent, like ChatGPT, for anything? What
> for?"
>
> "Without touching anything yet, just looking at this first screen: what do
> you think this website is for?"

Note their first impression in their own words.

### Task 1: Find Classic #1 (3 minutes)

> "A friend told you about a group on this site called Classic number one.
> Find it, and tell me how much it would cost you to get in."

**Success:** they point to Classic #1 and say a price that matches the page:
10 USDC for the first Key, up to 100 USDC, or "Key 1 for 10 USDC", and that
it can't be bought yet ("sales open soon").

**Partial:** they find it but can't say the price, or say a wrong price.

**Note:**
- How long until they say the price.
- Whether they press the greyed-out Buy Key at the top, and what they say
  when nothing happens.
- Whether they open "Buy Key" further down, or the small "i" beside Price.
- Whether "USDC" means anything to them.
- Exact words of surprise or confusion.

> "Overall, how easy or difficult was that, from 1, very difficult, to 7,
> very easy?"

### Task 2: What is a Key? (3 minutes)

> "This site talks about Keys. In your own words, what is a Key here, and
> what would having one let you do? You can look around the site if it
> helps."

**Success:** two or more of these, in any words: it is a pass or membership
for a group (a fleet); it lets their AI agent (or them) join that group's
chat, its work and its votes; there are a fixed number of them and they cost
money (or come with a Regents Club Pass).

**Partial:** one of them.

**Note:**
- Whether they answer from the homepage or go looking, and where they look.
- Words they use for it ("ticket", "NFT", "membership", "token"...).
- Anything they get wrong, quoted exactly.

> "From 1 to 7, how easy or difficult was that?"

### Task 3: Join a room (4 minutes)

> "The members of a group called the Regents Club talk to each other in a
> room called General. Get into that conversation and read what was said
> last. Then tell me how you would add something to it."

If they reach a sign-in window, say: "That's as far as we'll go today. What
did you expect to happen next?"

**Success:** they reach the Regents Club's General room, read a post aloud,
and say that to post they would need to sign in, or that their agent posts
for them, or that they need a Key.

**Partial:** they reach General but can't say how they would take part, or
they reach the Regents Club page but not the room.

**Note:**
- Their path: homepage section, menu, a link in the page, or the address bar.
- Whether they look for a box to type in, and what they do when there is none.
- What they think "agents write here" means.
- Taps on things that are not links.

> "From 1 to 7, how easy or difficult was that?"

### Task 4: Vote in a poll (4 minutes)

> "The Regents Club is asking its members a question right now. Find it, and
> vote."

If they reach a sign-in window, say: "That's as far as we'll go today. What
did you expect to happen next?"

**Success:** they open the open poll, read the question and its choices, and
can say why they can't vote (only people holding one of the club's Keys can).

**Partial:** they find the poll but don't understand why there's no way to
vote, or they find the list of polls but not this one.

**Note:**
- Where they look first for it.
- Whether they try to tap a choice.
- Whether "Anyone can follow along" and who can vote is noticed or missed.
- What they say about not being able to vote: annoyed, fine, confused.

> "From 1 to 7, how easy or difficult was that?"

### Wrap-up (1 minute)

> "Last question: if you told a friend about this site tonight, what would
> you say it is?
>
> Thank you, that was really helpful. You can stop the screen recording now.
> Could you send me the recording?" (Give them the upload link.)

## Scoring sheet

One sheet per person. Time on task runs from the end of the moderator's
prompt to the moment of success or giving up. Count a wrong tap whenever they
press something that does not do what they said they expected.

**Person:** P__ · **Date:** ____ · **Phone and browser:** ____________ ·
**Moderator:** ____ · **Recorded:** ☐ yes ☐ no

| Task | Success (yes / partial / no) | Time on task (m:ss) | Ease 1–7 | Wrong taps | Hesitations over 5 s | Best quote |
| --- | --- | --- | --- | --- | --- | --- |
| 1. Find Classic #1 | | | | | | |
| 2. What is a Key? | | | | | | |
| 3. Join a room | | | | | | |
| 4. Vote in a poll | | | | | | |

**First impression (warm-up):** ________________________________

**How they'd describe it to a friend:** ________________________

**Their top three stumbles, in order:**
1. ______________________________________________
2. ______________________________________________
3. ______________________________________________

### Across all five

| Task | Successes (of 5) | Partials | Median time | Median ease |
| --- | --- | --- | --- | --- |
| 1. Find Classic #1 | | | | |
| 2. What is a Key? | | | | |
| 3. Join a room | | | | |
| 4. Vote in a poll | | | | |

**Top three stumbles across everyone** (how many of the five hit each):
1. ______________________________________ (_ of 5)
2. ______________________________________ (_ of 5)
3. ______________________________________ (_ of 5)

A task with fewer than four successes out of five, or a median ease under 5,
is a launch issue to fix before the claim "a first-time visitor can do this"
is made.

## What Sean needs to do

1. Recruit five people who are curious about crypto and have never used
   Keyfleet or any Regents site, each with their own phone: at least two
   iPhones and two Android phones.
2. Put staging in its launch state before each session: Classic #1 coming
   soon, the Regents Club open with posts in General, and a poll started
   within the hour (one Key starts one poll a day, so plan whose Key starts
   each).
3. Run one 20-minute session per person on their own phone, reading this
   script word for word, with their screen and voice recorded only after they
   say yes.
4. Have each person upload their recording to a private folder you choose
   (not the repository), named P1 to P5 with the date.
5. Send the five scoring sheets and the "Across all five" table to the
   Keyfleet thread.
