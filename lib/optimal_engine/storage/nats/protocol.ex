defmodule OptimalEngine.Storage.NATS.Protocol do
  @moduledoc """
  The NATS client protocol as pure functions: frames parsed out of a byte
  buffer, and the commands a client sends encoded to iodata. No socket here,
  so the long-lived client (`OptimalEngine.Storage.NATS.Connection`) and the
  tests share one parser.

  `parse/1` returns every complete frame in the buffer and the bytes left
  over (a partial line, or a message whose payload has not all arrived yet).
  Frames:

    * `{:info, map}`, `:ping`, `:pong`, `:ok`, `{:err, message}`
    * `{:msg, %{subject:, sid:, reply:, headers:, status:, description:, payload:}}`:
      a `MSG` or an `HMSG`. `headers` is a map of header name to value (the
      last one wins for a repeated name), `status` the status code of an
      `HMSG` whose header line carries one (`"404"`, `"408"`, `"503"`), as
      JetStream answers a pull that found nothing or a subject nobody serves.

  A frame the parser does not know is `{:unknown, line}`, never a raise; a
  `MSG` line that does not parse is `{:error, :bad_frame}` and stops the
  parse, because nothing after it can be framed.
  """

  @crlf "\r\n"

  @type msg :: %{
          subject: String.t(),
          sid: String.t(),
          reply: String.t() | nil,
          headers: %{optional(String.t()) => String.t()},
          status: String.t() | nil,
          description: String.t() | nil,
          payload: binary()
        }

  @type frame ::
          {:info, map()}
          | :ping
          | :pong
          | :ok
          | {:err, String.t()}
          | {:msg, msg()}
          | {:unknown, String.t()}

  @doc "Every complete frame in `buffer`, oldest first, and the rest."
  @spec parse(binary()) :: {:ok, [frame()], binary()} | {:error, :bad_frame}
  def parse(buffer) when is_binary(buffer), do: parse(buffer, [])

  defp parse(buffer, acc) do
    case :binary.split(buffer, @crlf) do
      [_partial] ->
        {:ok, Enum.reverse(acc), buffer}

      [line, rest] ->
        case frame(line, rest) do
          {:ok, frame, rest} -> parse(rest, [frame | acc])
          :incomplete -> {:ok, Enum.reverse(acc), buffer}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp frame("MSG " <> args, rest) do
    case String.split(args, " ", trim: true) do
      [subject, sid, reply, size] -> body(subject, sid, reply, nil, size, rest)
      [subject, sid, size] -> body(subject, sid, nil, nil, size, rest)
      _ -> {:error, :bad_frame}
    end
  end

  defp frame("HMSG " <> args, rest) do
    case String.split(args, " ", trim: true) do
      [subject, sid, reply, header_size, size] -> body(subject, sid, reply, header_size, size, rest)
      [subject, sid, header_size, size] -> body(subject, sid, nil, header_size, size, rest)
      _ -> {:error, :bad_frame}
    end
  end

  defp frame("INFO " <> json, rest) do
    case Jason.decode(json) do
      {:ok, %{} = info} -> {:ok, {:info, info}, rest}
      _ -> {:ok, {:unknown, "INFO"}, rest}
    end
  end

  defp frame("-ERR" <> message, rest),
    do: {:ok, {:err, message |> String.trim() |> String.trim("'")}, rest}

  defp frame(line, rest) do
    case line |> String.trim() |> String.upcase() do
      "PING" -> {:ok, :ping, rest}
      "PONG" -> {:ok, :pong, rest}
      "+OK" -> {:ok, :ok, rest}
      _ -> {:ok, {:unknown, line}, rest}
    end
  end

  # The payload follows the control line and ends with CRLF; until all of it
  # is in the buffer the frame is incomplete and the line stays unconsumed.
  defp body(subject, sid, reply, header_size, size, rest) do
    with {total, ""} <- Integer.parse(size),
         {:ok, header_bytes} <- header_bytes(header_size, total) do
      if byte_size(rest) >= total + 2 do
        <<data::binary-size(total), @crlf, rest::binary>> = rest
        <<header_block::binary-size(header_bytes), payload::binary>> = data
        {status, description, headers} = headers(header_block)

        {:ok,
         {:msg,
          %{
            subject: subject,
            sid: sid,
            reply: reply,
            headers: headers,
            status: status,
            description: description,
            payload: payload
          }}, rest}
      else
        :incomplete
      end
    else
      _ -> {:error, :bad_frame}
    end
  end

  defp header_bytes(nil, _total), do: {:ok, 0}

  defp header_bytes(value, total) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 and n <= total -> {:ok, n}
      _ -> :error
    end
  end

  @doc """
  The status, its description and the header map of a header block
  (`NATS/1.0[ <status>[ <description>]]\\r\\n<Name>: <value>\\r\\n...\\r\\n`).
  An empty block is no status and no headers.
  """
  @spec headers(binary()) :: {String.t() | nil, String.t() | nil, map()}
  def headers(""), do: {nil, nil, %{}}

  def headers(block) do
    [first | lines] = String.split(block, @crlf)

    {status, description} =
      case String.split(String.trim(first), " ", parts: 3) do
        ["NATS/1.0", status, description] -> {status, description}
        ["NATS/1.0", status] -> {status, nil}
        _ -> {nil, nil}
      end

    headers =
      for line <- lines,
          line != "",
          [name, value] <- [String.split(line, ":", parts: 2)],
          into: %{} do
        {String.trim(name), String.trim(value)}
      end

    {status, description, headers}
  end

  # ---------------------------------------------------------------------------
  # Encoding
  # ---------------------------------------------------------------------------

  @doc "`CONNECT` with its options."
  @spec connect(map()) :: iodata()
  def connect(options), do: ["CONNECT ", Jason.encode!(options), @crlf]

  @doc "`PING`."
  @spec ping() :: iodata()
  def ping, do: "PING\r\n"

  @doc "`PONG`."
  @spec pong() :: iodata()
  def pong, do: "PONG\r\n"

  @doc "`SUB <subject> <sid>`."
  @spec sub(String.t(), String.t() | integer()) :: iodata()
  def sub(subject, sid), do: ["SUB ", subject, " ", to_string(sid), @crlf]

  @doc "`UNSUB <sid>`."
  @spec unsub(String.t() | integer()) :: iodata()
  def unsub(sid), do: ["UNSUB ", to_string(sid), @crlf]

  @doc """
  A publish: `PUB` without headers, `HPUB` with them. `reply` may be `nil`.
  Header names and values must not carry CR or LF; such a header is refused
  with `ArgumentError` rather than letting it end the header block early.
  """
  @spec pub(String.t(), String.t() | nil, iodata(), map() | [{String.t(), String.t()}]) ::
          iodata()
  def pub(subject, reply, payload, headers \\ %{})

  def pub(subject, reply, payload, headers) when headers == %{} or headers == [] do
    payload = IO.iodata_to_binary(payload)

    [
      "PUB ",
      subject,
      reply_part(reply),
      " ",
      Integer.to_string(byte_size(payload)),
      @crlf,
      payload,
      @crlf
    ]
  end

  def pub(subject, reply, payload, headers) do
    payload = IO.iodata_to_binary(payload)
    block = header_block(headers)
    total = byte_size(block) + byte_size(payload)

    [
      "HPUB ",
      subject,
      reply_part(reply),
      " ",
      Integer.to_string(byte_size(block)),
      " ",
      Integer.to_string(total),
      @crlf,
      block,
      payload,
      @crlf
    ]
  end

  defp reply_part(nil), do: ""
  defp reply_part(reply), do: [" ", reply]

  @doc "The header block for `headers`, `NATS/1.0` first and an empty line last."
  @spec header_block(map() | [{String.t(), String.t()}]) :: binary()
  def header_block(headers) do
    lines =
      Enum.map(headers, fn {name, value} ->
        name = to_string(name)
        value = to_string(value)

        if String.contains?(name, ["\r", "\n", ":"]) or String.contains?(value, ["\r", "\n"]),
          do: raise(ArgumentError, "a NATS header may not carry CR, LF or a colon in its name")

        [name, ": ", value, @crlf]
      end)

    IO.iodata_to_binary(["NATS/1.0", @crlf, lines, @crlf])
  end

  @doc """
  Whether `subject` is a valid subject to publish on: dot-separated tokens,
  none empty, no whitespace, no wildcard.
  """
  @spec publishable?(term()) :: boolean()
  def publishable?(subject) when is_binary(subject) and subject != "" do
    not String.match?(subject, ~r/[\s*>]/) and
      subject |> String.split(".") |> Enum.all?(&(&1 != ""))
  end

  def publishable?(_subject), do: false

  @doc """
  A subject token for any string: bytes outside `[A-Za-z0-9_-]` are
  percent-encoded, so two ids never share a token and none breaks a subject
  (a dot, a space, `*` and `>` included).
  """
  @spec token(String.t()) :: String.t()
  def token(value) when is_binary(value) do
    URI.encode(value, fn char ->
      char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?_, ?-]
    end)
  end
end
