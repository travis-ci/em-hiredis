require 'uri'

module EventMachine::Hiredis
  # Emits the following events
  #
  # * :connected - on successful connection or reconnection
  # * :reconnected - on successful reconnection
  # * :disconnected - no longer connected, when previously in connected state
  # * :reconnect_failed(failure_number) - a reconnect attempt failed
  #     This event is passed number of failures so far (1,2,3...)
  # * :monitor
  #
  class BaseClient
    include EventEmitter
    include EM::Deferrable

    attr_reader :host, :port, :password, :db, :user

    def initialize(host = 'localhost', port = 6379, password = nil, db = nil, user= nil)
      @host, @port, @password, @db, @user = host, port, password, db, user
      @defs = []
      @command_queue = []

      @closing_connection = false
      @reconnect_failed_count = 0
      @reconnect_timer = nil
      @failed = false

      self.on(:failed) {
        @failed = true
        @command_queue.each do |df, _, _|
          df.fail(Error.new("Redis connection in failed state"))
        end
        @command_queue = []
      }
    end

    # Configure the redis connection to use
    #
    # In usual operation, the uri should be passed to initialize. This method
    # is useful for example when failing over to a slave connection at runtime
    #
    def configure(uri_string)
      uri = URI(uri_string)

      if uri.scheme == "unix"
        @host = uri.path
        @port = nil
      else
        @host = uri.host
        @port = uri.port
        @password = uri.password
        @user = uri.user
        path = uri.path[1..-1]
        @db = path.to_i # Empty path => 0
      end
    end

    def connect
      @connection = EM.connect(@host, @port, Connection, @host, @port)

      @connection.on(:closed) do
        if @connected
          @defs.each { |d| d.fail(Error.new("Redis disconnected")) }
          @defs = []
          @deferred_status = nil
          @connected = false
          unless @closing_connection
            # Next tick avoids reconnecting after for example EM.stop
            EM.next_tick { reconnect }
          end
          emit(:disconnected)
          EM::Hiredis.logger.info("#{@connection} Disconnected")
        else
          unless @closing_connection
            @reconnect_failed_count += 1
            @reconnect_timer = EM.add_timer(EM::Hiredis.reconnect_timeout) {
              @reconnect_timer = nil
              reconnect
            }
            emit(:reconnect_failed, @reconnect_failed_count)
            EM::Hiredis.logger.info("#{@connection} Reconnect failed")

            if @reconnect_failed_count >= 4
              emit(:failed)
              self.fail(Error.new("Could not connect after 4 attempts"))
            end
          end
        end
      end

      @connection.on(:connected) do
        @connected = true
        @reconnect_failed_count = 0
        @failed = false

        select(@db) unless @db == 0
        if @user && !@user.empty?
          auth(password, user) if @password
        else
          auth(@password) if @password
        end

        @command_queue.each do |df, command, args|
          @connection.send_command(command, args)
          @defs.push(df)
        end
        @command_queue = []

        emit(:connected)
        EM::Hiredis.logger.info("#{@connection} Connected")
        succeed

        if @reconnecting
          @reconnecting = false
          emit(:reconnected)
        end
      end

      @connection.on(:message) do |reply|
        if RuntimeError === reply
          raise "Replies out of sync: #{reply.inspect}" if @defs.empty?
          deferred = @defs.shift
          error = RedisError.new(reply.message)
          error.redis_error = reply
          deferred.fail(error) if deferred
        else
          handle_reply(reply)
        end
      end

      @connected = false
      @reconnecting = false

      return self
    end

    # Indicates that commands have been sent to redis but a reply has not yet
    # been received
    #
    # This can be useful for example to avoid stopping the
    # eventmachine reactor while there are outstanding commands
    #
    def pending_commands?
      @connected && @defs.size > 0
    end

    def connected?
      @connected
    end

    def select(db, &blk)
      @db = db
      method_missing(:select, db, &blk)
    end

    def auth(password, user = nil, &blk)
      @password = password
      if user 
        method_missing(:auth,user, password, &blk)
      else
        method_missing(:auth, password, &blk)
      end
    end

    def close_connection
      EM.cancel_timer(@reconnect_timer) if @reconnect_timer
      @closing_connection = true
      @connection.close_connection_after_writing
    end

    def reconnect_connection
      EM.cancel_timer(@reconnect_timer) if @reconnect_timer
      reconnect
    end

    private

    def method_missing(sym, *args)
      deferred = EM::DefaultDeferrable.new
      # Shortcut for defining the callback case with just a block
      deferred.callback { |result| yield(result) } if block_given?

      if @connected
        @connection.send_command(sym, args)
        @defs.push(deferred)
      elsif @failed
        deferred.fail(Error.new("Redis connection in failed state"))
      else
        @command_queue << [deferred, sym, args]
      end

      deferred
    end

    def reconnect
      @reconnecting = true
      @connection.reconnect @host, @port
      EM::Hiredis.logger.info("#{@connection} Reconnecting")
    end

    def handle_reply(reply)
      if @defs.empty?
        if @monitoring
          emit(:monitor, reply)
        else
          raise "Replies out of sync: #{reply.inspect}"
        end
      else
        deferred = @defs.shift
        deferred.succeed(reply) if deferred
      end
    end
  end
end
