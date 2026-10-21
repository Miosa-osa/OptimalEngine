defmodule OptimalEngine.Storage.S3EndpointPathTest do
  @moduledoc """
  An S3 endpoint may live under a path, which is how MIOSA serves its own
  gateway at `/api/v1/storage/s3`.

  The path must be part of both the request and the signature. Dropping it sent
  every object call to the API root, so a backup shipped `:not_found` while the
  bucket was healthy.
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.Storage.S3

  defp config(path, bucket \\ "proof-backup") do
    %{
      endpoint: %URI{scheme: "https", authority: "api.miosa.ai", host: "api.miosa.ai", path: path},
      bucket: bucket,
      region: "us-east-1",
      prefix: "",
      path_style: true,
      timeout: 30_000,
      max_retries: 0,
      access_key_id: "test",
      secret_access_key: "test"
    }
  end

  test "the signed path includes the endpoint path" do
    assert S3.signed_path(config("/api/v1/storage/s3"), "proof/backups/snap.enc") ==
             "/api/v1/storage/s3/proof-backup/proof/backups/snap.enc"
  end

  test "an endpoint without a path signs the bucket at the root" do
    assert S3.signed_path(config(nil), "backups/snap.enc") ==
             "/proof-backup/backups/snap.enc"

    assert S3.signed_path(config("/"), "backups/snap.enc") ==
             "/proof-backup/backups/snap.enc"
  end

  test "a trailing slash on the endpoint does not double the separator" do
    assert S3.signed_path(config("/api/v1/storage/s3/"), "k") ==
             "/api/v1/storage/s3/proof-backup/k"
  end
end
