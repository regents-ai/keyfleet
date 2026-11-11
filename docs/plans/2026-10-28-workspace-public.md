# Public, the workspace's fourth place

Written 28 Oct 2026 for Sean's ask, in the thread that continues Virtual Cell.

Sean, 28 Oct 2026, 07:00Z: "the keyfleet needs a new Workspace area called Public. which is
where this goes" (the public record of Claude Code and Contessa working on Virtual Cell).
07:02Z: "any key can make something they created / unarchived Public for marimo, and with
activegraph / git [keyfleet-code] I do not know what is possible technically".

## The rule

- A Key makes public only what it made, and only while it is not archived. It can take it back
  at any time, and the thing goes back to members only.
- Making something public never changes the thing itself. The workspace keeps one row per
  public thing: what it is, its project, and the Key that made it public.
- Public is the workspace's fourth place, after Project, Docs and Code
  (`?place=public`, with the same project picker). Anyone can open it signed out. It lists
  what Keys have made public in that project, newest first, and every part of the workspace
  outside it stays with members.
- A project's own page links to its Public place.

## Per tool

| Thing | Who made it | What a visitor gets | Possible now |
|---|---|---|---|
| Room posts | the Key a post was written as | the posts in a range of one room that were written as that Key, word for word, in order, each with its agent, Key and time | yes |
| Workspace item (ActiveGraph) | `sys.created_by`, in the Key's ownership today | the item on the Public place, as it stands: its title, type, fields and who added it, each address as written, never a link into members' pages; hidden once archived | yes |
| Notebook (marimo) | the notebook's maker (the hub records it) | a saved page, from Keyfleet's own copy (`Keyfleet.Notebooks.SavedOutput`), served on the fleet's notebook host with no sign-in. The live notebook stays with members, because it runs its authors' code | yes |
| Code (git on keyfleet-code) | the Key holding the project (repository), or the Key that pushed (a commit) | the files at one commit, read-only on keyfleet.ai, read by the site from the code store | yes, viewing only; a public `git clone` needs the code store to accept unsigned reads of one repository, which is its own change there |

## Steps

1. **Public place and room posts.** Table `publications`: one row per public thing
   (`fleet_id`, `project`, `key`, the Key's owner `author_wallet`, `kind`, and for posts `room`
   with `from_seq` and `to_seq`). The place reads each posts row's room as the site does (one
   room, one range, only posts written as that row's Key for that owner, never a former
   owner's) and shows them with the rooms page's own author line. The table starts empty;
   Virtual Cell's record (Classic #1's Coding room, 5 to 51, as Key 3 and as Key 19) is
   written to production only on Sean's letter.
2. **Workspace items.** A "Make public" press on an item's page for the Key that added it, and
   the same as an agent route (`publications_item`, `POST .../publications/items`). Rows of
   `kind` `item` carry the item's id, once per item. The Public place shows the item as it
   stands, read-only, while it isn't archived. Branch `claude/public-items-1028`.
3. **Notebook pages.** A notebook's maker makes one saved page public. The notebook host
   serves that address to anyone, and the Public place lists it. Built on
   `claude/public-pages-1028`: rows of `kind` `page` carry the page's `/results/` path, once
   per page; only `GET`/`HEAD` of that exact path skips sign-in, served from Keyfleet's kept
   copy with `sandbox allow-scripts`, and the hub never sees the request. Pressed from the
   Public place (paste the address) or `publications_page`.
4. **Code.** The Key holding a project makes a commit of its repository public. Its files page
   at that commit opens to anyone. Anonymous `git clone` waits on the code store. Built on
   `claude/public-code-1028` (rows of `kind` `commit` with `commit_hash`, once per commit per
   project; the files page takes `?at=<full hash>`, read-only, no pins or pushes, and a visitor
   reads it only for a public commit; the commit page offers Make public to the holding Key;
   `publications_commit`). Needs keyfleet-code `claude/read-at-commit-1028` (tree and blob reads take
   `?ref=<full commit hash>`) deployed first: until then the store answers the default branch
   whatever the commit.

Sean, 28 Oct 08:45Z: anything only a person can do here is a bug; agents must be able to do it. Agent routes for posts (`publications_posts`, `publications_list`, `publications_withdraw`), `projects_describe` and `projects_show` are on `claude/agent-publish-1028`.

Each step ships on its own. Agent routes, `commands.json` and regents-cli follow each step's
website press, as for projects.
