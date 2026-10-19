defmodule OptimalEngine.Connectors.BeehiivTest do
  @moduledoc """
  beehiiv adapter end to end against a recorded beehiiv API recording
  (`test/fixtures/connectors/beehiiv/routes.json`): a two-page post list and a
  one-page subscription list, both bearer-authenticated.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Connectors.Adapters.Beehiiv
  alias OptimalEngine.Signal
  alias OptimalEngine.Test.ConnectorFixtureStub

  @config %{
    "publication_id" => "pub_0001",
    "credentials" => %{"api_key" => "example-beehiiv-key"}
  }

  setup do
    stub = ConnectorFixtureStub.install(:beehiiv)
    on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)
    {:ok, stub: stub}
  end

  describe "init/1" do
    test "rejects a config without the publication id" do
      assert {:error, {:missing_config, [:publication_id]}} =
               Beehiiv.init(%{"credentials" => %{"api_key" => "example-beehiiv-key"}})
    end

    test "rejects a config without the api key" do
      assert {:error, {:missing_credentials, [:api_key]}} =
               Beehiiv.init(%{"publication_id" => "pub_0001"})
    end

    test "accepts the publication id with the api key" do
      assert {:ok, _state} = Beehiiv.init(@config)
    end
  end

  describe "full sync" do
    test "walks every page of both families and transforms each record", %{stub: stub} do
      {:ok, state} = Beehiiv.init(@config)
      assert {:ok, %{signals: signals, cursor: cursor}} = Beehiiv.sync(state, nil)

      # Three posts across two pages, then two subscribers on one page. A
      # finished walk parks the cursor on nil: the next run starts over.
      assert length(signals) == 5
      assert cursor == nil

      assert signals |> Enum.map(& &1.genre) |> Enum.frequencies() == %{
               "post" => 3,
               "subscriber" => 2
             }

      # Posts come first, in page order.
      assert signals |> Enum.take(3) |> Enum.map(& &1.title) == [
               "Example Co launch notes",
               "Five lessons from customers",
               "Roadmap preview"
             ]

      urls = stub |> ConnectorFixtureStub.calls() |> Enum.map(& &1.url)

      assert urls == [
               "https://api.beehiiv.com/v2/publications/pub_0001/posts?limit=100&page=1",
               "https://api.beehiiv.com/v2/publications/pub_0001/posts?limit=100&page=2",
               "https://api.beehiiv.com/v2/publications/pub_0001/subscriptions?limit=100&page=1"
             ]
    end

    test "sends the api key as a bearer token on every request", %{stub: stub} do
      {:ok, state} = Beehiiv.init(@config)
      {:ok, _result} = Beehiiv.sync(state, nil)

      calls = ConnectorFixtureStub.calls(stub)
      assert length(calls) == 3

      assert Enum.all?(calls, fn call ->
               Enum.any?(call.headers, fn {k, v} ->
                 k == "authorization" and v == "Bearer example-beehiiv-key"
               end)
             end)
    end
  end

  describe "families" do
    test "families: [posts] reads posts only and never asks for subscribers", %{stub: stub} do
      {:ok, state} = Beehiiv.init(Map.put(@config, "families", ["posts"]))

      assert {:ok, %{signals: signals, cursor: nil}} = Beehiiv.sync(state, nil)
      assert Enum.map(signals, & &1.genre) == ["post", "post", "post"]

      urls = stub |> ConnectorFixtureStub.calls() |> Enum.map(& &1.url)
      refute Enum.any?(urls, &String.contains?(&1, "/subscriptions"))
    end

    test "a cursor for a family the row no longer reads starts over on the first one", %{
      stub: stub
    } do
      {:ok, state} = Beehiiv.init(Map.put(@config, "families", ["posts"]))

      assert {:ok, %{signals: signals}} = Beehiiv.sync(state, "subscribers:1")
      assert Enum.all?(signals, &(&1.genre == "post"))

      [first | _] = ConnectorFixtureStub.calls(stub)
      assert String.ends_with?(first.url, "/posts?limit=100&page=1")
    end

    test "an unknown or empty family list is a config error, not a silent full read" do
      for families <- [["posts", "likes"], [], "posts"] do
        {:ok, state} = Beehiiv.init(Map.put(@config, "families", families))
        assert {:error, {:invalid_config, :families}} = Beehiiv.sync(state, nil)
      end
    end
  end

  describe "cursor" do
    test "advances by page and family when the page bound is reached" do
      {:ok, state} = Beehiiv.init(Map.put(@config, "max_pages", 1))

      assert {:ok, %{signals: first_page, cursor: "posts:2"}} = Beehiiv.sync(state, nil)

      assert Enum.map(first_page, & &1.title) == [
               "Example Co launch notes",
               "Five lessons from customers"
             ]

      # Resuming at page 2 finishes the posts and parks on the first
      # subscriber page.
      assert {:ok, %{signals: [post], cursor: "subscribers:1"}} = Beehiiv.sync(state, "posts:2")
      assert post.title == "Roadmap preview"

      assert {:ok, %{signals: subscribers, cursor: nil}} = Beehiiv.sync(state, "subscribers:1")
      assert Enum.map(subscribers, & &1.genre) == ["subscriber", "subscriber"]
    end

    test "an unreadable cursor starts the walk over", %{stub: stub} do
      {:ok, state} = Beehiiv.init(@config)

      assert {:ok, %{signals: signals}} = Beehiiv.sync(state, "not-a-cursor")
      assert length(signals) == 5

      [first | _] = ConnectorFixtureStub.calls(stub)
      assert String.ends_with?(first.url, "/posts?limit=100&page=1")
    end

    test "stops at the page bound when the API keeps reporting more pages" do
      stub =
        ConnectorFixtureStub.install(:beehiiv,
          status: 200,
          body: %{
            "data" => [%{"id" => "post_9999", "title" => "Endless"}],
            "page" => 1,
            "total_pages" => 99
          }
        )

      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = Beehiiv.init(Map.put(@config, "max_pages", 3))

      assert {:ok, %{signals: signals, cursor: "posts:4"}} = Beehiiv.sync(state, nil)
      assert length(signals) == 3
      assert length(ConnectorFixtureStub.calls(stub)) == 3
    end
  end

  describe "errors" do
    test "an unauthorized key is :auth_expired" do
      stub = ConnectorFixtureStub.install(:beehiiv, status: 401)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = Beehiiv.init(@config)
      assert {:error, :auth_expired} = Beehiiv.sync(state, nil)
    end

    test "a forbidden key is :auth_expired" do
      stub = ConnectorFixtureStub.install(:beehiiv, status: 403)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = Beehiiv.init(@config)
      assert {:error, :auth_expired} = Beehiiv.sync(state, nil)
    end

    test "a rate-limited list is :rate_limited" do
      stub = ConnectorFixtureStub.install(:beehiiv, status: 429)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = Beehiiv.init(@config)
      assert {:error, :rate_limited} = Beehiiv.sync(state, nil)
    end

    test "a server error is :transient" do
      stub = ConnectorFixtureStub.install(:beehiiv, status: 503)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = Beehiiv.init(@config)
      assert {:error, :transient} = Beehiiv.sync(state, nil)
    end

    test "an unexpected 200 body is an error, not a crash" do
      stub = ConnectorFixtureStub.install(:beehiiv, status: 200, body: %{"message" => "hello"})
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = Beehiiv.init(@config)
      assert {:error, {:unexpected_response, 200}} = Beehiiv.sync(state, nil)
    end

    test "an unreachable endpoint is a transport error, not a crash" do
      stub = ConnectorFixtureStub.install(:beehiiv, unreachable: true)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = Beehiiv.init(@config)
      assert {:error, _reason} = Beehiiv.sync(state, nil)
    end
  end

  describe "transform/1" do
    test "maps a post: title, preview text, genre, path and publish date" do
      {:ok, state} = Beehiiv.init(@config)
      {:ok, %{signals: signals}} = Beehiiv.sync(state, nil)

      [post] = Enum.filter(signals, &(&1.title == "Example Co launch notes"))

      assert post.genre == "post"
      assert post.content == "A short look at what Example Co shipped this quarter."
      assert post.entities == []
      assert post.path == "optimal://connectors/beehiiv/post_0001"

      # publish_date is epoch seconds.
      assert DateTime.to_unix(post.modified_at) == 1_792_486_800
    end

    test "falls back to the subtitle when the preview text is empty, and strips HTML" do
      {:ok, state} = Beehiiv.init(@config)
      {:ok, %{signals: signals}} = Beehiiv.sync(state, nil)

      [post] = Enum.filter(signals, &(&1.title == "Five lessons from customers"))
      assert post.content == "Notes from Example Co customer calls"

      [html_preview] = Enum.filter(signals, &(&1.title == "Roadmap preview"))
      assert html_preview.content == "What is coming next at Example Co."
    end

    test "maps a subscriber: email entity, status lines, genre, path and created date" do
      {:ok, state} = Beehiiv.init(@config)
      {:ok, %{signals: signals}} = Beehiiv.sync(state, nil)

      [jane] = Enum.filter(signals, &(&1.title == "Subscriber jane@example.com"))

      assert jane.genre == "subscriber"
      assert jane.entities == ["jane@example.com"]
      assert jane.path == "optimal://connectors/beehiiv/sub_0001"

      assert jane.content ==
               "Email: jane@example.com\nStatus: active\nTier: free\nSource: newsletter"

      # created is epoch seconds.
      assert DateTime.to_unix(jane.modified_at) == 1_792_929_600
      assert DateTime.to_unix(jane.created_at) == 1_792_929_600

      # A null utm_source leaves its line out.
      [sam] = Enum.filter(signals, &(&1.title == "Subscriber sam@example.com"))
      assert sam.content == "Email: sam@example.com\nStatus: active\nTier: premium"
    end

    test "returns a Signal for a minimal payload of either family" do
      assert {:ok, %Signal{} = post} = Beehiiv.transform(%{"id" => "post_9"})
      assert post.id =~ "beehiiv:"
      assert post.genre == "post"
      assert post.title == "Untitled"

      assert {:ok, %Signal{} = subscriber} =
               Beehiiv.transform(%{"id" => "sub_9", "email" => "x@example.com"})

      assert subscriber.genre == "subscriber"
      assert subscriber.entities == ["x@example.com"]
    end

    test "gives the same id for the same record, so a replayed page creates no duplicate" do
      {:ok, first} = Beehiiv.transform(%{"id" => "post_0001", "title" => "A"})
      {:ok, second} = Beehiiv.transform(%{"id" => "post_0001", "title" => "A, edited"})
      assert first.id == second.id
    end
  end
end
