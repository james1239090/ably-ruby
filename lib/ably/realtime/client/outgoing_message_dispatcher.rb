module Ably::Realtime
  class Client
    # OutgoingMessageDispatcher is a (private) class that is used to deliver
    # outgoing {Ably::Realtime::Models::ProtocolMessage}s using the {Ably::Realtime::Connection}
    # when the connection state is capable of delivering messages
    class OutgoingMessageDispatcher
      include Ably::Modules::EventMachineHelpers

      ACTION = Models::ProtocolMessage::ACTION

      def initialize(client)
        @client = client
        subscribe_to_outgoing_protocol_message_queue
        setup_event_handlers
      end

      private
      attr_reader :client

      def connection
        client.connection
      end

      def can_send_messages?
        connection.connected?
      end

      def messages_in_outgoing_queue?
        !outgoing_queue.empty?
      end

      def outgoing_queue
        connection.__outgoing_message_queue__
      end

      def pending_queue
        connection.__pending_message_queue__
      end

      def deliver_queued_protocol_messages
        condition = -> { can_send_messages? && messages_in_outgoing_queue? }
        non_blocking_loop_while(condition) do
          protocol_message = outgoing_queue.shift
          pending_queue << protocol_message if protocol_message.ack_required?
          connection.send_text(protocol_message.to_json)
          client.logger.debug("Prot msg sent =>: #{protocol_message.action} #{protocol_message}")
        end
      end

      def subscribe_to_outgoing_protocol_message_queue
        connection.__outgoing_protocol_msgbus__.subscribe(:message) do |*args|
          deliver_queued_protocol_messages
        end
      end

      def setup_event_handlers
        connection.on(:connected) do
          deliver_queued_protocol_messages
        end
      end
    end
  end
end