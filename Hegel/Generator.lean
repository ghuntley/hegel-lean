namespace Hegel

/-- The frontend-facing choice source. Native test cases implement this through libhegel. -/
class DataSource (m : Type → Type) where
  chooseNat : Nat → Nat → m Nat
  chooseBool : m Bool

/-- A compositional value generator, parameterized by the choice source effect. -/
structure Generator (m : Type → Type) (α : Type) where
  generate : m α

namespace Generator

def pure [Pure m] (value : α) : Generator m α := ⟨Pure.pure value⟩

def map [Functor m] (f : α → β) (generator : Generator m α) : Generator m β :=
  ⟨f <$> generator.generate⟩

def flatMap [Monad m] (generator : Generator m α)
    (f : α → Generator m β) : Generator m β :=
  ⟨generator.generate >>= fun value => (f value).generate⟩

def zip [Monad m] (left : Generator m α) (right : Generator m β) : Generator m (α × β) :=
  flatMap left fun a => map (fun b => (a, b)) right

def zip3 [Monad m] (first : Generator m α) (second : Generator m β)
    (third : Generator m γ) : Generator m (α × β × γ) :=
  flatMap first fun a => flatMap second fun b => map (fun c => (a, b, c)) third

def booleans [DataSource m] : Generator m Bool := ⟨DataSource.chooseBool⟩

def naturals [DataSource m] (min max : Nat) : Generator m Nat :=
  ⟨DataSource.chooseNat min max⟩

def oneOf [Monad m] [DataSource m] (first : Generator m α)
    (rest : Array (Generator m α)) : Generator m α := ⟨do
  let index ← DataSource.chooseNat 0 rest.size
  if index = 0 then first.generate
  else match rest[index - 1]? with
    | some generator => generator.generate
    | none => first.generate⟩

def elements [Monad m] [DataSource m] (first : α) (rest : Array α) : Generator m α :=
  oneOf (pure first) (rest.map pure)

def option [Monad m] [DataSource m] (element : Generator m α) : Generator m (Option α) :=
  oneOf (pure none) #[map some element]

def list [Monad m] [DataSource m] (element : Generator m α)
    (minSize := 0) (maxSize := 10) : Generator m (List α) := ⟨do
  let size ← DataSource.chooseNat minSize maxSize
  let mut result := []
  for _ in [0:size] do result := (← element.generate) :: result
  return result.reverse⟩

end Generator
end Hegel
