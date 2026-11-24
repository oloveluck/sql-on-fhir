# SQL on FHIR ViewDefinitions

A view flattens FHIR resources into a table: one row per resource (or per item of a repeating
element), one column per FHIRPath. Use it for tables and counts across a population.

**Write a view as source text**, in a `.sof` file: SQL's clauses with FHIRPath between them
(`SELECT … FROM Patient WHERE …`). It compiles to a *ViewDefinition*, the JSON resource the SQL on
FHIR standard defines and other tools exchange; a `*.view.json` file holding that JSON is read just
the same, and either form turns into the other without loss. This engine passes the shared SQL on
FHIR test suite, 144 of 144.

This guide is for writing views here: the language in brief, the ways to run one, and what to do
when something goes wrong. `LANGUAGE.md` defines the source text (grammar, what each part compiles
to); the specification is the reference for the ViewDefinition itself.

## Official references
- SQL on FHIR: https://sql-on-fhir.org
- The specification (ViewDefinition, the operations): https://build.fhir.org/ig/FHIR/sql-on-fhir-v2/
- FHIRPath, the language of every path: http://hl7.org/fhirpath/N1/

## Cheat sheet
```sof
CREATE VIEW bp_readings
  WITH (status = 'active')
AS
SELECT
  getResourceKey() AS id,
  subject.getReferenceKey(Patient) AS patient,
  effective.ofType(dateTime) AS date,
  (SELECT
     code.coding.code.first() AS code,
     value.ofType(Quantity).value AS value
   FROM component)
FROM Observation
WHERE code.coding.exists(system = 'http://loinc.org' and code = '85354-9')
```
The rules of the text, all of them:
- **Keywords are in capitals** (`SELECT FROM AS WHERE AND OR NULL REPEAT UNION ALL DECLARE CREATE
  VIEW WITH TYPE COLLECTION NOT DESCRIPTION TAG`); between them stands FHIRPath, whose own words
  are lower case. So `value as Quantity AS quantity` is a path and its column name.
- **A column** is `path AS name`; a path that is one element's name needs no `AS` (`gender`). After
  it: `COLLECTION` (every value, as a list), `TYPE dateTime`, `DESCRIPTION 'text'`.
- **A row for each item**: a parenthesised `SELECT … FROM path` (the standard's `forEach`);
  `FROM path OR NULL` keeps a resource that has none, with nulls (`forEachOrNull`);
  `FROM REPEAT item, answer.item` follows the paths to any depth (`repeat`). Paths inside are
  relative to the item.
- **Alternatives stacked**: `(SELECT … FROM telecom UNION ALL SELECT … FROM contact.telecom)`,
  the last item of its `SELECT`; the selects name the same columns in the same order.
- **Which resources**: `WHERE cond AND cond` (each must be true; FHIRPath's lower-case `and` stays
  inside one condition).
- **A value named once**: `DECLARE loinc = 'http://loinc.org', top integer = 3` before `SELECT`;
  paths read `%loinc`.
- **The view itself**: `CREATE VIEW name WITH (status = 'active', title = '…') AS` before the
  query; `WITH` takes any other element of a ViewDefinition, its value written as JSON. A bare
  `SELECT … FROM Patient` is a view with no name.
- Comments are `--`, `//` and `/* */`. Several views in a file are separated by `;`.

That text compiles to this ViewDefinition (`sql-on-fhir compile` prints it; `decompile` goes back):
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
```sof
CREATE VIEW patients WITH (status = 'active') AS
SELECT getResourceKey() AS id, gender, birthDate AS birth_date
FROM Patient
```
which is this ViewDefinition:
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
sql-on-fhir run patients.sof data/ --format csv         # source text, over a directory of resources, a Bundle, or one resource
sql-on-fhir run patients.view.json bundle.json          # a ViewDefinition as JSON; NDJSON, the default; also json, fhir
sql-on-fhir compile patients.sof                        # the ViewDefinitions a file states, as FHIR JSON (-o dir/ writes <name>.view.json)
sql-on-fhir decompile patients.view.json                # a ViewDefinition as source text
sql-on-fhir run meds.view.json r4/ --fhir-version 4.0.1 # read the data as R4 (or 5.0.0); R6 is the default
sql-on-fhir features                                    # everything it does, as a list; `features view`, `features sql-run` … for one table
```
`features` is the map: every element of a view, every function a path may call, every parameter of
`$sql-run` and `$sql-export`, what refuses a view and what is not done, each with what happens to
it here (`yes`, `partly`, `unused`, `refused`, `no`) and the definition in the source that does it.
A view that is not a ViewDefinition (a misspelled element, a wrong type, a required element left
out, a name a database does not take, a path that is not FHIRPath) is refused before it reads any
data, with the reason and exit status 1; so is a view that fails on the
data, and a `#lang sql-on-fhir` file that does not compile (its message, no stack trace). A path to
an element the resource type lacks in the FHIR version read is said at its line and column: the
refusal when a column reads it from a resource, else a `warning:` on stderr beside the table. Two
more warnings come beside the table (stdout and the exit status are unchanged): a JSON view that
states no `status`, a view whose `fhirVersion` is not the version the data is read as, and data the
view reads that the read left out (below).

A `.sof` file may state several views; `run` takes the first. A problem in source text is said at
its line and column, exit status 1: the text's syntax (`patients.sof:2:3: this column needs a name:
write `name.family AS <name>``), a path that is not FHIRPath, a result that is no ViewDefinition.

**As a module.** A file that starts with `#lang sql-on-fhir` is a Racket module of views: source
text, or (beginning with a parenthesis) the forms generated from the IG. Either way a mistake is a
compile error at its place in the file, and the module provides `resources` (the typed views) and
`(->json)`; run as a program it prints its views as JSON.

**As an operation.** `$sql-run` and `$sql-export` (`sql-on-fhir/operations`) are the IG's operations
as procedures, over the current data source; `view-rows` gives the rows as hashes. `patient` and
`group` keep the resources of those patients and of a Group's members (each must resolve), `_since`
those changed after an instant. A Library subject, `source` and Parquet are answered `not-supported`.

**In a workspace** (fhir-mcp). A `.sof` file (or a `*.view.json` file) is a view, its canonical
`<workspace canonical>/ViewDefinition/<file stem>` unless it names one, checked as you write it;
in SQL it is the table named by the file (keep one view to a file there).
`run` answers its rows over the workspace's data in column order. `explain` of one resource
(`Patient/p1`) shows the rows that resource alone produces, the rows it would produce without the
`where`, and whether each `where` holds for it. `query("view", "SELECT id FROM Patient")` runs a
view without a file (source text, or JSON).

## Common problems
- ``unexpected word `select` (keywords are written in capitals: `SELECT`; in lower case `select` is
  read as part of a path)``: write the language's keywords in capitals; lower case belongs to
  FHIRPath.
- ``this column needs a name: write `name.family AS <name>` ``: only a path that is a single
  element's name may stand without `AS`.
- ``a UNION ALL group comes last in its SELECT``: move the columns before it, or wrap the group as
  `(SELECT (… UNION ALL …))`.
- `unknown field …`: the view is strictly checked against the ViewDefinition model generated from the
  IG. Fix the element's name; the message gives the element and a link to its definition.
- ``select[0].column[1].name "first-name" is not a name a database takes: letters, digits and _ only,
  starting with a letter``: the definition's rule for a column's, a constant's and the view's `name`.
  ``the column name `id` is used twice``: the columns of one table are named apart.
- ``select[0] has more than one of `forEach`, `forEachOrNull` and `repeat`: a select takes one``: nest
  a `select` inside the first for the second.
- ``the path "name." is not FHIRPath: the expression ends after `.` ``: a path's syntax, said whatever
  the data (in a workspace, at the path's line and column).
- `path yields 2 items without collection=true`: a column's path gave several values. Narrow it
  (`.first()`, a `where(…)`), make a row per item with `forEach`, or mark the column
  `"collection": true` to get a list.
- A resource is missing from the rows: a `forEach` over an element it does not have drops it. Use
  `forEachOrNull` to keep it with nulls, or check the `where` with `explain`.
- A choice element: `value.ofType(Quantity).value` and `effective.ofType(dateTime)` name the member.
- `getReferenceKey()` reads relative references (`Patient/p1`); an absolute URL gives null.
- `"live" is not in the required value set for ViewDefinition.status`: a code outside its value
  set (`status`, `resource`, `fhirVersion`), in a JSON view as in the `#lang sql-on-fhir` form.
- ``the view has no `resource` (the type of resource the view reads, such as "Patient")``,
  ``select[0].column[2] has no `name` ``: a required element is missing, named where. Held:
  `resource`, `select`, a column's `name` and `path`, a `where`'s `path`, a constant's `name` and
  value. Not refused in JSON: `status` (the shared suite's own views leave it out). The view runs
  with ``warning: view.json:1:1: no `status` (the standard requires it: "draft", "active", "retired"
  or "unknown")``, on the command line and as a warning of the workspace file; the `#lang` form
  requires it.
- `no element MedicationRequest.medicationCodeableConcept (the data is read as FHIR R6; --fhir-version
  4.0.1 reads it as R4)`: the command line reads data as R6 unless `--fhir-version` says `4.0.1` or
  `5.0.0` (a workspace reads it in the workspace's version). For R4 data, name the version.
- ``warning: view.json:3:2: the view is for FHIR 4.0 (`fhirVersion`) and the data is read as FHIR R6;
  --fhir-version 4.0.1 reads it as R4``: a view may name the versions it is written for; the option
  still decides how the data is read.
- `"resourceDefinition"` beside `"resourceType"` (the IG's examples carry it: R6 writes the canonical
  of ViewDefinition's definition there) is accepted and names no element.
- ``1 of 1 MedicationRequest resources holds `medicationCodeableConcept`, which was not read: FHIR R6
  has no such element (the first: MedicationRequest/m1); --fhir-version 4.0.1 reads the data as R4``:
  a path valid in both versions with different meanings (`medication.ofType(CodeableConcept)` on a
  MedicationRequest) finds nothing in R4 data read as R6. The column is empty and the warning says
  what the resources held.
- ``1 of 2 Observation resources holds a value at `effectiveDateTime` that is not valid FHIR and was
  not read (the first: Observation/o1: "2021-05-31T00:00:00" — a time needs a time zone, such as Z or
  +01:00)``: an empty cell where the resource has a value. Resources are read leniently, and a value
  that is not valid FHIR is left out. Only what the view's paths read is reported (a dropped
  `period.start` is nothing to a view that reads `period.end`), once per element, counted over the
  resources. In a workspace the same sentences are the run's `unread`. `view-rows` and `$sql-run`
  return the rows alone; set `current-read-log` (sql-on-fhir/operations) to collect the drops.
