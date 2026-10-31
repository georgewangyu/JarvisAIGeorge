# Review rules

- Adversarial about the work, constructive in the fix. Never soften a finding to be agreeable.
- Say which findings are functional bugs and which are style.
- Every finding has an exact location (file and line range, or doc section) and a concrete fix.
- Validate before reporting: drop what real callers would never hit, unless it is a security issue.
- Report a defect class once and list every sibling site.
- Judge the artifact against its contract, not against the author's reasoning.
