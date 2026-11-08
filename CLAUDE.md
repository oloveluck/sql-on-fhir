# CLAUDE.md — sql-on-fhir

Part of the fhir family (conventions, HTDP style and the package map live in the main `fhir` repo's
CLAUDE.md). Collection `sql-on-fhir`; `raco sql-on-fhir`.

- **From the spec.** `target.rkt` is a fhir/codegen target over `spec/hl7.fhir.uv.sql-on-fhir.tgz`
  (whitelist ViewDefinition, delegating to the R6 tower, collection "sql-on-fhir"): `model/` is
  GENERATED — never edit it; `raco sql-on-fhir regen` writes it, `check` (and tests/tck-test.rkt)
  verifies it. That gives the typed ViewDefinition (strict `from-json` is the view validator),
  `#lang sql-on-fhir/model` (re-exported as `#lang sql-on-fhir`, lang/reader.rkt), the required-binding
  terminology, and the package's OperationDefinitions as data (`model/operations.rkt`).
- **view.rkt** — the evaluator (restored from the family's earlier viewdef/eval.rkt): structural
  recursion over select items (column / forEach / forEachOrNull / repeat / nested select / unionAll),
  constants as %externals, %rowIndex, getResourceKey/getReferenceKey as an AST rewrite, every path
  through the fhirpath engine.
- **operations.rkt** — `$sql-run` / `$sql-export` as fhir/operation values on the generated
  definitions; data from `current-data-source`; `view-rows` for plain rows.
- **tests/** — harness.rkt runs one suite file (strict view parse = expectError, multiset row
  comparison, expectColumns order); run.rkt is `raco sql-on-fhir tck` with the floor; tck-test.rkt is
  what `raco test` runs. The suite is vendored verbatim (SOURCE.txt with the commit); `fetch` refreshes.
- **workspace.rkt** — the workspace support (fhir/lang/workspace): a ViewDefinition as JSON
  (`*.view.json`) is an artifact (url `<canonical>/ViewDefinition/<stem>` unless it has one), checked by
  the strict parse; `run` = its rows in column order; `explain` of a resource = the rows it alone
  produces, the rows without `where`, and each `where` clause alone.
