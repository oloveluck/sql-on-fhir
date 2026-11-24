#lang racket/base

;;; features.rkt — everything this package does, as ONE table. Start here.
;;;
;;; SQL on FHIR, in the specification (the IG package in spec/), is three things; this file lists
;;; each of them element by element, and then what this package puts around them:
;;;
;;;   the-view             a ViewDefinition's elements             the IG's StructureDefinition
;;;   in-a-path            what a path may call and name           FHIRPath, and the IG's own functions
;;;   sql-run, sql-export  the two operations, by parameter        the IG's OperationDefinitions
;;;   refusals, warnings   what a view is held to; what is said beside its rows
;;;   ways-to-run          the command line, the forms a view and its data take
;;;   the-source           the source text that compiles to a ViewDefinition (LANGUAGE.md)
;;;   from-racket          what `(require sql-on-fhir)` gives a program
;;;   in-a-workspace       what an agent's workspace (fhir-mcp) gets
;;;   not-done             what the specification has and this package does not
;;;
;;; Each row says what is DONE with the thing (a State), which definition does it (the file and
;;; the name to read) and which files of the shared test suite try it.
;;;
;;; The table is an index, and it is held to what it indexes:
;;;   - tests/features-test.rkt fails when the IG's definitions hold an element, an operation
;;;     parameter or an output format that no row names (so a newer IG, regenerated, shows what
;;;     is new), when a row names a definition its file does not have, when a file of the suite
;;;     is no row's, and when `(require sql-on-fhir)` and `from-racket` differ;
;;;   - each module's own tests hold its dispatch tables to its rows (view.rkt's `sof-functions`,
;;;     operations.rkt's `formats` and `refused-inputs`, cli.rkt's commands and FHIR versions,
;;;     definition.rkt's constraints).
;;;
;;; `raco sql-on-fhir features [<table>] [--json]` prints it.
;;;
;;; Data definitions.
;;; A Feature is (feature area names state where suite what)
;;;   area  : Symbol                the table it is a row of (`tables` lists them)
;;;   names : (Listof String)       the thing as it is written: an element's path below
;;;                                 ViewDefinition, a parameter's name (`subject.name` for a part,
;;;                                 `_format=csv` for one value of one), a command's usage line
;;;   state : State
;;;   where : (list file name) | #f the definition to read; #f: nothing here does anything with it
;;;   suite : (Listof Symbol)       the shared suite's files that try it
;;;                                 (tests/vendor/sql-on-fhir-tests/<name>.json)
;;;   what  : String                what it does here, in a sentence
;;; A State is one of
;;;   yes      done as the specification says
;;;   partly   done in part: the row says which part
;;;   unused   accepted and kept; nothing is computed from it
;;;   refused  given, the view or the call is refused, with the reason
;;;   no       not done
;;;   own      this package's own: the specification has no such thing
;;; A Table is (table area title intro): a group of rows, with the heading and the sentence it is
;;;   printed under.

(require racket/list racket/string json)

(provide (struct-out feature) (struct-out table)
         states tables features features-of command-usages
         features->text features->jsexpr)

(struct feature (area names state where suite what) #:transparent)
(struct table (area title intro) #:transparent)

;; states : (Listof (cons State String))   every State, with what it means
(define states
  '((yes . "done as the specification says")
    (partly . "done in part")
    (unused . "accepted and kept; nothing is computed from it")
    (refused . "refused, with the reason")
    (no . "not done")
    (own . "this package's own")))

;; rows : area (list names state where suite what) … -> (Listof Feature)
;; names may be given as one string
(define (rows area . specs)
  (for/list ([s (in-list specs)])
    (define-values (names state where suite what) (apply values s))
    (feature area (if (string? names) (list names) names) state where suite what)))

;; ---- the view: a ViewDefinition's elements --------------------------------------------------------
(define the-view
  (rows 'view
   '("resource" yes (view.rkt compile-view) (view_resource basic)
     "the type of resource the view reads; resources of other types are passed over, not read")
   '("select" yes (view.rkt eval-view) (basic combinations)
     "the table: for each resource, the rows of every top-level select multiplied together")
   '(("select.column" "select.column.name" "select.column.path") yes (view.rkt item-rows) (basic)
     "a column: its name, and the path that gives its value over the current item — nothing is null, one value is the value")
   '("select.column.collection" yes (view.rkt cell) (collection)
     "true: the column holds every value of its path, as a list; without it several values are an error")
   '("select.column.type" no #f ()
     "the type a column declares is not checked against its values, nor used to convert them")
   '(("select.column.description" "select.column.tag" "select.column.tag.name" "select.column.tag.value") unused #f ()
     "kept in the view; nothing here reads a column's description or its tags (a database's type hints)")
   '("select.forEach" yes (view.rkt sel-rows) (foreach)
     "one row for each item of the path; no item, no row")
   '("select.forEachOrNull" yes (view.rkt null-row) (foreach)
     "as forEach, but no item gives one row of nulls")
   '("select.repeat" yes (view.rkt transitive-closure) (repeat)
     "one row for each item reached by following the paths to any depth (a questionnaire's items inside items)")
   '("select.select" yes (view.rkt item-rows) (combinations)
     "a select inside a select: its rows multiply into the outer row")
   '("select.unionAll" yes (view.rkt compile-select) (union)
     "the rows of each branch, one branch after another; the branches name the same columns in the same order")
   '(("where" "where.path") yes (view.rkt passes-wheres?) (where logic)
     "a resource is kept when every where path is true of it")
   '("where.description" unused #f ()
     "kept in the view")
   '(("constant" "constant.name" "constant.value[x]") yes (view.rkt constants-env) (constant constant_types)
     "a value named once and read by paths as %name; every primitive type the definition allows")
   '("status" partly (workspace.rkt status-problem) ()
     "the definition requires it; a view without one runs all the same, with a warning (33 of the suite's own views leave it out)")
   '("fhirVersion" partly (workspace.rkt version-problem) ()
     "does not choose the FHIR version the data is read as (--fhir-version and the workspace do); a warning when the data is read as another")
   '("name" yes (operations.rkt $sql-export) ()
     "names the view's output in an export; held to be a name a database takes")
   '(("url" "version") yes (operations.rkt stored-view-by-url) ()
     "how `subjectCanonical` (url, or url|version) finds a view the data source holds")
   '("id" yes (operations.rkt subject-view) ()
     "how `subjectReference` (ViewDefinition/<id>) finds a view the data source holds")
   '("profile" unused #f ()
     "the profiles the view was written for: no resource is checked against them")
   '(("identifier" "versionAlgorithm[x]" "title" "experimental" "date" "publisher" "contact" "description"
      "useContext" "jurisdiction" "purpose" "copyright" "copyrightLabel" "approvalDate" "lastReviewDate"
      "effectivePeriod" "topic" "author" "editor" "reviewer" "endorser" "relatedArtifact"
      "meta" "implicitRules" "language" "text" "contained")
     unused #f ()
     "what a view says about itself: read, held to its type, kept")
   '(("extension" "modifierExtension") unused #f ()
     "read at every level and kept; no extension changes what a view means here, a modifierExtension included")))

;; ---- in a path ------------------------------------------------------------------------------------
(define in-a-path
  (rows 'path
   '("FHIRPath" yes (view.rkt eval-expr)
     (fhirpath fhirpath_numbers fn_boundary fn_empty fn_extension fn_first fn_join fn_oftype logic)
     "every path is FHIRPath, run by the family's fhirpath engine: the whole language, not only the subset the specification requires of an implementation")
   '("getResourceKey()" yes (view.rkt resource-key) (fn_reference_keys)
     "the key of the resource: its id")
   '("getReferenceKey([Type])" yes (view.rkt reference-key) (fn_reference_keys)
     "the key a reference points to: the id of a relative reference (Patient/p1 gives p1); with a type, of references to that type only")
   '("%rowIndex" yes (view.rkt rows-over) (row_index)
     "the position, from 0, of the current item in the nearest forEach, forEachOrNull or repeat")
   '("%<constant>" yes (view.rkt constants-env) (constant constant_types)
     "a constant of the view, by its name; a name the view does not define is an error")))

;; ---- $sql-run -------------------------------------------------------------------------------------
(define sql-run
  (rows 'sql-run
   '("subjectResource" yes (operations.rkt subject-view) ()
     "the view itself, inline; applied as a procedure it is the subject: ($sql-run view #:_format \"csv\")")
   '("subjectCanonical" yes (operations.rkt stored-view-by-url) ()
     "a view the data source holds, by its url or url|version")
   '("subjectReference" yes (operations.rkt subject-view) ()
     "a view the data source holds, as ViewDefinition/<id>")
   '("resource" yes (operations.rkt view-data) ()
     "the data, inline (a Bundle is its entries); without it, the current data source's resources of the view's type")
   '("patient" yes (operations.rkt view-data) ()
     "only those patients' resources, and the Patients themselves; a patient that does not resolve is refused")
   '("group" yes (operations.rkt group-members) ()
     "only the resources of those Groups' active members; a group that does not resolve is refused")
   '("_since" yes (operations.rkt changed-after?) ()
     "only resources whose meta.lastUpdated is after it, compared as instants")
   '("_limit" yes (operations.rkt run) ()
     "at most that many rows")
   '("_format" yes (operations.rkt run) ()
     "the form of the answer: ndjson unless said")
   '("_format=ndjson" yes (operations.rkt rows->ndjson) ()
     "a Binary, application/x-ndjson: one JSON object to a line")
   '("_format=json" yes (operations.rkt rows->json) ()
     "a Binary, application/json: one array of objects")
   '("_format=csv" yes (operations.rkt rows->csv) ()
     "a Binary, text/csv (RFC 4180), the columns in the view's order; a list cell is its JSON text")
   '("_format=fhir" yes (operations.rkt rows->parameters) ()
     "a Parameters resource, one `row` per row; a null cell is left out")
   '("_format=parquet" refused (operations.rkt unwritten-formats) ()
     "answered not-supported")
   '("header" yes (operations.rkt header?) ()
     "csv: false leaves the heading line out")
   '("parameters" refused (operations.rkt refused-inputs) ()
     "values for a SQLQuery's or SQLView's parameters; a ViewDefinition declares none: answered invalid")
   '("source" refused (operations.rkt refused-inputs) ()
     "another place to read the data from: answered not-supported (the data is the data source's, or `resource`)")
   '("context" unused #f ()
     "resources a query may draw on: nothing to say of a ViewDefinition")))

(define sql-run-answers
  (rows 'sql-run-answers
   '("return" yes (operations.rkt run) ()
     "the table as a Binary of the format asked for; for _format=fhir a Parameters resource")))

;; ---- $sql-export ----------------------------------------------------------------------------------
(define sql-export
  (rows 'sql-export
   '("subject" yes (operations.rkt subject-inputs) ()
     "one view to a subject, every one run before the call answers")
   '(("subject.subjectResource" "subject.subjectCanonical" "subject.subjectReference") yes (operations.rkt subject-view) ()
     "the view, as for $sql-run: inline, by canonical, or by reference")
   '("subject.name" yes (operations.rkt $sql-export) ()
     "the name of that view's output; else the view's own name; two outputs of one name are refused")
   '("subject.parameters" refused (operations.rkt refused-inputs) ()
     "as for $sql-run: a ViewDefinition declares none")
   '(("patient" "group" "_since") yes (operations.rkt view-data) ()
     "as for $sql-run, for every subject")
   '("_format" yes (operations.rkt $sql-export) ()
     "the format of every output: ndjson unless said")
   '(("_format=ndjson" "_format=json" "_format=csv") yes (operations.rkt run) ()
     "each output a Binary of that format, as $sql-run writes it")
   '("_format=parquet" refused (operations.rkt unwritten-formats) ()
     "answered not-supported")
   '("_format=fhir" refused (operations.rkt $sql-export) ()
     "$sql-run's alone (the definition's value set for an export leaves it out): answered invalid")
   '("header" yes (operations.rkt header?) ()
     "csv: false leaves the heading line out of every output")
   '("clientTrackingId" yes (operations.rkt $sql-export) ()
     "handed back in the answer")
   '("source" refused (operations.rkt refused-inputs) ()
     "answered not-supported")
   '("context" unused #f ()
     "nothing to say of a ViewDefinition")))

(define sql-export-answers
  (rows 'sql-export-answers
   '("exportId" yes (operations.rkt $sql-export) ()
     "export-<n>, counted within the process")
   '("status" partly (operations.rkt $sql-export) ()
     "always `completed`: every view has run when the call answers, so nothing is ever in progress, failed or cancelled")
   '(("clientTrackingId" "_format") yes (operations.rkt $sql-export) ()
     "handed back when given")
   '(("output" "output.name") yes (operations.rkt $sql-export) ()
     "one output to a subject, under its name")
   '("output.location" partly (operations.rkt $sql-export) ()
     "urn:sql-export:<name> — a name, not a place to fetch: the table is in the answer, under `result`")
   '("output.result" own (operations.rkt $sql-export) ()
     "the table itself, a Binary: what a client would have fetched from the location")
   '("location" no #f ()
     "there is no job to poll: the answer is the finished manifest")
   '(("cancelUrl" "exportStartTime" "exportEndTime" "exportDuration" "estimatedTimeRemaining") no #f ()
     "not written: an export is over when the call answers")))

;; ---- what a view is held to -----------------------------------------------------------------------
(define refusals
  (rows 'refusals
   '("an element the definition does not have, or a value of another shape" yes (definition.rkt read-view) (validate)
     "before any data is read: the strict parse against the model generated from the IG")
   '("a required element left out" yes (definition.rkt definition-problems) (validate view_resource constant)
     "before any data is read, named where it is missing: resource, select, a column's name or path, a where's path, a constant's name or value")
   '("a code outside its required value set" yes (definition.rkt binding-problems) ()
     "before any data is read: status, resource, fhirVersion")
   '("sql-name" yes (definition.rkt own-constraints) ()
     "before any data is read: the view's, a constant's or a column's name is not a name a database takes")
   '("sql-expressions" yes (definition.rkt own-constraints) ()
     "before any data is read: a select with more than one of forEach, forEachOrNull and repeat")
   '("a path that is not FHIRPath" yes (view.rkt compile-path) (validate)
     "before any data is read, with the path and what is wrong with it")
   '("unionAll branches of different columns" yes (view.rkt compile-select) (union)
     "before any data is read: the branches name the same columns, in the same order")
   '("a column name used twice" yes (view.rkt compile-view) ()
     "before any data is read: the columns of a table are named apart")
   '("several values for one cell" yes (view.rkt cell) (collection)
     "when a resource meets it: a column without `collection` whose path gives more than one value")
   '("a where that is no boolean" yes (view.rkt passes-wheres?) (validate)
     "when a resource meets it: a where path that gives anything but true or false")
   '("an element the type does not have" yes (view.rkt eval-expr) ()
     "when a resource meets it: a column's or a where's path names an element its type lacks (a forEach's or a repeat's gives no item instead)")
   '("a constant the view does not define" yes (view.rkt eval-expr) (constant)
     "when a resource meets it: a path reads %name and the view has no such constant")))

(define warnings
  (rows 'warnings
   '("no `status`" own (workspace.rkt status-problem) ()
     "the standard requires one; said where the view begins")
   '("`fhirVersion` is not the version read" own (workspace.rkt version-problem) ()
     "the view names the FHIR versions it is for, and the data is read as another")
   '("a path to an element the type lacks" own (workspace.rkt path-problems) ()
     "found without data, at the path's line and column in the file, with the nearest element's name")
   '("data the read left out" own (unread.rkt unread-notes) ()
     "what the view reads and the lenient read of the data dropped — an element the version read does not have, a value that is not valid FHIR — counted over the resources, the first named")))

;; ---- ways to run ----------------------------------------------------------------------------------
;; A row whose name begins `raco sql-on-fhir <command>` IS that command's usage line: cli.rkt's
;; usages are these rows (`command-usages`).
(define ways-to-run
  (rows 'run
   '("raco sql-on-fhir run <view.sof | view.json | view.rkt> [<data dir | bundle.json | resource.json>] [--format ndjson|json|csv|fhir] [--fhir-version 4.0.1|5.0.0|6.0.0]"
     own (cli.rkt cmd-run) ()
     "a view over data, the table on standard output; this is $sql-run")
   '("a view as source text" own (sof.rkt read-sof) ()
     "a .sof file: `SELECT … FROM Patient WHERE …`, the SQL dialect with FHIRPath of LANGUAGE.md, compiled to the ViewDefinition it states (the first, when it states several) and checked as one; the table `source` lists its parts")
   '("a view as FHIR JSON" yes (definition.rkt read-view) ()
     "any JSON file holding a ViewDefinition, as the specification and its suite write one: the form source text compiles to")
   '("a view as `#lang sql-on-fhir`" own (lang/reader.rkt read-syntax-either) ()
     "a file of any extension that starts with that line is a Racket module of views: source text, or (beginning with a parenthesis) the forms generated from the IG; either way a mistake is a compile error at its place")
   '("data: a directory, a Bundle, a resource" own (cli.rkt read-data) ()
     "a folder of JSON files one resource to a file, a file holding a Bundle, or a file holding one resource; none: the heading and no rows")
   '("--format ndjson|json|csv|fhir" own (cli.rkt cmd-run) ()
     "$sql-run's _format; ndjson unless said")
   '("--fhir-version 4.0.1|5.0.0|6.0.0" own (cli.rkt load-tower!) ()
     "the FHIR version the data is read as; 6.0.0 (the version the view model is built over) unless said")
   '("raco sql-on-fhir compile <file.sof> [-o <dir>]" own (cli.rkt cmd-compile) ()
     "source text to the ViewDefinitions it states, as FHIR JSON: printed, or each written to <dir>/<name>.view.json")
   '("raco sql-on-fhir decompile <view.json>…" own (cli.rkt cmd-decompile) ()
     "ViewDefinitions as the source text that states them")
   '("raco sql-on-fhir features [<table>] [--json]" own (cli.rkt cmd-features) ()
     "this table, or one of its tables by name; as JSON")
   '("raco sql-on-fhir tck [-v]" own (cli.rkt cmd-tck) ()
     "the shared test suite, file by file, against its floor")
   '("raco sql-on-fhir regen" own (cli.rkt cmd-regen) ()
     "write model/ again from the IG package in spec/")
   '("raco sql-on-fhir check" own (cli.rkt cmd-check) ()
     "verify model/ is what spec/ generates")
   '("raco sql-on-fhir fetch [--version 3.0.0-ballot] [--tests-commit <sha>]" own (cli.rkt cmd-fetch) ()
     "download the IG package and the shared test suite again (needs the network)")))

;; ---- the source text ------------------------------------------------------------------------------
;; LANGUAGE.md is the definition of the language; these rows are its parts, each with the function
;; that compiles it. (The keywords named here are the lexer's: tests/language-test.rkt.)
(define the-source
  (rows 'source
   '("SELECT <items> FROM <Resource>" own (compile.rkt view-of) ()
     "a statement: one view, compiled to one ViewDefinition; the items in the order written are the table's columns in that order")
   '("<path> AS <name>" own (compile.rkt column-of) ()
     "a column; a path that is one element's name needs no AS and is named by it")
   '("TYPE, COLLECTION, NOT COLLECTION, DESCRIPTION, TAG" own (compile.rkt column-of) ()
     "after a column: its type, that it holds every value as a list, its description, its tags")
   '("(SELECT <items> FROM <path>)" own (compile.rkt select-of) ()
     "a nested select, a row for each item of the path (forEach); without FROM, over the same item")
   '("FROM <path> OR NULL" own (compile.rkt select-of) ()
     "a row for each item, and one row of nulls when there is none (forEachOrNull)")
   '("FROM REPEAT <path>, <path>" own (compile.rkt select-of) ()
     "a row for each item reached by following the paths to any depth (repeat)")
   '("(SELECT … UNION ALL SELECT …)" own (compile.rkt items-of) ()
     "the rows of each select, one after another (unionAll); the last item of its SELECT")
   '("WHERE <path> AND <path>" own (compile.rkt condition-of) ()
     "the resources kept: each condition one `where`, with its DESCRIPTION when it has one")
   '("DECLARE <name> [<type>] = <value>" own (compile.rkt constant-of) ()
     "a constant, read by paths as %name; without a type the value says it")
   '("CREATE VIEW <name> WITH (<element> = <value>) AS" own (compile.rkt options-of) ()
     "the view's name, and every other element of the view by its own name, its value written as JSON")
   '("a path" own (compile.rkt path-of) ()
     "FHIRPath as it is, from its first token to the keyword, comma or parenthesis that ends it; in double quotes, exactly the text between them")
   '("keywords in capitals" own (parser/lexer.rkt tokenize) ()
     "what tells the language's words from FHIRPath's lower-case ones (`value as Quantity AS quantity`); comments are --, // and /* */")
   '("several statements" own (compile.rkt compile-sof) ()
     "a file states any number of views, separated by `;`")
   '("a ViewDefinition back to text" own (decompile.rkt view->sof) ()
     "the statement that compiles to exactly that ViewDefinition; what the language has no place for is refused, by name")
   '("checked as it is read" own (sof.rkt read-sof) ()
     "every problem at its line and column: the text's syntax, a path that is not FHIRPath, a result that is no ViewDefinition")))

;; ---- from Racket ----------------------------------------------------------------------------------
;; The names are what `(require sql-on-fhir)` provides (main.rkt), one row to a module's part of it.
(define from-racket
  (rows 'racket
   '(("$sql-run" "$sql-export") own (operations.rkt $sql-run) ()
     "the IG's operations as procedures (fhir/operation values), over `current-data-source`")
   '("view-rows" own (operations.rkt view-rows) ()
     "a ViewDefinition (JSON) over the data source, or over the resources given: its rows as hashes")
   '(("rows->csv" "rows->ndjson" "rows->json") own (operations.rkt rows->csv) ()
     "the output formats, over eval-view's rows")
   '(("current-read-log" "make-read-log" "read-log?" "read-log-count" "read-log-reads") own (operations.rkt read-log-reads) ()
     "what the lenient read of the data left out of what a view read")
   '("read-view" own (definition.rkt read-view) ()
     "a ViewDefinition (JSON) as the typed view the engine takes, or the problems that make it none")
   '("definition-url" own (definition.rkt definition-url) ()
     "the canonical of the definition views are held to")
   '(("eval-view" "view-columns") own (view.rkt eval-view) ()
     "the engine: a typed view over typed resources, its rows and its column names in order")
   '(("exn:fail:view" "path-syntax-problem" "rewrite-sof") own (view.rkt compile-path) ()
     "a view refused before any data is read; what is wrong with a path's syntax; the IG's functions rewritten as plain FHIRPath")
   '(("sof->views" "compile-sof" "compiled") own (compile.rkt compile-sof) ()
     "source text (LANGUAGE.md) to the ViewDefinitions it states, as JSON; with where each statement begins")
   '(("read-sof" "source-text?") own (sof.rkt read-sof) ()
     "the same, each result held to what a ViewDefinition is; whether a file's text is source text")
   '(("view->sof" "views->sof" "exn:fail:unwritable") own (decompile.rkt view->sof) ()
     "a ViewDefinition as the source text that states it; the refusal when the language has no place for something in it")
   '(("view-chains" "unread-notes") own (unread.rkt unread-notes) ()
     "the elements a view's paths walk; a sentence for each that the read left out")
   '(("features" "features-of" "tables" "table" "states" "feature" "command-usages" "features->text" "features->jsexpr")
     own (features.rkt features) ()
     "this table")))

;; ---- in a workspace -------------------------------------------------------------------------------
(define in-a-workspace
  (rows 'workspace
   '("a `*.view.json` file" own (workspace.rkt artifacts) ()
     "the ViewDefinition <workspace canonical>/ViewDefinition/<file stem> unless it names its own, with every problem of it as it is written")
   '("run" own (workspace.rkt run) ()
     "its rows over the workspace's data, in column order, with what the read left out")
   '("explain" own (workspace.rkt explain) ()
     "one resource: the rows it alone gives, how many without the `where`, and whether each `where` holds for it")
   '("learn://sql-on-fhir" own (workspace.rkt guide) ()
     "guide.md, the format for agents")))

;; ---- not done -------------------------------------------------------------------------------------
(define not-done
  (rows 'not-done
   '("SQLQuery and SQLView" refused (operations.rkt subject-view) ()
     "the IG's Libraries of SQL over views (and its sql-text extension): a Library as the subject is answered not-supported")
   '("an asynchronous export" no #f ()
     "a job that is started, polled at its location and cancelled: $sql-export runs every view before it answers")
   '("ShareableViewDefinition and TabularViewDefinition" no #f ()
     "the IG's profiles of a view: a view that claims one is not held to it")
   '("the IG's search parameters" no #f ()
     "nothing here searches ViewDefinitions: a stored view is found by canonical or by id")
   '("Parquet" no #f ()
     "no output is written as Parquet")))

;; ---- the tables -----------------------------------------------------------------------------------
;; tables : (Listof Table)   in the order they are read and printed
(define tables
  (list (table 'view "A ViewDefinition's elements" "paths below ViewDefinition, from the IG's definition of one")
        (table 'path "In a path" "what a column's, a where's, a forEach's or a repeat's path may call and name")
        (table 'sql-run "$sql-run takes" "the inputs of the IG's operation that runs one view; `_format=x` is one value of `_format`")
        (table 'sql-run-answers "$sql-run answers" "")
        (table 'sql-export "$sql-export takes" "the inputs of the IG's operation that runs several views; `subject.x` is a part of `subject`")
        (table 'sql-export-answers "$sql-export answers" "")
        (table 'refusals "What refuses a view" "each an error with its reason: an OperationOutcome from an operation, exit status 1 from the command")
        (table 'warnings "What is said beside the rows" "the table is printed all the same; the command writes these on standard error")
        (table 'run "From the command line" "")
        (table 'source "The source text (.sof)" "the SQL dialect with FHIRPath that compiles to ViewDefinitions: LANGUAGE.md defines it")
        (table 'racket "From Racket" "(require sql-on-fhir)")
        (table 'workspace "In a workspace" "fhir-mcp: a directory of files an agent works in")
        (table 'not-done "Not done" "what the specification has and this package does not")))

;; features : (Listof Feature)   every row, table by table
(define features
  (append the-view in-a-path sql-run sql-run-answers sql-export sql-export-answers
          refusals warnings ways-to-run the-source from-racket in-a-workspace not-done))

;; features-of : area -> (Listof Feature)
(define (features-of area) (filter (lambda (f) (eq? (feature-area f) area)) features))

;; command-usages : -> (Listof (list command usage-line))   the command line's commands, from the
;; rows that are usage lines
(define (command-usages)
  (for*/list ([f (in-list (features-of 'run))]
              [m (in-value (regexp-match #px"^raco sql-on-fhir ([a-z]+)" (car (feature-names f))))]
              #:when m)
    (list (cadr m) (car (feature-names f)))))

;; ---- printed --------------------------------------------------------------------------------------
;; features->text : (Listof Feature) -> string   the rows under their tables' headings: state, what
;; is written, what it does; then where to read it and which suite files try it
(define (features->text fs)
  (define out (open-output-string))
  (fprintf out "SQL on FHIR, as this package does it. Each row: what is done with it, what you write, what it does;\nthen the definition to read and the shared suite's files that try it.\n")
  (fprintf out "  ~a\n" (string-join (for/list ([s (in-list states)]) (format "~a: ~a" (car s) (cdr s))) "\n  "))
  (for ([t (in-list tables)])
    (define mine (filter (lambda (f) (eq? (feature-area f) (table-area t))) fs))
    (when (pair? mine)
      (fprintf out "\n~a~a\n" (table-title t) (if (equal? (table-intro t) "") "" (format " — ~a" (table-intro t))))
      (for ([f (in-list mine)])
        (fprintf out "  ~a ~a\n" (pad (symbol->string (feature-state f)) 8) (string-join (feature-names f) ", "))
        (fprintf out "           ~a\n" (feature-what f))
        (define pointers
          (append (if (feature-where f) (list (format "~a `~a`" (car (feature-where f)) (cadr (feature-where f)))) '())
                  (if (pair? (feature-suite f)) (list (format "suite: ~a" (string-join (map symbol->string (feature-suite f)) ", "))) '())))
        (when (pair? pointers) (fprintf out "           [~a]\n" (string-join pointers "; "))))))
  (get-output-string out))
(define (pad s n) (string-append s (make-string (max 0 (- n (string-length s))) #\space)))

;; features->jsexpr : (Listof Feature) -> jsexpr   the same rows as a list of objects
(define (features->jsexpr fs)
  (for/list ([f (in-list fs)])
    (hasheq 'table (symbol->string (feature-area f))
            'names (feature-names f)
            'state (symbol->string (feature-state f))
            'file (if (feature-where f) (symbol->string (car (feature-where f))) (json-null))
            'definition (if (feature-where f) (symbol->string (cadr (feature-where f))) (json-null))
            'suite (map symbol->string (feature-suite f))
            'what (feature-what f))))

(module+ test
  (require rackunit)
  ;; every row is of a table, in a state there is, and says what it does; a row that does something
  ;; names where, a row that does nothing names nowhere
  (for ([f (in-list features)])
    (check-true (and (memq (feature-area f) (map table-area tables)) #t) (format "~a" (feature-names f)))
    (check-true (and (assq (feature-state f) states) #t) (format "~a" (feature-names f)))
    (check-true (and (pair? (feature-names f)) (andmap string? (feature-names f))))
    (check-true (and (string? (feature-what f)) (not (equal? (feature-what f) ""))))
    (check-equal? (and (feature-where f) #t) (and (not (memq (feature-state f) '(unused no))) #t)
                  (format "~a: a row names a definition unless nothing is done" (feature-names f))))
  ;; no table is empty, and within a table no name is said twice
  (for ([t (in-list tables)])
    (define names (append-map feature-names (features-of (table-area t))))
    (check-true (pair? names) (format "~a" (table-area t)))
    (check-false (check-duplicates names) (format "~a" (table-area t))))
  ;; the commands, from their rows
  (check-equal? (map car (command-usages)) '("run" "compile" "decompile" "features" "tck" "regen" "check" "fetch"))
  (check-regexp-match #rx"^raco sql-on-fhir run <view" (cadr (assoc "run" (command-usages))))
  ;; printed: a heading per table, a row's three lines; one table alone
  (define text (features->text features))
  (for ([t (in-list tables)]) (check-true (string-contains? text (string-append "\n" (table-title t)))))
  (check-true (string-contains? text "  yes      select.forEach\n           one row for each item of the path; no item, no row\n           [view.rkt `sel-rows`; suite: foreach]\n"))
  (check-false (string-contains? (features->text (features-of 'path)) "$sql-run takes"))
  (check-equal? (hash-ref (car (features->jsexpr (features-of 'path))) 'definition) "eval-expr")
  (check-equal? (hash-ref (car (features->jsexpr (features-of 'not-done))) 'state) "refused"))
