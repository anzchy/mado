# Interaction & lifecycle checklist

Use this for every new or changed mode, panel, sheet, popover or async load (#410). Audits kept reopening work
over combinations the brief and test matrix never named: Esc while a panel is open, focus after a mode change,
refresh during a load, closing a window with work in flight, relaunch, and results that land after the user moved
on. This file names those cases once so briefs, test matrices and audits all use the same list.

Visual and state dimensions — longest zh/en label, light/dark, @1x/@2x, viewport breakpoints — are **not** repeated
here. They live in the
[brief template](../../.agents/skills/picsee-delegator/references/templates/brief-template.md) sections
"UI design contract" and "Design-derived assertions" (content pressure column), and in [`ui-parity-contract.md`](ui-parity-contract.md). Do not multiply each lifecycle case by each visual
dimension; there is no quota.

## How to fill it in

The delegator copies the applicable cases into the brief's **Interaction & lifecycle** section. Each applicable
case is one row, written as start state → event sequence → expected result → proving test or device run:

| Case | Start state | Event sequence | Expected result | Proving test or device run |
|---|---|---|---|---|
| `<case>` | `<mode, selection, what is loading>` | `<user/system events in order>` | `<observable result: state, focus, what is shown, what is not delivered>` | `<test name>` or `Device-Smoke: <step>` |

- A case that cannot happen for this change gets `n/a` with a one-line reason (for example "no async work",
  "panel has no keyboard focus"). A blank row or a bare `n/a` is not a reason.
- The proving test is written in the test matrix before implementation, like any other RED. A case only a signed
  App can show (real window close, relaunch with grants) names the device run instead and stays `NOT VERIFIED`
  until that run exists.
- Assert on what the user observes or what the model publishes, not on a flag the implementation happens to set.

## Cases

### 1. Esc
Esc from every new state: which layer closes first (popover, sheet, panel, mode), where the user lands, and that
one Esc never closes two layers. Include Esc while a load for that state is still running, and Esc when a text
field inside the state has focus.

### 2. Focus
After the state opens and after it closes: which view is first responder, whether arrow keys and ⌘ shortcuts reach
the intended target, and that focus does not land on a hidden or disabled control. Include VoiceOver order when the
state adds controls.

### 3. Refresh
A refresh, rescan or file-system change while the state is open or loading: the state keeps or drops its selection
by a stated rule, and the old content is not shown under the new one.

### 4. Close
Closing the window (or the last window) while the state is open: no orphaned panel, popover or sheet, no crash,
and the next window opens in the defined default state.

### 5. Relaunch
Quit and relaunch with the state open: what is restored, what is deliberately not restored, and that restored
state does not reference grants, files or items that no longer exist.

### 6. Cancel mid-load
The user leaves (navigates, switches mode, presses Esc, selects another item) while a load for this state is
running: the load is cancelled or its result discarded, and progress UI disappears.

### 7. Tasks cancelled on close
Work started by the state (decode, metadata read, thumbnail, scan, file access) is cancelled or released when its
window or owner closes: no task keeps a security-scoped resource, a decoder or memory alive past its owner.

### 8. Late or stale completion
A result that completes after it was superseded (newer request, different item, closed window) is never delivered
to the screen or the model. Prove it with an ordering the test controls (generation/token check, out-of-order
completion), not with a sleep. This is audit dimension D3 (`docs/agents/audit-dimensions.md`): a stale result
delivered is High.

## Who checks what

- **Delegator:** fills the brief section, marking each case applicable or `n/a` with a reason.
- **Implementer:** turns every applicable row into a test-matrix entry (or a named device run) in the
  `/tdd-guardian:workflow` design-tests step, and reports the row → test mapping in the handoff.
- **Auditor:** checks each applicable row has a discriminating proving test or named device run, and each `n/a`
  reason holds against the code. A missing row for a reachable case is at least Medium.
