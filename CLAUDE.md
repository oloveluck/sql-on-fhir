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
  produces, the rows without `where`, and each `where` clause alone. It also provides `guide`.
- **Docs for users and agents** (the family's pattern, see the main repo's CLAUDE.md): `guide.md` is
  the format for agents (cheat sheet, worked example, running it, common problems), provided by
  `workspace.rkt` as `guide` (fhir-mcp's `learn://sql-on-fhir`); `tests/guide-test.rkt` parses every
  ```view block strictly and checks the rows and problems the text states. `.claude/skills/sql-on-fhir`
  is the workflow without MCP (every command in it was run). `scribblings/sql-on-fhir.scrbl` is the
  manual; `tests/docs-test.rkt` renders it and fails on a broken reference to its own sections or
  bindings. Writing them fixed: `run` treated only `.rkt` files as modules (the manual's `.sof` file
  crashed reading JSON) — a file starting with `#lang` is one now, and a file that is not JSON is a
  one-line error; a view that fails on the data (a multi-valued column) escaped `$sql-run` as a raw
  exception (a stack trace at the CLI, a 500 over HTTP) — it is an OperationOutcome, `processing`.
  Then fixed (2026-11-09): a JSON view was not checked against its required bindings (`"status":
  "live"` ran; the `#lang` form refused it at compile time). The runtime schema carries no binding
  (only the form macros' field-specs do), so `operations.rkt`'s `typed-view` reads the required
  bindings from the IG's StructureDefinition snapshot in `spec/` (once, lazily) and checks each code
  against the generated terminology's expansion — all 144 suite views pass it.
