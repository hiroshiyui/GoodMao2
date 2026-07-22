defmodule Goodmao2.NativeTest do
  use ExUnit.Case, async: true

  alias Goodmao2.Native

  describe "add/2" do
    test "adds two integers" do
      assert Native.add(2, 3) == 5
      assert Native.add(-4, 1) == -3
    end

    test "an out-of-range sum raises rather than panicking or wrapping across the boundary" do
      # i64 overflow returns a BadArg error term (surfaced as ArgumentError) instead of
      # unwinding a Rust panic into a NIF crash or silently wrapping to a negative number.
      max = 9_223_372_036_854_775_807

      assert_raise ArgumentError, fn -> Native.add(max, 1) end
    end
  end
end
