# Writing style rules

These rules apply to every file in this repo: docs, comments, commit messages, PR
descriptions, and script output. CI and pre-commit enforce the hard rules via
`scripts/lint-language.sh`.

## Rule 1 — no AI references or attribution

Nothing in this repo may identify content as AI-produced or reference AI tooling as its
author. Concretely banned:

- Commit trailers such as `Co-Authored-By: Claude`, `Co-Authored-By: <any AI>`,
  `Generated with <tool>`, or emoji-robot bylines
- "As an AI", "AI-generated", "written by/with ChatGPT/Claude/Copilot" anywhere in
  docs or comments
- Badges or footers advertising generation tools

Rationale: the repo speaks with one voice — the maintainer's. Provenance of a change is
the review and the tests, not a byline.

## Rule 2 — no AI-tell language

Text must not read like generated filler. Research on overused model vocabulary (see
sources) converges on the same tells; the study finding "delve" up ~400% in post-2022
PubMed abstracts is the canonical example.

**Hard-banned (lint fails):** delve, tapestry, "in today's", "it's worth noting",
"it's important to note", "in conclusion", furthermore, moreover, "game-changer",
seamless/seamlessly, "embark", "let's dive", "dive into", "let's explore", elevate,
supercharge, "unlock the".

**Discouraged (reviewer judgment, not linted):** leverage (verb), utilize (use "use"),
robust, pivotal, cutting-edge, landscape (metaphorical), realm, synergy, testament,
harness (verb), streamline, underscore (verb), empower, crucial, "navigating X".
These have legitimate technical uses; flag them in review when they read as filler.

**Structural tells to avoid:** rule-of-three padding ("fast, reliable, and secure"),
paragraph-opening "Additionally,"/"Notably,", conclusions that restate the section,
hedging ("may potentially"), and enthusiasm inflation ("powerful", "amazing").

**Write instead:** short declarative sentences, concrete nouns, measured claims,
numbers over adjectives. "ufw blocks inbound by default" beats "a robust firewall
posture is seamlessly enforced".

## Enforcement

- `scripts/lint-language.sh` greps staged text files for the hard-banned list and any
  AI-attribution pattern; wired into `.pre-commit-config.yaml` (this file and the
  script itself are excluded — they must name the banned terms).
- Commit messages are checked by the same script via the `commit-msg` stage.

## Sources

- [Words and phrases that make it obvious you used ChatGPT](https://medium.com/learning-data/words-and-phrases-that-make-it-obvious-you-used-chatgpt-2ba374033ac6)
- [300+ overused AI words list (2026)](https://alstonantony.com/seo-strategy/chatgpt-overused/)
- [Most common ChatGPT words to avoid](https://walterwrites.ai/most-common-chatgpt-words-to-avoid/)
- [The "delve" phenomenon in PubMed](https://ruben.substack.com/p/delve)
- [Words to avoid so you don't sound like AI](https://aisdr.com/blog/words-to-avoid-so-you-dont-sound-like-ai/)
