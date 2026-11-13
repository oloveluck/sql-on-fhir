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

(require racket/contract racket/match racket/list racket/string
         (only-in fhir/model/node fhir? fhir-ref fhir-type)
         (only-in fhir/model/base primitive-type? primitive-type-value)
         (only-in fhir/model/leaf pv)
         (only-in fhir/primitives/primitives primitive->jsexpr)
         (only-in fhirpath/parser/parse parse-fhirpath)
         (only-in fhirpath/parser/ast fp-call fp-call? fp-call-target fp-call-name fp-call-args
                  fp-invoke fp-invoke? fp-invoke-target fp-invoke-name
                  fp-binop fp-binop? fp-binop-op fp-binop-lhs fp-binop-rhs
                  fp-unop fp-unop? fp-unop-op fp-unop-operand
                  fp-index fp-index? fp-index-target fp-index-idx
                  fp-typeop fp-typeop? fp-typeop-op fp-typeop-operand fp-typeop-type
                  fp-lit)
         (only-in fhirpath/eval eval-fhirpath)
         (only-in fhirpath/value item->system fp-quantity? fp-long? fp-long-v)
         (only-in fhirpath/decimal fp-decimal? decimal->string)
         (only-in fhirpath/temporal-ops moment? moment->string moment-kind)
         (only-in fhir/serialize/to-json node->jsexpr))

(provide
 (contract-out
  ;; eval-view : typed ViewDefinition node × resources -> rows (each an ordered alist)
  [eval-view    (-> fhir? (listof fhir?) (listof list?))]
  ;; view-columns : the view's column names, in declaration order
  [view-columns (-> fhir? (listof symbol?))]
  ;; rewrite-sof : FHIRPath AST -> AST   getResourceKey()/getReferenceKey(Type) as plain FHIRPath (the
  ;; workspace checks a view's paths after it, as the engine evaluates them)
  [rewrite-sof  (-> any/c any/c)]))

;; ---- typed-node field helpers ----------------------------------------------
;; fld : node key -> value|#f ; flds : node key -> (Listof value) ; pv from model/leaf
(define (fld n k) (fhir-ref n k #f))
(define (flds n k) (define v (fhir-ref n k '())) (if (list? v) v (list v)))
(define (pstr n k) (let ([v (fld n k)]) (and v (pv v))))

;; ---- entry ------------------------------------------------------------------
(define (eval-view view resources)
  (define consts (constants-env view))
  (define wheres (for/list ([w (in-list (flds view 'where))]) (parse-path (pstr w 'path))))
  (define rtype (string->symbol (or (pstr view 'resource)
                                    (error 'eval-view "the view has no `resource` (the type of resource it reads)"))))
  (define sels (flds view 'select))
  (append*
   (for/list ([r (in-list resources)]
              #:when (eq? (fhir-type r) rtype)
              #:when (passes-wheres? r wheres consts))
     (product-rows sels r consts 0))))

;; the resource must satisfy every where path — a where evaluating to a non-boolean is a VIEW error
(define (passes-wheres? r wheres consts)
  (for/and ([ast (in-list wheres)])
    (define v (map item->system (eval-path ast r consts 0)))
    (cond [(null? v) #f]
          [(and (null? (cdr v)) (boolean? (car v))) (car v)]
          [else (error 'eval-view "where path must resolve to a boolean, got ~a" v)])))

;; view-columns : declaration-order column names (for expectColumns)
(define (view-columns view)
  (define (of-sel s)
    (append (for/list ([c (in-list (flds s 'column))]) (string->symbol (pstr c 'name)))
            (append-map of-sel (flds s 'select))
            (let ([u (flds s 'unionAll)]) (if (pair? u) (of-sel (car u)) '()))))
  (append-map of-sel (flds view 'select)))

;; ---- the structural recursion over select items -----------------------------
;; product-rows : (Listof Sel) focus consts idx -> (Listof Row)   cartesian product of item row-sets
(define (product-rows sels focus consts idx)
  (for/fold ([rows (list '())])
            ([s (in-list sels)])
    (define item-rows (sel-rows s focus consts idx))
    (for*/list ([base (in-list rows)] [add (in-list item-rows)]) (append base add))))

;; sel-rows : Sel focus consts idx -> (Listof Row)   the rows of ONE select item
(define (sel-rows s focus consts idx)
  (define fe (pstr s 'forEach))
  (define feon (pstr s 'forEachOrNull))
  (define rep (map pv (flds s 'repeat)))
  (cond
    [(pair? rep)
     (define elems (transitive-closure rep focus consts))
     (if (null? elems) '() (append* (for/list ([e (in-list elems)] [i (in-naturals)]) (item-rows s e consts i))))]
    [(or fe feon)
     (define ast (parse-path (or fe feon)))       ; parse errors surface (an invalid view must error)
     (define elems (eval-tolerant ast focus consts idx))
     (cond
       [(pair? elems) (append* (for/list ([e (in-list elems)] [i (in-naturals)]) (item-rows s e consts i)))]
       [feon (list (null-row s consts))]          ; forEachOrNull: one row evaluated over the empty focus
       [else '()])]                               ; forEach: eliminates the row
    [else (item-rows s focus consts idx)]))

;; item-rows : the rows of a select item at ONE focus — its own columns × nested selects × unionAll
(define (item-rows s focus consts idx)
  (define col-row (columns-row (flds s 'column) focus consts idx))
  (define parts
    (append (if col-row (list (list col-row)) '())
            (for/list ([sub (in-list (flds s 'select))]) (sel-rows sub focus consts idx))
            (let ([u (flds s 'unionAll)])
              (cond [(null? u) '()]
                    [else
                     ;; branches must agree on column names AND order — a structural view error
                     (define shapes (map branch-columns u))
                     (unless (andmap (lambda (sh) (equal? sh (car shapes))) (cdr shapes))
                       (error 'eval-view "unionAll branches disagree on columns: ~a" shapes))
                     (list (append* (for/list ([b (in-list u)]) (sel-rows b focus consts idx))))]))))
  (for/fold ([rows (list '())]) ([p (in-list parts)])
    (for*/list ([base (in-list rows)] [add (in-list p)]) (append base add))))

;; branch-columns : Sel -> the branch's ordered column names (for unionAll congruence checking)
(define (branch-columns s)
  (append (for/list ([c (in-list (flds s 'column))]) (pstr c 'name))
          (append-map branch-columns (flds s 'select))
          (let ([u (flds s 'unionAll)]) (if (pair? u) (branch-columns (car u)) '()))))

;; columns-row : (Listof Column) focus -> Row|#f   one row of column values (or #f when no columns)
(define (columns-row cols focus consts idx)
  (and (pair? cols)
       (for/list ([c (in-list cols)])
         (define items (eval-path (parse-path (pstr c 'path)) focus consts idx))
         (define collection? (eq? (pstr c 'collection) #t))
         (cons (string->symbol (pstr c 'name))
               (cond
                 [collection? (map item->jsexpr items)]
                 [(null? items) 'null]
                 [(null? (cdr items)) (item->jsexpr (car items))]
                 [else (error 'eval-view "column ~a: path yields ~a items without collection=true"
                              (pstr c 'name) (length items))])))))

;; null-row : the forEachOrNull empty case — each column path is evaluated over the EMPTY collection
;; (so element navigation propagates to null, while focus-independent paths like %rowIndex still
;; produce their value), recursing into nested/unionAll column sets
(define (null-row s consts)
  (append (for/list ([c (in-list (flds s 'column))])
            (define items (with-handlers ([exn:fail? (lambda (_) '())])
                            (eval-fhirpath (parse-path (pstr c 'path)) '()
                                           #:externals (hash-set consts "rowIndex" (list 0))
                                           #:strict? #f)))
            (cons (string->symbol (pstr c 'name))
                  (cond [(eq? (pstr c 'collection) #t) (map item->jsexpr items)]
                        [(null? items) 'null]
                        [else (item->jsexpr (car items))])))
          (append-map (lambda (sub) (null-row sub consts)) (flds s 'select))
          (let ([u (flds s 'unionAll)]) (if (pair? u) (null-row (car u) consts) '()))))

;; transitive-closure : (Listof path-string) focus -> all descendants reached by repeatedly applying
;; the paths, in DEPTH-FIRST preorder (matching the reference's row/index order); elements lacking
;; the path simply contribute nothing (a repeat path is inherently heterogeneous)
(define (transitive-closure paths focus consts)
  (define asts (map parse-path paths))
  (define (step f)
    (append* (for/list ([a (in-list asts)]) (eval-tolerant a f consts 0))))
  (let walk ([node focus])
    (append* (for/list ([child (in-list (step node))])
               (cons child (walk child))))))

;; ---- constants + path evaluation --------------------------------------------
;; the %-externals hash from view.constant (value[x] -> a one-item collection) — computed once
(define (constants-env view)
  (for/fold ([h (hash)]) ([c (in-list (flds view 'constant))])
    (hash-set h (pstr c 'name) (constant-value c))))

;; the first value[x] field on a constant node (Coding of kinds is irrelevant — take any value*)
(define (constant-value c)
  (define names '(valueBase64Binary valueBoolean valueCanonical valueCode valueDate valueDateTime
                  valueDecimal valueId valueInstant valueInteger valueInteger64 valueOid
                  valuePositiveInt valueString valueTime valueUnsignedInt valueUri valueUrl valueUuid))
  (for/or ([n (in-list names)]) (let ([v (fld c n)]) (and v (list v)))))

;; parse-path : string -> AST  (memoized by parse-fhirpath) with the SOF-specific calls rewritten
(define (parse-path s) (rewrite-sof (parse-fhirpath s)))

;; eval-path : AST focus consts idx -> (Listof item)
(define (eval-path ast focus consts idx)
  (eval-fhirpath ast (list focus)
                 #:externals (hash-set consts "rowIndex" (list idx))
                 #:strict? #f))

;; eval-tolerant : like eval-path, but an UNKNOWN-ELEMENT navigation yields no elements (forEach and
;; repeat paths are applied to heterogeneous foci); every other error — bad syntax, unknown
;; %constant, type errors — still surfaces as a view error
(define (eval-tolerant ast focus consts idx)
  (with-handlers ([(lambda (e) (and (exn:fail? e) (regexp-match? #px"no element" (exn-message e))))
                   (lambda (_) '())])
    (eval-path ast focus consts idx)))

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
