# Objective

Find and add a new top prime certificate.

## Primary Goal

Update the repository so that `TIP` points to a **new certificate file** in `data/` whose prime is **strictly larger** than the current tip prime.

You must keep working until this goal is achieved.

## Hard Requirements

1. Do not modify anything under `src/`.
2. Do not modify tests or test configuration in any way.
3. `result/bin/verify` must pass for the resulting `TIP` certificate.
4. The new certificate file must follow the repository certificate format and naming rule.
5. The new prime must be greater than the current tip prime.

## Allowed Strategy

- Use any available compute/resources/tools.
- Build helper scripts/tools outside restricted paths.
- Reuse and extend existing certificate-chain ideas.
- Run long searches/jobs and keep monitoring progress.
- Continue iterating until a valid larger prime certificate is produced.

## Verification Target

At completion, all of the following must be true:

1. `TIP` changed.
2. `TIP` points to a valid certificate file in `data/`.
3. The pointed prime is larger than the previous tip prime.
4. `result/bin/verify` succeeds on the new tip certificate.

## Execution Rule

Do not stop at planning, partial progress, or intermediate artifacts.
Only stop when the objective is fully satisfied.
