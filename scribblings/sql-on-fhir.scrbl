#lang scribble/manual
@(require (for-label racket/base racket/contract sql-on-fhir/view sql-on-fhir/operations))

@title{sql-on-fhir: SQL on FHIR}

@hyperlink["https://build.fhir.org/ig/FHIR/sql-on-fhir-v2/"]{SQL on FHIR}, run over FHIR data. You write a
ViewDefinition, a flat table over one resource type with a FHIRPath per column, in a @tt{.sof} file;
@tt{raco sql-on-fhir run} evaluates it over a directory of resources and prints rows. The
ViewDefinition model is generated from HL7's published package, so a view is checked against the
IG's own model when it compiles, and the IG's @tt{$sql-run} and @tt{$sql-export} operations are
provided. The shared test suite passes, 144 of 144. Part of the
@hyperlink["https://github.com/oloveluck/fhir"]{fhir} family.

@table-of-contents[]

@section{Quick start}

@bold{1. Install.} The packages are not on the Racket package server yet; clone the repositories
side by side and install from source:

@verbatim{
raco pkg install --link --auto fhir/fhir fhir/fhir-spec fhirpath sql-on-fhir
}

@bold{2. Write a view.}

@verbatim|{#lang sql-on-fhir
(ViewDefinition
 (name "bp_readings") (status "active") (resource "Observation")
 (where (ViewDefinitionWhere (path "code.coding.where(system = 'http://loinc.org').code = '85354-9'")))
 (select (ViewDefinitionSelect
          (column (ViewDefinitionSelectColumn (name "patient") (path "subject.getReferenceKey(Patient)"))
                  (ViewDefinitionSelectColumn (name "date") (path "effective.ofType(dateTime)"))
                  (ViewDefinitionSelectColumn (name "systolic")
                    (path "component.where(code.coding.code = '8480-6').value.ofType(Quantity).value"))))))}|

@bold{3. Run it over a directory of resources.}

@verbatim{
$ raco sql-on-fhir run readings.sof patients/ --format csv
patient,date,systolic
p1,2024-03-01T09:00:00Z,152
p1,2024-04-02T09:30:00Z,138
}

A misspelled element, a wrong type or a @tt{status} outside its value set is a compile error on the
form.

@section{Writing a view}

A ViewDefinition picks a resource type, filters it (@tt{where}) and selects columns, each a FHIRPath
path. The forms are the IG's elements in the @tt{fhir/r6} form syntax: @tt{ViewDefinition},
@tt{ViewDefinitionWhere}, @tt{ViewDefinitionSelect} (@tt{column}, nested @tt{select},
@tt{forEach}, @tt{forEachOrNull}, @tt{repeat}, @tt{unionAll}), @tt{ViewDefinitionSelectColumn}
(@tt{path}, @tt{name}, @tt{description}, @tt{collection}, @tt{type}, @tt{tag}) and
@tt{ViewDefinitionConstant} (a @tt{%name} for paths). Paths may use @tt{getResourceKey()},
@tt{getReferenceKey(Type)}, @tt{%rowIndex} and the view's constants. The reference is the
@hyperlink["https://build.fhir.org/ig/FHIR/sql-on-fhir-v2/"]{SQL on FHIR IG}.

@section{Using it}

@subsection{Command line}

@tabular[#:style 'boxed #:sep @hspace[2]
(list (list @tt{raco sql-on-fhir run view.sof data/ [--format ndjson|json|csv|fhir]} "a view (a module or JSON) over a directory, Bundle or resource")
      (list @tt{raco sql-on-fhir tck [-v]} "the shared suite (floor 144)")
      (list @tt{raco sql-on-fhir regen | check} @elem{regenerate the model from @tt{spec/}; verify it is current})
      (list @tt{raco sql-on-fhir fetch [--version v] [--tests-commit sha]} "refresh the package and the suite"))]

Exit codes: 0, 1 on an error or a suite regression, 2 on usage.

@subsection{As a module}

@racket[(require "readings.sof")] gives @racket[resources] (typed nodes), @racket[(->nodes)] and
@racket[(->json)] (the ViewDefinitions as JSON). @tt{racket readings.sof} prints the JSON.

@racketblock[
(require (only-in "readings.sof" [->json views])
         fhir/data-source (only-in sql-on-fhir/operations view-rows))
(parameterize ([current-data-source (resources->data-source observations)])
  (view-rows (car (views))))         (code:comment "a list of hashes, one per reading")
]

@subsection{As an operation}

@tt{$sql-run} answers the IG's formats as a Binary (or rows as a Parameters); data comes from
@racket[current-data-source] or @tt{#:resource} inputs. fhir-server serves the same values over
HTTP with @racket[(serve-operations (list $sql-run $sql-export) #:port 8080)].

@racketblock[
(require fhir/operation fhir/data-source sql-on-fhir/operations)
(parameterize ([current-data-source (directory->data-source "patients/")])
  ($sql-run view #:_format "csv")                       (code:comment "the view is the subject")
  (apply-operation "$sql-run" #:subjectCanonical "http://example.org/ViewDefinition/x" #:_format "fhir"))
]

@section{Limits}

@itemlist[
@item{No SQL database: views are evaluated in memory through the fhirpath engine, one row list per
view.}
@item{@tt{$sql-run} ignores @tt{parameters}, @tt{context}, @tt{group} and @tt{source}; a
@tt{patient} that does not resolve filters to nothing; only ViewDefinition subjects (no SQLQuery or
SQLView Libraries); no Parquet.}
@item{@tt{$sql-export} completes synchronously, with the results inline as Binaries: no job, polling,
cancellation or download urls; @tt{_format=fhir} becomes ndjson.}
@item{A column's @tt{type} and @tt{tag} are not enforced; constants must be primitives;
@tt{getReferenceKey()} expects relative @tt{Type/id} references.}]

@section{Reference}

@subsection[#:style 'unnumbered]{@hash-lang[] @tt{sql-on-fhir}}
@defmodulelang[sql-on-fhir]

Each top-level form builds a typed ViewDefinition; the module provides @racket[resources],
@racket[(->nodes)] and @racket[(->json)].

@subsection[#:style 'unnumbered]{@tt{sql-on-fhir/view}}
@defmodule[sql-on-fhir/view]

@defproc[(eval-view [view fhir?] [resources (listof fhir?)]) (listof list?)]{
The rows of a typed ViewDefinition over typed resources, each row an association list from column
name to value, in column order. Every path goes through the fhirpath engine; a view error is raised
by @racket['eval-view].}
@defproc[(view-columns [view fhir?]) (listof symbol?)]{The column names, in declaration order.}

@subsection[#:style 'unnumbered]{@tt{sql-on-fhir/operations}}
@defmodule[sql-on-fhir/operations]

@defthing[$sql-run procedure?]{
On the IG's @tt{SQLRun} definition, registered when the module loads. The view is the subject
(@tt{subjectResource}), or named by @tt{#:subjectCanonical} or @tt{#:subjectReference} from the
data source. Data: @tt{#:resource} inputs (Bundles unwrapped) or the data source, filtered by
@tt{#:patient} and @tt{#:_since}; @tt{#:_limit}. @tt{#:_format} is @racket["ndjson"] (the default),
@racket["json"] or @racket["csv"] (with @tt{#:header}) as a Binary, or @racket["fhir"] as a
Parameters of rows.}
@defthing[$sql-export procedure?]{
@tt{#:subject} is a list of views, references or canonicals; completes synchronously with a manifest
Parameters: one @tt{output} per subject, its result a Binary.}
@defproc[(view-rows [view hash?] [resources (or/c (listof hash?) #f) #f]) (listof hash?)]{
Rows as hashes for a ViewDefinition given as JSON (strictly parsed); @racket[resources] default to
the data source's.}
@deftogether[(
@defproc[(rows->ndjson [rows list?]) string?]
@defproc[(rows->json [rows list?]) string?]
@defproc[(rows->csv [columns list?] [rows list?] [#:header? header? boolean? #t]) string?])]{The formats, over @racket[eval-view]'s rows.}
