# Regression Cases

Use these cases to sanity-check whether the skill is preserving contribution boundaries instead of inflating ordinary implementation details.

## Case 1: Repeated Training Packaged As A Strategy

### Scenario

The real work was:

- Train the detector once at 640 resolution
- Continue training from the saved checkpoint at 800 resolution
- Observe that localization improved

The author does **not** claim this as a novel method contribution. It is a training fact and should be treated as an implementation detail unless the paper explicitly studies it with controlled evidence.

### Bad output

`We propose a two-stage progressive-resolution training strategy that improves localization quality.`

Why this is bad:

- It upgrades a routine training procedure into a named `strategy`
- It suggests a method contribution that the author may not be claiming
- It risks misleading readers, reviewers, or committee members about what is actually novel

### Good output

`The detector was trained first at 640 resolution and then continued at 800 resolution, which improved localization quality on this dataset.`

Or, if the detail is not central to the summary:

`The detector was trained and optimized for the target dataset.`

### Expected ruling

- Classify as: `implementation detail`
- Do not place it in the abstract, contribution list, or conclusion as a named contribution unless the paper explicitly defends it as one
- Prefer labels such as `training setup`, `continued optimization`, or `detector configuration`
- Reject labels such as `strategy`, `framework`, `mechanism`, or `novel module`

### Quick decision test

Ask:

`If a committee member asks whether this is a claimed method contribution or just how the system was trained, what is the honest answer?`

If the honest answer is `just how it was trained`, the inflated wording must be rejected.
