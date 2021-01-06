require_relative "log_entry"

class Log
  protected
  attr_reader :entries, :entries_mutex

  public
  attr_reader :tag

  def initialize(tag, entries = [])
    @tag = tag
    @entries = entries
    @entries_mutex = Mutex.new
  end

  # Called with
  # `<action>, log_entry_hash`
  # and `<action>` can either be `:add` or `:replace`
  def on_update(&block)
    @on_update = block
  end

  def <<(new_data)
    # Split lines but keep the newline - https://stackoverflow.com/a/18089658/588314
    lines = new_data.split /(?<=\n)/
    return if lines.empty?

    # buffer the operations so @on_update can be called without holding the mutex
    # in case the block calls << again.
    operations = []

    @entries_mutex.synchronize do
      # Append to the last line if it isn't complete yet
      if @entries.last and not @entries.last.is_complete?
        @entries.last << lines.shift
        operations << { action: :replace, entry: @entries.last.to_hash }
      end

      @entries += lines.map do |l| 
        new_entry = LogEntry.new(@tag, l)
        operations << { action: :add, entry: new_entry.to_hash }
        new_entry
      end
    end

    operations.each do |o|
      @on_update&.call(o[:action], o[:entry])
    end
  end

  def to_s
    @entries_mutex.synchronize do
      @entries.map { |e| e.to_s }.join.chomp + "\n"
    end
  end

  def to_hash_array
    @entries_mutex.synchronize do
      @entries.map { |e| e.to_hash }
    end
  end

  def merge(other)
    @entries_mutex.synchronize do
      other.entries_mutex.synchronize do

        own_entries = @entries.dup
        other_entries = other.entries.dup

        if own_entries.last and not own_entries.last.is_complete?
          own_entries[-1] = own_entries.last.deep_clone
        end
        if other_entries.last and not other_entries.last.is_complete?
          other_entries[-1] = other_entries.last.deep_clone
        end

        Log.new(nil, own_entries + other_entries)
      end
    end
  end

  def sort!
    @entries_mutex.synchronize do
      @entries.sort! { |a, b| a.timestamp <=> b.timestamp }
    end
  end
end
