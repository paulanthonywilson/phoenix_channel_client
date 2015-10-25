defmodule Phoenix.Channel.Client.Socket do

  defmacro __using__(opts) do
    quote do
      require Logger
      unquote(config(opts))
      unquote(socket())
    end
  end

  defp config(opts) do
    quote do
      var!(otp_app) = unquote(opts)[:otp_app] || raise "socket expects :otp_app to be given"
      var!(config) = Application.get_env(var!(otp_app), __MODULE__)
    end
  end

  defp socket do
    quote unquote: false do
      use GenServer
      #require Logger

      alias Poison, as: JSON
      #alias Phoenix.Channel.Client.Push

      def start_link() do
        GenServer.start_link(__MODULE__, unquote(var!(config)), name: __MODULE__)
      end

      def push(pid, topic, event, payload) do
        GenServer.call(pid, {:push, topic, event, payload})
      end

      def channel_link(pid, channel, topic) do
        GenServer.call(pid, {:channel_link, channel, topic})
      end

      def init(opts) do
        send(self, :connect)
        {:ok, %{
          opts: opts,
          socket: nil,
          channels: [],
          state: :disconnected
        }}
      end

      def init(opts, _conn_state) do
        {:ok, %{
          sender: opts[:sender],
          ref: 0
        }}
      end

      def handle_call({:push, topic, event, payload}, _from, %{socket: socket} = state) do
        Logger.debug "Socket Push: #{inspect topic}, #{inspect event}, #{inspect payload}"
        send(socket, {:send, %{topic: topic, event: event, payload: payload}})
        {:noreply, state}
      end

      def handle_call({:channel_link, channel, topic}, _from, state) do
        {:reply, channel, %{state | channels: [{channel, topic} | state.channels]}}
      end

      def handle_info(:connect, %{opts: opts} = state) do
        headers = opts[:headers] || []
        :crypto.start
        :ssl.start
        opts = Keyword.put(opts, :sender, self)
        {:ok, pid} = :websocket_client.start_link(String.to_char_list(opts[:url]), __MODULE__, opts,
                                 extra_headers: headers)
        Logger.debug "[socket] pid: #{inspect pid}"
        {:noreply, %{state | socket: pid}}
      end

      # New Messages from the socket come in here
      def handle_info(%{"topic" => topic, "event" => event, "payload" => payload, "ref" => ref} = msg, %{channels: channels} = s) do
        Logger.debug "Channels: #{inspect channels}"
        Enum.filter(channels, fn({channel, channel_topic}) ->
          Logger.debug "Chan: #{inspect channel_topic}"
          Logger.debug "Topic: #{inspect topic}"
          topic == channel_topic
        end)
        |> Enum.each(fn({channel, _}) ->
          Logger.debug "Trigger"
          send(channel, {:trigger, event, payload, ref})
        end)
        {:noreply, s}
      end

      @doc """
      Receives JSON encoded Socket.Message from remote WS endpoint and
      forwards message to client sender process
      """
      def websocket_handle({:text, msg}, _conn_state, state) do
        Logger.debug "Recv: #{inspect msg}"
        Logger.debug "Sender: #{inspect state.sender}"
        send state.sender, JSON.decode!(msg)
        {:ok, state}
      end

      @doc """
      Sends JSON encoded Socket.Message to remote WS endpoint
      """
      def websocket_info({:send, msg}, _conn_state, state) do
        msg = Map.put(msg, :ref, to_string(state.ref + 1))
        Logger.debug "Send Message: #{inspect msg}"
        {:reply, {:text, json!(msg)}, put_in(state, [:ref], state.ref + 1)}
      end

      def websocket_info(:close, _conn_state, _state) do
        {:close, <<>>, "done"}
      end

      def websocket_terminate(_reason, _conn_state, _state) do
        :ok
      end

      @doc """
      Sends an event to the WebSocket server per the Message protocol
      """
      # def push(socket_pid, topic, %Push{event: event, payload: payload}) do
      #   Logger.debug "Socket Push: #{inspect topic}, #{inspect event}, #{inspect payload}"
      #   send socket_pid, {:send, %{topic: topic, event: event, payload: payload}}
      # end

      defp json!(map), do: JSON.encode!(map)
    end
  end

end
