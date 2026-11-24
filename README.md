# sql-on-fhir — SQL on FHIR

> Part of [fhir](https://github.com/oloveluck/fhir), a toolkit for AI agents on FHIR: an
> agent reads and writes FHIR's languages, and the JSON is what they compile to. A view makes a
> table an agent queries in SQL in one call; a mistake is one line, at its place in the view.

A FHIR record is a nested document: a patient holds a list of names, each with its own parts. A
table has rows and columns. [SQL on FHIR](https://build.fhir.org/ig/FHIR/sql-on-fhir-v2/) is the
standard for getting from one to the other, by way of a *ViewDefinition*: a resource that names
the columns you want and where each one's value is found. This package gives views a source
language, compiles it to ViewDefinitions, and runs them over your data.

```sql
-- patients.sof: one row to a patient
CREATE VIEW patients WITH (status = 'active') AS
SELECT
  getResourceKey() AS id,
  name.family.first() AS family,
  gender,
  birthDate AS birth_date
FROM Patient
```

```
$ sql-on-fhir run patients.sof data/ --format csv
id,family,gender,birth_date
ann,Lee,female,1974-12-25
bob,Ortiz,male,1990-03-01
```

The text is SQL's clauses with [FHIRPath](http://hl7.org/fhirpath/N1/) between them: keywords in
capitals, everything else a path into the record. `sql-on-fhir compile patients.sof` prints the
ViewDefinition it states, the JSON other SQL on FHIR tools read; `decompile` turns any
ViewDefinition back into text, without loss. A ViewDefinition written as JSON runs the same way.
[LANGUAGE.md](LANGUAGE.md) defines the language: its grammar, and what each part compiles to.

## Install

Build the [fhir family's tools](https://github.com/oloveluck/fhir#install) once; `sql-on-fhir` is
one of them. With Racket, `raco sql-on-fhir` is the same command.

## Documentation

**[oloveluck.github.io/sql-on-fhir](https://oloveluck.github.io/sql-on-fhir/)**: a first example
step by step, a row per record or per repeated item, filters, output formats, and the reference.

- For agents: [guide.md](guide.md), a cheat sheet and the common problems, each one tested; and
  the [sql-on-fhir skill](.claude/skills/sql-on-fhir/SKILL.md).
- The source language, specified: [LANGUAGE.md](LANGUAGE.md). Every example in it is compiled by
  the tests, and its grammar is the one the parser is built from.
- What it does, all of it, as one list: `sql-on-fhir features`, printed from
  [features.rkt](features.rkt) — each part of a view, each parameter of the two operations, what is
  refused and what is not done, with the definition in the source that does it.
- How well it works (all 144 tests of the shared SQL on FHIR suite): [TESTING.md](TESTING.md).
- How it is built: [CLAUDE.md](CLAUDE.md).

License: MIT.
