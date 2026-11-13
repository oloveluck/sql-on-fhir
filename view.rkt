#lang racket/base

;;; view.rkt — evaluate a SQL on FHIR ViewDefinition over FHIR resources -> flat rows.
;;;
;;; The view is a TYPED node from the model generated from the IG package (`sql-on-fhir/model`: the schema IS the data
;;; definition); resources are typed nodes; every path is evaluated with the repo's FHIRPath engine.
;;;
;;; Semantics (sql-on-fhir v2/v3):
;;;   view        : for each resource of view.resource that satisfies every `where` path, the rows
;;;                 are the CARTESIAN PRODUCT of the row-sets of the top-level select items.
;;;   select item : `column` yields ONE row of column values over the current focus;
;;;                 `forEach` maps the item over each element of its path (empty -> no rows);
;;;                 `forEachOrNull` likewise, but empty -> one all-null row;
;;;                 `repeat` is forEach over the TRANSITIVE closure of the path(s);
;;;                 nested `select` multiplies in; `unionAll` concatenates its branches' rows.
;;;   column      : path must yield 0..1 items (null / scalar) unless `collection` is true (-> JSON
;;;                 array); >1 items without collection is an error.
;;;   constants   : view.constant values are injected as %name FHIRPath externals; %rowIndex is the
;;;                 ordinal of the current element in the nearest enclosing forEach/repeat.
;;;   getResourceKey()/getReferenceKey(Type?) : SOF-specific functions, handled by an AST rewrite
;;;                 (resource key = id; reference key = the id part of a relative reference,
;;;                 filtered by type when given).
;;;
;;; A Row is an ordered (Listof (cons Symbol jsexpr)) — order carries column order for
;;; expectColumns; compare as hashes for row equality.
;;;
;;; The typed node is COMPILED once, before any resource is read, into the data the evaluator recurs on:
;;;
;;; A View is (view type consts wheres selects)
;;;   type : Symbol, the resource type read; consts : the %externals (name -> one-item collection);
;;;   wheres : (Listof Expr); selects : (Listof Sel)
;;; A Sel is (sel iteration columns selects unions) — one select item:
;;;   columns : (Listof Col); selects, unions : (Listof Sel) (nested `select`, `unionAll` branches)
;;; An Iteration is one of
;;;   #f                      the item's rows over the focus it is given
;;;   (each expr or-null?)    over each element of the path (`forEach`); none: no row, or, with
;;;                           or-null? (`forEachOrNull`), the one null row
;;;   (repeat exprs)          over every element reached by following the paths to any depth
;;; A Col is (col name expr collection?) — name : Symbol
;;; An Expr is (expr text ast verdicts) — a path parsed once, getResourceKey/getReferenceKey
;;;   rewritten; verdicts : focus type -> #f | exn, the static pass's answer, asked once per type
;;;
;;; What can be told of a view without data is told when it is compiled, as an `exn:fail:view`: a
;;; path that does not parse, `unionAll` branches whose columns differ, a column name used twice, no
;;; `resource`. What depends on the data (a column with several values, a `where` that is no
;;; boolean, an unknown %constant) is an `exn:fail` when a resource meets it.

(require racket/contract racket/match racket/list racket/string
         (only-in fhir/model/node fhir? fhir-ref fhir-type)
         (only-in fhir/model/base primitive-type?)
         (only-in fhir/model/leaf pv)
         (only-in fhir/primitives/primitives primitive->jsexpr)
         (only-in fhir/diagnostic exn:fail:diagnostic? exn:fail:diagnostic-diagnostic diagnostic-message)
         (only-in fhirpath/parser/parse parse-fhirpath)
         (only-in fhirpath/parser/ast fp-call fp-invoke fp-binop fp-unop fp-index fp-typeop fp-lit)
         (only-in fhirpath/eval fp-eval)
         (only-in fhirpath/analyze analyze)
         (only-in fhirpath/environment make-env)
         (only-in fhirpath/value item->system fp-long? fp-long-v)
         (only-in fhirpath/decimal fp-decimal? decimal->string)
         (only-in fhirpath/temporal-ops moment? moment->string moment-kind)
         (only-in fhir/serialize/to-json node->jsexpr))

(provide
 (contract-out
  ;; eval-view : typed ViewDefinition node × resources -> rows (each an ordered alist)
  [eval-view    (-> fhir? (listof fhir?) (listof list?))]
  ;; view-columns : the view's column names, in declaration order
  [view-columns (-> fhir? (listof symbol?))]
  ;; a view refused before any data is read (the message says why); `path` is the path's text when
  ;; the problem is one path's syntax, else #f
  [struct (exn:fail:view exn:fail) ([message string?] [continuation-marks continuation-mark-set?] [path (or/c string? #f)])]
  ;; rewrite-sof : FHIRPath AST -> AST   getResourceKey()/getReferenceKey(Type) as plain FHIRPath (the
  ;; workspace checks a view's paths after it, as the engine evaluates them)
  [rewrite-sof  (-> any/c any/c)]))

(struct view (type consts wheres selects))
(struct sel (iteration columns selects unions))
(struct each (expr or-null?))
(struct repeat (exprs))
(struct col (name expr collection?))
(struct expr (text ast verdicts))
(struct exn:fail:view exn:fail (path))

;; refuse : (or/c string #f) format-string value … -> raises exn:fail:view
(define (refuse path fmt . args)
  (raise (exn:fail:view (string-append "eval-view: " (apply format fmt args)) (current-continuation-marks) path)))

;; ---- typed-node field helpers ----------------------------------------------
;; fld : node key -> value|#f ; flds : node key -> (Listof value) ; pstr : node key -> scalar|#f
(define (fld n k) (fhir-ref n k #f))
(define (flds n k) (define v (fhir-ref n k '())) (if (list? v) v (list v)))
(define (pstr n k) (let ([v (fld n k)]) (and v (pv v))))

;; ---- compiling: ViewDefinition node -> View ----------------------------------
;; compile-view : node -> View   raises exn:fail:view
(define (compile-view node)
  (define type (or (pstr node 'resource) (refuse #f "the view has no `resource` (the type of resource it reads)")))
  (define selects (map compile-select (flds node 'select)))
  (cond [(check-duplicates (append-map sel-names selects))
         => (lambda (name) (refuse #f "the column name `~a` is used twice: the columns of a table are named apart" name))])
  (view (string->symbol type) (constants-env node)
        (for/list ([w (in-list (flds node 'where))]) (compile-path (pstr w 'path) "a `where`"))
        selects))

;; compile-select : select node -> Sel   `unionAll` branches agree on column names AND order
(define (compile-select s)
  (define each-path (or (pstr s 'forEach) (pstr s 'forEachOrNull)))
  (define repeats (map pv (flds s 'repeat)))
  (define unions (map compile-select (flds s 'unionAll)))
  (define shapes (map sel-names unions))
  (unless (or (null? shapes) (andmap (lambda (sh) (equal? sh (car shapes))) (cdr shapes)))
    (refuse #f "unionAll branches disagree on columns: ~a" shapes))
  (sel (cond [(pair? repeats) (repeat (for/list ([p (in-list repeats)]) (compile-path p "a `repeat`")))]
             [each-path (each (compile-path each-path "a `forEach`") (and (pstr s 'forEachOrNull) #t))]
             [else #f])
       (for/list ([c (in-list (flds s 'column))])
         (col (string->symbol (or (pstr c 'name) (refuse #f "a column has no `name`")))
              (compile-path (pstr c 'path) (format "column `~a`" (pstr c 'name)))
              (eq? (pstr c 'collection) #t)))
       (map compile-select (flds s 'select))
       unions))

;; sel-names : Sel -> (Listof Symbol)   its columns in declaration order: its own, its nested
;; selects', its first unionAll branch's (the branches agree)
(define (sel-names s)
  (append (map col-name (sel-columns s))
          (append-map sel-names (sel-selects s))
          (if (pair? (sel-unions s)) (sel-names (car (sel-unions s))) '())))

;; compile-path : string|#f owner -> Expr   parsed once, the SOF-specific calls rewritten; `owner`
;; says whose path it is when there is none, or it does not parse
(define (compile-path text owner)
  (unless (string? text) (refuse #f "~a has no `path`" owner))
  (define ast
    (with-handlers ([exn:fail:diagnostic?
                     (lambda (e) (refuse text "the path ~s is not FHIRPath: ~a" text
                                         (diagnostic-message (exn:fail:diagnostic-diagnostic e))))])
      (parse-fhirpath text)))
  (expr text (rewrite-sof ast) (make-hasheq)))

;; constants-env : node -> (Hash String Collection)   view.constant as %externals: the first value[x]
;; a constant carries, as a one-item collection
(define (constants-env node)
  (for/fold ([h (hash)]) ([c (in-list (flds node 'constant))])
    (hash-set h (pstr c 'name) (for/or ([n (in-list constant-value-keys)]) (let ([v (fld c n)]) (and v (list v)))))))
(define constant-value-keys
  '(valueBase64Binary valueBoolean valueCanonical valueCode valueDate valueDateTime
    valueDecimal valueId valueInstant valueInteger valueInteger64 valueOid
    valuePositiveInt valueString valueTime valueUnsignedInt valueUri valueUrl valueUuid))

;; ---- entry ------------------------------------------------------------------
(define (eval-view node resources)
  (define v (compile-view node))
  (define consts (view-consts v))
  (append*
   (for/list ([r (in-list resources)]
              #:when (eq? (fhir-type r) (view-type v))
              #:when (passes-wheres? r (view-wheres v) consts))
     (product (for/list ([s (in-list (view-selects v))]) (sel-rows s r consts 0))))))

;; the resource must satisfy every where path — a where evaluating to a non-boolean is a VIEW error
(define (passes-wheres? r wheres consts)
  (for/and ([x (in-list wheres)])
    (define v (map item->system (eval-expr x r consts 0)))
    (cond [(null? v) #f]
          [(and (null? (cdr v)) (boolean? (car v))) (car v)]
          [else (error 'eval-view "where path must resolve to a boolean, got ~a" v)])))

;; view-columns : declaration-order column names (for expectColumns)
(define (view-columns node) (append-map sel-names (view-selects (compile-view node))))

;; ---- the structural recursion over select items -----------------------------
;; product : (Listof (Listof Row)) -> (Listof Row)   the cartesian product of row-sets, each row the
;; concatenation of one row from every set, in order
(define (product row-sets)
  (for/fold ([rows (list '())]) ([set (in-list row-sets)])
    (for*/list ([base (in-list rows)] [add (in-list set)]) (append base add))))

;; sel-rows : Sel focus consts idx -> (Listof Row)   the rows of ONE select item
(define (sel-rows s focus consts idx)
  (match (sel-iteration s)
    [#f (item-rows s focus consts idx)]
    [(each x or-null?)
     (define elems (eval-tolerant x focus consts idx))
     (cond [(pair? elems) (rows-over s elems consts)]
           [or-null? (list (null-row s consts))]          ; forEachOrNull: one row over the empty focus
           [else '()])]                                   ; forEach: eliminates the row
    [(repeat xs) (rows-over s (transitive-closure xs focus consts) consts)]))

;; rows-over : Sel (Listof focus) consts -> (Listof Row)   the item's rows at each focus, %rowIndex
;; its ordinal
(define (rows-over s foci consts)
  (append* (for/list ([f (in-list foci)] [i (in-naturals)]) (item-rows s f consts i))))

;; item-rows : the rows of a select item at ONE focus — its own columns × nested selects × unionAll
(define (item-rows s focus consts idx)
  (product
   (append (if (pair? (sel-columns s))
               (list (list (for/list ([c (in-list (sel-columns s))])
                             (cons (col-name c) (cell c (eval-expr (col-expr c) focus consts idx))))))
               '())
           (for/list ([sub (in-list (sel-selects s))]) (sel-rows sub focus consts idx))
           (if (pair? (sel-unions s))
               (list (append* (for/list ([b (in-list (sel-unions s))]) (sel-rows b focus consts idx))))
               '()))))

;; cell : Col (Listof item) -> jsexpr   a column's value: a list when `collection`, else null or
;; the one item — several without `collection` is an error
(define (cell c items)
  (cond [(col-collection? c) (map item->jsexpr items)]
        [(null? items) 'null]
        [(null? (cdr items)) (item->jsexpr (car items))]
        [else (error 'eval-view "column ~a: path yields ~a items without collection=true" (col-name c) (length items))]))

;; null-row : the forEachOrNull empty case — each column path is evaluated over the EMPTY collection
;; (so element navigation propagates to null, while focus-independent paths like %rowIndex still
;; produce their value; of several values the first), recursing into nested/unionAll column sets
(define (null-row s consts)
  (append (for/list ([c (in-list (sel-columns s))])
            (define items (with-handlers ([exn:fail? (lambda (_) '())])
                            (fp-eval (expr-ast (col-expr c)) '() (make-env '() #:externals (hash-set consts "rowIndex" (list 0))))))
            (cons (col-name c) (cell c (if (or (col-collection? c) (null? items)) items (list (car items))))))
          (append-map (lambda (sub) (null-row sub consts)) (sel-selects s))
          (if (pair? (sel-unions s)) (null-row (car (sel-unions s)) consts) '())))

;; transitive-closure : (Listof Expr) focus -> all descendants reached by repeatedly applying
;; the paths, in DEPTH-FIRST preorder (matching the reference's row/index order); elements lacking
;; the path simply contribute nothing (a repeat path is inherently heterogeneous)
(define (transitive-closure xs focus consts)
  (let walk ([node focus])
    (append* (for*/list ([x (in-list xs)] [child (in-list (eval-tolerant x node consts 0))])
               (cons child (walk child))))))

;; ---- path evaluation --------------------------------------------------------
;; static-problem : Expr focus -> exn | #f   what FHIRPath's static pass says of the path over the
;; focus's type (an element the type lacks). It depends on the type alone, so it is asked once per
;; type, not once per resource and cell.
(define (static-problem x focus)
  (and (fhir? focus)
       (hash-ref! (expr-verdicts x) (fhir-type focus)
                  (lambda () (with-handlers ([exn:fail? values])
                               (analyze (expr-ast x) (fhir-type focus) #:strict? #f)
                               #f)))))

;; eval-expr : Expr focus consts idx -> (Listof item)   what `eval-fhirpath` does (the static pass,
;; then the evaluation), the first once per focus type
(define (eval-expr x focus consts idx)
  (cond [(static-problem x focus) => raise]
        [else (fp-eval (expr-ast x) (list focus)
                       (make-env (list focus) #:externals (hash-set consts "rowIndex" (list idx))))]))

;; eval-tolerant : like eval-expr, but an UNKNOWN-ELEMENT navigation yields no elements (forEach and
;; repeat paths are applied to heterogeneous foci); every other error — an unknown %constant, type
;; errors — still surfaces as a view error
(define (eval-tolerant x focus consts idx)
  (with-handlers ([(lambda (e) (and (exn:fail? e) (regexp-match? #px"no element" (exn-message e))))
                   (lambda (_) '())])
    (eval-expr x focus consts idx)))

;; ---- SOF-specific function rewrite ------------------------------------------
;; getResourceKey() -> id ; X.getReferenceKey([Type]) ->
;;   X[.where(reference.matches('^Type/…'))].reference.replaceMatches('^[^/]+/', '')
;; A pure structural rewrite over the prefab FHIRPath AST (nothing in the engine changes).
(define (rewrite-sof ast)
  (match ast
    [(fp-call t 'getResourceKey '()) (fp-invoke (and t (rewrite-sof t)) 'id)]
    [(fp-call t 'getReferenceKey args)
     (define t* (and t (rewrite-sof t)))
     (define typed
       (match args
         [(list (fp-invoke #f ty))
          (fp-call t* 'where
                   (list (fp-call (fp-invoke #f 'reference) 'matches
                                  (list (fp-lit (format "^~a/[^/]+$" ty))))))]
         [_ (if t* t* (fp-invoke #f 'reference))]))     ; untyped: keep the target as-is
     (fp-call (fp-invoke typed 'reference) 'replaceMatches (list (fp-lit "^[^/]+/") (fp-lit "")))]
    [(fp-call t n args) (fp-call (and t (rewrite-sof t)) n (map rewrite-sof args))]
    [(fp-invoke t n) (fp-invoke (and t (rewrite-sof t)) n)]
    [(fp-binop op l r) (fp-binop op (rewrite-sof l) (rewrite-sof r))]
    [(fp-unop op o) (fp-unop op (rewrite-sof o))]
    [(fp-index t i) (fp-index (rewrite-sof t) (rewrite-sof i))]
    [(fp-typeop op o ty) (fp-typeop op (rewrite-sof o) ty)]
    [_ ast]))

;; ---- item -> row-cell jsexpr -------------------------------------------------
;; item->jsexpr : a FHIRPath item -> the JSON value that lands in a row cell.
;; A FHIR primitive renders as its JSON scalar (lexeme-faithful — date/dateTime keep their string
;; form); System values produced by expressions (moments from boundary ops, decimals, …) follow.
(define (item->jsexpr item)
  (cond
    [(primitive-type? item) (primitive->jsexpr item)]
    [else (system->jsexpr item)]))

(define (system->jsexpr item)
  (define v (item->system item))
  (cond
    [(boolean? v) v]
    [(exact-integer? v) v]
    [(fp-long? v) (fp-long-v v)]
    [(fp-decimal? v) (string->number (decimal->string v))]
    [(string? v) v]
    ;; a Date-kind moment renders date-only (boundary ops may carry filled time components)
    [(and (moment? v) (eq? (moment-kind v) 'date))
     (car (string-split (regexp-replace #px"^@" (moment->string v) "") "T"))]
    [(moment? v) (regexp-replace #px"^@T?" (moment->string v) "")]
    [(fhir? v) (node->jsexpr v)]
    [(fhir? item) (node->jsexpr item)]
    [else (format "~a" v)]))

(module+ test
  (require rackunit json
           (only-in sql-on-fhir/model/types)
           (only-in fhir/serialize/from-json from-json)
           (only-in fhir/result/result ok-value))
  (define (mk js) (ok-value (from-json js #:lenient? #t)))
  (define pt (mk (hasheq 'resourceType "Patient" 'id "p1"
                         'name (list (hasheq 'family "Chalmers") (hasheq 'family "Windsor")))))
  (define view (mk (hasheq 'resourceType "ViewDefinition" 'status "active" 'resource "Patient"
                           'select (list (hasheq 'column (list (hasheq 'name "id" 'path "id")))
                                         (hasheq 'forEach "name"
                                                 'column (list (hasheq 'name "family" 'path "family")))))))
  (check-equal? (eval-view view (list pt))
                '(((id . "p1") (family . "Chalmers")) ((id . "p1") (family . "Windsor"))))
  (check-equal? (view-columns view) '(id family))
  ;; a view that names no resource type says so (it was `string->symbol: contract violation`)
  (check-exn #rx"eval-view: the view has no `resource`"
             (lambda () (eval-view (mk (hasheq 'resourceType "ViewDefinition" 'status "active"
                                               'select (list (hasheq 'column (list (hasheq 'name "id" 'path "id"))))))
                                   (list pt)))))
