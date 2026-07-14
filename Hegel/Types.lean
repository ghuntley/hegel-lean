namespace Hegel

structure Date where
  year : Int32
  month : UInt8
  day : UInt8
  deriving Repr, BEq

structure Time where
  hour : UInt8
  minute : UInt8
  second : UInt8
  microsecond : UInt32 := 0
  deriving Repr, BEq

structure DateTime where
  date : Date
  time : Time
  deriving Repr, BEq

end Hegel
