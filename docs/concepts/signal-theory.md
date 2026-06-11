# Signal Theory

Signal Theory is the engine's classification model for turning noisy input into
structured operating context.

The core shape is:

```text
Signal = Mode + Genre + Type + Format + Structure
```

| Dimension | Question | Examples |
| --- | --- | --- |
| Mode | What kind of medium is this? | linguistic, visual, audio, code, event, multimodal |
| Genre | What social/work form is it? | note, decision, transcript, spec, runbook, brief, report |
| Type | What action does it perform? | inform, decide, ask, commit, warn, delegate, evidence |
| Format | How is it encoded? | markdown, JSON, PDF, image, audio, video, API payload |
| Structure | What skeleton does it follow? | freeform note, checklist, meeting log, table, contract, issue |

## Why It Exists

The engine cannot treat every input as generic text. A support ticket, meeting
transcript, calendar event, design screenshot, deployment log, and model output
need different routing, extraction, retention, and review rules.

Signal classification answers:

```text
What is this?
Where should it route?
Which parser or adapter should process it?
What claims can be extracted from it?
How trustworthy is it?
Which projection should display it?
```

## Boundary

Signals are interpretations, not truth.

```text
Source Package preserves what arrived.
Signal classifies what kind of thing it is.
Claim records what the source appears to say.
Fact records what review/policy accepts as true.
```

This separation is the main safety rule. The engine can classify a messy input
without believing it.

