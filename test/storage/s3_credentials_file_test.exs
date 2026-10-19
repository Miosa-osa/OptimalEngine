defmodule OptimalEngine.Storage.S3CredentialsFileTest do
  @moduledoc """
  `OPTIMAL_S3_CREDENTIALS_FILE` lets an operator drop the access key id and
  secret into a file instead of editing a launcher. The environment still
  wins, the values are never echoed in an error or a log, and the stub's
  signature check proves the secret read from the file is the one used.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalEngine.Storage.{Providers, S3}
  alias OptimalEngine.TestSupport.S3Stub

  @moduletag :tmp_dir

  @env ~w(OPTIMAL_S3_ENDPOINT OPTIMAL_S3_BUCKET OPTIMAL_S3_REGION OPTIMAL_S3_ACCESS_KEY_ID
          OPTIMAL_S3_SECRET_ACCESS_KEY OPTIMAL_S3_PREFIX OPTIMAL_S3_CREDENTIALS_FILE
          OPTIMAL_S3_MAX_RETRIES OPTIMAL_S3_TRACE)

  setup %{tmp_dir: tmp} do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    ref = S3Stub.ref()
    on_exit(fn -> S3Stub.stop(ref) end)
    {:ok, stub} = S3Stub.start(ref: ref, bucket: "engine-test")

    Enum.each(@env, &System.delete_env/1)
    System.put_env("OPTIMAL_S3_ENDPOINT", stub.endpoint)
    System.put_env("OPTIMAL_S3_BUCKET", stub.bucket)
    System.put_env("OPTIMAL_S3_REGION", stub.region)

    on_exit(fn ->
      S3Stub.stop_agent(stub.agent)

      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    %{stub: stub, creds: Path.join(tmp, "s3-credentials")}
  end

  defp use_file(path, contents) do
    File.write!(path, contents)
    System.put_env("OPTIMAL_S3_CREDENTIALS_FILE", path)
  end

  test "a two-line file supplies the access key id and the secret", %{stub: stub, creds: file} do
    use_file(file, "#{stub.access_key_id}\n#{stub.secret_access_key}\n")

    assert S3.configured?()
    assert {:ok, _} = S3.put_object("from-file/two-lines.txt", "bytes")
    assert S3Stub.object_body(stub.agent, "from-file/two-lines.txt") == "bytes"
  end

  test "KEY=VALUE files accept comments, quotes, export, and the AWS names", %{
    stub: stub,
    creds: file
  } do
    use_file(file, """
    # dropped in by the operator
    export OPTIMAL_S3_ACCESS_KEY_ID="#{stub.access_key_id}"

    OPTIMAL_S3_SECRET_ACCESS_KEY='#{stub.secret_access_key}'
    """)

    assert {:ok, _} = S3.put_object("from-file/key-value.txt", "a")

    use_file(file, """
    [default]
    aws_access_key_id = #{stub.access_key_id}
    aws_secret_access_key = #{stub.secret_access_key}
    """)

    assert {:ok, _} = S3.put_object("from-file/aws.txt", "b")
  end

  test "a secret containing '=' is read whole in the two-line form", %{creds: file} do
    use_file(file, "AKIDEXAMPLE\nabc=def==\n")
    assert {:ok, config} = S3.config()
    assert config.access_key_id == "AKIDEXAMPLE"
    assert config.secret_access_key == "abc=def=="
  end

  test "the environment wins over the file, one value at a time", %{stub: stub, creds: file} do
    use_file(file, "wrong-key-id\nwrong-secret\n")
    System.put_env("OPTIMAL_S3_ACCESS_KEY_ID", stub.access_key_id)
    System.put_env("OPTIMAL_S3_SECRET_ACCESS_KEY", stub.secret_access_key)
    assert {:ok, _} = S3.put_object("from-env/a.txt", "a")

    # Only the secret from the environment: the key id still comes from the file.
    use_file(file, "#{stub.access_key_id}\nwrong-secret\n")
    System.delete_env("OPTIMAL_S3_ACCESS_KEY_ID")
    assert {:ok, config} = S3.config()
    assert config.access_key_id == stub.access_key_id
    assert config.secret_access_key == stub.secret_access_key
  end

  test "a missing or malformed file is reported without its contents", %{creds: file} do
    System.put_env("OPTIMAL_S3_CREDENTIALS_FILE", file <> ".absent")
    refute S3.configured?()
    assert {:error, :credentials_file_unreadable} = S3.config()

    use_file(file, "only-one-line-super-secret-value\n")
    assert {:error, :credentials_file_invalid} = S3.config()
    refute inspect(S3.get_object("any/key")) =~ "super-secret"

    use_file(file, "OPTIMAL_S3_ACCESS_KEY_ID=id-only-super-secret\n")
    assert {:error, :credentials_file_invalid} = S3.config()
  end

  test "the provider inventory counts credentials from the file as configured", %{
    stub: stub,
    creds: file
  } do
    use_file(file, "#{stub.access_key_id}\n#{stub.secret_access_key}\n")

    provider = Providers.list() |> Enum.find(&(&1.id == "s3"))
    assert provider.configured
    assert provider.missing_environment == []
    assert "OPTIMAL_S3_CREDENTIALS_FILE" in provider.optional_environment
  end

  test "the secret from the file never reaches a log, even while tracing", %{
    stub: stub,
    creds: file
  } do
    use_file(file, "#{stub.access_key_id}\n#{stub.secret_access_key}\n")
    System.put_env("OPTIMAL_S3_TRACE", "1")

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, _} = S3.put_object("traced/a.txt", "a")
        assert {:error, :not_found} = S3.get_object("traced/absent.txt")
      end)

    refute log =~ stub.secret_access_key
  end
end
