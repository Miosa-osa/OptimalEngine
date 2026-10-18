defmodule OptimalEngine.Connectors.Adapters.Stripe do
  @moduledoc """
  Stripe connector - customers, invoices and charges as read-only Signals.

  ## Required config keys
    * `:resources` - a list drawn from `"customers"`, `"invoices"`, `"charges"`.
      An empty list pulls all three. Anything else is refused by `init/1`.

  ## Credentials
    * `:api_key` - a restricted key with read access to the chosen resources,
      sent as `Authorization: Bearer <key>`. Never a secret key with write access.

  ## Cursor shape
  Opaque: `"<resource>:<last_id>"`, e.g. `"invoices:in_0042"`. Initial sync: `nil`.

  A sync walks the resources in the order customers, invoices, charges and pages
  each one with `starting_after=<last id>` while Stripe says `has_more`. Stripe
  lists newest first, so paging runs from the newest object to the oldest. A sync
  reads at most 20 pages; when that budget runs out before the account is read,
  the cursor names the page still to read and the next run resumes there:

    * `"invoices:in_0042"` - customers are done; resume invoices after `in_0042`
    * `"invoices:"` - customers are done; invoices start from the top
    * `nil` - every resource was read to its end

  A finished walk resets the cursor, so the next run reads the account again from
  the newest object. That is deliberate: an invoice changes status after it is
  created, and a re-read is how an `open` invoice becomes `paid`. Signal ids are
  derived from the Stripe id, so a re-read carries the same ids.
  A cursor that names a resource this connector no longer pulls, or that does not
  parse, starts the walk over. A resume id Stripe has since deleted (HTTP 400)
  restarts that resource from the top instead of wedging on a dead cursor.

  ## Structured amounts
  A `%Signal{}` has no metadata map, so a Signal that carries money puts one
  labelled, parseable line first in `content`, then a blank line, then the
  human sentences:

      amount_minor=120000 amount_paid_minor=0 currency=usd status=open

      Invoice INV-0007 is outstanding, 1200.00 USD due 2026-11-01.
      Billed to Jane Example (jane@example.com).

  The first line is space-separated `key=value` pairs with no spaces inside a value:

    * `amount_minor` - the amount in the currency's smallest unit, as Stripe
      reports it (invoice `amount_due`, charge `amount`)
    * `amount_paid_minor` - what has been received (invoice `amount_paid`, charge
      `amount` once it `succeeded`, otherwise `0`)
    * `currency` - the lower-case ISO code
    * `status` - Stripe's own status string

  Customers carry no amount and have no such line. An invoice that still owes
  money (`open`, or `uncollectible`) gets a sentence of the form
  `Invoice <number> is outstanding, <remaining> <CURRENCY> due <YYYY-MM-DD>.`
  so `OptimalEngine.Operating.Loops.detect/2` reads it as a `payment_owed` loop
  with the due date resolved from the ISO date. Paid, draft and void invoices and
  all charges are written so that no money loop is detected.

  ## Errors
  `401` and `403` are `:auth_expired`, `429` is `:rate_limited`, `5xx` is
  `:transient`, a transport failure is `{:error, reason}`. Nothing here raises.

  ## Money data and workspaces
  These Signals are restricted money data. This adapter does not decide where
  they land: keeping them out of a sandbox or a non-hq workspace is enforced
  downstream, by routing and the workspace wall, not here.
  """

  use OptimalEngine.Connectors.Adapters.Base,
    kind: :stripe,
    display_name: "Stripe",
    auth_scheme: :token,
    required_keys: [:resources],
    credential_keys: [:api_key]

  alias OptimalEngine.Connectors.HTTP

  @base_url "https://api.stripe.com/v1"
  @page_size 100
  @max_pages 20

  # Order matters: it is the order a sync walks them in, and what a cursor means.
  @resources ~w(customers invoices charges)
  @objects %{"customers" => "customer", "invoices" => "invoice", "charges" => "charge"}

  # Stripe's smallest unit is 1/100 except for these. UGX, ISK, HUF and TWD stay
  # two-decimal in the API for backward compatibility.
  @zero_decimal ~w(bif clp djf gnf jpy kmf krw mga pyg rwf vnd vuv xaf xof xpf)
  @three_decimal ~w(bhd jod kwd omr tnd)

  @max_text 120

  @impl true
  def init(config) do
    with {:ok, state} <- super(config),
         {:ok, resources} <- resolve_resources(pick(state, :resources)) do
      {:ok, Map.put(state, :resources, resources)}
    end
  end

  @impl true
  def sync(state, cursor) do
    with {:ok, resources} <- resolve_resources(pick(state, :resources)) do
      headers = [{"authorization", "Bearer #{pick(state, :api_key)}"}]
      walk(plan(resources, cursor), headers, @max_pages, [])
    end
  end

  @impl true
  def transform(%{"id" => id} = raw) when is_binary(id) and id != "" do
    case object_kind(raw) do
      "customer" -> {:ok, customer_signal(raw)}
      "invoice" -> {:ok, invoice_signal(raw)}
      "charge" -> {:ok, charge_signal(raw)}
      _ -> {:error, {:unsupported_object, raw["object"] || id}}
    end
  end

  def transform(_raw), do: {:error, :invalid_payload}

  # ---- config -------------------------------------------------------------------

  defp resolve_resources(nil), do: {:ok, @resources}
  defp resolve_resources([]), do: {:ok, @resources}

  defp resolve_resources(list) when is_list(list) do
    requested = Enum.map(list, &to_string/1)

    case Enum.reject(requested, &(&1 in @resources)) do
      [] -> {:ok, Enum.filter(@resources, &(&1 in requested))}
      unknown -> {:error, {:invalid_config, {:unknown_resources, unknown}}}
    end
  end

  defp resolve_resources(_other), do: {:error, {:invalid_config, :resources}}

  # ---- walking ------------------------------------------------------------------

  # The resources still to pull, each with the id to page after. The cursor names
  # the resource it stopped in: the ones before it are done, it resumes after the
  # cursor's id, and the ones after it start from the top.
  defp plan(resources, cursor) do
    with {resource, after_id} <- parse_cursor(cursor),
         true <- resource in resources,
         {_done, [^resource | later]} <- Enum.split_while(resources, &(&1 != resource)) do
      [{resource, after_id} | Enum.map(later, &{&1, nil})]
    else
      _ -> Enum.map(resources, &{&1, nil})
    end
  end

  defp parse_cursor(cursor) when is_binary(cursor) do
    case String.split(cursor, ":", parts: 2) do
      [resource, ""] -> {resource, nil}
      [resource, id] -> {resource, id}
      _ -> nil
    end
  end

  defp parse_cursor(_cursor), do: nil

  defp cursor_for(resource, nil), do: "#{resource}:"
  defp cursor_for(resource, id), do: "#{resource}:#{id}"

  # Every resource was read to its end: the next run starts over.
  defp walk([], _headers, _budget, acc) do
    {:ok, %{signals: Enum.reverse(acc), cursor: nil}}
  end

  # The request budget is spent: park the cursor on the page still to read.
  defp walk([{resource, after_id} | _rest], _headers, 0, acc) do
    {:ok, %{signals: Enum.reverse(acc), cursor: cursor_for(resource, after_id)}}
  end

  defp walk([{resource, after_id} | rest], headers, budget, acc) do
    case fetch_page(resource, after_id, headers) do
      {:ok, records, has_more?} ->
        acc = Enum.reduce(records, acc, &prepend_signal(&1, resource, &2))

        next =
          case last_id(records) do
            id when has_more? and is_binary(id) -> [{resource, id} | rest]
            _ -> rest
          end

        walk(next, headers, budget - 1, acc)

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_page(resource, after_id, headers) do
    case HTTP.get_json(page_url(resource, after_id), headers: headers) do
      {:ok, %{status: 200, body: %{"data" => data} = body}} when is_list(data) ->
        {:ok, data, body["has_more"] == true}

      {:ok, %{status: 200}} ->
        {:error, {:unexpected_body, resource}}

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, :auth_expired}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} when status >= 500 ->
        {:error, :transient}

      # The object this run was to resume after is gone (a deleted customer).
      # Start the resource over rather than fail on the same dead cursor forever.
      {:ok, %{status: 400}} when is_binary(after_id) ->
        fetch_page(resource, nil, headers)

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp page_url(resource, nil), do: "#{@base_url}/#{resource}?limit=#{@page_size}"

  defp page_url(resource, after_id) do
    page_url(resource, nil) <> "&starting_after=" <> URI.encode_www_form(after_id)
  end

  defp last_id(records) do
    case List.last(records) do
      %{"id" => id} when is_binary(id) -> id
      _ -> nil
    end
  end

  # A list endpoint does not say which object it returned in every payload, so the
  # resource the page came from fills in a missing `object`.
  defp prepend_signal(record, resource, acc) when is_map(record) do
    case transform(Map.put_new(record, "object", @objects[resource])) do
      {:ok, signal} -> [signal | acc]
      _ -> acc
    end
  end

  defp prepend_signal(_record, _resource, acc), do: acc

  # ---- mapping ------------------------------------------------------------------

  defp object_kind(%{"object" => object}) when object in ["customer", "invoice", "charge"],
    do: object

  defp object_kind(%{"id" => "cus_" <> _}), do: "customer"
  defp object_kind(%{"id" => "in_" <> _}), do: "invoice"
  defp object_kind(%{"id" => "ch_" <> _}), do: "charge"
  defp object_kind(_raw), do: nil

  defp customer_signal(raw) do
    name = text(raw["name"])
    email = text(raw["email"])
    who = clip(name || email || raw["id"])
    created = Transform.parse_epoch(raw["created"])

    intro =
      "Customer #{who}" <>
        if(name && email, do: " (#{email})", else: "") <>
        ", created #{DateTime.to_date(created)}."

    build(raw, created, %{
      title: "Customer #{who}",
      content: join_lines([intro, labelled("Description", raw["description"])]),
      genre: "customer",
      entities: emails([email])
    })
  end

  defp invoice_signal(raw) do
    currency = currency(raw)
    amount = int(raw["amount_due"])
    paid = int(raw["amount_paid"])
    label = text(raw["number"]) || raw["id"]
    name = text(raw["customer_name"])
    email = text(raw["customer_email"])
    created = Transform.parse_epoch(raw["created"])
    status = text(raw["status"]) || "unknown"

    sentences = [
      invoice_sentence(status, label, amount, paid, currency, due_on(raw["due_date"])),
      billed_to(name, email),
      labelled("Hosted invoice", raw["hosted_invoice_url"])
    ]

    build(raw, created, %{
      title: "Invoice #{label}",
      content: money_content(amount, paid, currency, status, sentences),
      genre: "invoice",
      entities: emails([email])
    })
  end

  defp charge_signal(raw) do
    currency = currency(raw)
    amount = int(raw["amount"])
    status = text(raw["status"]) || "unknown"
    paid = if status == "succeeded", do: amount, else: 0
    created = Transform.parse_epoch(raw["created"])

    sentences = [
      "Payment #{raw["id"]} of #{money(amount, currency)} #{charge_verb(status)}.",
      labelled("Receipt email", raw["receipt_email"]),
      labelled("Description", raw["description"])
    ]

    build(raw, created, %{
      title: "Payment #{raw["id"]}",
      content: money_content(amount, paid, currency, status, sentences),
      genre: "payment",
      entities: emails([text(raw["receipt_email"])])
    })
  end

  defp build(raw, created, attrs) do
    Transform.new_signal(
      Map.merge(
        %{
          id: Transform.signal_id(:stripe, raw["id"]),
          path: Transform.source_uri(:stripe, raw["id"]),
          mode: :linguistic,
          created_at: created,
          modified_at: created
        },
        attrs
      )
    )
  end

  # An invoice that still owes money reads as an open payment loop, with the due
  # date as an ISO date in the same sentence. The wording of the others stays clear
  # of due / outstanding / overdue / unpaid / owed so they never read as one, and a
  # paid invoice leaves its due date out for the same reason.
  defp invoice_sentence(status, label, amount, paid, currency, due_on)
       when status in ["open", "uncollectible"] do
    remaining = max(amount - paid, 0)
    marker = if status == "uncollectible", do: ", marked uncollectible", else: ""

    "Invoice #{label} is outstanding, #{money(remaining, currency)}" <>
      if(due_on, do: " due #{due_on}", else: "") <> marker <> "."
  end

  defp invoice_sentence("paid", label, amount, paid, currency, _due_on) do
    "Invoice #{label} was paid, #{money(max(paid, amount), currency)}."
  end

  defp invoice_sentence("draft", label, amount, _paid, currency, _due_on) do
    "Invoice #{label} is a draft, #{money(amount, currency)}, not yet sent."
  end

  defp invoice_sentence("void", label, amount, _paid, currency, _due_on) do
    "Invoice #{label} was voided, #{money(amount, currency)}."
  end

  defp invoice_sentence(status, label, amount, _paid, currency, _due_on) do
    "Invoice #{label} has status #{status}, #{money(amount, currency)}."
  end

  defp charge_verb("succeeded"), do: "succeeded"
  defp charge_verb("pending"), do: "is pending"
  defp charge_verb("failed"), do: "failed"
  defp charge_verb(status), do: "has status #{status}"

  defp billed_to(nil, nil), do: nil
  defp billed_to(name, nil), do: "Billed to #{clip(name)}."
  defp billed_to(nil, email), do: "Billed to #{email}."
  defp billed_to(name, email), do: "Billed to #{clip(name)} (#{email})."

  defp money_content(amount, paid, currency, status, sentences) do
    line = "amount_minor=#{amount} amount_paid_minor=#{paid} currency=#{currency} status=#{status}"
    line <> "\n\n" <> join_lines(sentences)
  end

  defp join_lines(lines), do: lines |> Enum.reject(&is_nil/1) |> Enum.join("\n")

  defp labelled(label, value) do
    case text(value) do
      nil -> nil
      value -> "#{label}: #{clip(value)}"
    end
  end

  defp emails(values), do: Enum.reject(values, &is_nil/1)

  defp due_on(nil), do: nil

  defp due_on(epoch) when is_number(epoch) do
    epoch |> Transform.parse_epoch() |> DateTime.to_date() |> Date.to_iso8601()
  end

  defp due_on(_other), do: nil

  defp currency(raw) do
    case text(raw["currency"]) do
      nil -> "unknown"
      code -> String.downcase(code)
    end
  end

  # A minor-unit integer as a decimal string: 120000 usd -> "1200.00 USD".
  defp money(minor, currency) do
    exponent =
      cond do
        currency in @zero_decimal -> 0
        currency in @three_decimal -> 3
        true -> 2
      end

    sign = if minor < 0, do: "-", else: ""
    magnitude = abs(minor)

    number =
      if exponent == 0 do
        Integer.to_string(magnitude)
      else
        divisor = Integer.pow(10, exponent)

        fraction =
          magnitude |> rem(divisor) |> Integer.to_string() |> String.pad_leading(exponent, "0")

        "#{div(magnitude, divisor)}.#{fraction}"
      end

    "#{sign}#{number} #{String.upcase(currency)}"
  end

  defp int(value) when is_integer(value), do: value
  defp int(value) when is_float(value), do: trunc(value)
  defp int(_value), do: 0

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil

  defp clip(value), do: String.slice(value, 0, @max_text)
end
