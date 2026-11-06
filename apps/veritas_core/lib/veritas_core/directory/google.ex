defmodule Veritas.Core.Directory.Google do
  @moduledoc """
  The company's people, as Google Workspace holds them.

  ## What this is, and what it is not

  Signing in with Google is **OIDC**, and it needs no admin scope: it is a
  different integration, and `Veritas.Authn` is its seam. This is the other
  thing — **administering people in Google Workspace** — which is the Admin
  Directory API, a service account, and domain-wide delegation.

  ## The access this adapter needs

  The operator grants the service account these scopes, in the Google Admin
  console, and delegates them domain-wide to a user who may read and write
  people:

      https://www.googleapis.com/auth/admin.directory.user.readonly
      https://www.googleapis.com/auth/admin.directory.user

  The read scope lists people; the write scope creates them. `required_scopes/0`
  is how the operator sees this before they grant it.

  ## What is **not** proven

  **The calls to Google are not proven.** They need a service account with
  domain-wide delegation, and this build has none — so the adapter is written
  to the API and has never been run against it. What is proved is the seam:
  the port, the shapes, the screen that reads them, and the mapping from the
  API's own JSON onto the port's person. The corpus's rule applies: no
  capability is claimed before it has been measured.
  """
  @behaviour Veritas.Core.Directory

  @base_url "https://admin.googleapis.com/admin/directory/v1"
  @token_url "https://oauth2.googleapis.com/token"
  @grant_type "urn:ietf:params:oauth:grant-type:jwt-bearer"

  @scope_read "https://www.googleapis.com/auth/admin.directory.user.readonly"
  @scope_write "https://www.googleapis.com/auth/admin.directory.user"

  # How long the signed assertion lives. Google accepts an hour; the
  # assertion is exchanged for an access token immediately.
  @assertion_lifetime 3600

  @pool :veritas_directory_pool

  @impl Veritas.Core.Directory
  def required_scopes, do: [@scope_read, @scope_write]

  @impl Veritas.Core.Directory
  def list(opts) do
    with {:ok, token} <- access_token(opts),
         {:ok, body} <- get(token, list_url(opts), opts) do
      {:ok, body |> users() |> Enum.map(&person/1)}
    end
  end

  @impl Veritas.Core.Directory
  def read(id, opts) do
    with {:ok, token} <- access_token(opts),
         {:ok, body} <- get(token, "#{@base_url}/users/#{URI.encode(id)}", opts) do
      {:ok, person(body)}
    end
  end

  @impl Veritas.Core.Directory
  def create(attrs, opts) do
    with {:ok, token} <- access_token(opts),
         {:ok, body} <- post(token, "#{@base_url}/users", attrs, opts) do
      {:ok, person(body)}
    end
  end

  @doc """
  The URL the directory's people are listed from.

  Public because it is a **fact about the request**, and a fact that can be
  checked without a network.
  """
  @spec list_url(keyword()) :: String.t()
  def list_url(opts) do
    query =
      URI.encode_query(%{
        "customer" => Keyword.get(opts, :customer, "my_customer"),
        "maxResults" => Keyword.get(opts, :limit, 100)
      })

    "#{@base_url}/users?#{query}"
  end

  @doc """
  The person the API's own JSON carries.

  Public because it is a **mapping**, and a mapping can be checked without a
  network.
  """
  @spec person(map()) :: Veritas.Core.Directory.person()
  def person(body) do
    %{
      id: body["id"] || body["primaryEmail"],
      email: body["primaryEmail"],
      name: name(body),
      kind: :directory,
      provider: :google
    }
  end

  defp name(body) do
    case body["name"] do
      %{"fullName" => full} -> full
      _ -> body["name"] || body["givenName"]
    end
  end

  defp users(body), do: Map.get(body, "users", []) || []

  # ── the access token ────────────────────────────────────────────────────────

  defp access_token(opts) do
    with {:ok, key} <- private_key(opts),
         {:ok, assertion} <- assertion(key, opts),
         {:ok, body} <- post_form(@token_url, assertion, opts) do
      case Map.fetch(body, "access_token") do
        {:ok, token} -> {:ok, token}
        :error -> {:error, :no_access_token}
      end
    end
  end

  # The service account's private key, from the JSON key file the operator
  # downloaded from the Google console.
  defp private_key(opts) do
    with {:ok, path} <- fetch(opts, :key_path),
         {:ok, contents} <- File.read(path),
         {:ok, json} <- Jason.decode(contents),
         {:ok, pem} <- Map.fetch(json, "private_key") do
      pem_entry(pem)
    end
  end

  defp pem_entry(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _rest] -> {:ok, :public_key.pem_entry_decode(entry)}
      [] -> {:error, :no_private_key}
    end
  end

  # The signed assertion Google exchanges for an access token. It is a JWT:
  # a header, the claims, and a signature over the two.
  defp assertion(key, opts) do
    now = System.system_time(:second)

    header = %{"alg" => "RS256", "typ" => "JWT"}

    claims = %{
      "iss" => issuer(opts),
      "scope" => Enum.join(required_scopes(), " "),
      "aud" => @token_url,
      "iat" => now,
      "exp" => now + @assertion_lifetime,
      "sub" => subject(opts)
    }

    signing_input =
      base64url(Jason.encode!(header)) <> "." <> base64url(Jason.encode!(claims))

    {:ok, signing_input <> "." <> base64url(sign(signing_input, key))}
  end

  defp sign(data, key) do
    :crypto.sign(:sha256, data, key, :rsa_pkcs1_sha256)
  end

  defp base64url(binary), do: Base.url_encode64(binary, padding: false)

  defp issuer(opts) do
    case fetch(opts, :client_email) do
      {:ok, email} ->
        {:ok, email}

      {:error, _reason} ->
        with {:ok, json} <- key_json(opts), do: {:ok, Map.get(json, "client_email")}
    end
  end

  defp subject(opts), do: Keyword.get(opts, :subject, "")

  defp key_json(opts) do
    with {:ok, path} <- fetch(opts, :key_path),
         {:ok, contents} <- File.read(path) do
      Jason.decode(contents)
    end
  end

  defp fetch(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:not_configured, key}}
    end
  end

  # ── the requests ────────────────────────────────────────────────────────────

  defp get(token, url, opts) do
    request = Finch.build(:get, url, [{"authorization", "Bearer " <> token}])
    finch(request, opts)
  end

  defp post(token, url, attrs, opts) do
    request =
      Finch.build(
        :post,
        url,
        [{"authorization", "Bearer " <> token}, {"content-type", "application/json"}],
        Jason.encode!(attrs)
      )

    finch(request, opts)
  end

  defp post_form(url, assertion, opts) do
    body = URI.encode_query(%{"assertion" => assertion, "grant_type" => @grant_type})

    request =
      Finch.build(
        :post,
        url,
        [{"content-type", "application/x-www-form-urlencoded"}],
        body
      )

    finch(request, opts)
  end

  defp finch(request, opts) do
    case Finch.request(request, @pool, receive_timeout: timeout(opts)) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        decode(body)

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:http_error, status, summarise(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :not_json}
    end
  end

  # The API's own error, in a form that is safe to show: it names the code
  # and the message, and carries neither the token nor the key.
  defp summarise(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} -> message
      _ -> "the directory refused the request"
    end
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout, 30_000)
end
