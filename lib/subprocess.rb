require "thread"
require "open3"
require_relative "log"

class Subprocess
  # Helper to decouple the update handling from the processing loop.
  # Otherwise update handlers reacting to log output would
  # not be able to call `subprocess.write` because `write` blocks
  # until the input is processed. But the processing loop would be
  # waiting until the update handler has processed the log output.
  # This would be a deadlock.
  class OnUpdateForwarder
    def initialize(callback)
      @callback = callback
      @updates = []
      @should_run = false
      # protects access to @updates _and_ @should_run
      @mutex = Mutex.new
      @signal = ConditionVariable.new

      start
    end

    def on_update(action, parameter)
      @mutex.synchronize do
        # Don't accept new input if we're not supposed to run anymore.
        # This prevents that processing thread from running idefinitely 
        # (and thus `stop` blocking) if new updates flood in faster than
        # the thread can process them.
        return if not @should_run

        @updates << { action: action, parameter: parameter }
        # signal the processing thread to let it process the update(s)
        @signal.signal
      end
    end

    def stop
      @mutex.synchronize do
        @should_run = false
        # Process updates one more time
        @signal.signal
      end
      # wait for all updates which had been enqueued before calling `stop` to be processed
      @thread.join
    end

    private

    def start
      @mutex.synchronize { @should_run = true }
      
      @thread = Thread.new do
        # keep going if _either_ we're not stopped yet _or_ there are still updates to be sent out
        while @mutex.synchronize { @should_run or not @updates.empty? } do
          due_updates = []
          @mutex.synchronize do
            # wait for the next updates to arrive
            @signal.wait(@mutex) if @updates.empty?
            # take all updates which accumulated
            due_updates = @updates
            @updates = []
            # release the mutex -> the update handler can cause another `on_update` without causing a deadlock
          end
          # call the update handler with all due updates
          due_updates.each { |u| @callback.call(u[:action], u[:parameter]) }
        end
      end
    end
  end

  def initialize(command, substitute_input_logs: false)
    @command = command
    @substitute_input_logs = substitute_input_logs

    @out = Log.new :out
    @err = Log.new :err

    @out.on_update { |action, log_entry_hash| @on_update_forwarder&.on_update(action, log_entry_hash) }
    @err.on_update { |action, log_entry_hash| @on_update_forwarder&.on_update(action, log_entry_hash) }

    @alive = true
    @alive_mutex = Mutex.new
    
    @pid = nil
    @pid_mutex = Mutex.new
    @pid_signal = ConditionVariable.new

    @input_buffer_queue = []
    @input_buffer_queue_mutex = Mutex.new
  end

  # Called with:
  #  - `:add, log_entry_hash` when a new log entry has been added
  #  - `:replace, log_entry_hash` when a log entry has been replaced
  #  - `:start, pid` when the process has started
  #  - `:exit, status` when the process has exited
  def on_update(&block)
    @on_update_forwarder = OnUpdateForwarder.new(block)
  end

  def running?
    @pid_mutex.synchronize { !@pid.nil? }
  end

  def alive?
    @alive_mutex.synchronize { @alive }
  end

  def log
    merged = @out.merge(@err)
    merged.sort!
    merged
  end

  # Blocks until the given text is passed to the imapfilter process
  def write(text)
    return if not alive?
    @input_buffer_queue_mutex.synchronize do
      signal = ConditionVariable.new
      @input_buffer_queue << { text: text, signal: signal }
      # wait for this input to be processed
      signal.wait(@input_buffer_queue_mutex)
    end
  end
  alias_method :<<, :write

  def start
    raise "Not alive anymore. Can only be started once." if not alive?
    @pid_mutex.synchronize do
      raise "Already started. Can only be started once" if not @pid.nil?
    end

    Thread.new do

      # inspired by http://coldattic.info/post/63/
      # and https://gist.github.com/chrisn/7450808
      Open3.popen3(@command) do |stdin, stdout, stderr, wait_thr|
        @pid_mutex.synchronize do
          @pid = wait_thr.pid
          @pid_signal.broadcast
        end

        @on_update_forwarder&.on_update(:start, wait_thr.pid)

        stream_to_log = {
          stdout => @out,
          stderr => @err
        }

        local_input_buffer = ""

        # loop until all output streams are closed
        until stream_to_log.empty? do
          if local_input_buffer.empty?
            # transfer new input to a thread-local input buffer
            @input_buffer_queue_mutex.synchronize do
              local_input_buffer << @input_buffer_queue.first[:text] if not @input_buffer_queue.empty?
            end
          end
          # only wait for stdin to be ready if we have something to write
          input_streams = local_input_buffer.empty? ? nil : [stdin]

          # wait at most 1s for any stream to become ready
          ready_streams = IO.select(stream_to_log.keys, input_streams, nil, 1)

          if not ready_streams
            # return if the process is dead - https://stackoverflow.com/a/14381862/588314
            # `waitpid()` with `WNOHANG` will return the PID exactly _once_ and only _after_ the process has finished.
            break if Process.waitpid(wait_thr.pid, Process::WNOHANG)
            # next round: select again
            next
          end

          readable = ready_streams[0]
          writable = ready_streams[1]

          # write to stdin
          if writable.include? stdin
            begin
              # extract a chunk of input data (like bacon but input data)
              chunk = local_input_buffer.slice(0...4096)
              # try to write the whole chunk
              written_bytes = stdin.write_nonblock chunk
              # remove the part which could be written from the input buffer
              local_input_buffer.slice! 0...written_bytes

              # Add obfuscated input to output
              chunk = chunk.gsub(/[^\n]+/, "<input>") if @substitute_input_logs
              @out << chunk

              # Remove input buffer from queue if it has been written completely
              if local_input_buffer.empty?
                @input_buffer_queue_mutex.synchronize do
                  input_buffer = @input_buffer_queue.shift
                  # Continue the thread waiting for this input to be processed
                  input_buffer[:signal].signal
                end
              end
            rescue IO::WaitWritable
              # we'll just try again if writing failed
            end
          end

          # read from stdout and stderr
          readable.each do |stream|
            begin
              # This write triggers an input and the input waits until it is processed - by this loop -> DEADLOCK
              stream_to_log[stream] << stream.read_nonblock(4096)
            rescue EOFError
              stream_to_log.delete stream
            end
          end
        end

        wait_thr.join

        @pid_mutex.synchronize do
          @alive_mutex.synchronize { @alive = false }
          @pid = nil
          @pid_signal.broadcast
        end

        @on_update_forwarder&.on_update(:exit, wait_thr.value.exitstatus)
        @on_update_forwarder&.stop
      end

    end

    # wait for the process to be started before returning
    @pid_mutex.synchronize do
      @pid_signal.wait(@pid_mutex) if @pid.nil?
      @pid
    end
  end

  def stop
    @pid_mutex.synchronize do
      return if @pid.nil?
      Process.kill("SIGINT", @pid)
      # block until the process has exited
      @pid_signal.wait(@pid_mutex) unless @pid.nil?
    end
  end

  def signal(signal)
    @pid_mutex.synchronize do
      return if @pid.nil?
      Process.kill(signal, @pid)
    end
  end
end
