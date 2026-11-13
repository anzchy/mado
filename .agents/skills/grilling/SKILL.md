---
name: grilling
description: Interview the user relentlessly about a plan or design until every branch of the decision tree is resolved. Used by grill-with-docs; not for implementation.
---

Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one by one.

- Ask one question, or one small group of tightly related questions, at a time. In Claude Code, use `AskUserQuestion`.
- For each question, give your recommended answer and why.
- If a question can be answered by exploring the codebase, the docs or the ADRs, explore them instead of asking.
- Probe edge cases with concrete scenarios, and flag any answer that conflicts with an existing ADR, GLOSSARY term or ledger acceptance.
- Record each decision as it is made, quoting the user's own words where they gave them.
