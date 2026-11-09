# SQL on FHIR ViewDefinitions

A ViewDefinition flattens FHIR resources into a table: one row per resource (or per item of a
repeating element), one column per FHIRPath. It is JSON, written in a `*.view.json` file (or as
`#lang sql-on-fhir` forms). Use it for tables and counts across a population. This engine passes the
shared SQL on FHIR test suite, 144 of 144.

This guide is for writing views here: the format in brief, the ways to run one, and what to do when
something goes wrong. The specification is the reference for the format itself.

## Official references
- SQL on FHIR: https://sql-on-fhir.org
- The specification (ViewDefinition, the operations): https://build.fhir.org/ig/FHIR/sql-on-fhir-v2/
- FHIRPath, the language of every path: http://hl7.org/fhirpath/N1/

## Cheat sheet
```view
{
  "resourceType": "ViewDefinition",
  "name": "bp_readings",
  "status": "active",
  "resource": "Observation",
  "where": [{"path": "code.coding.exists(system = 'http://loinc.org' and code = '85354-9')"}],
  "select": [
    {"column": [
      {"name": "id", "path": "getResourceKey()"},
      {"name": "patient", "path": "subject.getReferenceKey(Patient)"},
      {"name": "date", "path": "effective.ofType(dateTime)"}]},
    {"forEach": "component", "column": [
      {"name": "code", "path": "code.coding.code.first()"},
      {"name": "value", "path": "value.ofType(Quantity).value"}]}
  ]
}
```
Over a blood-pressure panel with a systolic and a diastolic component, this gives two rows, one per
component, each with the Observation's `id`, `patient` and `date`. The selects of one view multiply:
`forEach` makes a row per item, `forEachOrNull` keeps a resource that has none (with nulls),
`unionAll` stacks selects as alternatives, and `repeat` follows a path recursively (nested
`item.item`). `where` keeps the resources whose path is true. `constant` names values the paths use
as `%name`. `getResourceKey()` is the resource's id and `getReferenceKey(Patient)` the id a reference
names, so the two join. A column's path must give at most one value per row, unless the column says
`"collection": true`.

## Worked example
```view
{"resourceType": "ViewDefinition", "name": "patients", "status": "active", "resource": "Patient",
 "select": [{"column": [{"name": "id", "path": "getResourceKey()"},
                        {"name": "gender", "path": "gender"},
                        {"name": "birth_date", "path": "birthDate"}]}]}
```
Over a female patient `p1` born 1974-12-25 and a male patient `p2` born 1990-03-01, as CSV:
```
id,gender,birth_date
p1,female,1974-12-25
p2,male,1990-03-01
```

## Running it
**Command line.** `sql-on-fhir` (or `raco sql-on-fhir`):
```
sql-on-fhir run patients.view.json data/ --format csv   # a directory of resources, a Bundle, or one resource
sql-on-fhir run patients.view.json bundle.json          # NDJSON, the default; also json, fhir
sql-on-fhir run readings.sof data/                      # a #lang sql-on-fhir module, whatever its extension
```
A view that is not a ViewDefinition (a misspelled element, a wrong type) is refused before it runs,
with the reason and exit status 1; so is a view that fails on the data.

**As a module.** A file that starts with `#lang sql-on-fhir` writes the view in forms generated from
the IG, so a misspelled element or a `status` outside its value set is a compile error. It provides
`resources` (the typed views) and `(->json)`.

**As an operation.** `$sql-run` and `$sql-export` (`sql-on-fhir/operations`) are the IG's operations
as procedures, over the current data source; `view-rows` gives the rows as hashes.

**In a workspace** (fhir-mcp). A `*.view.json` file is a ViewDefinition, its canonical
`<workspace canonical>/ViewDefinition/<file stem>` unless it names one, checked as you write it.
`run` answers its rows over the workspace's data in column order. `explain` of one resource
(`Patient/p1`) shows the rows that resource alone produces, the rows it would produce without the
`where`, and whether each `where` holds for it. `query("view", <json>)` runs a view without a file.

## Common problems
- `unknown field …`: the view is strictly checked against the ViewDefinition model generated from the
  IG. Fix the element's name; the message gives the element and a link to its definition.
- `path yields 2 items without collection=true`: a column's path gave several values. Narrow it
  (`.first()`, a `where(…)`), make a row per item with `forEach`, or mark the column
  `"collection": true` to get a list.
- A resource is missing from the rows: a `forEach` over an element it does not have drops it. Use
  `forEachOrNull` to keep it with nulls, or check the `where` with `explain`.
- A choice element: `value.ofType(Quantity).value` and `effective.ofType(dateTime)` name the member.
- `getReferenceKey()` reads relative references (`Patient/p1`); an absolute URL gives null.
- A view in JSON is checked for structure; a `status` outside its value set is caught only in the
  `#lang sql-on-fhir` form.
