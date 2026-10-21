defmodule OptimalEngine.Store.Postgres.Extension do
  @moduledoc """
  Postgrex extensions that encode parameters with SQLite's type affinity and
  decode results the way SQLite returns them.

  The extensions under `OptimalEngine.Store.Postgres.Extensions` take priority
  over Postgrex's own for the types they match (see
  `OptimalEngine.Store.Postgres.Types`); every other type keeps the Postgrex
  default. The conversion rules live in `OptimalEngine.Store.Postgres.Affinity`.
  """

  @doc false
  # The shared part of one extension: init, matching and the binary format.
  defmacro __using__(opts) do
    matching = Keyword.fetch!(opts, :matching)

    quote do
      @moduledoc false
      @behaviour Postgrex.Extension

      @impl Postgrex.Extension
      def init(_opts), do: nil

      @impl Postgrex.Extension
      def matching(_state), do: unquote(matching)

      @impl Postgrex.Extension
      def format(_state), do: :binary
    end
  end
end

defmodule OptimalEngine.Store.Postgres.Extensions.Text do
  use OptimalEngine.Store.Postgres.Extension,
    matching: [send: "textsend", send: "varcharsend", send: "bpcharsend", send: "unknownsend"]

  @impl Postgrex.Extension
  def encode(_state) do
    quote location: :keep do
      value ->
        text = OptimalEngine.Store.Postgres.Affinity.to_text(value)
        [<<byte_size(text)::signed-size(32)>> | text]
    end
  end

  @impl Postgrex.Extension
  def decode(_state) do
    quote location: :keep do
      <<len::signed-size(32), value::binary-size(len)>> -> :binary.copy(value)
    end
  end
end

defmodule OptimalEngine.Store.Postgres.Extensions.Int8 do
  use OptimalEngine.Store.Postgres.Extension, matching: [send: "int8send"]

  @impl Postgrex.Extension
  def encode(_state) do
    quote location: :keep do
      value ->
        int =
          OptimalEngine.Store.Postgres.Affinity.to_integer(
            value,
            -9_223_372_036_854_775_808..9_223_372_036_854_775_807
          )

        <<8::signed-size(32), int::signed-size(64)>>
    end
  end

  @impl Postgrex.Extension
  def decode(_state) do
    quote location: :keep do
      <<8::signed-size(32), int::signed-size(64)>> -> int
    end
  end
end

defmodule OptimalEngine.Store.Postgres.Extensions.Int4 do
  use OptimalEngine.Store.Postgres.Extension, matching: [send: "int4send"]

  @impl Postgrex.Extension
  def encode(_state) do
    quote location: :keep do
      value ->
        int =
          OptimalEngine.Store.Postgres.Affinity.to_integer(
            value,
            -2_147_483_648..2_147_483_647
          )

        <<4::signed-size(32), int::signed-size(32)>>
    end
  end

  @impl Postgrex.Extension
  def decode(_state) do
    quote location: :keep do
      <<4::signed-size(32), int::signed-size(32)>> -> int
    end
  end
end

defmodule OptimalEngine.Store.Postgres.Extensions.Int2 do
  use OptimalEngine.Store.Postgres.Extension, matching: [send: "int2send"]

  @impl Postgrex.Extension
  def encode(_state) do
    quote location: :keep do
      value ->
        int = OptimalEngine.Store.Postgres.Affinity.to_integer(value, -32_768..32_767)
        <<2::signed-size(32), int::signed-size(16)>>
    end
  end

  @impl Postgrex.Extension
  def decode(_state) do
    quote location: :keep do
      <<2::signed-size(32), int::signed-size(16)>> -> int
    end
  end
end

defmodule OptimalEngine.Store.Postgres.Extensions.Float8 do
  use OptimalEngine.Store.Postgres.Extension, matching: [send: "float8send"]

  @impl Postgrex.Extension
  def encode(_state) do
    quote location: :keep do
      value ->
        float = OptimalEngine.Store.Postgres.Affinity.to_float(value)
        <<8::signed-size(32), float::float-size(64)>>
    end
  end

  @impl Postgrex.Extension
  def decode(_state) do
    quote location: :keep do
      <<8::signed-size(32), float::float-size(64)>> -> float
    end
  end
end

defmodule OptimalEngine.Store.Postgres.Extensions.Float4 do
  use OptimalEngine.Store.Postgres.Extension, matching: [send: "float4send"]

  @impl Postgrex.Extension
  def encode(_state) do
    quote location: :keep do
      value ->
        float = OptimalEngine.Store.Postgres.Affinity.to_float(value)
        <<4::signed-size(32), float::float-size(32)>>
    end
  end

  @impl Postgrex.Extension
  def decode(_state) do
    quote location: :keep do
      <<4::signed-size(32), float::float-size(32)>> -> float
    end
  end
end

defmodule OptimalEngine.Store.Postgres.Extensions.Bytea do
  use OptimalEngine.Store.Postgres.Extension, matching: [send: "byteasend"]

  @impl Postgrex.Extension
  def encode(_state) do
    quote location: :keep do
      value ->
        bytes = OptimalEngine.Store.Postgres.Affinity.to_bytes(value)
        [<<byte_size(bytes)::signed-size(32)>> | bytes]
    end
  end

  @impl Postgrex.Extension
  def decode(_state) do
    quote location: :keep do
      <<len::signed-size(32), value::binary-size(len)>> -> :binary.copy(value)
    end
  end
end

defmodule OptimalEngine.Store.Postgres.Extensions.Bool do
  use OptimalEngine.Store.Postgres.Extension, matching: [send: "boolsend"]

  @impl Postgrex.Extension
  def encode(_state) do
    quote location: :keep do
      value ->
        case OptimalEngine.Store.Postgres.Affinity.to_boolean(value) do
          true -> <<1::signed-size(32), 1>>
          false -> <<1::signed-size(32), 0>>
        end
    end
  end

  # SQLite has no boolean: a comparison in a select list returns 1 or 0.
  @impl Postgrex.Extension
  def decode(_state) do
    quote location: :keep do
      <<1::signed-size(32), byte>> -> min(byte, 1)
    end
  end
end

defmodule OptimalEngine.Store.Postgres.Extensions.Json do
  use OptimalEngine.Store.Postgres.Extension, matching: [type: "json"]

  # JSON stays text, as SQLite's JSON functions return it.
  @impl Postgrex.Extension
  def encode(_state) do
    quote location: :keep do
      value ->
        text = OptimalEngine.Store.Postgres.Affinity.to_text(value)
        [<<byte_size(text)::signed-size(32)>> | text]
    end
  end

  @impl Postgrex.Extension
  def decode(_state) do
    quote location: :keep do
      <<len::signed-size(32), value::binary-size(len)>> -> :binary.copy(value)
    end
  end
end

defmodule OptimalEngine.Store.Postgres.Extensions.Jsonb do
  use OptimalEngine.Store.Postgres.Extension, matching: [type: "jsonb"]

  # The binary jsonb format is a version byte (1) followed by the JSON text.
  @impl Postgrex.Extension
  def encode(_state) do
    quote location: :keep do
      value ->
        text = OptimalEngine.Store.Postgres.Affinity.to_text(value)
        [<<byte_size(text) + 1::signed-size(32), 1>> | text]
    end
  end

  @impl Postgrex.Extension
  def decode(_state) do
    quote location: :keep do
      <<len::signed-size(32), value::binary-size(len)>> ->
        OptimalEngine.Store.Postgres.Extensions.Jsonb.text(value)
    end
  end

  @doc false
  def text(<<1, json::binary>>), do: :binary.copy(json)
end
