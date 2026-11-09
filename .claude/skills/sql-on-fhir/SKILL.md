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
2. **Read the refusal.** A view the model does not accept is refused before it runs, exit 1:
   ```
   sql-on-fhir: not a valid ViewDefinition: ViewDefinition: unknown field selct (see https://build.fhir.org/ig/FHIR/sql-on-fhir-v2/viewdefinition.html#ViewDefinition)
   ```
   A view that fails on the data is refused the same way:
   `sql-on-fhir: column codes: path yields 2 items without collection=true`.
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
instead of the data source), `#:patient`, `#:_since`, `#:_limit`, `#:header`. A failure raises
`exn:fail:operation` with an OperationOutcome.

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
refreshes the package and the suite. `tests/guide-test.rkt` keeps guide.md's examples true.
