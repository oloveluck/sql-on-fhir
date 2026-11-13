#lang scribble/manual
@; Text in @tt is shown exactly as written: no curly quotes, and "--" stays two hyphens.
@(require (only-in scribble/core [element literal-element]))
@(define (tt . text) (literal-element (quote tt) text))
@(require (for-label racket/base racket/contract sql-on-fhir/view sql-on-fhir/definition sql-on-fhir/operations sql-on-fhir/workspace))

@; a path shown inline, with its single quotes kept straight (plain @tt would curl them)
@(define (path . strs) (tt (literal (apply string-append strs))))

@title{sql-on-fhir: SQL on FHIR}

A FHIR record is a nested document. A patient holds a list of names, and each name a list of given
names; a blood pressure reading holds two measurements inside it. That shape suits passing records
between systems. It does not suit counting them: a spreadsheet, a database or a statistics package
wants a @italic{table}, where every row has the same columns and every cell holds one value.

@hyperlink["https://build.fhir.org/ig/FHIR/sql-on-fhir-v2/"]{SQL on FHIR} is the standard for
getting from one to the other. You write a @italic{ViewDefinition}: a short JSON file that says
which kind of record you want, which columns the table has, and where in the record each column's
value is found. The same file works in any tool that follows the standard.

This package runs a ViewDefinition over your FHIR data and prints the table, as CSV for a
spreadsheet or as JSON for a program. A mistake in the view is reported before anything runs.

Part of the @hyperlink["https://oloveluck.github.io/fhir/"]{fhir} family of FHIR languages and tools.

@table-of-contents[]

@section{What you can do with it}

@itemlist[
@item{@bold{Turn a folder of FHIR records into a table}: @secref["first"].}
@item{@bold{Get one row per record, or one row per repeated item} inside it, such as each phone
number or each measurement: @secref["rows"].}
@item{@bold{Keep only the records you want}: @secref["where"].}
@item{@bold{Make tables that join}, a table of readings and a table of patients sharing a patient
id: @secref["keys"].}
@item{@bold{Choose the output} for what reads it next, a spreadsheet, a database loader or another
FHIR system: @secref["formats"].}
@item{@bold{Use a view from a program}, as rows in Racket or as a FHIR operation over HTTP:
@secref["racket"] and @secref["operation"].}]

@section[#:tag "first"]{A first example}

@bold{1. Install} the tools as the @hyperlink["https://oloveluck.github.io/fhir/"]{family's front
page} describes. The command is then @tt{raco sql-on-fhir} (or @tt{sql-on-fhir}, if you built the
standalone tools).

@bold{2. Have some records.} The data is a folder of FHIR resources as JSON files, one record to a
file. Here it is two patients in @tt{data/}. Ann has two given names and two phone numbers; Bob has
one given name and no phone.

@verbatim|{{"resourceType": "Patient", "id": "ann", "gender": "female", "birthDate": "1974-12-25",
 "name": [{"family": "Lee", "given": ["Ann", "Marie"]}],
 "telecom": [{"system": "phone", "value": "555-0100", "use": "home"},
             {"system": "phone", "value": "555-0101", "use": "work"}]}

{"resourceType": "Patient", "id": "bob", "gender": "male", "birthDate": "1990-03-01",
 "name": [{"family": "Ortiz", "given": ["Bob"]}]}}|

@bold{3. Write a view}, @tt{patients.view.json}:

@verbatim|{{
  "resourceType": "ViewDefinition",
  "name": "patients",
  "status": "active",
  "resource": "Patient",
  "select": [
    {"column": [
      {"name": "id", "path": "getResourceKey()"},
      {"name": "family", "path": "name.family.first()"},
      {"name": "gender", "path": "gender"},
      {"name": "birth_date", "path": "birthDate"}]}
  ]
}}|

Reading it from the top:

@itemlist[
@item{@tt{resourceType} says this file is a ViewDefinition. @tt{name} is the table's name.
@tt{status} is required by the standard; write @tt{"active"}.}
@item{@tt{resource} is the kind of record the table is made from. Every Patient in the data becomes
a row; records of other kinds are passed over.}
@item{@tt{select} holds the columns. Each column has a @tt{name}, the heading it gets in the table,
and a @tt{path}, which says where its value is in the record.}
@item{A path is written in @italic{FHIRPath}, the small language FHIR uses to point into a record.
@tt{gender} is the record's @tt{gender}. @tt{name.family.first()} goes into the names, takes each
one's family name, and keeps the first. @tt{getResourceKey()} is the record's id.}]

@bold{4. Run it} over the folder:

@verbatim{
$ raco sql-on-fhir run patients.view.json data/ --format csv
id,family,gender,birth_date
ann,Lee,female,1974-12-25
bob,Ortiz,male,1990-03-01
}

One heading line, then one row for each patient, with the columns in the order the view lists them.
@litchar{--format csv} asks for comma-separated text, which a spreadsheet opens directly. The other
formats are in @secref["formats"].

@bold{5. Make a mistake.} Add a column for the given name, with the path @tt{name.given}. Ann has
two given names, and a cell holds one value, so the view is refused:

@verbatim{
$ raco sql-on-fhir run given.view.json data/ --format csv
sql-on-fhir: column given: path yields 2 items without collection=true
}

This is the central difficulty of flattening, and there are three ways out. Take one value
(@tt{name.given.first()}). Ask for a row per value (@secref["rows"]). Or say the cell may hold a
list, by adding @tt{"collection": true} to the column:

@verbatim|{
$ raco sql-on-fhir run given2.view.json data/
{"given":["Ann","Marie"],"id":"ann"}
{"given":["Bob"],"id":"bob"}
}|

@section{Writing a view}

A view picks a kind of record, optionally filters it, and lists columns. This section takes those
one idea at a time. The format itself is defined by the
@hyperlink["https://build.fhir.org/ig/FHIR/sql-on-fhir-v2/"]{SQL on FHIR specification}; the paths
are @hyperlink["http://hl7.org/fhirpath/N1/"]{FHIRPath}.

@subsection[#:tag "columns"]{A column is a path}

A column's @tt{path} starts at the record and walks inward, one element name after another, with
dots between: @tt{birthDate}, @tt{name.family}, @tt{code.coding.code}. Where an element repeats, the
path gives every value, so you often finish with something that picks one:

@itemlist[
@item{@tt{name.family.first()}: the first of them.}
@item{@path{name.where(use = 'official').family}: only from the names that match a condition.}
@item{@path{telecom.where(system = 'phone').value.first()}: both together.}]

A path that finds nothing gives an empty cell (@tt{null} in JSON), not an error. A path that names
an element the record type does not have is refused, at its line and column in the file and with
the name you probably meant:

@verbatim|{
sql-on-fhir: patients.view.json:10:34: no element Patient.gendr (did you mean `gender`?) (the data is read as FHIR R6; --fhir-version 4.0.1 reads it as R4)
}|

The end of the message says which version of FHIR the records are read as (@secref["versions"]).

Some FHIR elements can hold one of several types, and are written with the type in their name: an
Observation's value is @tt{valueQuantity} or @tt{valueString}, its time @tt{effectiveDateTime} or
@tt{effectivePeriod}. In a path you write the plain name and then say which type you mean:
@tt{value.ofType(Quantity).value} is the number of a quantity, @tt{effective.ofType(dateTime)} a
single moment.

A column may also carry a @tt{description}, a @tt{type} and @tt{tag}s. They are kept in the view
for other tools and do not change the rows here.

@subsection[#:tag "rows"]{One row per record, or one per repeated item}

By default a view gives one row for each record. To get a row for each @italic{item} of a repeating
element instead (each phone number, each measurement in a panel), put those columns in a part of
the @tt{select} that says @tt{forEach}. This is @tt{phones.view.json}:

@verbatim|{{
  "resourceType": "ViewDefinition",
  "name": "phones",
  "status": "active",
  "resource": "Patient",
  "select": [
    {"column": [{"name": "id", "path": "getResourceKey()"}]},
    {"forEach": "telecom.where(system = 'phone')", "column": [
      {"name": "use", "path": "use"},
      {"name": "number", "path": "value"}]}
  ]
}}|

@verbatim{
$ raco sql-on-fhir run phones.view.json data/ --format csv
id,use,number
ann,home,555-0100
ann,work,555-0101
}

The @tt{select} now has two parts. The first has the columns that are about the whole record. The
second has a @tt{forEach} path, and its columns' paths start at each item that path finds, not at
the record: @tt{use} here is the phone's @tt{use}. The parts are combined, so each phone's row
also carries the patient's @tt{id}.

Bob is missing: he has no phone, so there is no item to make a row from. When you want every record
to appear at least once, write @tt{forEachOrNull} in place of @tt{forEach}. A record with no items
then gets one row with those cells empty:

@verbatim{
$ raco sql-on-fhir run phones-all.view.json data/ --format csv
id,use,number
ann,home,555-0100
ann,work,555-0101
bob,,
}

A part of a @tt{select} may contain a @tt{select} of its own, for a list inside a list (each given
name of each name). Inside a @tt{forEach}, @tt{%rowIndex} is the item's position, counted from 0.

@subsection[#:tag "where"]{Keeping only some records}

A @tt{where} is a filter: a path that is true or false for a record. Only the records for which it
is true make rows. This view lists the women:

@verbatim|{{
  "resourceType": "ViewDefinition",
  "name": "women",
  "status": "active",
  "resource": "Patient",
  "where": [{"path": "gender = 'female'"}],
  "select": [
    {"column": [
      {"name": "id", "path": "getResourceKey()"},
      {"name": "birth_date", "path": "birthDate"}]}
  ]
}}|

@verbatim{
$ raco sql-on-fhir run women.view.json data/ --format csv
id,birth_date
ann,1974-12-25
}

Text is written in single quotes. When @tt{where} lists several paths, a record must pass all of
them. A path that finds nothing counts as false. A path that gives something other than true or
false is a mistake in the view and is refused:

@verbatim{
sql-on-fhir: where path must resolve to a boolean, got (Ann Marie)
}

The usual filter on clinical records is by code: "only the blood pressure readings" is
@path{code.coding.exists(system = 'http://loinc.org' and code = '85354-9')}, as in the next example.

@subsection[#:tag "keys"]{Keys: tables that join}

Records point at one another: a reading names the patient it belongs to. Two functions, which exist
only in view paths, turn those links into values two tables share. @tt{getResourceKey()} is a
record's own id. @tt{getReferenceKey(Patient)} is the id of the patient a link names. So a table of
readings and a table of patients can be joined on them.

Here are two blood pressure readings for Ann. Each is one Observation with two @tt{component}s, the
systolic and the diastolic pressure, each with its own code:

@verbatim|{{"resourceType": "Observation", "id": "bp-1", "status": "final",
 "code": {"coding": [{"system": "http://loinc.org", "code": "85354-9"}]},
 "subject": {"reference": "Patient/ann"}, "effectiveDateTime": "2024-03-01T09:00:00Z",
 "component": [
   {"code": {"coding": [{"system": "http://loinc.org", "code": "8480-6"}]},
    "valueQuantity": {"value": 152, "unit": "mmHg", "system": "http://unitsofmeasure.org", "code": "mm[Hg]"}},
   {"code": {"coding": [{"system": "http://loinc.org", "code": "8462-4"}]},
    "valueQuantity": {"value": 95, "unit": "mmHg", "system": "http://unitsofmeasure.org", "code": "mm[Hg]"}}]}}|

The second, @tt{bp-2}, is a month later with 138 over 88. This view, @tt{bp.view.json}, makes a row
for each measurement:

@verbatim|{{
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
}}|

@verbatim{
$ raco sql-on-fhir run bp.view.json data/ --format csv
id,patient,date,code,value
bp-1,ann,2024-03-01T09:00:00Z,8480-6,152
bp-1,ann,2024-03-01T09:00:00Z,8462-4,95
bp-2,ann,2024-04-02T09:30:00Z,8480-6,138
bp-2,ann,2024-04-02T09:30:00Z,8462-4,88
}

The @tt{patient} column holds @tt{ann}, the same value as the @tt{id} column of the patients table
in @secref["first"]. @tt{getReferenceKey} reads links written the usual short way
(@tt{Patient/ann}); a link written as a full web address gives an empty cell.

@subsection{Naming a value once}

When the same code or text appears in several paths, give it a name under @tt{constant} and use it
as @tt{%name}. This view puts the two pressures side by side, one row per reading:

@verbatim|{{
  "resourceType": "ViewDefinition",
  "name": "bp_wide",
  "status": "active",
  "resource": "Observation",
  "constant": [{"name": "systolic", "valueCode": "8480-6"}, {"name": "diastolic", "valueCode": "8462-4"}],
  "where": [{"path": "code.coding.exists(system = 'http://loinc.org' and code = '85354-9')"}],
  "select": [
    {"column": [
      {"name": "patient", "path": "subject.getReferenceKey(Patient)"},
      {"name": "date", "path": "effective.ofType(dateTime)"},
      {"name": "systolic", "path": "component.where(code.coding.code = %systolic).value.ofType(Quantity).value"},
      {"name": "diastolic", "path": "component.where(code.coding.code = %diastolic).value.ofType(Quantity).value"}]}
  ]
}}|

@verbatim{
$ raco sql-on-fhir run bp-wide.view.json data/ --format csv
patient,date,systolic,diastolic
ann,2024-03-01T09:00:00Z,152,95
ann,2024-04-02T09:30:00Z,138,88
}

A constant's value is written with its type, as FHIR does: @tt{valueCode}, @tt{valueString},
@tt{valueInteger}, @tt{valueBoolean} and so on.

@subsection{Stacking rows, and lists inside lists}

Two more words cover the shapes that are left.

@tt{unionAll} stacks the rows of several alternatives that have the same columns. This view lists
each patient's phones and then their names, in one table:

@verbatim|{"select": [
  {"column": [{"name": "id", "path": "getResourceKey()"}],
   "unionAll": [
     {"forEach": "telecom", "column": [{"name": "kind", "path": "system"}, {"name": "text", "path": "value"}]},
     {"forEach": "name", "column": [{"name": "kind", "path": "'name'"}, {"name": "text", "path": "family"}]}]}
]}|

@verbatim{
id,kind,text
ann,phone,555-0100
ann,phone,555-0101
ann,name,Lee
bob,name,Ortiz
}

@tt{repeat} follows a path again and again, for records that nest to any depth. A filled-in
questionnaire holds items that hold items; @tt{{"repeat": ["item"], "column": […]}} gives a row for
every item at every level:

@verbatim{
id,link_id,text
qr1,1,About you
qr1,1.1,Smoker
qr1,1.2,Allergies
qr1,1.2.1,Penicillin
}

@subsection[#:tag "refused"]{When a view is refused}

A view is checked against the standard's own description of a ViewDefinition before it runs. Each
problem is one line, and the command exits with status 1.

@itemlist[
@item{@bold{A misspelt word of the format} (@tt{selct} for @tt{select}):
@verbatim{sql-on-fhir: not a valid ViewDefinition: ViewDefinition: unknown field selct (see https://build.fhir.org/ig/FHIR/sql-on-fhir-v2/viewdefinition.html#ViewDefinition)}}
@item{@bold{A value outside the allowed list} (@tt{status}, @tt{resource} and @tt{fhirVersion} each
have one; a status is @tt{active}, @tt{draft}, @tt{retired} or @tt{unknown}):
@verbatim{sql-on-fhir: not a valid ViewDefinition: "live" is not in the required value set for ViewDefinition.status (http://hl7.org/fhir/ValueSet/publication-status)}}
@item{@bold{A required part left out}: @tt{resource}, @tt{select}, a column's @tt{name} or
@tt{path}, the @tt{path} of a @tt{where}. The message says where it is missing and what it is:
@verbatim|{sql-on-fhir: not a valid ViewDefinition: the view has no `resource` (the type of resource the view reads, such as "Patient")
sql-on-fhir: not a valid ViewDefinition: select[0].column[2] has no `name` (the column's name in the table)}|
@tt{status} is the exception: a view without it runs, and a warning says it is missing
(@secref["limits"]):
@verbatim|{sql-on-fhir: warning: patients.view.json:1:1: no `status` (the standard requires it: "draft", "active", "retired" or "unknown")}|}
@item{@bold{A name a database would not take.} The view's own @tt{name}, a constant's and a
column's are letters, digits and @tt{_}, starting with a letter: the standard's rule, so that a view
makes a table anywhere. Two columns of one table cannot share a name either:
@verbatim|{sql-on-fhir: not a valid ViewDefinition: select[0].column[1].name "birth-date" is not a name a database takes: letters, digits and _ only, starting with a letter
sql-on-fhir: not a valid ViewDefinition: the column name `id` is used twice: the columns of a table are named apart}|}
@item{@bold{Two ways of making rows in one select.} A select takes one of @tt{forEach},
@tt{forEachOrNull} and @tt{repeat}; for a second, put a select inside the first:
@verbatim|{sql-on-fhir: not a valid ViewDefinition: select[0] has more than one of `forEach`, `forEachOrNull` and `repeat`: a select takes one}|}
@item{@bold{A path that is not FHIRPath} (here @tt{name.family.}, with a dot too many), whether or
not there are records to read:
@verbatim|{sql-on-fhir: not a valid ViewDefinition: the path "name.family." is not FHIRPath: the expression ends after `.`}|}
@item{@bold{A path to an element the record type does not have}, a misspelling or an element of
another FHIR version: refused when a column reads it from a record, as in @secref["columns"]. Where
nothing fails, the table is printed and the problem is a warning beside it (on the error stream, so
it does not end up in a file the table is written to). That happens when there are no records of
the view's kind, and when the path is a @tt{forEach}, which passes over what it does not find:
@verbatim|{sql-on-fhir: warning: meds.view.json:9:32: no element MedicationRequest.medicationCodeableConcept (the data is read as FHIR R6; --fhir-version 4.0.1 reads it as R4)}|}
@item{@bold{An empty cell where the record has a value.} Records are read tolerantly: an element
the FHIR version does not have, and a value that is not valid FHIR, are left out, and the cell that
reads them is empty. When that happens to something the view reads, a warning counts the records
and names the first. Here one of two blood pressure readings gives its date and time without a time
zone, which FHIR does not allow:
@verbatim|{sql-on-fhir: warning: 1 of 2 Observation resources holds a value at `effectiveDateTime` that is not valid FHIR and was not read (the first: Observation/bp-1: "2021-05-31T00:00:00" — a time needs a time zone, such as Z or +01:00)
id,date
bp-1,
bp-2,2021-06-14T09:30:00Z}|
Nothing is said about what the view does not read: a view of the same records that asks only for
their codes gets no warning.}
@item{@bold{A path that gives several values} for one cell: @tt{column given: path yields 2 items
without collection=true}. Narrow the path, use @tt{forEach}, or mark the column as a collection
(@secref["first"], step 5).}
@item{@bold{A record is missing from the rows}, with no message: a @tt{forEach} over an element the
record does not have drops it (@tt{forEachOrNull} keeps it), or a @tt{where} is false for it. To
see which, run a view with only that path as a column.}
@item{@bold{A file that is not JSON}: @tt{sql-on-fhir: view.json is not JSON: …}, with the place
reading stopped.}]

@section{Running it}

@subsection{Command line}

The command you will use is @tt{run}. The others are for people working on the package itself.

@tabular[#:style 'boxed #:sep @hspace[2]
(list (list @tt{raco sql-on-fhir run view.json data/ [--format ndjson|json|csv|fhir] [--fhir-version 4.0.1|5.0.0|6.0.0]} @elem{a view (JSON, or a @hash-lang[] @tt{sql-on-fhir} module of any extension) over a directory, Bundle or resource})
      (list @tt{raco sql-on-fhir tck [-v]} @elem{the shared test suite, with its report; @tt{-v} prints each failure})
      (list @tt{raco sql-on-fhir regen} @elem{regenerate the ViewDefinition model from the specification's package in @tt{spec/}})
      (list @tt{raco sql-on-fhir check} "verify the generated model is current")
      (list @tt{raco sql-on-fhir fetch [--version v] [--tests-commit sha]} "download the specification's package and the test suite again (needs the network)"))]

The data given to @tt{run} is one of three things: a folder of JSON files, one record to a file; a
single file holding a @italic{Bundle}, which is FHIR's envelope for many records in one file; or a
single file holding one record. Only the records of the view's @tt{resource} kind are read; the
rest are ignored. With no data at all, you get the heading and no rows.

Exit status: 0 when the table was printed; 1 when the view was refused, a file was not JSON, a
@hash-lang[] @tt{sql-on-fhir} file did not compile, or the view failed on the data (each the reason
alone, with no trace of the program behind it), and when the test suite regresses; 2 when the
command was called wrongly, such as with a file that does not exist or a FHIR version it does not
read.

@subsection[#:tag "versions"]{Which FHIR version the data is read as}

FHIR comes in versions: R4 (4.0.1), R5 (5.0.0) and R6. Most elements are the same in all of them,
and records that use only those read the same whichever version is named; every other example in
this manual is like that. @tt{run} reads records as R6 unless @litchar{--fhir-version} says
@tt{4.0.1} or @tt{5.0.0}.

It matters when a view reads an element one version has and another does not. An R4
MedicationRequest names its drug in @tt{medicationCodeableConcept}; R5 replaced that with an
element called @tt{medication}, of another type. Here is one such R4 record, @tt{r4/m1.json}, and a
view over it, @tt{meds.view.json}:

@verbatim|{{"resourceType": "MedicationRequest", "id": "m1", "status": "active", "intent": "order",
 "medicationCodeableConcept": {"text": "metformin 500 mg"},
 "subject": {"reference": "Patient/ann"}}

{
  "resourceType": "ViewDefinition",
  "name": "meds",
  "status": "active",
  "resource": "MedicationRequest",
  "select": [
    {"column": [
      {"name": "patient", "path": "subject.getReferenceKey(Patient)"},
      {"name": "drug", "path": "medicationCodeableConcept.text"}]}
  ]
}}|

Read as R4, the drug is there. Read as R6, the element does not exist, and the message says so and
names the option:

@verbatim|{
$ raco sql-on-fhir run meds.view.json r4/ --format csv --fhir-version 4.0.1
patient,drug
ann,metformin 500 mg

$ raco sql-on-fhir run meds.view.json r4/ --format csv
sql-on-fhir: meds.view.json:9:32: no element MedicationRequest.medicationCodeableConcept (the data is read as FHIR R6; --fhir-version 4.0.1 reads it as R4)
}|

A path can also be right in both versions and mean different things in them. Written as
@tt{medication.ofType(CodeableConcept).text}, the @tt{drug} column is a valid path in R6 too, where
it finds nothing in an R4 record. The table is printed with the cell empty, and a warning says what
was in the records and not read:

@verbatim|{
$ raco sql-on-fhir run meds-both.view.json r4/ --format csv
sql-on-fhir: warning: 1 of 1 MedicationRequest resources holds `medicationCodeableConcept`, which was not read: FHIR R6 has no such element (the first: MedicationRequest/m1); --fhir-version 4.0.1 reads the data as R4
patient,drug
ann,
}|

So for R4 data, name the version.

A view can say which versions it is written for, in @tt{fhirVersion}. The option still decides how
the records are read; when the two disagree, a warning says so and names the option. With
@tt{"fhirVersion": ["4.0"]} on the sixth line of a view:

@verbatim|{
$ raco sql-on-fhir run r4.view.json data/ --format csv
sql-on-fhir: warning: r4.view.json:6:3: the view is for FHIR 4.0 (`fhirVersion`) and the data is read as FHIR R6; --fhir-version 4.0.1 reads it as R4
id,gender
ann,female
}|

@subsection[#:tag "formats"]{Output formats, and what each is for}

@litchar{--format} chooses how the same rows are written.

@tabular[#:style 'boxed #:sep @hspace[2]
(list (list @bold{format} @bold{what you get} @bold{use it for})
      (list @tt{csv} "a heading line, then one comma-separated line per row" "a spreadsheet, or a database's import command")
      (list @tt{ndjson} "one JSON object per line (the default)" "data tools that read a file line by line, and large outputs")
      (list @tt{json} "one JSON array holding every row" "a program that reads the whole answer at once")
      (list @tt{fhir} @elem{a FHIR @tt{Parameters} resource, one @tt{row} per row} "handing the rows to another FHIR system"))]

The same two patients as NDJSON:

@verbatim|{
$ raco sql-on-fhir run patients.view.json data/
{"birth_date":"1974-12-25","family":"Lee","gender":"female","id":"ann"}
{"birth_date":"1990-03-01","family":"Ortiz","gender":"male","id":"bob"}
}|

Three details matter when another program reads the output:

@itemlist[
@item{@bold{Column order.} CSV and @tt{fhir} keep the view's column order. In the two JSON formats
each row's keys are in alphabetical order; read them by name.}
@item{@bold{Empty cells.} An empty cell is nothing between the commas in CSV, @tt{null} in JSON,
and left out of the row in @tt{fhir}.}
@item{@bold{Types.} JSON keeps numbers as numbers, true and false as themselves, and a
@tt{collection} column as a list. CSV is text: a list is written as its JSON
(@tt{"[""Ann"",""Marie""]"}), a cell containing a comma or a quote is quoted, and lines end with a
carriage return and a line feed, as the CSV standard (RFC 4180) says.}]

Parquet, a format the specification also names, is not written.

@subsection[#:tag "lang"]{A view written as Racket forms}

The same view can be written in a file that starts with @tt{#lang sql-on-fhir}, as nested forms in
place of JSON. What you gain is earlier checking: the file is a Racket module, and a misspelt
element, a status outside its list or a path that is not FHIRPath stops it from compiling. This is
@tt{readings.sof}:

@verbatim|{#lang sql-on-fhir
(ViewDefinition
 (name "bp_readings") (status "active") (resource "Observation")
 (where (ViewDefinitionWhere (path "code.coding.exists(system = 'http://loinc.org' and code = '85354-9')")))
 (select (ViewDefinitionSelect
          (column (ViewDefinitionSelectColumn (name "patient") (path "subject.getReferenceKey(Patient)"))
                  (ViewDefinitionSelectColumn (name "date") (path "effective.ofType(dateTime)"))
                  (ViewDefinitionSelectColumn (name "systolic")
                    (path "component.where(code.coding.code = '8480-6').value.ofType(Quantity).value"))))))}|

It runs the same way, whatever the file is called:

@verbatim{
$ raco sql-on-fhir run readings.sof data/ --format csv
patient,date,systolic
ann,2024-03-01T09:00:00Z,152
ann,2024-04-02T09:30:00Z,138
}

@tt{racket readings.sof} prints the view as JSON, the form to give to another tool.

The forms are the specification's elements, in the form syntax of the family's @tt{fhir/r6}
language: @tt{ViewDefinition}; @tt{ViewDefinitionWhere}; @tt{ViewDefinitionSelect} (with
@tt{column}, a nested @tt{select}, @tt{forEach}, @tt{forEachOrNull}, @tt{repeat}, @tt{unionAll});
@tt{ViewDefinitionSelectColumn} (@tt{path}, @tt{name}, @tt{description}, @tt{collection},
@tt{type}, @tt{tag}); and @tt{ViewDefinitionConstant}. A mistake stops the file from compiling.
@tt{run} prints the message, which says where the mistake is (file, line and column) and names the
form, and exits with status 1:

@verbatim|{
$ raco sql-on-fhir run readings.sof data/
sql-on-fhir: readings.sof:3:41: ViewDefinition: unknown field ViewDefinition.resorce
  at: resorce
  in: (resorce "Observation")

$ raco sql-on-fhir run readings.sof data/
sql-on-fhir: readings.sof:3:30: ViewDefinition: "live" is not in the required value set for ViewDefinition.status (http://hl7.org/fhir/ValueSet/publication-status); valid codes: (active draft retired unknown)
  in: "live"

$ raco sql-on-fhir run readings.sof data/
sql-on-fhir: readings.sof:7:66: ViewDefinition: the path "effective.ofType(dateTime" is not FHIRPath: the expression ends after `dateTime`
  at: "effective.ofType(dateTime"
  in: (path "effective.ofType(dateTime")
}|

The last is a path with its closing bracket missing: every path in the file is read as FHIRPath
when the file compiles. Unlike a JSON view, this form also refuses a view that leaves out
@tt{status}.

The repository's @tt{examples/patient-demographics.rkt} is a view written this way.

@subsection[#:tag "racket"]{From a Racket program}

@racket[view-rows] takes a view as JSON and gives its rows, each a hash from column name to value.
Give it the records, or let it read them from the current @italic{data source}, the family's way
of naming where data is (a folder, records in memory, a server's store):

@racketblock[
(require json fhir/data-source (only-in sql-on-fhir/operations view-rows))
(define (read-file f) (call-with-input-file f read-json))
(define view (read-file "patients.view.json"))

(view-rows view (map read-file '("data/ann.json" "data/bob.json")))
(code:comment "=> (list (hasheq 'id \"ann\" 'family \"Lee\" 'gender \"female\" 'birth_date \"1974-12-25\")")
(code:comment "         (hasheq 'id \"bob\" 'family \"Ortiz\" 'gender \"male\" 'birth_date \"1990-03-01\"))")

(parameterize ([current-data-source (directory->data-source "data/")])
  (view-rows view))                  (code:comment "the same rows, from the folder")
]

A module written in @hash-lang[] @tt{sql-on-fhir} provides its views: @racket[resources] (the typed
ViewDefinitions), @racket[(->nodes)] (the same) and @racket[(->json)] (as JSON, what
@racket[view-rows] takes).

@racketblock[
(require (only-in "readings.sof" [->json views])
         fhir/data-source (only-in sql-on-fhir/operations view-rows))
(parameterize ([current-data-source (resources->data-source observations)])
  (view-rows (car (views))))
(code:comment "=> (list (hasheq 'patient \"ann\" 'date \"2024-03-01T09:00:00Z\" 'systolic 152) …)")
]

@subsection[#:tag "operation"]{As a FHIR operation}

The specification defines two @italic{operations}, named requests a FHIR system can answer:
@tt{$sql-run} runs one view and answers its rows, and @tt{$sql-export} runs several. Both are here
as procedures, built on the specification's own definitions, so a server can offer them and a
program can call them.

@racketblock[
(require fhir/operation fhir/data-source sql-on-fhir/operations)
(parameterize ([current-data-source (directory->data-source "data/")])
  ($sql-run view #:_format "csv")                       (code:comment "the view is the subject")
  (apply-operation "$sql-run" #:subjectCanonical "http://example.org/ViewDefinition/x" #:_format "fhir")
  ($sql-export #:subject (list view) #:_format "csv"))
]

@tt{$sql-run} answers CSV, NDJSON or JSON as a FHIR @tt{Binary} resource (the text, base64-encoded)
and @tt{fhir} as a @tt{Parameters} of rows. The view is given directly, or named by its url
(@tt{#:subjectCanonical}) or its reference (@tt{#:subjectReference}) and found in the data source.
The data is the data source's, or records given with @tt{#:resource}. @tt{#:patient} keeps one
patient's records and @tt{#:group} those of a Group's members (a patient or a group the data source
does not hold is refused), @tt{#:_since} those updated after a time, @tt{#:_limit} the first rows,
and @tt{#:header "false"} leaves the heading out of CSV.

A view that is refused, or that fails on the data, raises @tt{exn:fail:operation} carrying an
@tt{OperationOutcome}, FHIR's resource for reporting a problem. Its code is @tt{invalid} for a view
that is refused, @tt{processing} for a path with several values for one cell, and
@tt{not-supported} for what the specification defines and this package does not do
(@secref["limits"]).

@tt{$sql-export} answers at once with a @tt{Parameters} resource: an @tt{exportId}, the status
@tt{completed}, and one @tt{output} per view with its result inside as a @tt{Binary}. An output is
named by its subject's @tt{name}, else by the view's; two outputs of one name are refused.

To offer both over HTTP, fhir-server serves any operation value:

@racketblock[
(require fhir/data-source sql-on-fhir/operations (only-in fhir/capability/operations serve-operations))
(parameterize ([current-data-source (directory->data-source "data/")])
  (serve-operations (list $sql-run $sql-export) #:port 8080))
]

A @tt{POST} of a @tt{Parameters} resource to @tt{/$sql-run}, holding the view as
@tt{subjectResource} and @tt{_format} @tt{csv}, is then answered with the CSV.

@section{For an AI agent, and in an editor}

@itemlist[
@item{@bold{For an agent.} In an
@hyperlink["https://oloveluck.github.io/fhir/fhir-mcp/index.html"]{fhir-mcp} workspace a
@tt{*.view.json} file is a ViewDefinition, checked as it is written: a path naming an element the
record type lacks is reported at its place in the file, with the nearest name. @tt{run} gives the
view's rows over the workspace's data. @tt{explain} of one record shows the rows that record alone
produces, the rows it would produce without the @tt{where}, and whether each @tt{where} holds for
it. Every view is also a table that the workspace's SQL queries can read, which is where the SQL in
the name comes in. The repository's @tt{guide.md} is the format written for an agent to read
(fhir-mcp serves it as @tt{learn://sql-on-fhir}), and @tt{.claude/skills/sql-on-fhir} is the same
workflow for an agent using the command line.}
@item{@bold{In an editor.} The family's language server does not cover views. A JSON view is
checked when it runs; a @hash-lang[] @tt{sql-on-fhir} file is checked when it compiles.}]

@section[#:tag "limits"]{Limits}

@itemlist[
@item{@bold{No database.} The command makes the table; it does not run SQL. Views are evaluated in
memory, one list of rows per view. To query the result, load the CSV or NDJSON into the database or
spreadsheet you use, or work in a fhir-mcp workspace, where views are tables.}
@item{@bold{The command line reads data as FHIR R6 unless told otherwise}
(@secref["versions"]), and it does not look at the records to find out. A path to an element the
version does not have gets a message, and so does an element of the records that the version does
not have, when the view reads it (@secref["versions"]). Both are warnings: the table is still
printed, with those cells empty. (A fhir-mcp workspace reads data in the workspace's own FHIR
version.)}
@item{@bold{A value that is not valid FHIR is not read}, and its cell is empty: a date and time
written without a time zone (@tt{2021-05-31T00:00:00}) is one. A warning says so when the view
reads that element (@secref["refused"]); the value itself is not repaired.}
@item{@bold{The warnings about data are the command line's and the workspace's.} A program that
calls @racket[view-rows] or @tt{$sql-run} gets the rows alone, unless it sets
@racket[current-read-log] and reads what was left out from it.}
@item{@bold{@tt{$sql-run}} runs a ViewDefinition only. The specification's SQLQuery and SQLView
Libraries (SQL over views), reading from an external @tt{source}, and Parquet output are answered
@tt{not-supported}. @tt{context} is accepted and unused: it supplies what a Library depends on.}
@item{@bold{@tt{$sql-export}} finishes at once, with the results inside its answer as Binaries.
There is no background job, polling, cancellation or download address.}
@item{@bold{Columns.} A column's @tt{type} is not checked against the values its path gives, and
not used to convert them; the standard says an implementation should report a mismatch, and a
value that is not a simple one without a @tt{type}. A @tt{tag} is kept and not used.}
@item{@bold{@tt{fhirVersion} and @tt{profile} do not choose anything.} A view's @tt{fhirVersion} is
compared with the version the data is read as, and a difference is a warning
(@secref["versions"]); the option, or the workspace, decides. Whether the records conform to a
view's @tt{profile} is not checked.}
@item{@bold{@tt{status} is not insisted on.} The standard requires it, and a JSON view without it
runs all the same, with a warning: 33 of the 133 views the standard's own test suite expects to run
leave it out, so refusing them would fail that suite. Every other required part is asked for
(@secref["refused"]), and the @hash-lang[] @tt{sql-on-fhir} form asks for @tt{status} too.}
@item{@bold{References.} @tt{getReferenceKey()} reads relative references (@tt{Patient/ann}); an
absolute address gives an empty cell.}]

@section[#:tag "words"]{Words used here}

@itemlist[
@item{@bold{FHIR}: the health-care standard for records exchanged between systems.
@bold{Resource}: one record of a given kind (a Patient, an Observation), written as JSON.}
@item{@bold{Bundle}: one FHIR file that holds many resources.}
@item{@bold{R4}, @bold{R5}, @bold{R6}: versions of FHIR (4.0.1, 5.0.0, and 6.0.0 as it stands in ballot).
A few elements differ between them.}
@item{@bold{ViewDefinition}, or @bold{view}: the JSON file that describes a table over one kind of
resource: its filters and its columns.}
@item{@bold{Column}: a name and a path; @bold{row}: one line of the table, for one resource or one
item inside it.}
@item{@bold{FHIRPath}: the language of every path, for pointing at values inside a resource
(@tt{name.family.first()}).}
@item{@bold{@tt{forEach}}, @bold{@tt{forEachOrNull}}: make a row per item of a repeating element;
the second keeps a resource that has none. @bold{@tt{where}}: a filter on resources.
@bold{@tt{unionAll}}: stack alternatives. @bold{@tt{repeat}}: follow a path to any depth.}
@item{@bold{Collection}: a column whose cell may hold a list.}
@item{@bold{Constant}: a named value a view's paths use as @tt{%name}.}
@item{@bold{Key}: a value two tables share so they can be joined: a resource's id
(@tt{getResourceKey()}) and the id a reference names (@tt{getReferenceKey()}).}
@item{@bold{Choice element}: an element that can hold one of several types, written with the type in
its name (@tt{valueQuantity}); in a path, @tt{value.ofType(Quantity)}.}
@item{@bold{Value set}: a fixed list of allowed codes, such as the four a @tt{status} may be.}
@item{@bold{CSV}: comma-separated text, one row per line. @bold{NDJSON}: one JSON object per line.}
@item{@bold{The specification}, or @bold{IG} (implementation guide): the published SQL on FHIR
standard. Its @bold{package} is the machine-readable copy this tool's model is generated from.}
@item{@bold{Operation}: a named request a FHIR system answers, written with a dollar sign
(@tt{$sql-run}). @bold{Parameters}, @bold{Binary}, @bold{OperationOutcome}: the FHIR resources for
an operation's inputs and outputs, for raw content, and for a reported problem.}
@item{@bold{Canonical}: the url that names a definition such as a view, wherever it is stored.}
@item{@bold{Data source}: the family's value for "where the data is": a folder, resources in
memory, or a server's store.}]

@section{How it is tested}

@itemlist[
@item{The test suite the SQL on FHIR project publishes for implementations to share: 144 of 144
tests give the expected rows, and every view the suite calls invalid is refused.
@tt{raco sql-on-fhir tck} runs it.}
@item{The ten ViewDefinitions the specification's package publishes as its examples are each
accepted as published, and no rule this package holds a view to refuses a view the suite runs.}
@item{The ViewDefinition model is generated from the specification's published package (version
3.0.0-ballot), not written by hand, so what a view may contain is what the standard says.
@tt{raco sql-on-fhir check} verifies the generated files are current.}
@item{Every view in the repository's @tt{guide.md} is checked by the tests, and its examples give
the rows the text states. This manual is rendered by a test that fails on a broken reference.}
@item{The command is run by a test as you would run it, which checks what it prints and its exit
status: the refusals and warnings quoted in this manual, and R4 data read as R4.}]

@tt{raco test .} in the repository runs all of it. The repository's @tt{TESTING.md} says where the
suite and the package come from and how to run each check. Both are copied into the repository
unchanged: the specification's package under the CC0-1.0 licence, the test suite under MIT, as this
package is.

@section{Reference}

@subsection[#:style 'unnumbered]{@hash-lang[] @tt{sql-on-fhir}}
@defmodulelang[sql-on-fhir]

Each top-level form builds a typed ViewDefinition; the module provides @racket[resources],
@racket[(->nodes)] and @racket[(->json)].

@subsection[#:style 'unnumbered]{@tt{sql-on-fhir/view}}
@defmodule[sql-on-fhir/view]

@defproc[(eval-view [view fhir?] [resources (listof fhir?)]) (listof list?)]{
The rows of a typed ViewDefinition over typed resources, each row an association list from column
name to value, in column order. Every path goes through the fhirpath engine, parsed once for the
view. What is wrong with the view itself is raised before any resource is read, as an
@racket[exn:fail:view]; what goes wrong on the data (several values for one cell) is an
@racket[exn:fail] raised by @racket['eval-view].}
@defproc[(view-columns [view fhir?]) (listof symbol?)]{The column names, in declaration order.}
@defstruct[(exn:fail:view exn:fail) ([path (or/c string? #f)])]{
A view the engine refuses whatever the data: a path that is not FHIRPath (@racket[path] is its
text), @tt{unionAll} branches whose columns differ, a column name used twice, no @tt{resource}.}

@subsection[#:style 'unnumbered]{@tt{sql-on-fhir/definition}}
@defmodule[sql-on-fhir/definition]

@defproc[(read-view [view hash?]) (or/c fhir? (listof string?))]{
A ViewDefinition given as JSON, as the typed node @racket[eval-view] takes, when it is one by the
specification's definition; else what is wrong with it, one string per problem. Checked: the
elements and their shapes, the required elements (all but @tt{status}), the codes of required value
sets, and the definition's own rules (@secref["refused"]). R6's @tt{resourceDefinition} beside
@tt{resourceType} is accepted.}

@subsection[#:style 'unnumbered]{@tt{sql-on-fhir/operations}}
@defmodule[sql-on-fhir/operations]

@defthing[$sql-run procedure?]{
On the IG's @tt{SQLRun} definition, registered when the module loads. The view is the subject
(@tt{subjectResource}), or named by @tt{#:subjectCanonical} or @tt{#:subjectReference} from the
data source. Data: @tt{#:resource} inputs (Bundles unwrapped) or the data source, filtered by
@tt{#:patient}, @tt{#:group} and @tt{#:_since}; @tt{#:_limit}. @tt{#:_format} is @racket["ndjson"]
(the default), @racket["json"] or @racket["csv"] (with @tt{#:header}) as a Binary, or
@racket["fhir"] as a Parameters of rows. @tt{#:parameters} is refused, as the definition says of a
ViewDefinition.}
@defthing[$sql-export procedure?]{
@tt{#:subject} is a list of views, references or canonicals (in a @tt{Parameters} resource, a
@tt{subject} with a @tt{name} part and one of @tt{subjectResource}, @tt{subjectCanonical},
@tt{subjectReference}); completes synchronously with a manifest Parameters: one @tt{output} per
subject, its result a Binary. @tt{#:_format "fhir"} is refused, as the definition says.}
@defproc[(view-rows [view hash?] [resources (or/c (listof hash?) #f) #f]) (listof hash?)]{
Rows as hashes for a ViewDefinition given as JSON (strictly parsed); @racket[resources] default to
the data source's.}
@deftogether[(
@defparam[current-read-log log (or/c #f read-log?)]
@defproc[(make-read-log) read-log?]
@defproc[(read-log? [v any/c]) boolean?]
@defproc[(read-log-count [log read-log?]) exact-nonnegative-integer?]
@defproc[(read-log-reads [log read-log?]) (listof (cons/c hash? (or/c list? 'unreadable)))])]{
What the tolerant read of the data left out. While @racket[current-read-log] holds a log, every
record a view reads is counted, and each one whose read dropped something is kept with what was
dropped: a list of @racket[(list path value)], the path as in the JSON
(@tt{period.start}, @tt{name[1].family}), or @racket['unreadable] for a record that could not be
read at all. The default is @racket[#f]: nothing is recorded.}
@deftogether[(
@defproc[(rows->ndjson [rows list?]) string?]
@defproc[(rows->json [rows list?]) string?]
@defproc[(rows->csv [columns list?] [rows list?] [#:header? header? boolean? #t]) string?])]{The formats, over @racket[eval-view]'s rows.}

@subsection[#:style 'unnumbered]{@tt{sql-on-fhir/workspace}}
@defmodule[sql-on-fhir/workspace]

@defthing[workspace-support any/c]{The @tt{fhir/lang/workspace} support fhir-mcp loads for views.}
@defproc[(path-problems [file (or/c path-string? #f)] [text string?] [view hash?]) list?]{
The view's column, @tt{forEach} and @tt{where} paths that name an element its record type does not
have, each a diagnostic at the path's place in @racket[text] (the file's own text).}
@defproc[(status-problem [file (or/c path-string? #f)] [text string?] [view hash?]) any/c]{
A warning diagnostic when the view states no @tt{status}, at the view's opening brace; else
@racket[#f].}
@defproc[(version-problem [file (or/c path-string? #f)] [text string?] [view hash?] [version-name string?]) any/c]{
A warning diagnostic when the view names the FHIR versions it is for (@tt{fhirVersion}) and
@racket[version-name], the one the data is read as (@racket["R4"], @racket["R6"]), is none of them,
at @tt{fhirVersion}; else @racket[#f].}
@defproc[(with-unread [view hash?] [version-name string?] [thunk (-> any)]) (values any/c (listof string?))]{
Calls @racket[thunk] with a read log (@racket[current-read-log]) and returns its result with one
sentence for each element the view reads that the read of the data left out: the sentences the
command line prints as warnings. @racket[version-name] is the FHIR version the data is read as,
such as @racket["R4"].}
@defthing[guide string?]{The repository's @tt{guide.md}: the format for agents (fhir-mcp's
@tt{learn://sql-on-fhir}).}
