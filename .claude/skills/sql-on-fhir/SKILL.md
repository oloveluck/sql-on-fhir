---
name: sql-on-fhir
description: Write, check and run SQL on FHIR ViewDefinitions without an MCP server — `raco sql-on-fhir run` (a view over a directory, Bundle or resource, as CSV, NDJSON, JSON or FHIR Parameters), `#lang sql-on-fhir` modules, `$sql-run`/`$sql-export` as operations, `view-rows` from Racket, the shared test suite, and regenerating the model from the IG package. Use when writing or debugging a *.view.json ViewDefinition, flattening FHIR resources into a table, or working on the view engine.
---

# SQL on FHIR without MCP

Read [`guide.md`](../../../guide.md) first: the ViewDefinition format in brief, a checked cheat sheet
and worked example, and the common problems (that guide is what fhir-mcp serves as
`learn://sql-on-fhir`). This skill is the workflow around it.

`sql-on-fhir` and `raco sql-on-fhir` are the same tool (the standalone build is `dist/bin/sql-on-fhir`).

## The loop
1. **Run the view over data.** The data is a directory of FHIR JSON files, a Bundle, or one resource:
   ```
   raco sql-on-fhir run patients.view.json data/ --format csv
   ```
   ```
   id,gender,birth_date
   p1,female,1974-12-25
   p2,male,1990-03-01
   ```
   `--format` is `ndjson` (the default), `json`, `csv` or `fhir` (a Parameters of rows). A
   `#lang sql-on-fhir` module runs the same way, whatever its extension (`run readings.sof data/`).
   The data is read as FHIR R6 unless `--fhir-version 4.0.1` (R4) or `5.0.0` says otherwise; for R4
   data, say so (R4's `medicationCodeableConcept` is not an element of R6):
   ```
   raco sql-on-fhir run meds.view.json r4/ --format csv --fhir-version 4.0.1
   ```
2. **Read the refusal.** A view the model does not accept is refused before it runs, exit 1:
   ```
   sql-on-fhir: not a valid ViewDefinition: ViewDefinition: unknown field selct (see https://build.fhir.org/ig/FHIR/sql-on-fhir-v2/viewdefinition.html#ViewDefinition)
   ```
   So is a view that leaves out a required element, named where it is missing (all but `status`,
   which the shared suite's own views omit: the view runs, with ``warning: view.json:1:1: no
   `status` (the standard requires it: …)`` on stderr):
   ```
   sql-on-fhir: not a valid ViewDefinition: select[0].column[2] has no `name` (the column's name in the table)
   ```
   So are the definition's own rules, and a path that is not FHIRPath (whatever the data):
   ```
   sql-on-fhir: not a valid ViewDefinition: select[0].column[1].name "birth-date" is not a name a database takes: letters, digits and _ only, starting with a letter
   sql-on-fhir: not a valid ViewDefinition: the column name `id` is used twice: the columns of a table are named apart
   sql-on-fhir: not a valid ViewDefinition: select[0] has more than one of `forEach`, `forEachOrNull` and `repeat`: a select takes one
   sql-on-fhir: not a valid ViewDefinition: the path "name.family." is not FHIRPath: the expression ends after `.`
   ```
   A view that fails on the data is refused the same way:
   `sql-on-fhir: column codes: path yields 2 items without collection=true`. A path to an element
   the type lacks in the version read is said at its line and column — the refusal when a column
   reads it from a resource, a `warning:` on stderr when nothing fails (no resources of the type, a
   `forEach`):
   ```
   sql-on-fhir: meds.view.json:9:32: no element MedicationRequest.medicationCodeableConcept (the data is read as FHIR R6; --fhir-version 4.0.1 reads it as R4)
   ```
   A view that names the versions it is for (`"fhirVersion": ["4.0"]`), read as another, is warned:
   ```
   sql-on-fhir: warning: r4.view.json:6:3: the view is for FHIR 4.0 (`fhirVersion`) and the data is read as FHIR R6; --fhir-version 4.0.1 reads it as R4
   ```
   An empty cell where the resource has a value is said too, when the view reads the element
   (stdout and the exit status are unchanged; what the view does not read is not reported):
   ```
   sql-on-fhir: warning: 1 of 1 MedicationRequest resources holds `medicationCodeableConcept`, which was not read: FHIR R6 has no such element (the first: MedicationRequest/m1); --fhir-version 4.0.1 reads the data as R4
   sql-on-fhir: warning: 1 of 2 Observation resources holds a value at `effectiveDateTime` that is not valid FHIR and was not read (the first: Observation/bp-1: "2021-05-31T00:00:00" — a time needs a time zone, such as Z or +01:00)
   ```
   A `#lang sql-on-fhir` file that does not compile prints its message alone (`sql-on-fhir:
   readings.sof:3:41: ViewDefinition: unknown field ViewDefinition.resorce`, the form on the next
   lines), exit 1. A path that is not FHIRPath is such an error, at its string
   (``bad-path.sof:5:68: ViewDefinition: the path "family." is not FHIRPath: the expression ends
   after `.` ``): `raco make` finds it.
3. **Narrow it down.** Too few rows: a `where` that is false, or a `forEach` over an element some
   resources lack (`forEachOrNull` keeps them). Check one path at a time with FHIRPath
   (`raco fhirpath '<path>' resource.json`, the fhirpath skill), or run a view with just that column.

## From Racket
```racket
(require json fhir/operation fhir/data-source sql-on-fhir/operations)
(define view (call-with-input-file "patients.view.json" read-json))
(view-rows view patients)                                ; rows as hashes, over the resources given
(parameterize ([current-data-source (directory->data-source "data/")])
  (view-rows view)                                       ; over the data source's resources of the view's type
  ($sql-run view #:_format "csv")                        ; a Binary (base64 CSV); "fhir" gives a Parameters
  ($sql-export #:subject (list view) #:_format "csv"))   ; a manifest Parameters: exportId, status, output
```
`$sql-run` also names a stored view: `(apply-operation "$sql-run" #:subjectCanonical "<url>" …)` finds
the ViewDefinition with that url in the data source. Inputs: `#:resource` (resources or Bundles
instead of the data source), `#:patient` and `#:group` (a Group's members; each must be in the data
source), `#:_since`, `#:_limit`, `#:header`. A failure raises `exn:fail:operation` with an
OperationOutcome: `invalid` for a refused view or input, `processing` for a failure on the data,
`not-supported` for a Library subject, `#:source` and Parquet. `$sql-export` refuses `_format` `fhir`
and two outputs of one name (a subject's `name` part names its output).

A `#lang sql-on-fhir` module provides `resources` (typed views) and `(->json)`:
```racket
(require (only-in "readings.sof" [->json views]) (only-in sql-on-fhir/operations view-rows))
(view-rows (car (views)) observations)
```
`racket readings.sof` prints the view as JSON.

## Working on the engine
`CLAUDE.md` is the architecture. `raco test .` runs everything; `raco sql-on-fhir tck` is the shared
suite (144/144, the floor; `-v` also prints each failure). `model/` is GENERATED from the IG package in
`spec/`: never edit it — `raco sql-on-fhir regen` rewrites it, `raco sql-on-fhir check` verifies it
("the model is up to date with spec/"), and `raco sql-on-fhir fetch [--version V] [--tests-commit SHA]`
refreshes the package and the suite. `tests/guide-test.rkt` keeps guide.md's examples true;
`tests/cli-test.rkt` runs the command itself (messages, warnings, exit statuses, `--fhir-version`);
`tests/tck-test.rkt` also holds the IG's own ten example views to be accepted as published.
The modules: `definition.rkt` (a view held to the IG's definition), `view.rkt` (the engine: a view
compiled once, then run), `operations.rkt`, `unread.rkt`, `workspace.rkt`, `cli.rkt`.
