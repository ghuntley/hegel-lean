namespace Hegel.TwosComplement

private partial def naturalBytes (value : Nat) : List UInt8 :=
  if value < 256 then [UInt8.ofNat value]
  else UInt8.ofNat (value % 256) :: naturalBytes (value / 256)

private partial def fixedNaturalBytes (value width : Nat) : List UInt8 :=
  if width = 0 then []
  else UInt8.ofNat (value % 256) :: fixedNaturalBytes (value / 256) (width - 1)

private partial def negativeWidth (magnitude width : Nat) : Nat :=
  if magnitude <= 2 ^ (8 * width - 1) then width
  else negativeWidth magnitude (width + 1)

private def listToByteArray (bytes : List UInt8) : ByteArray :=
  bytes.foldl (fun result byte => result.push byte) ByteArray.empty

/-- Minimal signed two's-complement little-endian representation. -/
def encode (value : Int) : ByteArray :=
  if value >= 0 then
    let bytes := naturalBytes value.toNat
    let bytes := if bytes.getLast! >= 128 then bytes ++ [0] else bytes
    listToByteArray bytes
  else
    let width := negativeWidth value.natAbs 1
    let modulus : Nat := 2 ^ (8 * width)
    let representation := (Int.ofNat modulus + value).toNat
    listToByteArray (fixedNaturalBytes representation width)

/-- Decode signed two's-complement little-endian bytes. Empty input is rejected. -/
def decode (bytes : ByteArray) : Option Int :=
  if bytes.isEmpty then none
  else
    let unsigned := Id.run do
      let mut value := 0
      let mut factor := 1
      for index in [0:bytes.size] do
        value := value + bytes[index]!.toNat * factor
        factor := factor * 256
      return value
    let signSet := bytes[bytes.size - 1]! >= 128
    if signSet then
      some (Int.ofNat unsigned - Int.ofNat (2 ^ (8 * bytes.size)))
    else
      some (Int.ofNat unsigned)

end Hegel.TwosComplement
