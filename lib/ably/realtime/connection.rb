module Ably
  module Realtime
    # The Connection class represents the connection associated with an Ably Realtime instance.
    # The Connection object exposes the lifecycle and parameters of the realtime connection.
    #
    # Connections will always be in one of the following states:
    #
    #   initialized:  0
    #   connecting:   1
    #   connected:    2
    #   disconnected: 3
    #   suspended:    4
    #   closed:       5
    #   failed:       6
    #
    # Note that the states are available as Enum-like constants:
    #
    #   Connection::STATE.Initialized
    #   Connection::STATE.Connecting
    #   Connection::STATE.Connected
    #   Connection::STATE.Disconnected
    #   Connection::STATE.Suspended
    #   Connection::STATE.Closed
    #   Connection::STATE.Failed
    #
    # Connection emit errors - use `on(:error)` to subscribe to errors
    #
    # @example
    #    client = Ably::Realtime::Client.new('key.id:secret')
    #    client.connection.on(:connected) do
    #      puts "Connected with connection ID: #{client.connection.id}"
    #    end
    #
    # @!attribute [r] state
    #   @return [Ably::Realtime::Connection::STATE] connection state
    #
    class Connection
      include Ably::Modules::EventEmitter
      include Ably::Modules::Conversions
      extend Ably::Modules::Enum

      # Valid Connection states
      STATE = ruby_enum('STATE',
        :initialized,
        :connecting,
        :connected,
        :disconnected,
        :suspended,
        :closing,
        :closed,
        :failed
      )
      include Ably::Modules::StateEmitter
      include Ably::Modules::UsesStateMachine

      # Expected format for a connection recover key
      RECOVER_REGEX = /^(?<recover>[\w-]+):(?<connection_serial>\-?\w+)$/

      # A unique public identifier for this connection, used to identify this member in presence events and messages
      # @return [String]
      attr_reader :id

      # A unique private connection key used to recover this connection, assigned by Ably
      # @return [String]
      attr_reader :key

      # The serial number of the last message to be received on this connection, used to recover or resume a connection
      # @return [Integer]
      attr_reader :serial

      # When a connection failure occurs this attribute contains the Ably Exception
      # @return [Ably::Models::ErrorInfo,Ably::Exceptions::BaseAblyException]
      attr_reader :error_reason

      # {Ably::Realtime::Client} associated with this connection
      # @return [Ably::Realtime::Client]
      attr_reader :client

      # Underlying socket transport used for this connection, for internal use by the client library
      # @return [Ably::Realtime::Connection::WebsocketTransport]
      # @api private
      attr_reader :transport

      # The Connection manager responsible for creating, maintaining and closing the connection and underlying transport
      # @return [Ably::Realtime::Connection::ConnectionManager]
      # @api private
      attr_reader :manager

      # An internal queue used to manage unsent outgoing messages.  You should never interface with this array directly
      # @return [Array]
      # @api private
      attr_reader :__outgoing_message_queue__

      # An internal queue used to manage sent messages.  You should never interface with this array directly
      # @return [Array]
      # @api private
      attr_reader :__pending_message_queue__

      # @api public
      def initialize(client)
        @client                     = client
        @serial                     = -1
        @__outgoing_message_queue__ = []
        @__pending_message_queue__  = []

        Client::IncomingMessageDispatcher.new client, self
        Client::OutgoingMessageDispatcher.new client, self

        @state_machine = ConnectionStateMachine.new(self)
        @state         = STATE(state_machine.current_state)
        @manager       = ConnectionManager.new(self)
      end

      # Causes the connection to close, entering the closed state, from any state except
      # the failed state. Once closed, the library will not attempt to re-establish the
      # connection without a call to {Connection#connect}.
      #
      # @yield [Ably::Realtime::Connection] block is called as soon as this connection is in the Closed state
      #
      # @return [EventMachine::Deferrable]
      #
      def close(&success_block)
        unless closing? || closed?
          raise exception_for_state_change_to(:closing) unless can_transition_to?(:closing)
          transition_state_machine :closing
        end
        deferrable_for_state_change_to(STATE.Closed, &success_block)
      end

      # Causes the library to attempt connection.  If it was previously explicitly
      # closed by the user, or was closed as a result of an unrecoverable error, a new connection will be opened.
      #
      # @yield [Ably::Realtime::Connection] block is called as soon as this connection is in the Connected state
      #
      # @return [EventMachine::Deferrable]
      #
      def connect(&success_block)
        unless connecting? || connected?
          raise exception_for_state_change_to(:connecting) unless can_transition_to?(:connecting)
          transition_state_machine :connecting
        end
        deferrable_for_state_change_to(STATE.Connected, &success_block)
      end

      # Sends a ping to Ably and yields the provided block when a heartbeat ping request is echoed from the server.
      # This can be useful for measuring true roundtrip client to Ably server latency for a simple message, or checking that an underlying transport is responding currently.
      # The elapsed milliseconds is passed as an argument to the block and represents the time taken to echo a ping heartbeat once the connection is in the `:connected` state.
      #
      # @yield [Integer] if a block is passed to this method, then this block will be called once the ping heartbeat is received with the time elapsed in milliseconds
      #
      # @example
      #    client = Ably::Rest::Client.new(api_key: 'key.id:secret')
      #    client.connection.ping do |ms_elapsed|
      #      puts "Ping took #{ms_elapsed}ms"
      #    end
      #
      # @return [void]
      #
      def ping(&block)
        raise RuntimeError, 'Cannot send a ping when connection is not open' if initialized?
        raise RuntimeError, 'Cannot send a ping when connection is in a closed or failed state' if closed? || failed?

        started = nil

        wait_for_ping = Proc.new do |protocol_message|
          if protocol_message.action == Ably::Models::ProtocolMessage::ACTION.Heartbeat
            __incoming_protocol_msgbus__.unsubscribe(:protocol_message, &wait_for_ping)
            time_passed = (Time.now.to_f * 1000 - started.to_f * 1000).to_i
            block.call time_passed if block_given?
          end
        end

        once_or_if(STATE.Connected) do
          started = Time.now
          send_protocol_message action: Ably::Models::ProtocolMessage::ACTION.Heartbeat.to_i
          __incoming_protocol_msgbus__.subscribe :protocol_message, &wait_for_ping
        end
      end

      # @!attribute [r] recovery_key
      #   @return [String] recovery key that can be used by another client to recover this connection with the :recover option
      def recovery_key
        "#{key}:#{serial}" if connection_resumable?
      end

      # Configure the current connection ID and connection key
      # @return [void]
      # @api private
      def update_connection_id_and_key(connection_id, connection_key)
        @id  = connection_id
        @key = connection_key
      end

      # Store last received connection serial so that the connection can be resumed from the last known point-in-time
      # @return [void]
      # @api private
      def update_connection_serial(connection_serial)
        @serial = connection_serial
      end

      # Disable automatic resume of a connection
      # @return [void]
      # @api private
      def reset_resume_info
        @key    = nil
        @serial = nil
      end

      # @!attribute [r] __outgoing_protocol_msgbus__
      # @return [Ably::Util::PubSub] Client library internal outgoing protocol message bus
      # @api private
      def __outgoing_protocol_msgbus__
        @__outgoing_protocol_msgbus__ ||= create_pub_sub_message_bus
      end

      # @!attribute [r] __incoming_protocol_msgbus__
      # @return [Ably::Util::PubSub] Client library internal incoming protocol message bus
      # @api private
      def __incoming_protocol_msgbus__
        @__incoming_protocol_msgbus__ ||= create_pub_sub_message_bus
      end

      # @!attribute [r] host
      # @return [String] The host name used for this connection, for network connection failures a {Ably::FALLBACK_HOSTS fallback host} is used to route around networking or intermittent problems
      def host
        if can_use_fallback_hosts?
          client.fallback_endpoint.host
        else
          client.endpoint.host
        end
      end

      # @!attribute [r] port
      # @return [Integer] The default port used for this connection
      def port
        client.use_tls? ? 443 : 80
      end

      # @!attribute [r] logger
      # @return [Logger] The {Ably::Logger} for this client.
      #                  Configure the log_level with the `:log_level` option, refer to {Ably::Realtime::Client#initialize}
      def logger
        client.logger
      end

      # Add protocol message to the outgoing message queue and notify the dispatcher that a message is
      # ready to be sent
      #
      # @param [Ably::Models::ProtocolMessage] protocol_message
      # @return [void]
      # @api private
      def send_protocol_message(protocol_message)
        add_message_serial_if_ack_required_to(protocol_message) do
          Ably::Models::ProtocolMessage.new(protocol_message).tap do |protocol_message|
            add_message_to_outgoing_queue protocol_message
            notify_message_dispatcher_of_new_message protocol_message
            logger.debug("Connection: Prot msg queued =>: #{protocol_message.action} #{protocol_message}")
          end
        end
      end

      # @api private
      def add_message_to_outgoing_queue(protocol_message)
        __outgoing_message_queue__ << protocol_message
      end

      # @api private
      def notify_message_dispatcher_of_new_message(protocol_message)
        __outgoing_protocol_msgbus__.publish :protocol_message, protocol_message
      end

      # @api private
      def create_websocket_transport(&block)
        operation = proc do
          URI(client.endpoint).tap do |endpoint|
            url_params = client.auth.auth_params.merge(
              timestamp: as_since_epoch(Time.now),
              format:    client.protocol,
              echo:      client.echo_messages
            )

            if connection_resumable?
              url_params.merge! resume: key, connection_serial: serial
              logger.debug "Resuming connection key #{key} with serial #{serial}"
            elsif connection_recoverable?
              url_params.merge! recover: connection_recover_parts[:recover], connection_serial: connection_recover_parts[:connection_serial]
              logger.debug "Recovering connection with key #{client.recover}"
              once(:connected, :closed, :failed) do
                client.disable_automatic_connection_recovery
              end
            end

            endpoint.query = URI.encode_www_form(url_params)
          end.to_s
        end

        callback = proc do |url|
          begin
            @transport = EventMachine.connect(host, port, WebsocketTransport, self, url) do |websocket_transport|
              yield websocket_transport if block_given?
            end
          rescue EventMachine::ConnectionError => error
            manager.connection_opening_failed error
          end
        end

        # client.auth.auth_params is a blocking call, so defer this into a thread
        EventMachine.defer operation, callback
      end

      # @api private
      def release_websocket_transport
        @transport = nil
      end

      # @api private
      def set_failed_connection_error_reason(error)
        @error_reason = error
      end

      # As we are using a state machine, do not allow change_state to be used
      # #transition_state_machine must be used instead
      private :change_state

      private
      def create_pub_sub_message_bus
        Ably::Util::PubSub.new(
          coerce_into: Proc.new do |event|
            raise KeyError, "Expected :protocol_message, :#{event} is disallowed" unless event == :protocol_message
            :protocol_message
          end
        )
      end

      def add_message_serial_if_ack_required_to(protocol_message)
        if Ably::Models::ProtocolMessage.ack_required?(protocol_message[:action])
          add_message_serial_to(protocol_message) { yield }
        else
          yield
        end
      end

      def add_message_serial_to(protocol_message)
        @serial += 1
        protocol_message[:msgSerial] = serial
        yield
      rescue StandardError => e
        @serial -= 1
        raise e
      end

      # Simply wait until the next EventMachine tick to ensure Connection initialization is complete
      def when_initialized(&block)
        EventMachine.next_tick { yield }
      end

      def connection_resumable?
        !key.nil? && !serial.nil?
      end

      def connection_recoverable?
        connection_recover_parts
      end

      def connection_recover_parts
        client.recover.to_s.match(RECOVER_REGEX)
      end

      def can_use_fallback_hosts?
        if client.environment.nil? && client.custom_realtime_host.nil?
          if connecting? && previous_state
            use_fallback_if_disconnected? || use_fallback_if_suspended?
          end
        end
      end

      def use_fallback_if_disconnected?
        second_reconnect_attempt_for(:disconnected, 1)
      end

      def use_fallback_if_suspended?
        second_reconnect_attempt_for(:suspended, 2) # on first suspended state use default Ably host again
      end

      def second_reconnect_attempt_for(state, first_attempt_count)
        previous_state == state && manager.retry_count_for_state(state) >= first_attempt_count
      end
    end
  end
end
