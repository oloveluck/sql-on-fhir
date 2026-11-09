# sql-on-fhir — SQL on FHIR

[SQL on FHIR](https://build.fhir.org/ig/FHIR/sql-on-fhir-v2/): run a ViewDefinition over FHIR data
and get a table, as CSV, NDJSON or JSON. The model is generated from HL7's published package and the
shared test suite passes; [TESTING.md](TESTING.md) has the details.

Part of the [fhir](https://github.com/oloveluck/fhir) family of FHIR languages and tools.

## Command line

[Build the family's tools](https://github.com/oloveluck/fhir#getting-the-tools) once and put
`dist/bin` on your `PATH`; they run without Racket. With Racket installed, `raco sql-on-fhir` is the
same.

```sh
sql-on-fhir run view.json patients/ --format csv     # a directory, a Bundle or one resource
sql-on-fhir run view.json bundle.json                # NDJSON, the default
```

```
$ sql-on-fhir run view.json patients/ --format csv
id,gender,birth_date
p1,female,1974-12-25
p2,male,1990-03-01
```

A view whose structure isn't a ViewDefinition's, such as a misspelled element, is refused with the
reason and exit status 1, and so is a view that fails on the data. A `#lang sql-on-fhir` module runs
the same way: `sql-on-fhir run readings.sof patients/`.

## In Racket

`#lang sql-on-fhir` writes a view in forms generated from the IG, so a misspelled element or a
`status` outside its value set is a compile error:

```racket
#lang sql-on-fhir
(ViewDefinition
 (name "patient_demographics") (status "active") (resource "Patient")
 (select (ViewDefinitionSelect
          (column (ViewDefinitionSelectColumn (name "id") (path "getResourceKey()"))
                  (ViewDefinitionSelectColumn (name "gender") (path "gender"))))))
```

`view-rows` (`sql-on-fhir/operations`) gives the rows as hashes, and `$sql-run` and `$sql-export` are
operations you apply like procedures or serve over HTTP.

## Develop

```sh
raco pkg install --link --auto ../fhir/fhir ../fhir/fhir-spec ../fhirpath .   # repos side by side
raco test .
```

Reference: [oloveluck.github.io/sql-on-fhir](https://oloveluck.github.io/sql-on-fhir/). The format for
agents, with a checked cheat sheet and the common problems: [guide.md](guide.md); the workflow
without MCP: [.claude/skills/sql-on-fhir](.claude/skills/sql-on-fhir/SKILL.md). License: MIT;
the vendored IG package is CC0-1.0 and the test suite MIT.
