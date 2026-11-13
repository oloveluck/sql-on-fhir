# sql-on-fhir — SQL on FHIR

A FHIR record is a nested document: a patient holds a list of names, each with its own parts. A
table has rows and columns. [SQL on FHIR](https://build.fhir.org/ig/FHIR/sql-on-fhir-v2/) is the
standard for getting from one to the other: you write a *ViewDefinition*, a short JSON file that
names the columns you want and where each one's value is found. This package runs it over your data
and prints the table, ready for SQL or a spreadsheet.

```
$ sql-on-fhir run patients.view.json data/ --format csv
id,family,gender,birth_date
ann,Lee,female,1974-12-25
bob,Ortiz,male,1990-03-01
```

The view behind it is a list of columns, each a name and a path into the record:

```json
{"resourceType": "ViewDefinition", "name": "patients", "status": "active", "resource": "Patient",
 "select": [{"column": [{"name": "id", "path": "getResourceKey()"},
                        {"name": "family", "path": "name.family.first()"},
                        {"name": "gender", "path": "gender"},
                        {"name": "birth_date", "path": "birthDate"}]}]}
```

## Install

Build the [fhir family's tools](https://github.com/oloveluck/fhir#install) once; `sql-on-fhir` is
one of them. With Racket, `raco sql-on-fhir` is the same command.

## Documentation

**[oloveluck.github.io/sql-on-fhir](https://oloveluck.github.io/sql-on-fhir/)**: a first example
step by step, a row per record or per repeated item, filters, output formats, and the reference.

- How well it works (all 144 tests of the shared SQL on FHIR suite): [TESTING.md](TESTING.md).
- For AI agents: [guide.md](guide.md), a cheat sheet and the common problems, each one tested; and
  the [sql-on-fhir skill](.claude/skills/sql-on-fhir/SKILL.md).
- How it is built: [CLAUDE.md](CLAUDE.md).

Part of the [fhir](https://github.com/oloveluck/fhir) family. License: MIT.
