import Lean

-- TODO: Fix documentation

-- Pretty much lifted from Hspec
inductive FailureReason
  | noReason
  | reason (descr : String := "")
  | noMatch (descr : String := "") (exp got : String)
  | error {ε α : Type} (descr : String := "") (ex : Except ε α)

def FailureReason.toString : FailureReason → String
  | .noReason              => "× Failure!"
  | .reason         descr  => descr
  | .noMatch descr exp got =>
    let msg := s!"Expected '{exp}' but got '{got}'"
    if descr.isEmpty then msg else s!"{descr}: {msg}"
  | .error   descr except  =>
    if descr.isEmpty then "Exception thrown" else s!"{descr}"

inductive Result
  | ok   (successMessage : String := "✓ Success!")
  | fail (reason : FailureReason := .noReason) -- (Maybe Location)

def Result.toString : Result → String
  | .ok   msg => msg
  | .fail rsn => rsn.toString

-- helper function for now, but can very easily add more robust descriptions in the generic specs
-- below
def ofBool : Bool → Result
  | true  => .ok
  | false => .fail

def Result.toBool : Result → Bool
  | .ok _ => true
  | _     => false

-- I went back and forth on this for a while, and arrived at this tentative definition of a Spec.
structure SpecOn {α : Type} (obj : α) where
  -- Specs can contain parameters to allow for an eventual way of writing specs
  testParam : Type
  -- The actual property that's being tested
  -- I wanted this to be a literal `Prop`, but dealing with the `DecidablePred`
  -- instance was annoying
  prop : testParam → Result

@[reducible] def equals {α : Type} [BEq α] (a b : α) : SpecOn () :=
  ⟨Unit, fun _ => ofBool $ a == b⟩

-- The idea is to write generic specs in the library like this one
@[reducible] def alwaysEquals {α β : Type} [BEq β] (f : α → β) (b : β) : SpecOn f :=
  ⟨α, fun a => ofBool $ f a == b⟩

-- Specs can also not contain parameters if they're specs about things that don't fit neatly into
-- a function type
@[reducible] def doesntContain {β : Type} [BEq β] (bx : List β) : SpecOn bx :=
  ⟨β, fun b => ofBool $ not $ bx.contains b⟩

@[reducible] def depDoesntContain {α β : Type} [BEq β] (f : α → List β) : SpecOn f :=
  ⟨α × β, fun (a, b) => ofBool $ not $ (f a).contains b⟩

@[reducible] def neverContains {α β : Type} [BEq β] (f : α → List β) (b : β) : SpecOn f :=
  ⟨α, fun a => ofBool $ not $ (f a).contains b⟩

section SectionExample

variable {α : Type} {a : α}

-- Basic Example type, as functionality is added it will probably get more complicated (custom messages
-- and configurations per example)
structure ExampleOf (spec : SpecOn a) where
  descr : Option String
  exam  : spec.testParam

abbrev ExamplesOf (spec : SpecOn a) := List $ ExampleOf spec

namespace ExampleOf

-- Tool to construct "default" examples from a given parameter, this will be helpful eventually when
-- examples become more complicated
def fromParam {spec : SpecOn a} (input : spec.testParam) : ExampleOf spec :=
  ⟨none, input⟩

def fromDescrParam {spec : SpecOn a} (descr : String) (input : spec.testParam) : ExampleOf spec :=
  ⟨descr, input⟩

-- Check the example, and get a `Result`
def check {α : Type} {a : α} {spec : SpecOn a} (exmp : ExampleOf spec) : Result :=
  spec.prop exmp.exam

-- This can eventually be expanded so a run does more than just IO
def run {α : Type} {a : α} {spec : SpecOn a} (exmp : ExampleOf spec) : Bool × String :=
  let res := exmp.check
  let msg : String := match exmp.descr with
    | none   => res.toString
    | some d => s!"it {d}: {res.toString}"
  (res.toBool, msg)

end ExampleOf

-- Ditto from above
namespace ExamplesOf

def fromParams {α : Type} {a : α} {spec : SpecOn a}
    (input : List spec.testParam) : ExamplesOf spec :=
  input.map <| .fromParam

def fromDescrParams {α : Type} {a : α} {spec : SpecOn a}
    (descr : String) (input : List spec.testParam) : ExamplesOf spec :=
  input.map <| .fromDescrParam descr

def check {α : Type} {a : α} {spec : SpecOn a} (exmp : ExamplesOf spec) : List Result :
  exmp.map ExampleOf.check

def run {α : Type} {a : α} {spec : SpecOn a} (exmps : ExamplesOf spec) : List (Bool × String) :=
  exmps.map ExampleOf.run

end ExamplesOf

end SectionExample

open Lean

def getBool! : Expr → Bool
  | .const ``Bool.true  .. => true
  | .const ``Bool.false .. => false
  | _                      => unreachable!

def getStr! : Expr → String
  | .lit (.strVal s) _ => s
  | _                  => panic! "not Expr.lit!"

def recoverTestResult (res : Expr) : Bool × String :=
  (getBool! $ res.getArg! 2, getStr! $ res.getArg! 3)

open Meta Elab Command Term in
elab "#spec " term:term : command =>
  liftTermElabM `assert do
    let term ← elabTerm term none
    synthesizeSyntheticMVarsNoPostponing
    let type ← inferType term
    if type.isAppOf ``ExampleOf then
      -- `Bool × String`
      let res ← reduce (← mkAppM ``ExampleOf.run #[term])
      dbg_trace res.getArg! 3
      match recoverTestResult res with
      | (true,  msg) => logInfo msg
      | (false, msg) => throwError msg
    else if type.isAppOf ``ExamplesOf then
       -- `List (Bool × String)`
      let res ← reduce (← mkAppM ``ExamplesOf.run #[term])
      match res.listLit? with
      | none => unreachable!
      | some (_, res) =>
        let res := res.map recoverTestResult
        let success? := res.foldl (init := true) fun acc (b, _) => acc && b
        let msg' : String := "\n".intercalate $ res.map fun (_, msg) => msg
        if success? then logInfo msg' else throwError msg'
    else throwError "Invalid term to run '#spec' with"

def foo (n : Nat) : Nat := n

-- Once we have generic specs above, we can easily construct specs for particular examples
-- The idea is to hook this into a version of the syntax Arthur implemented in `YatimaSpec.lean`
@[reducible] def fooSpec : SpecOn foo := alwaysEquals foo 4

-- Can create examples for the specs also using .fromParam
def fooExample  : ExampleOf fooSpec  := .fromDescrParam "this message" 4
def fooExamples : ExamplesOf fooSpec := .fromParams [2,3,4,5,6,6]

def fooExamples' : ExamplesOf fooSpec := .fromDescrParams "hihi" [2,3,4,5,6,6]

#spec fooExample
