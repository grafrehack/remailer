require 'socket'
require 'eventmachine'

class Remailer::SMTP::Client < Remailer::AbstractConnection
  # == Submodules ===========================================================
  
  autoload(:Interpreter, 'remailer/smtp/client/interpreter')

  # == Constants ============================================================
  
  include Remailer::Constants
  
  DEFAULT_TIMEOUT = 5
  
  # == Properties ===========================================================
  
  attr_accessor :active_message
  attr_accessor :remote, :max_size, :protocol, :hostname
  attr_accessor :pipelining, :tls_support, :auth_support
  attr_accessor :timeout
  attr_accessor :options
  attr_reader :error, :error_message

  # == Extensions ===========================================================

  include EventMachine::Deferrable

  # == Class Methods ========================================================

  def self.default_timeout
    DEFAULT_TIMEOUT
  end
  
  def self.default_port
    SMTP_PORT
  end

  # Opens a connection to a specific SMTP server. Options can be specified:
  # * port => Numerical port number (default is 25)
  # * require_tls => If true will fail connections to non-TLS capable
  #   servers (default is false)
  # * username => Username to authenticate with the SMTP server (optional)
  # * password => Password to authenticate with the SMTP server (optional)
  # * use_tls => Will use TLS if availble (default is true)
  # * debug => Where to send debugging output (IO or Proc)
  # * connect => Where to send a connection notification (IO or Proc)
  # * error => Where to send errors (IO or Proc)
  # * on_connect => Called upon successful connection (Proc)
  # * on_error => Called upon connection error (Proc)
  # * on_disconnect => Called when connection is closed (Proc)
  # A block can be supplied in which case it will stand in as the :connect
  # option. The block will recieve a first argument that is the status of
  # the connection, and an optional second that is a diagnostic message.
  def self.open(smtp_server, options = nil, &block)
    super(smtp_server, options, &block)
  end
  
  # == Instance Methods =====================================================

  # Called by AbstractConnection at the end of the initialize procedure
  def after_initialize
    @protocol = :smtp

    if (using_proxy?)
      proxy_connection_initiated!
      use_socks5_interpreter!
    else
      use_smtp_interpreter!
    end
  end

  # Closes the connection after all of the queued messages have been sent.
  def close_when_complete!
    @options[:close] = true
  end

  # Sends an email message through the connection at the earliest opportunity.
  # A callback block can be supplied that will be executed when the message
  # has been sent, an unexpected result occurred, or the send timed out.
  def send_email(from, to, data, &block)
    if (block_given?)
      self.class.warn_about_arguments(block, 1..2)
    end
    
    message = {
      :from => from,
      :to => to,
      :data => data,
      :callback => block
    }
    
    @messages << message
    
    # If the connection is ready to send...
    if (@interpreter and @interpreter.state == :ready)
      # ...send the message right away.
      after_ready
    end
  end

  # Tests the validity of an email address through the connection at the
  # earliest opportunity. A callback block can be supplied that will be
  # executed when the address has been tested, an unexpected result occurred,
  # or the request timed out.
  def test_email(from, to, &block)
    if (block_given?)
      self.class.warn_about_arguments(block, 1..2)
    end
    
    message = {
      :from => from,
      :to => to,
      :test => true,
      :callback => block
    }
    
    @messages << message
    
    # If the connection is ready to send...
    if (@interpreter and @interpreter.state == :ready)
      # ...send the message right away.
      after_ready
    end
  end
  
  def after_unbind
    if (@active_message)
      debug_notification(:disconnect, "Disconnected by remote before transaction could be completed.")

      if (callback = @active_message[:callback])
        callback.call(nil)

        @active_message = nil
      end
    elsif (@closed)
      debug_notification(:disconnect, "Disconnected from remote.")
    elsif (!@established)
      error_notification(:hangup, "Disconnected from remote before fully established.")
    else
      debug_notification(:disconnect, "Disconnected by remote while connection was idle.")
    end
  end
  
  # Returns true if the connection has been unbound by EventMachine, false
  # otherwise.
  def unbound?
    !!@unbound
  end

  # This implements the EventMachine::Connection#receive_data method that
  # is called each time new data is received from the socket.
  def receive_data(data)
    reset_timeout!

    @buffer ||= ''
    @buffer << data

    if (interpreter = @interpreter)
      interpreter.process(@buffer) do |reply|
        debug_notification(:receive, "[#{interpreter.label}] #{reply.inspect}")
      end
    else
      error_notification(:out_of_band, "Receiving data before a protocol has been established.")
    end
  end

  def post_init
    @timer = EventMachine.add_periodic_timer(1) do
      check_for_timeouts!
    end
  end
  
  #
  def detach
    @timer.cancel
    super
  end
  
  # Returns the current state of the active interpreter, or nil if no state
  # is assigned.
  def state
    if (interpreter = @interpreter)
      @interpreter.state
    else
      nil
    end
  end

  # Sends a single line to the remote host with the appropriate CR+LF
  # delmiter at the end.
  def send_line(line = '')
    reset_timeout!

    send_data(line + CRLF)

    debug_notification(:send, line.inspect)
  end

  def resolve_hostname(hostname)
    record = Socket.gethostbyname(hostname)
    
    # FIXME: IPv6 Support here
    address = (record and record[3])
    
    if (address)
      debug_notification(:resolver, "Address #{hostname} resolved as #{address.unpack('CCCC').join('.')}")
    else
      debug_notification(:resolver, "Address #{hostname} could not be resolved")
    end
    
    yield(address) if (block_given?)

    address
  rescue
    nil
  end

  # Resets the timeout time. Returns the time at which a timeout will occur.
  def reset_timeout!
    @timeout_at = Time.now + @timeout
  end
  
  # Returns the number of seconds remaining until a timeout will occur, or
  # nil if no time-out is pending.
  def time_remaning
    @timeout_at and (@timeout_at.to_i - Time.now.to_i)
  end
  
  # Checks for a timeout condition, and if one is detected, will close the
  # connection and send appropriate callbacks.
  def check_for_timeouts!
    return if (!@timeout_at or Time.now < @timeout_at or @timed_out)

    @timed_out = true
    @timeout_at = nil

    if (@connected and @active_message)
      message_callback(:timeout, "Response timed out before send could complete")
      error_notification(:timeout, "Response timed out")
      debug_notification(:timeout, "Response timed out")
      send_callback(:on_error)
    elsif (!@connected)
      remote_options = @options
      interpreter = @interpreter
      
      if (self.proxy_connection_initiated?)
        remote_options = @options[:proxy]
      end
      
      message = "Timed out before a connection could be established to #{remote_options[:host]}:#{remote_options[:port]}"
      
      if (interpreter)
        message << " using #{interpreter.label}"
      end
      
      connect_notification(false, message)
      debug_notification(:timeout, message)
      error_notification(:timeout, message)

      send_callback(:on_error)
    else
      interpreter = @interpreter

      if (interpreter and interpreter.respond_to?(:close))
        interpreter.close
      else
        send_callback(:on_disconnect)
      end
    end

    close_connection
  end
  
  # Returns true if pipelining support has been detected on the connection,
  # false otherwise.
  def pipelining?
    !!@pipelining
  end

  # Returns true if pipelining support has been detected on the connection,
  # false otherwise.
  def tls_support?
    !!@tls_support
  end
  
  # Returns true if the connection has been closed, false otherwise.
  def closed?
    !!@closed
  end
  
  # Returns true if an error has occurred, false otherwise.
  def error?
    !!@error
  end
  
  # Switches to use the SMTP interpreter for all subsequent communication
  def use_smtp_interpreter!
    @interpreter = SMTPInterpreter.new(:delegate => self)
  end

  # Callback receiver for when the proxy connection has been completed.
  def after_proxy_connected
    use_smtp_interpreter!
  end

  def after_ready
    super
    
    return if (@active_message)
  
    if (@active_message = @messages.shift)
      if (@interpreter.state == :ready)
        @interpreter.enter_state(:send)
      end
    elsif (@options[:close])
      if (callback = @options[:after_complete])
        callback.call
      end
      
      @interpreter.enter_state(:quit)
    end
  end

  def after_message_sent(reply_code, reply_message)
    message_callback(reply_code, reply_message)

    @active_message = nil
  end
end
