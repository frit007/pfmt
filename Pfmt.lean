namespace Pfmt

/-
TODO list: nextcloud
-/

/--
A decision tree for rendering a document. If a `Doc` does not contain a `Doc.choice`
constructor we call it "choice free". Usually we view a `Doc` in a rendering
context that consists of:
1. A width limit `W` which we attempt to respect when rendering a `Doc`.
2. A current column position `c`.
3. An indentation level `i`.
-/
inductive Doc where
/--
Render a `String` that does not contain newlines.
-/
| text (s : String)
/--
Render a newline.
-/
| newline
/--
Concatenate two documents unaligned. If `l` is the chars that we get from `lhs`
and `r` from `rhs` they will render as:
```
llllllllll
lllllrrrrrrrr
rrrrrr
```
-/
| concat (lhs rhs : Doc)
/--
Render `doc` width the indentation level increased by `nesting`.
-/
| nest (nesting : Nat) (doc : Doc)
/--
Render `doc` with the indentation level set to the column position.
-/
| align (doc : Doc)
/--
Make a choice between rendering either `lhs` or `rhs` by picking the prettier variant.
-/
| choice (lhs rhs : Doc)
deriving Inhabited

instance : Append Doc where
  append lhs rhs := .concat lhs rhs

/--
This typeclass allows us to calculate the cost of a `Doc`. We use it to find
the prettier document in `Doc.choice`. A valid `Cost` instance must satisfy
the laws defined in `LawfulCost`.
-/
class Cost (χ : Type) extends LE χ, Add χ where
  /--
  Compute the cost of a `String` of length `length`, rendered at `col` with a certain
  `widhLimit`.
  -/
  text : (widthLimit : Nat) → (col : Nat) → (length : Nat) → χ
  /--
  Compute the cost of a new line.
  -/
  nl : (indent : Nat) → χ

/--
A `Measure` contains a `Doc` along with meta information from the rendering process.
We use it in `MeasureSet`s to find the prettiest document.
-/
structure Measure (χ : Type) where
  /--
  The last column position if we choose to use `layout`.
  -/
  last : Nat
  /--
  The cost of using `layout`.
  -/
  cost : χ
  /--
  The choice less document that we are contemplating to use.
  -/
  layout : Doc
deriving Inhabited

instance [Cost χ] : LE (Measure χ) where
  le lhs rhs := lhs.last ≤ rhs.last ∧ lhs.cost ≤ rhs.cost

instance [Cost χ] [DecidableRel (LE.le (α := χ))] (lhs rhs : Measure χ) : Decidable (lhs ≤ rhs) :=
  inferInstanceAs (Decidable (lhs.last ≤ rhs.last ∧ lhs.cost ≤ rhs.cost))

/--
Lifting `Doc.concat` to `Measure`.
-/
def Measure.concat [Cost χ] (lhs rhs : Measure χ) : Measure χ :=
  { last := rhs.last, cost := lhs.cost + rhs.cost, layout := lhs.layout ++ rhs.layout }

instance [Cost χ] : Append (Measure χ) where
  append := Measure.concat

/--
A set of `Measure`s out of which we will pick an optimal `Doc` in the end.
-/
inductive MeasureSet (χ : Type) where
/--
If a branch of the rendering process would end up producing only invalid documents
it produces a `MeasureSet.tainted`. It consists of a thunk that we can evaluate
to a `Measure` if we end up finding no way to produce a valid document.
-/
| tainted (m : Unit → Measure χ)
/--
A list of `Measure`s that form a Pareto front for our rendering problem.
This list is ordered by the last line length in strict ascending order.
-/
| set (ms : List (Measure χ))
deriving Inhabited

/--
If `MeasureSet.merge` receives two `MeasureSet.set` we use this operation to combine them
into a new Pareto front with correct ordering.
-/
private def mergeSet [Cost χ] [DecidableRel (LE.le (α := χ))] (lhs rhs : List (Measure χ)) : List (Measure χ) :=
  match h1:lhs, h2:rhs with
  | [], _ => rhs
  | _, [] => lhs
  | l :: ls, r :: rs =>
    if l ≤ r then
      mergeSet lhs rs
    else if r ≤ l then
      mergeSet ls rhs
    else if l.last > r.last then
      l :: mergeSet ls rhs
    else
      r :: mergeSet lhs rs
termination_by mergeSet lhs rhs => lhs.length + rhs.length

/--
Combine the results from two `MeasureSet`s.
-/
def MeasureSet.merge [Cost χ] [DecidableRel (LE.le (α := χ))] (lhs rhs : MeasureSet χ) : MeasureSet χ :=
  match lhs, rhs with
  | _, .tainted .. => lhs
  | .tainted .., _ => rhs
  | .set lhs, .set rhs => .set (mergeSet lhs rhs)

/--
This function efficiently computes a Pareto front for the problem of rendering
a `Doc` at a certain column position with a certain indentation level and width limit.
-/
def Doc.resolve [Inhabited χ] [Cost χ] [DecidableRel (LE.le (α := χ))] (doc : Doc) (col indent widthLimit : Nat) : MeasureSet χ :=
  -- If we were to exceed the widthLimit we delay any attempt to optimize
  -- the layout of `doc` in hopes that another branch of this function finds
  -- a non tainted `MeasureSet`.
  let exceeds :=
    match doc with
    | .text s => indent > widthLimit || col + s.length > widthLimit
    | _ => indent > widthLimit || col > widthLimit
  if exceeds then
    .tainted (fun _ =>
      match core doc col indent with
      | .tainted m => m ()
      | .set (m :: _) => m
      | .set [] => panic! "Empty measure sets are impossible"
    )
  else
    core doc col indent
where
  /--
  The core resolver that actually computes the `MeasureSet`s that result from rendering `doc`
  in the given context.
  -/
  core (doc : Doc) (col : Nat) (indent : Nat) : MeasureSet χ :=
    -- If we end up in this function we know that this cannot exceed the widthLimit
    -- and can thus savely return a set in all cases except concat.
    match doc with
    | .text s =>
      .set [{
        last := col + s.length,
        cost := Cost.text widthLimit col s.length
        layout := doc
      }]
    | .newline =>
      .set [{
        last := indent,
        cost := Cost.nl indent,
        layout := doc
      }]
    | .concat lhs rhs => processConcat (fun l => core rhs l.last indent) (core lhs col indent)
    | .choice lhs rhs => MeasureSet.merge (core lhs col indent) (core rhs col indent)
    | .nest indentOffset doc => core doc col (indent + indentOffset)
    | .align doc => core doc col col

  /--
  Compute the set that contains the concatenations of all possible lhs measures
  with their corresponding rhs measure.
  -/
  processConcat (processLeft : Measure χ → MeasureSet χ) (leftSet : MeasureSet χ) : MeasureSet χ :=
    match leftSet with
    | .tainted leftThunk =>
      -- If the lhs is already tainted we can wrap the computation of the rhs
      -- in a tainted thunk, thus prunning it away.
      .tainted (fun _ =>
        let left := leftThunk ()
        match processLeft left with
        | .tainted rightThunk => left ++ rightThunk ()
        | .set (right :: _) => left ++ right
        | .set [] => panic! "Empty measure sets are impossible"
      )
    | .set lefts =>
       let concatOneWithRight (l : Measure χ) : MeasureSet χ :=
         -- This is an optimized version of dedup from the paper. We use it to maintain
         -- the Pareto front invariant.
         let rec dedup (rights result : List (Measure χ)) (currentBest : Measure χ) : List (Measure χ) :=
           match rights with
           | [] => List.reverse (currentBest :: result)
           | r :: rights =>
             let current := l ++ r
             if current.cost ≤ currentBest.cost then
               dedup rights result current
             else
               dedup rights (currentBest :: result) current
         match processLeft l with
         | .tainted rightThunk => .tainted (fun _ => l ++ rightThunk ())
         | .set (r :: rights) => .set (dedup rights [] (l ++ r))
         | .set [] => panic! "Empty measure sets are impossible"

       let rec concatAllWithRight (lefts : List (Measure χ)) : MeasureSet χ :=
         match lefts with
         | [] => panic! "Empty measure sets are impossible"
         | [l] => concatOneWithRight l
         | l :: ls => MeasureSet.merge (concatOneWithRight l) (concatAllWithRight ls)
       concatAllWithRight lefts

structure PrintResult (χ : Type) where
  layout : String
  isTainted : Bool
  cost : χ
deriving Inhabited

/--
Render a choice less `Doc`.
-/
def Doc.render (doc : Doc) (col : Nat) : String :=
  Array.foldl (init := "") (· ++ "\n" ++ ·) (go doc col 0)
where
  /--
  A straight forward implementation of the choice less document semantics from Fig 8.
  -/
  go (doc : Doc) (col indent : Nat) : Array String := Id.run do
    match doc with
    | .text str => #[str]
    | .newline => #["", "".pushn ' ' indent]
    | .align doc => go doc col col
    | .nest indentOffset doc => go doc col (indent + indentOffset)
    | .concat lhs rhs =>
      let mut lrender := go lhs col indent
      if lrender.size == 1 then
        let lfirst := lrender[0]!
        let mut rrender := go rhs (col + lfirst.length) indent
        let rfirst := rrender[0]!
        rrender := rrender.set! 0 (lfirst ++ rfirst)
        rrender
      else
        let llast := lrender[lrender.size - 1]!
        let rrender := go rhs (llast.length) indent
        let rfirst := rrender[0]!
        lrender := lrender.set! (lrender.size - 1) (llast ++ rfirst)
        lrender := lrender ++ rrender[0:(rrender.size - 1)]
        lrender
    | .choice .. => panic! "Not a choice less document"

#eval IO.println <| Doc.render (.text "f" ++ .text "(" ++ .align (.newline ++ .text "x") ++ .newline ++ .text ")") 0

/--
Find an optimal layout for a document and render it.
-/
def Doc.print [Inhabited χ] [Cost χ] [DecidableRel (LE.le (α := χ))] (doc : Doc) (col widthLimit : Nat) : PrintResult χ :=
  let measures := doc.resolve (χ := χ) col 0 widthLimit
  let (measure, isTainted) :=
    match measures with
    | .tainted thunk => (thunk (), true)
    | .set (measure :: _) => (measure, false)
    | .set [] => panic! "Empty measure sets are impossible"
  {
    layout := doc.render col,
    isTainted := isTainted,
    cost := measure.cost
  }

def Doc.comma : Doc := .text ","
def Doc.lbrack : Doc := .text "["
def Doc.rbrack : Doc := .text "]"
def Doc.lbrace : Doc := .text "{"
def Doc.rbrace : Doc := .text "}"
def Doc.lparen : Doc := .text "("
def Doc.rparen : Doc := .text ")"
def Doc.dquote : Doc := .text "\""
def Doc.empty : Doc := .text ""
def Doc.space : Doc := .text " "

structure DefaultCost where
  widthCost : Nat
  lineCost : Nat
  deriving Inhabited, Repr

def DefaultCost.add (lhs rhs : DefaultCost) : DefaultCost :=
  { widthCost := lhs.widthCost + rhs.widthCost, lineCost := lhs.lineCost + rhs.lineCost }

instance : Add DefaultCost where
  add := DefaultCost.add

def DefaultCost.le (lhs rhs : DefaultCost) : Bool :=
  if lhs.widthCost == rhs.widthCost then lhs.lineCost ≤ rhs.lineCost else lhs.widthCost < rhs.widthCost

instance foo : LE DefaultCost where
  le lhs rhs := DefaultCost.le lhs rhs

instance : DecidableRel (LE.le (α := DefaultCost)) := fun _ _ => Bool.decEq _ _

def DefaultCost.text (widthLimit : Nat) (col : Nat) (length : Nat) : DefaultCost :=
  if col + length > widthLimit then
    let a := max widthLimit col - widthLimit
    let b := col + length - max widthLimit col
    { widthCost := b * (2 * a + b), lineCost := 0 }
  else
    { widthCost := 0, lineCost := 0 }

def DefaultCost.nl (_indent : Nat) : DefaultCost :=
  { widthCost := 0, lineCost := 1 }

instance : Cost DefaultCost where
  text := DefaultCost.text
  nl := DefaultCost.nl

end Pfmt
