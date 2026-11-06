defmodule Veritas.Authn.Local.Breach do
  @moduledoc """
  The breached-password check.

  `docs/09` §3: *"Passwords are checked against a local breached-password
  list at set-time."* The check happens when a password is **set**, not when
  it is used: a password that was breached after it was set cannot be helped,
  but a password that is known to be breached before it is set can be
  refused, and refusing it is the whole point of the list.

  ## What the list is, honestly

  Two sources, and the difference between them matters:

    * A **shipped list** — a set of well-known breached passwords compiled
      into the release. It is small, it is free, it is always present, and
      it is not the whole of the public breach corpus. It exists so that a
      deployment that has configured nothing still refuses `password` and
      `123456`.
    * An **operator list** — a file the deployment points at with
      `VERITAS_BREACHED_PASSWORD_LIST`, one password per line. This is where
      a deployment puts the full corpus it wants to refuse.

  The corpus does not name a source or an update mechanism for the list, and
  this module does not invent one: it ships a floor and it accepts a file.
  What it does **not** do is pretend the shipped list is exhaustive. A
  deployment that wants the full corpus configures one.

  ## When the operator's list cannot be read

  A configured list that cannot be read is a misconfiguration, and the
  password change is **refused** rather than quietly checked against the
  smaller shipped list. A check that silently becomes weaker is worse than
  no check, because it looks like a check.
  """

  require Logger

  @list_var "VERITAS_BREACHED_PASSWORD_LIST"

  # The shipped floor: the passwords that appear at the top of every public
  # breach corpus. It is deliberately small — it is a floor, not a corpus.
  @shipped ~w(
    password password1 password12 password123 password1234
    123456 1234567 12345678 123456789 1234567890
    111111 000000 121212 654321
    qwerty qwertyui qwerty123 qwerty1
    letmein welcome welcome1 admin admin1 administrator
    iloveyou sunshine princess football baseball soccer hockey
    monkey dragon master michael shadow trustno1
    abc123 passw0rd pass123 secret secret1
    changeme default root toor login access
    god love sex 1234 4321 666666 888888
    hello hello1 test test123 guest guest123
    loveyou 1q2w3e4r qazwsx zaq12wsx
  )

  @doc """
  Whether a password is in the breached list.

  Returns `{:ok, breached?}`, or `{:error, reason}` when the operator's
  list was configured and could not be read — in which case the caller
  refuses the password rather than checking it against less than it was
  told to check against.
  """
  @spec breached?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def breached?(password) when is_binary(password) do
    candidate = normalise(password)

    case operator_entries() do
      {:ok, entries} -> {:ok, candidate in MapSet.new(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The shipped list, for an operator who wants to see what is refused by
  default.
  """
  @spec shipped() :: [String.t()]
  def shipped, do: @shipped

  @doc """
  The path of the operator's list, or nil when none is configured.
  """
  @spec operator_list_path() :: String.t() | nil
  def operator_list_path do
    case System.get_env(@list_var) do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  # The operator's list is read at the moment it is needed, so a deployment
  # can replace the file without restarting the Node.
  defp operator_entries do
    case operator_list_path() do
      nil ->
        {:ok, @shipped}

      path ->
        case File.read(path) do
          {:ok, contents} ->
            entries =
              contents
              |> String.split("\n", trim: true)
              |> Enum.map(&normalise/1)
              |> Enum.reject(&(&1 == ""))
              |> Kernel.++(@shipped)

            {:ok, entries}

          {:error, reason} ->
            Logger.error(
              "[veritas.authn] the breached-password list at #{inspect(path)} could not be read: " <>
                "#{:file.format_error(reason)}. The password change is refused rather than " <>
                "checked against a shorter list."
            )

            {:error, :breach_list_unavailable}
        end
    end
  end

  # The comparison ignores case and surrounding space, because a password
  # that is breached is breached however it is capitalised.
  defp normalise(password) do
    password |> String.trim() |> String.downcase()
  end
end
