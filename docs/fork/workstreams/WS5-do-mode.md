# WS5 — Do mode ("Hey Clicky, fill this page with my information")

**Branch:** `ws/do-mode` · **Runs:** Phase 2 (after WS3 E2E works) · **Read first:** PRODUCT.md (safety rows), CONTRACTS.md §2–§4, research/02 (Chrome + computer use), https://code.claude.com/docs/en/chrome.

## Goal
Let Clicky **act**: on web pages through Claude in Chrome (works on the Team plan), and later in native apps through Claude Code computer use on the personal plan.

## You own
- `session-template/CLAUDE.md` — the **Do mode** section (coordinate with WS3's file: add a clearly delimited section)
- `scripts/make-profile.sh` — creates `~/.clicky/profile.md` from a template **outside the repo** (0600), never overwrites
- `session-template/profile.template.md` — field names only (name, emails, phone, address, school, LinkedIn, GitHub, short bio, T-shirt size…), no values
- `test-fixtures/forms/` — local HTML forms (contact, sign-up with password field, multi-step checkout with a "Place order" button) served by `python3 -m http.server`
- `leanring-buddy/DoModeStatusBubbleView.swift` + state — status lines and confirmation question near the cursor (lead mounts it)
- `leanring-buddy/SpokenConfirmationListener.swift` — after a `confirm` event, speak the question, capture one utterance via `VoiceUtteranceProvider`, classify yes/no (simple word rules; unclear → ask again once), post `/v1/followup kind=confirmation`
- `scripts/frontmost-browser-tab.sh` (AppleScript via `osascript`) — returns URL/title of Chrome's active tab; Swift may call the same AppleScript to fill `browser_tab` in requests

## Tasks
1. **Spike:** in the `clicky` session, confirm Claude in Chrome can operate on the user's **existing active tab** (not only new tabs) when the request names it. Document the exact instruction wording that makes it reliable. If it can only open new tabs, decide: open the same URL in Claude's tab group and accept losing unsaved form state, or fall back to native computer use (personal plan).
2. Write the Do-mode rules (session CLAUDE.md): when a request is a do-request; read profile; fill visible fields; skip passwords/cards/gov IDs ("I left the password for you"); `status` every 2–3 actions; `confirm` before submit/send/purchase/delete/post; `respond` summary at the end; stop on `cancel`.
3. Swift confirmation loop + status bubble.
4. Test on all fixture forms; confirm the password field is never filled and "Place order" is never pressed without a spoken "yes".
5. **Later (Phase 3, design only now):** native computer use via a second session on the personal plan — `CLAUDE_CONFIG_DIR=$HOME/.claude-personal`, tmux `clicky-doer`, bridge instance on another port with server name `clicky_doer`. Write the design in `docs/fork/research/07-native-computer-use-plan.md`.

## Acceptance
- Contact and sign-up fixtures filled correctly from the profile, in the current tab, with status bubbles.
- Submit only after a spoken yes; "no" leaves the page untouched; "Hey Clicky, stop" halts mid-fill.
- `git grep` finds no personal values anywhere in the repo.
