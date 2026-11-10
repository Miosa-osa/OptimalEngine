defmodule OptimalEngine.Storage.NATS.Supervisor do
  @moduledoc """
  Supervises the Engine's NATS JetStream client
  (`OptimalEngine.Storage.NATS.Connection`) and the flows that run on it.

  It is always started. Without `OPTIMAL_NATS_URL` the connection idles as
  `not_configured` and nothing else runs, so an Engine that does not use NATS
  pays for one idle process. With it, the connection reconnects on its own;
  nothing under this supervisor gives up on a NATS outage, and no Engine
  write waits on NATS.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(_opts) do
    children = [
      # The work queues' periodic runs (OptimalEngine.Storage.NATS.WorkQueue).
      {Task.Supervisor, name: OptimalEngine.Storage.NATS.TaskSupervisor},
      OptimalEngine.Storage.NATS.Connection,
      OptimalEngine.Storage.NATS.LedgerPublisher,
      OptimalEngine.Storage.NATS.JobQueue,
      OptimalEngine.Storage.NATS.IntakeQueue
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 10, max_seconds: 60)
  end
end
