# Owner questions: why, how, what

This file records the questions the owner asked about how Mado is built and run, with the answer the owner accepted. Each entry explains what the thing is, why it works that way, and how it is used. Progress questions such as "what landed today" are not recorded: issues, PRs and the ledger answer those.

Newest entries first. Each entry quotes the question, gives the answer in three parts, and links the decision that came out of it.

---

## 2026-10-28 · What's the difference between the Backlog and a milestone on GitHub?

**Question.** 「github 中backlog和milestone有什么区别」 and 「backlog记录在哪里，一个单独的md，还是GitHub issues中？」

**What.**
- **A milestone** is a GitHub feature. It groups issues under one name, with an optional due date, a progress bar (closed / total) and its own page, and an issue can be in at most one milestone.
- **GitHub has no built-in "backlog".** In agile, a backlog is the list of unscheduled work. On GitHub it's usually a status column on a Projects board, or a label.
- **In Mado, `Backlog` is simply a milestone with that name.** It lives in GitHub Issues, with each item a normal issue (search `milestone:Backlog`), not in a separate md file.

| | `v0.0.1` / `v0.0.2` | `Backlog` |
|---|---|---|
| Means | must be done before this release ships | real work no release has committed to |
| Ends | closes when the release ships; the progress bar shows readiness | never; a long-lived holding area |
| Due date | may have one | none |
| In "ready now" | yes (`milestone:v0.0.1`) | no |
| Leaves by | being done and closed | promotion to a release milestone when it blocks release work (e.g. #249 on 2026-10-28), or closing |

**Why a milestone, not a label or a Projects column.** The rule is that every open issue has exactly one milestone. Because Backlog is a milestone, each issue is in exactly one bucket, and GitHub itself enforces it: an issue can't be both "v0.0.1" and "backlog". A label can't guarantee that, and a Projects column would be a second source of truth for the same fact. A separate md list would drift from the issues.

**How.** File process, tooling and flaky-test issues in `Backlog`. When one starts failing release PRs or blocks release work, move it to the current release milestone and dispatch it.

---

## 2026-10-28 · How does the build order map to the issues, and what is the Backlog?

**Question.** 「目前在开发的顺序和issue 是如何一一对应的，当前issues有60+个，你如何知道哪些先开发，哪些后开发」. Follow-up: 「解释一下backlog 是做什么的，和我之前的疑问有什么关系」.

**What.** Four separate facts live in four places, one place each.

| Fact | Where it lives | Example |
|---|---|---|
| Which release an issue ships in | the issue's **milestone**: `v0.0.1`, `v0.0.2` or `Backlog` | #113 is in `v0.0.1`; #144 (context menu) is in `v0.0.2` |
| Which spec a ticket belongs to | the **sub-issue** link (parent → child) | #229 is a child of spec #227 |
| What must finish first | the native **blocked-by** edge | #229 is blocked by #228 |
| What can start now | a **query**, computed and never stored | open, in `v0.0.1`, not blocked, not a spec, not already claimed |

When several tickets are ready at once, the tie-break is the plan's journey order (J1 open and browse, before J2 view and return; plan §1.6 and ADR-013). After that, the delegator applies three practical limits: the in-flight cap, file overlap between tickets, and auditor capacity.

**Why.** The order used to rest on sub-issue links under #130, blocked-by edges and the delegator's memory. A check on 2026-10-28 showed three problems:
- 28 open issues weren't linked anywhere, including that day's specs and their tickets.
- Some edges no longer meant anything once the release boundary moved.
- Nothing separated v0.0.1 work from later work, so v0.0.2 items looked "ready".

Using one place per fact removes the need to remember. A best-practice review agreed, and so did Codex. Their sources: GitHub's docs on milestones, sub-issues and dependencies; Azure DevOps (iteration path vs. work-item hierarchy); VS Code's monthly milestones; Google Issue Tracker ("Targeted To" vs. hotlists); and Matt Pocock's to-tickets frontier.

**The Backlog.** A milestone for work that is real but not tied to a release:
- flaky tests (#59, #197);
- tooling (#151, #195);
- process and verification ideas (#175–#178);
- untriaged notes (#183);
- ledger clean-up (#198).

Without it, the rule "every open issue has a milestone" would force these into v0.0.1, making v0.0.1 look bigger than it is, or into v0.0.2, promising them for a release nobody planned them for. With it, the v0.0.1 milestone is exactly what must be done before release, and its "ready now" query never offers Backlog items. Backlog items get done when they block release work; for example, a flaky test that keeps failing PR CI gets promoted to `v0.0.1` at that point.

**How.**
- `/to-spec` and `/to-tickets` create the spec and tickets. The delegator then links the spec under its parent and sets the milestone on the spec and every ticket.
- At dispatch, the delegator runs the query (`milestone:v0.0.1 -is:blocked label:ready-for-agent -has:sub-issue`), drops anything claimed or overlapping, and picks by journey order.
- A read-only check (planned) fails when an open issue has no milestone, a ticket has no parent, or an earlier release waits on a later one. `~/.picsee/timeline.json` becomes a view generated from the same data.

Decision: the owner chose 「Yes, list first, then apply」, 「Rescope #130 as the v0.0.1 parent」 and 「Split it」 (#142). Change list: `~/.picsee/herdr/delegator/tracker-change-list.md`. Reviews: `review-tracker-research.md`, `review-tracker-codex.md` in the same folder.

---

## 2026-10-28 · Does a fresh macOS user mean manual testing, and does my installed App work there?

**Question.** 「如果是fresh macos user，那需要人工来测试吗，目前user中安装的app，在新user界面能不能用」. Follow-up: 「You must quit your own Picsee first, 是我需要quit 当前claude picsee session，还是说退出picsee mac app?」.

**What.**
- **Apps by location:** an App in `/Applications` is visible to every user. One in your own `~/Applications` is visible only to you.
- **Data by user:** each macOS user gets their own Mado sandbox container (saved folders, favourites, preferences). A new user always starts at first launch (page 21).
- **The quit question:** it means the Mado Mac app, not the Claude session.

**Why automation stops at the user boundary.**
- The agents' tools run in your account's terminal, and their Accessibility and Screen Recording permissions are per user.
- When you switch to another user, your session goes to the background, so clicks and screenshots can't reach the other desktop.
- Granting those permissions inside the test user would change privacy settings, which only you may do.

Why your own account can't show a first launch:
- The release build uses the same bundle ID as your installed Mado, so it shares your container, which already has saved folders.
- Moving that container aside needs your explicit approval, and every Mado process must be closed first.

**How (owner's choice: option 3).** For the J1 record:
1. You quit the Mado Mac app and approve once.
2. The delegator backs up the container and moves it aside.
3. J1 runs automatically from a real first launch.
4. The original container is moved back, and your folders and favourites are checked.

If macOS refuses the move, the fallback is a 5-minute first-launch checklist that you run by hand in a fresh test user. Spec #235, ticket #239.

---

## 2026-10-28 · Does "Medium/High" mean model effort or task difficulty?

**Question.** Asked during the roster set-up: "what do you mean by Medium/High here, model effort or task difficulty?"

**What.** Task difficulty, also called the risk **tier**: Low, Medium or High. It is not the model's reasoning-effort setting. The tier describes how much damage a mistake in the change could do. For example:
- Low: a build setting.
- Medium: user data on disk, or a user-visible state.
- High: wide or security-sensitive changes.

**Why.** The tier decides how much review a change gets:
- **Low** items get one auditor.
- **Medium/High** items get two independent auditors.
- **Critical and High findings** block until a fresh-context confirm.

Mixing it up with model effort would tie review depth to how hard the model thought, instead of to how risky the change is.

**How.** The delegator sets the tier in each brief with a one-line reason. The owner's decisions:
- 「Medium/High 必经，Low 不用」: Medium/High items always get the dual audit; Low items don't.
- 「计入，总上限 4」: in-flight implementation items count toward a cap of four.
