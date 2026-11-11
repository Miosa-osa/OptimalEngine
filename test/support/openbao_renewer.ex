defmodule OptimalEngine.Test.OpenBaoRenewer do
  @moduledoc false
  # The application's OpenBao token renewer (`OptimalEngine.Storage.OpenBao.TokenRenewer`,
  # a child of `OptimalEngine.Supervisor`) reads OPTIMAL_OPENBAO_* when it runs, not
  # when it starts: one started while a test had OpenBao configured keeps renewing
  # against whatever stub a later test configures.

  alias OptimalEngine.Storage.OpenBao.TokenRenewer

  @doc "Stops the application's renewer, if it is running."
  def stop_app_renewer do
    Supervisor.terminate_child(OptimalEngine.Supervisor, TokenRenewer)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Starts the application's renewer again: `:ignore` unless OpenBao is configured now."
  def restart_app_renewer do
    stop_app_renewer()
    Supervisor.restart_child(OptimalEngine.Supervisor, TokenRenewer)
    :ok
  catch
    :exit, _ -> :ok
  end
end
