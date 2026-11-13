# CLAUDE.md — sql-on-fhir

Part of the fhir family (conventions, HTDP style and the package map live in the main `fhir` repo's
CLAUDE.md). Collection `sql-on-fhir`; `raco sql-on-fhir`.

- **From the spec.** `target.rkt` is a fhir/codegen target over `spec/hl7.fhir.uv.sql-on-fhir.tgz`
  (whitelist ViewDefinition, delegating to the R6 tower, collection "sql-on-fhir"): `model/` is
  GENERATED — never edit it; `raco sql-on-fhir regen` writes it, `check` (and tests/tck-test.rkt)
  verifies it. That gives the typed ViewDefinition (strict `from-json` is the view validator),
  `#lang sql-on-fhir/model` (re-exported as `#lang sql-on-fhir`, lang/reader.rkt), the required-binding
  terminology, and the package's OperationDefinitions as data (`model/operations.rkt`).
- **view.rkt** — the evaluator: the typed view is COMPILED once (`compile-view`: a View of Sels,
  each an Iteration — #f | `each` | `repeat` —, Cols and Exprs; the data definition is at the top of
  the file) and the rows are a structural recursion over that (`sel-rows`, `item-rows`, `product`),
  constants as %externals, %rowIndex, getResourceKey/getReferenceKey as an AST rewrite, every path
  through the fhirpath engine. What is wrong with the view itself is an `exn:fail:view`, raised
  before any resource is read.
- **definition.rkt** — a view held to the IG's StructureDefinition (`read-view`: the strict parse,
  required elements, required bindings, the definition's own constraints as FHIRPath).
- **operations.rkt** — `$sql-run` / `$sql-export` as fhir/operation values on the generated
  definitions; data from `current-data-source`; `view-rows` for plain rows; the read log.
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
    column without `name` a stack trace. `required-problems` (since the pass below: definition.rkt's
    `definition-problems`) walks the view's JSON
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

- **Quality, performance and specification pass** (2026-11-13). Held to a dump of what the code
  gives over the shared suite's 144 views and the IG's ten examples (rows as evaluated, `view-rows`,
  `$sql-run` in four formats, path and status problems, chains, unread notes) and of the command
  line over five views on the 262 eCQM resources read as R4 and as R6: identical before and after
  but for the changes named here.
  - **The engine compiles a view once** (view.rkt). It parsed nothing twice (parse-fhirpath is
    memoised) but rewrote each path's AST for every cell, checked a `unionAll`'s branches at every
    focus, and — through `eval-fhirpath` — ran FHIRPath's static pass (`analyze`) for every cell of
    every resource: 25% of the engine's time. `compile-view` builds the View once; an Expr keeps
    the static pass's verdict per focus type (`static-problem`, a hasheq in the Expr) and
    `eval-expr` is `fp-eval` after it, so the answer per (path, type) is asked once and a tolerated
    "no element" (forEach, repeat over heterogeneous foci) costs nothing the second time.
    `product` is the one cartesian product (`product-rows` and `item-rows` each had it), `cell` the
    one rule for a column's value (`columns-row` and `null-row` each had it), `sel-names` the one
    reading of a select's columns (`view-columns` and `branch-columns`). Engine over the five eCQM
    views, x10: 130 -> 76 ms; `view-rows` over the 262 mixed resources: 12-16 -> 2-7 ms (below).
  - **Static refusals are static** (BEHAVIOUR): a path that is not FHIRPath, `unionAll` branches of
    different columns and a column name used twice (new: the definition says "The column names in
    the output must not have any duplicates") are `exn:fail:view`, whatever the data — over no data
    such a view printed an empty table. `$sql-run` answers them `invalid`, "not a valid
    ViewDefinition: …" (they were `processing`, or nothing); the workspace positions a path's
    syntax error at its string (`exn:fail:view-path`); the `#lang sql-on-fhir` reader
    (lang/reader.rkt, ours; the generated one is wrapped) parses every string of a `path`,
    `forEach`, `forEachOrNull` or `repeat` form when the file is read (`check-paths!`,
    `path-syntax-problem`), so `raco make` fails at the string.
  - **definition.rkt**: what operations.rkt held a view to, moved to a module of its own and
    completed. `children-by-parent` is the definition as a table of Childs (name, JSON key or
    choice prefix, where its own children are — a contentReference followed —, its constraints),
    built once: the walk split every path and scanned every element at every object (validation
    plus compile: 0.42 -> 0.26 ms a view). NEW (BEHAVIOUR): the definition's own constraints are
    held, read from the snapshot and evaluated as FHIRPath on the typed node (`own-constraints`,
    `broken?`: a plain false only): `sql-name` (the view's, a constant's, a column's name) and
    `sql-expressions` (at most one of forEach, forEachOrNull, repeat — the engine silently took
    repeat, else forEach). None of the suite's 133 running views breaks one (tck-test).
    R6's `resourceDefinition` beside `resourceType` (the marker of a resource that is not in the
    core specification) is accepted when it names the definition: ALL TEN example ViewDefinitions
    of the IG package were refused as published (`unknown field resourceDefinition`); tck-test
    now holds them.
  - **Operations by their definitions** (BEHAVIOUR; operations.rkt's tests): `group` is the
    resources of a Group's active members (it was ignored: every patient's rows came back); a
    `patient` or `group` that does not resolve is `invalid` (over inline `resource`s a patient
    filters by reference alone); `parameters` is `invalid` for a ViewDefinition, `source` and a
    Library subject `not-supported` (all three were ignored, a Library read as a broken view);
    `_since` compares instants (`changed-after?`: as text, 23:30-05:00 sorted before the next
    day's 00:00Z); `header: false` given in a Parameters resource is read (`header?`: see "found
    elsewhere"). `$sql-export`: `_format=fhir` is refused (it became NDJSON), `header` applies, a
    subject's `name` part names its output, two outputs of one name are refused, `_format` is
    echoed. A view reads the resources of its type only (`of-type`): inline resources of other
    types were each parsed, and counted in the read log ("1 of 262 Observation resources").
  - **`fhirVersion`** (BEHAVIOUR): a view that names the versions it is for, read as another, is a
    warning at `fhirVersion` (`version-problem`, workspace.rkt; the command line adds the option
    that reads it as one of them). It does not choose the version: the option and the workspace do.
  - unread.rkt's `view-chains` is a pure structural recursion (`ends` answers where the values
    sit AND what was read on the way; it `set!` an accumulator); tests/harness.rkt folds (two
    `set!`s) and owns `suite-files` (the directory filter was written three times); cli.rkt's
    `located` is the one `file:line:col: message` (two copies).
  - Decided, not done: a column's `type` is not checked or used to convert (the standard: an
    implementation "should report an error" on a mismatch, or a complex value with no type). The
    suite does not measure it — its 1,019 typed cells all agree with their types by JSON kind and
    none is complex — and it needs the item's FHIR type at the cell with FHIR's subtype rules, and
    a warning channel beside the rows. `status` stays a warning (33 of 133). `$sql-export` stays
    synchronous (no `location` to poll); SQLQuery/SQLView Libraries and Parquet are out of scope.
    The Shareable and Tabular profiles are not checked when a view claims them. The specification's
    narrative pages could not be read in this session (sql-on-fhir.org and build.fhir.org were not
    reachable): alignment is to the package's StructureDefinition, OperationDefinitions and
    examples, and to the suite.
  - Found elsewhere, not fixed here: fhirpath's `matches`/`replaceMatches` compile their pattern on
    every call (42% of the engine's time on a view with reference keys, after this pass) and
    `analyze`'s `resolve` computes `fhir-ancestors` twice per step; its lex error for `@@` quotes
    no text. fhir/operation's `parameters->inputs` takes a parameter's first TRUE value, so
    `valueBoolean: false` arrives as the parameter object. The generated strict parse knows no
    `resourceDefinition` (any R6 additional resource meets that).
