defmodule RigInboundGatewayWeb.V1.SubscriptionController do
  use Rig.Config, [:cors]
  use RigInboundGatewayWeb, :controller

  alias Result

  alias Rig.Connection
  alias RIG.JWT
  alias Rig.Subscription
  alias RIG.Subscriptions
  alias RigAuth.AuthorizationCheck.Subscription, as: SubscriptionAuthZ
  alias RigAuth.Session

  require Logger

  # ---

  @doc false
  def handle_preflight(%{method: "OPTIONS"} = conn, _params) do
    conn
    |> with_allow_origin()
    |> put_resp_header("access-control-allow-methods", "PUT")
    |> put_resp_header("access-control-allow-headers", "content-type,authorization")
    |> send_resp(:no_content, "")
  end

  # ---

  defp with_allow_origin(conn) do
    %{cors: origins} = config()
    put_resp_header(conn, "access-control-allow-origin", origins)
  end

  # ---

  @doc """
  Sets subscriptions for an existing connection, replacing previous subscriptions.

  There may be multiple subscriptions contained in the request body. Each subscription
  refers to a single event type and may optionally include a constraint list
  (conjunctive normal form). Subscriptions that were present in a previous request but
  are no longer present in this one will be removed.

  ## Example

  Single subscription with a constraint that says "either head_repo equals
  `octocat/Hello-World`, or `base_repo` equals `octocat/Hello-World` (or both)":

      {
        "subscriptions": [
          {
            "eventType": "com.github.pull.create",
            "oneOf": [
              { "head_repo": "octocat/Hello-World" },
              { "base_repo": "octocat/Hello-World" }
            ]
          }
        ]
      }

  """
  @spec set_subscriptions(conn :: Plug.Conn.t(), params :: map) :: Plug.Conn.t()
  def set_subscriptions(
        %{method: "PUT", body_params: %{"subscriptions" => subscriptions}} = conn,
        %{
          "connection_id" => connection_id
        }
      )
      when is_list(subscriptions) do
    conn = with_allow_origin(conn)

    with :ok <- SubscriptionAuthZ.check_authorization(conn),
         {:ok, socket_pid} <- Connection.Codec.deserialize(connection_id),
         :ok <- connection_alive!(socket_pid) do
      # Updating the session allows blacklisting it later on:
      Session.update(conn, socket_pid)
      do_set_subscriptions(conn, socket_pid, subscriptions)
    else
      {:error, :not_authorized} ->
        conn |> put_status(:forbidden) |> text("Subscription denied.")

      {:error, :not_base64} ->
        Logger.warn(fn -> "Connection token #{connection_id} is not Base64 encoded." end)
        conn |> put_status(:bad_request) |> text("Invalid connection token.")

      {:error, :invalid_term} ->
        Logger.warn(fn -> "Connection token #{connection_id} is not a valid term." end)
        conn |> put_status(:bad_request) |> text("Invalid connection token.")

      {:error, :process_dead} ->
        conn |> put_status(:gone) |> text("Connection no longer exists.")

      {:error, :could_not_parse_subscriptions, bad_subscriptions} ->
        conn
        |> put_status(:bad_request)
        |> text("Could not parse subscriptions: #{inspect(bad_subscriptions)}")
    end
  end

  # ---

  defp do_set_subscriptions(conn, socket_pid, subscriptions_param) do
    with {:ok, jwt_subscriptions} <-
           conn.req_headers
           |> get_all_claims()
           |> Result.and_then(fn claims -> Subscriptions.from_jwt_claims(claims) end),
         {:ok, passed_subscriptions} <- parse_subscriptions(subscriptions_param) do
      subscriptions = jwt_subscriptions ++ passed_subscriptions
      send(socket_pid, {:set_subscriptions, subscriptions})
      send_resp(conn, :no_content, "")
    else
      {:error, error} when byte_size(error) > 0 ->
        conn
        |> put_status(:bad_request)
        |> text("cannot accept subscription request: #{error}")
    end
  end

  # ---

  defp connection_alive!(pid) do
    if Process.alive?(pid), do: :ok, else: {:error, :process_dead}
  end

  # ---

  # All claims, from all Authorization tokens. Returns a Result.
  defp get_all_claims(headers) do
    headers
    |> JWT.parse_http_header()
    |> Enum.reduce(%{}, fn
      {:ok, claims}, acc -> Map.merge(acc, claims)
      {:error, error}, _acc -> throw(error)
    end)
    |> Result.ok()
  catch
    %JWT.DecodeError{} = error ->
      Result.err("invalid authorization header: #{Exception.message(error)}")
  end

  # ---

  defp parse_subscriptions(subscriptions) when is_list(subscriptions) do
    subscriptions
    |> Enum.map(&Subscription.new!/1)
    |> Result.ok()
  rescue
    error in Subscription.ValidationError ->
      Result.err("could not parse given subscriptions: #{Exception.message(error)}")
  end
end
