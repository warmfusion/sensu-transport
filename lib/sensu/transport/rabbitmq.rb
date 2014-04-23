gem "amqp", "1.0.0"

require "amqp"

require File.join(File.dirname(__FILE__), "base")
require File.join(File.dirname(__FILE__), "patches", "amq")

module Sensu
  module Transport
    class RabbitMQ < Base
      def connect(options={})
        timeout = EM::Timer.new(20) do
          error = Error.new("timed out while attempting to connect to rabbitmq")
          @on_error.call(error)
        end
        on_failure = Proc.new do
          error = Error.new("failed to connect to rabbitmq")
          @on_error.call(error)
        end
        @connection = AMQP.connect(options, {
                                     :on_tcp_connection_failure => on_failure,
                                     :on_possible_authentication_failure => on_failure
                                   })
        @connection.logger = @logger
        @connection.on_open do
          timeout.cancel
        end
        reconnect = Proc.new do
          unless @connection.reconnecting?
            @before_reconnect.call
            @connection.periodically_reconnect(5)
          end
        end
        @connection.on_tcp_connection_loss(&reconnect)
        @connection.on_skipped_heartbeats(&reconnect)
        @channel = AMQP::Channel.new(@connection)
        @channel.auto_recovery = true
        @channel.on_error do |channel, channel_close|
          error = Error.new("rabbitmq channel closed")
          @on_error.call(error)
        end
        prefetch = 1
        if options.is_a?(Hash)
          prefetch = options[:prefetch] || 1
        end
        @channel.on_recovery do
          @after_reconnect.call
          @channel.prefetch(prefetch)
        end
        @channel.prefetch(prefetch)
        @queues = {}
      end

      def connected?
        @connection.connected?
      end

      def close
        @connection.close
      end

      def publish(exchange_type, exchange_name, message, options={}, &callback)
        begin
          @channel.method(exchange_type.to_sym).call(exchange_name, options).publish(message) do
            info = {}
            callback.call(info) if callback
          end
        rescue => error
          info = {:error => error}
          callback.call(info) if callback
        end
      end

      def subscribe(exchange_type, exchange_name, queue_name='', options={}, &callback)
        previously_declared = @queues.has_key?(queue_name)
        @queues[queue_name] ||= @channel.queue!(queue_name, :auto_delete => true)
        queue = @queues[queue_name]
        queue.bind(@channel.method(exchange_type.to_sym).call(exchange_name))
        unless previously_declared
          queue.subscribe(options, &callback)
        end
      end

      def unsubscribe(&callback)
        @queues.values.each do |queue|
          if connected?
            queue.unsubscribe
          else
            queue.before_recovery do
              queue.unsubscribe
            end
          end
        end
        @queues = {}
        @channel.recover if connected?
        super
      end
    end
  end
end