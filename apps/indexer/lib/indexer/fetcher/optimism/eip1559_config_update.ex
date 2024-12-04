defmodule Indexer.Fetcher.Optimism.EIP1559ConfigUpdate do
  @moduledoc """
  Fills op_eip1559_config_updates DB table.
  """

  use GenServer
  use Indexer.Fetcher

  require Logger

  import Ecto.Query

  import EthereumJSONRPC, only: [fetch_blocks_by_numbers: 3, json_rpc: 2, quantity_to_integer: 1]

  alias EthereumJSONRPC.Block.ByHash
  alias EthereumJSONRPC.Blocks
  alias Explorer.Chain.Block
  alias Explorer.Chain.Optimism.EIP1559ConfigUpdate
  alias Explorer.{Chain, Repo}
  alias Indexer.Fetcher.Optimism
  alias Indexer.Helper

  @fetcher_name :optimism_eip1559_config_updates
  @latest_block_check_interval_seconds 60
  @empty_hash "0x0000000000000000000000000000000000000000000000000000000000000000"

  def child_spec(start_link_arguments) do
    spec = %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, start_link_arguments},
      restart: :transient,
      type: :worker
    }

    Supervisor.child_spec(spec, [])
  end

  def start_link(args, gen_server_options \\ []) do
    GenServer.start_link(__MODULE__, args, Keyword.put_new(gen_server_options, :name, __MODULE__))
  end

  @impl GenServer
  def init(args) do
    json_rpc_named_arguments = args[:json_rpc_named_arguments]
    {:ok, %{}, {:continue, json_rpc_named_arguments}}
  end

  @impl GenServer
  def handle_continue(json_rpc_named_arguments, _state) do
    Logger.metadata(fetcher: @fetcher_name)

    optimism_env = Application.get_all_env(:indexer)[Indexer.Fetcher.Optimism]
    timestamp = optimism_env[:holocene_timestamp_l2]

    # todo: Subscriber.to

    with false <- is_nil(timestamp),
         {:ok, latest_block_number} = Optimism.get_block_number_by_tag("latest", json_rpc_named_arguments, Helper.infinite_retries_number()),
         wait_for_holocene(timestamp, json_rpc_named_arguments),
         l2_block_number = block_number_by_timestamp(timestamp, optimism_env[:block_duration], json_rpc_named_arguments),
         remove_invalid_updates(l2_block_number, latest_block_number),
         {:ok, last_l2_block_number} <- get_last_l2_block_number(json_rpc_named_arguments) do

      Logger.debug("l2_block_number = #{l2_block_number}")
      Logger.debug("last_l2_block_number = #{last_l2_block_number}")


      Process.send(self(), :continue, [])

      {:noreply, %{
        start_block: max(l2_block_number, last_l2_block_number),
        end_block: latest_block_number,
        json_rpc_named_arguments: json_rpc_named_arguments
      }}
    else
      true ->
        # Holocene timestamp is not defined, so we don't start this module
        {:stop, :normal, %{}}

      {:error, error_data} ->
        Logger.error("Cannot get last L2 block from RPC by its hash due to RPC error: #{inspect(error_data)}")
        {:stop, :normal, %{}}
    end
  end

  @impl GenServer
  def handle_info(
    :continue,
    %{
      start_block: start_block,
      end_block: end_block,
      json_rpc_named_arguments: json_rpc_named_arguments
    } = state
  ) do
    start_block..end_block
    |> Enum.chunk_every(10)
    |> Enum.each(fn block_numbers ->
      chunk_start = List.first(block_numbers)
      chunk_end = List.last(block_numbers)

      Helper.log_blocks_chunk_handling(chunk_start, chunk_end, start_block, end_block, nil, :L2)

      updates_count = handle_updates(block_numbers, json_rpc_named_arguments)

      Helper.log_blocks_chunk_handling(
        chunk_start,
        chunk_end,
        start_block,
        end_block,
        "#{updates_count} update(s).",
        :L2
      )
    end)

    Process.send(self(), :handle_realtime, [])

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({ref, _result}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  # Retrieves updated config parameters from the specified blocks and saves them to the database.
  #
  # ## Parameters
  # - `block_numbers`: The list of block numbers for which we need to check and update config parameters.
  #                    Note that the size of this list cannot be larger than max batch request size on RPC node.
  # - `json_rpc_named_arguments`: Configuration parameters for the JSON RPC connection.
  #
  # ## Returns
  # - The number of inserted rows into the `op_eip1559_config_updates` database table.
  @spec handle_updates([non_neg_integer()], EthereumJSONRPC.json_rpc_named_arguments()) :: non_neg_integer()
  defp handle_updates(block_numbers, json_rpc_named_arguments) do
    case fetch_blocks_by_numbers(block_numbers, json_rpc_named_arguments, false) do
      {:ok, %Blocks{blocks_params: blocks_params, errors: []}} ->
        last_block_number = List.last(block_numbers)

        Enum.reduce(block_numbers, 0, fn block_number, acc ->
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          block = Enum.find(blocks_params, %{extra_data: "0x"}, fn b -> b.number == block_number end)

          extra_data =
            block.extra_data
            |> String.trim_leading("0x")
            |> Base.decode16!(case: :mixed)

          return =
            with {:valid_format, true} <- {:valid_format, byte_size(extra_data) >= 9},
                 <<version::size(8), denominator::size(32), elasticity::size(32), _::binary>> = extra_data,
                 {:valid_version, _version, true} <- {:valid_version, version, version == 0},
                 prev_config = actual_config_for_block(block.number),
                 new_config = {denominator, elasticity},
                 {:updated_config, true} <- {:updated_config, prev_config != new_config} do
              update_config(block.number, block.hash, denominator, elasticity)
              Logger.info("Config was updated at block #{block.number}. Previous one: #{inspect(prev_config)}. New one: #{inspect(new_config)}.")
              acc + 1
            else
              {:valid_format, false} ->
                Logger.warn("extraData of the block ##{block_number} has invalid format. Ignoring it.")
                acc

              {:valid_version, version, false} ->
                Logger.warn("extraData of the block ##{block_number} has invalid version #{version}. Ignoring it.")
                acc

              {:updated_config, false} ->
                acc
            end

          if block.number == last_block_number do
            EIP1559ConfigUpdate.set_last_l2_block_hash(block.hash)
          end

          return
        end)

      {_, message_or_errors} ->
        message =
          case message_or_errors do
            %Blocks{errors: errors} -> errors
            msg -> msg
          end

        chunk_start = List.first(block_numbers)
        chunk_end = List.last(block_numbers)

        Logger.error("Cannot fetch blocks #{inspect(chunk_start..chunk_end)}. Error(s): #{inspect(message)} Retrying...")
        :timer.sleep(3000)
        handle_updates(block_numbers, json_rpc_named_arguments)
    end
  end

  # Reads the config actual before the specified block from the `op_eip1559_config_updates` table.
  #
  # ## Parameters
  # - `block_number`: The block number for which we need to read the actual config.
  #
  # ## Returns
  # - `{denominator, multiplier}` tuple in case the config exists.
  # - `nil` if the config is unknown.
  @spec actual_config_for_block(non_neg_integer()) :: {non_neg_integer(), non_neg_integer()} | nil
  defp actual_config_for_block(block_number) do
    query =
      from(u in EIP1559ConfigUpdate,
        select: {u.base_fee_max_change_denominator, u.elasticity_multiplier},
        where: u.l2_block_number < ^block_number,
        order_by: [desc: u.l2_block_number],
        limit: 1
      )

    Repo.one(query)
  end

  # Inserts a new row into the `op_eip1559_config_updates` database table.
  #
  # ## Parameters
  # - `l2_block_number`: L2 block number of the config update.
  # - `l2_block_hash`: L2 block hash of the config update.
  # - `base_fee_max_change_denominator`: A new value for EIP-1559 denominator.
  # - `elasticity_multiplier`: A new value for EIP-1559 multiplier.
  @spec update_config(non_neg_integer(), binary(), non_neg_integer(), non_neg_integer()) :: no_return()
  defp update_config(l2_block_number, l2_block_hash, base_fee_max_change_denominator, elasticity_multiplier) do
    updates = [%{
      l2_block_number: l2_block_number,
      l2_block_hash: l2_block_hash,
      base_fee_max_change_denominator: base_fee_max_change_denominator,
      elasticity_multiplier: elasticity_multiplier
    }]

    {:ok, _} =
      Chain.import(%{
        optimism_eip1559_config_updates: %{params: updates},
        timeout: :infinity
      })
  end

  # Determines a block number by its timestamp. The function firstly tries to get the nearest block
  # number to the specified timestamp using the database. If the block is not found, the RPC is used.
  #
  # ## Parameters
  # - `timestamp`: The timestamp for which the block number is being determined.
  # - `block_duration`: The average block duration, seconds. Used for RPC approach.
  # - `json_rpc_named_arguments`: Configuration parameters for the JSON RPC connection. Used for RPC approach.
  #
  # ## Returns
  # - The block number corresponding to the given timestamp.
  @spec block_number_by_timestamp(non_neg_integer(), non_neg_integer(), EthereumJSONRPC.json_rpc_named_arguments()) :: non_neg_integer()
  defp block_number_by_timestamp(timestamp, block_duration, json_rpc_named_arguments)
  
  defp block_number_by_timestamp(0, _block_duration, _json_rpc_named_arguments), do: 0

  defp block_number_by_timestamp(timestamp, block_duration, json_rpc_named_arguments) do
    {:ok, timestamp_dt} = DateTime.from_unix(timestamp)

    Logger.info("Trying to detect Holocene block number by its timestamp using indexed L2 blocks...")

    query =
      from(b in Block,
        select: b.number,
        where: b.timestamp >= ^timestamp_dt and b.consensus == true,
        order_by: [asc: b.number],
        limit: 1
      )

    block_number = Repo.one(query)

    if is_nil(block_number) do
      Logger.info("Cannot detect Holocene block number using indexed L2 blocks. Trying to calculate the number using RPC requests...")
      block_number_by_timestamp_from_rpc(timestamp, block_duration, json_rpc_named_arguments)
    else
      Logger.info("Holocene block number is detected using indexed L2 blocks. The block number is #{block_number}")
      block_number
    end
  end

  # Fetches block data by its hash using RPC request.
  #
  # ## Parameters
  # - `hash`: The block hash.
  # - `json_rpc_named_arguments`: Configuration parameters for the JSON RPC connection.
  #
  # ## Returns
  # - `{:ok, block}` tuple in case of success.
  # - `{:error, message}` tuple in case of failure.
  @spec get_block_by_hash(binary(), EthereumJSONRPC.json_rpc_named_arguments()) :: {:ok, any()} | {:error, any()}
  defp get_block_by_hash(hash, json_rpc_named_arguments) do
    req = ByHash.request(%{id: 0, hash: hash}, false)

    error_message = &"eth_getBlockByHash failed. Error: #{inspect(&1)}"

    Helper.repeated_call(&json_rpc/2, [req, json_rpc_named_arguments], error_message, Helper.infinite_retries_number())
  end

  # Gets the last known L2 block number from the `op_eip1559_config_updates` database table.
  # When the block number is found, the function checks that for actuality (to avoid reorg cases).
  # If the block is not consensus, the corresponding row is removed from the table and
  # the previous block becomes under consideration, and so on until a row with non-reorged
  # block is found.
  #
  # ## Parameters
  # - `json_rpc_named_arguments`: Configuration parameters for the JSON RPC connection.
  #
  # ## Returns
  # - `{:ok, number}` tuple with the block number of the last actual row. The number can be `0` if there are no rows.
  # - `{:error, message}` tuple in case of RPC error.
  @spec get_last_l2_block_number(EthereumJSONRPC.json_rpc_named_arguments()) :: {:ok, non_neg_integer()} | {:error, any()}
  defp get_last_l2_block_number(json_rpc_named_arguments) do
    last_l2_block_hash = EIP1559ConfigUpdate.last_l2_block_hash()

    last_l2_block_number =
      if last_l2_block_hash != @empty_hash do
        case get_block_by_hash(last_l2_block_hash, json_rpc_named_arguments) do
          {:ok, nil} ->
            # it seems there was a reorg, so we need to reset the block hash in the counter
            # and then use the below approach taking the block hash from `op_eip1559_config_updates` table
            EIP1559ConfigUpdate.set_last_l2_block_hash(@empty_hash)
            nil

          {:ok, last_l2_block} ->
            # the block hash is actual, so use the block number
            last_l2_block
            |> Map.get("number")
            |> quantity_to_integer()

          {:error, _} ->
            # something went wrong, so use the below approach
            nil
        end
      end
    
    if is_nil(last_l2_block_number) do
      query = from(u in EIP1559ConfigUpdate, select: {u.l2_block_number, u.l2_block_hash}, order_by: [desc: u.l2_block_number], limit: 1)

      {last_l2_block_number, last_l2_block_hash} =
        query
        |> Repo.one()
        |> Kernel.||({0, nil})

      with {:empty_hash, false} <- {:empty_hash, is_nil(last_l2_block_hash)},
           {:ok, last_l2_block} <- get_block_by_hash(last_l2_block_hash, json_rpc_named_arguments),
           {:empty_block, false} <- {:empty_block, is_nil(last_l2_block)} do
        {:ok, last_l2_block_number}
      else
        {:empty_hash, true} ->
          {:ok, 0}

        {:error, _} = error ->
          error

        {:empty_block, true} ->
          Logger.error(
            "Cannot find the last L2 block from RPC by its hash (#{last_l2_block_hash}). Probably, there was a reorg on L2 chain. Trying to check preceding block..."
          )

          Repo.delete_all(from(u in EIP1559ConfigUpdate, where: u.l2_block_number == ^last_l2_block_number))

          get_last_l2_block_number(json_rpc_named_arguments)
      end
    else
      {:ok, last_l2_block_number}
    end
  end

  # Determines a block number by its timestamp using RPC. The function uses the average block
  # duration and the latest block timestamp to calculate the required block number
  # by the specified timestamp.
  #
  # If the found block was created later or earlier than the given timestamp
  # (that can happen if the average block timestamp is not constant), the function
  # additionally clarifies the block duration using the neighbour block's timestamp
  # and tries to calculate the block number again.
  #
  # ## Parameters
  # - `timestamp`: The timestamp for which the block number is being determined.
  # - `block_duration`: The average block duration, seconds.
  # - `json_rpc_named_arguments`: Configuration parameters for the JSON RPC connection.
  # - `ref_block_number`: The reference block number for the calculation. The latest block is used by default.
  # - `ref_block_timestamp`: The timestamp of the reference block number. The latest block timestamp is used by default.
  #
  # ## Returns
  # - The block number corresponding to the given timestamp.
  @spec block_number_by_timestamp_from_rpc(non_neg_integer(), non_neg_integer(), EthereumJSONRPC.json_rpc_named_arguments(), non_neg_integer() | nil, non_neg_integer() | nil) :: non_neg_integer()
  defp block_number_by_timestamp_from_rpc(timestamp, block_duration, json_rpc_named_arguments, ref_block_number \\ nil, ref_block_timestamp \\ nil) do
    ref_block_number =
      if is_nil(ref_block_number) do
        {:ok, latest_block_number} = Helper.get_block_number_by_tag("latest", json_rpc_named_arguments, Helper.infinite_retries_number())
        latest_block_number
      else
        ref_block_number
      end

    ref_block_timestamp =
      if is_nil(ref_block_timestamp) do
        {:ok, ref_block_timestamp} = Helper.get_block_timestamp_by_number(ref_block_number, json_rpc_named_arguments, Helper.infinite_retries_number())
        ref_block_timestamp
      else
        ref_block_timestamp
      end

    gap = div(abs(ref_block_timestamp - timestamp), block_duration)

    block_number =
      if ref_block_timestamp > timestamp do
        ref_block_number - gap
      else
        ref_block_number + gap
      end

    {:ok, block_timestamp} = Helper.get_block_timestamp_by_number(block_number, json_rpc_named_arguments, Helper.infinite_retries_number())

    if block_timestamp == timestamp do
      Logger.info("Holocene block number was successfully calculated using RPC. The block number is #{block_number}")
      block_number
    else
      next_block_number = block_number + 1
      {:ok, next_block_timestamp} = Helper.get_block_timestamp_by_number(next_block_number, json_rpc_named_arguments, Helper.infinite_retries_number())

      if next_block_timestamp == timestamp do
        Logger.info("Holocene block number was successfully calculated using RPC. The block number is #{next_block_number}")
        next_block_number
      else
        :timer.sleep(1000)
        Logger.info("Another try for Holocene block number calculation using RPC...")
        Logger.debug("block_number = #{block_number}, next_block_number = #{next_block_number}, block_timestamp = #{block_timestamp}, next_block_timestamp = #{next_block_timestamp}")
        block_number_by_timestamp_from_rpc(timestamp, next_block_timestamp - block_timestamp, json_rpc_named_arguments, block_number, block_timestamp)
      end
    end
  end

  # Removes rows from the `op_eip1559_config_updates` table which relate to
  # pre-Holocene period or which have l2_block_number greater than the latest block number.
  # They could be created mistakenly as a result of the incorrect value of
  # INDEXER_OPTIMISM_L2_HOLOCENE_TIMESTAMP env variable or due to reorg.
  #
  # ## Parameters
  # - `block_number`: L2 block number of the Holocene upgrade.
  # - `latest_block_number`: The latest block number.
  @spec remove_invalid_updates(non_neg_integer(), non_neg_integer()) :: any()
  defp remove_invalid_updates(block_number, latest_block_number) do
    Repo.delete_all(from(u in EIP1559ConfigUpdate, where: u.l2_block_number < ^block_number or u.l2_block_number > ^latest_block_number))
  end

  # Infinitely waits for the OP Holocene upgrade.
  #
  # ## Parameters
  # - `timestamp`: The timestamp of the Holocene.
  # - `json_rpc_named_arguments`: Configuration parameters for the JSON RPC connection.
  @spec wait_for_holocene(non_neg_integer(), EthereumJSONRPC.json_rpc_named_arguments()) :: any()
  defp wait_for_holocene(timestamp, json_rpc_named_arguments) do
    {:ok, latest_timestamp} = Helper.get_block_timestamp_by_number(:latest, json_rpc_named_arguments, Helper.infinite_retries_number())

    if latest_timestamp < timestamp do
      Logger.info("Holocene is not activated yet. Waiting for the timestamp #{timestamp} to be reached...")
      :timer.sleep(@latest_block_check_interval_seconds * 1_000)
      wait_for_holocene(timestamp, json_rpc_named_arguments)
    else
      Logger.info("Holocene activation detected")
    end
  end
end
