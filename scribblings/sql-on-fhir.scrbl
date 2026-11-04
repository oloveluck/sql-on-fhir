#lang scribble/manual
@(require (for-label racket/base racket/contract sql-on-fhir/view sql-on-fhir/operations))

@title{sql-on-fhir: SQL on FHIR for Racket}

@hyperlink["https://build.fhir.org/ig/FHIR/sql-on-fhir-v2/"]{SQL on FHIR} ViewDefinitions as a
Racket language, a view engine over FHIR data, and the IG's @tt{$sql-run} and @tt{$sql-export}
operations. The ViewDefinition model and the operations' definitions are generated from HL7's
published package (3.0.0-ballot), so a view is checked against the IG's own model when it compiles.
The shared test suite from FHIR/sql-on-fhir.js passes, 144/144.

Part of the @hyperlink["https://github.com/oloveluck/fhir"]{fhir} family; depends on @tt{fhir} and
@tt{fhirpath}.

@table-of-contents[]

@section{Install}

@verbatim{
raco pkg install --link --auto fhir/fhir fhir/fhir-spec fhirpath sql-on-fhir      # from source
}

@section{@hash-lang[] @tt{sql-on-fhir}}
@defmodulelang[sql-on-fhir]

Each top-level form builds a typed ViewDefinition, with the @tt{fhir/r6} form syntax: a misspelled
element, a wrong type, or a @tt{status} outside its required value set is a compile error. The module
provides @racket[resources] (typed nodes), @racket[(->nodes)] and @racket[(->json)]. Running the file
prints the JSON.

@verbatim|{#lang sql-on-fhir
(ViewDefinition
 (name "bp_readings") (status "active") (resource "Observation")
 (where (ViewDefinitionWhere (path "code.coding.where(system = 'http://loinc.org').code = '85354-9'")))
 (select (ViewDefinitionSelect
          (column (ViewDefinitionSelectColumn (name "patient") (path "subject.getReferenceKey(Patient)"))
                  (ViewDefinitionSelectColumn (name "date") (path "effective.ofType(dateTime)"))
                  (ViewDefinitionSelectColumn (name "systolic")
                    (path "component.where(code.coding.code = '8480-6').value.ofType(Quantity).value"))))))}|

The forms: @tt{ViewDefinition}, @tt{ViewDefinitionConstant}, @tt{ViewDefinitionSelect} (column,
select, forEach, forEachOrNull, repeat, unionAll), @tt{ViewDefinitionSelectColumn} (path, name,
description, collection, type, tag), @tt{ViewDefinitionSelectColumnTag}, @tt{ViewDefinitionWhere}.

@section{The view engine}
@defmodule[sql-on-fhir/view]

@defproc[(eval-view [view fhir?] [resources (listof fhir?)]) (listof list?)]{
The rows of a typed ViewDefinition over typed resources, each row an ordered association list from
column name to value. Implements @tt{where}, @tt{column}, @tt{forEach}, @tt{forEachOrNull},
@tt{repeat}, nested @tt{select}, @tt{unionAll}, constants as @tt{%name}, @tt{%rowIndex},
@tt{getResourceKey()} and @tt{getReferenceKey(Type)}; every path goes through the fhirpath engine.}
@defproc[(view-columns [view fhir?]) (listof symbol?)]{The column names, in declaration order.}

@section{Operations}
@defmodule[sql-on-fhir/operations]

@tt{fhir/operation} values on the IG's OperationDefinitions, registered when the module loads; data
comes from @racket[current-data-source] (@tt{fhir/data-source}).

@defthing[$sql-run procedure?]{
The view is the subject (@tt{subjectResource}), or named by @tt{#:subjectCanonical} or
@tt{#:subjectReference} from the data source. Data: @tt{#:resource} inputs (Bundles unwrapped) or the
data source, filtered by @tt{#:patient} and @tt{#:_since}; @tt{#:_limit}. @tt{#:_format} is
@racket["ndjson"] (the default), @racket["json"] or @racket["csv"] (with @tt{#:header}) as a Binary,
or @racket["fhir"] as a Parameters of rows.
@racketblock[
(parameterize ([current-data-source (directory->data-source "patients/")])
  ($sql-run view #:_format "csv")
  (apply-operation "$sql-run" #:subjectCanonical "http://example.org/ViewDefinition/x" #:_format "fhir"))]}
@defthing[$sql-export procedure?]{
@tt{#:subject} is a list of views, references or canonicals; completes synchronously with a manifest
Parameters: one @tt{output} per subject with its result as a Binary.}
@defproc[(view-rows [view hash?] [resources (or/c (listof hash?) #f) #f]) (listof hash?)]{
Rows as hashes, for a ViewDefinition given as JSON; @racket[resources] default to the data source's.}
@deftogether[(
@defproc[(rows->ndjson [rows list?]) string?]
@defproc[(rows->json [rows list?]) string?]
@defproc[(rows->csv [columns list?] [rows list?] [#:header? header? boolean? #t]) string?])]{The formats, over @racket[eval-view]'s rows.}

@section{Command line}

@verbatim{
raco sql-on-fhir run <view.json | view.rkt> [<data dir | bundle.json | resource.json>] [--format ndjson|json|csv|fhir]
raco sql-on-fhir tck [-v]                                     the shared suite (floor 144)
raco sql-on-fhir regen | check                                regenerate the model from spec/; verify it is current
raco sql-on-fhir fetch [--version 3.0.0-ballot] [--tests-commit <sha>]
}

@tt{run} takes the view as JSON or as a @hash-lang[] @tt{sql-on-fhir} module. Exit codes: 0, 1 on an
error or a suite regression, 2 on usage.
