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
- **Claude as the user** (2026-11-09; the main repo's CLAUDE.md): the workspace checks every column,
  forEach and where path against the view's resource (`path-problems`, FHIRPath's static pass after
  `rewrite-sof`; inside a forEach against the element it iterates; `repeat` left to run time) and
  reports an element the type lacks at its string in the file, with a suggestion. 0 of the 144 suite
  views are flagged; workspace.rkt's test pins two typos at their lines.
- **What the manual found** (2026-11-13; four defects a person met writing it, each with a test that
  fails without its fix — `tests/cli-test.rkt` runs `raco sql-on-fhir run` in a process of its own
  and compares stdout, stderr and the exit status):
  - **A required element left out is a view problem.** The strict parse (`from-json`) checks the
    elements that are THERE (names, shapes, list or scalar), never that a required one is: a view
    without `resource` reached `string->symbol` (`contract violation`, through `$sql-run` too), a
    column without `name` a stack trace. `operations.rkt`'s `required-problems` walks the view's JSON
    beside the IG's StructureDefinition snapshot (`definition-elements`, read from spec/ once and
    shared with the required bindings; a contentReference continues at the element it names — a
    nested select is a select —, a choice is there when a member is) and `typed-view` refuses with
    where it is missing and what it is (``select[0].column[2] has no `name` (the column's name in
    the table)``; `required-words`, else the definition's `short`). `eval-view` says a missing
    `resource` itself (the harness calls it directly: the suite's three such views expect an error).
  - **`status` is NOT held, on purpose** (`unheld-required`); since 2026-11-13 a view without it
    is told so (below). The definition says 1..1 and the
    `#lang` form requires it, but 33 of the 133 views the shared suite expects to RUN leave it out:
    requiring it in JSON would refuse views the standard's own suite runs. tck-test.rkt prints the
    count (when it reaches 0 the exception can go) and checks that `typed-view` refuses no view the
    suite runs (the harness parses views itself, so the 144/144 would not have shown it).
  - **`run --fhir-version 4.0.1|5.0.0|6.0.0`** (default 6.0.0, as before). The view model is built
    over R6 and a process holds one type per name, so cli.rkt no longer requires the engine
    statically: `cmd-run` loads the asked version's tower (`fhir/r4/schemas`, `fhir/r5/schemas`),
    pins it (`pin-registered-types!`, fhir/model/registry — what the fhir-mcp hub does), and only
    then loads `sql-on-fhir/operations` and a view written as a module (both bring the R6 model,
    which now adds ViewDefinition and replaces nothing). They are named by
    `define-runtime-module-path-index`, so a standalone build carries them (not built here).
    R4's `MedicationRequest.medicationCodeableConcept` reads; nothing in fhir/ changed.
  - **A path to an element the type lacks in the version read is said, at its place in the file.**
    workspace.rkt exports `path-problems`; the command line runs it on the view (JSON or module
    text) and prints each as `sql-on-fhir: warning: view.json:9:32: no element … (the data is read
    as FHIR R6; --fhir-version 4.0.1 reads it as R4)` on stderr — a view over no data, or a
    `forEach` over such an element (the engine tolerates it: repeat and forEach meet heterogeneous
    foci), printed an empty table and exit 0. When the run then fails on that very path, the
    positioned line is the error, said once. `path-problems` reports a bad `forEach` once: the
    columns inside it are no longer each blamed for it.
  - **A `#lang sql-on-fhir` file that does not compile** (or raises, or provides no view) is its
    message alone, exit 1 (`read-view`, `module-error-text`): `sql-on-fhir: bad.sof:3:2:
    ViewDefinition: unknown field ViewDefinition.selct` and the form's `at:`/`in:` lines, no
    `context...`. A position is kept only when it is in the user's file. The generated reader
    (`model/lang/reader.rkt`, from fhir's codegen) now reads forms as syntax (`read-syntax`; it used
    `read`, so a form error carried no position, or kit.rkt's own), so every form error has its line
    and column.
- **What was still silent, said** (2026-11-13; `tests/cli-test.rkt`, `tests/guide-test.rkt` and the
  modules' own tests; stdout and the exit status never change, `typed-view`/`$sql-run` accept what
  they accepted):
  - **No `status`** is a warning: `workspace.rkt`'s `status-problem` (a warning-severity diagnostic
    at the view's opening brace; `text-location` is the one line/column computation) among a
    workspace file's artifacts' problems, and `sql-on-fhir: warning: view.json:1:1: no `status`
    (the standard requires it: "draft", "active", "retired" or "unknown")` from `run` (JSON views;
    the `#lang` form cannot leave it out).
  - **Data the read left out, when the view reads it.** `operations.rkt` keeps a read log when one
    is set (`current-read-log`, `make-read-log`, `read-log-count`, `read-log-reads`): `typed-resource`
    counts every resource and keeps each whose lenient read dropped values (`lenient-drops`; a
    resource that does not read at all is 'unreadable). `unread.rkt` decides what concerns the view:
    `view-chains` turns every path (columns under their forEach, where clauses, the arguments of
    where/select/exists… under the element they test; `repeat`'s paths whole) into the elements it
    walks — a Chain of Steps `(name . variant)`, functions left out, `ofType(T)`/`as T` narrowing
    the last step to that choice member — and a drop is RELEVANT when its JSON path agrees with a
    chain step by step for as long as both go (`effectiveDateTime` for `effective.ofType(dateTime)`,
    not for `effective.ofType(Period).start`; `period.start` for `period.start` or `period`, not for
    `period.end`). `unread-notes` groups the relevant drops by element and kind — FHIRPath's static
    pass over the dropped path says whether the version read has the element (`no-element`: "which
    was not read: FHIR R6 has no such element", and, read as R6 only, "--fhir-version 4.0.1 reads the
    data as R4") or the value is not valid FHIR (`invalid`: the first value quoted, with the
    calendar's reason from `drops-message` or "a time needs a time zone") — one sentence each,
    counted over the resources, the first named. `workspace.rkt`'s `with-unread` runs a thunk under
    a log and returns the sentences: `raco sql-on-fhir run` prints them as warnings (not for an
    element a path warning already named: `unread-warnings`), a workspace run carries them as its
    summary's `unread`. Decided by measuring: over the eCQM patients read as R4, a view of
    Observation codes says nothing, one of `effective.ofType(dateTime)` says 12 of 47, one of
    Encounter `period.start` 65 of 86 (and nothing of `period.end`); over the shared suite's 133
    running views it says nothing.
  - Not done: `view-rows`/`$sql-run` return rows alone (a caller sets `current-read-log`); the
    value itself is never repaired.
