require_relative "log_entry"

class Log
  protected
  attr_reader :entries, :entries_mutex

  public

  def initialize(tag, entries = [])
    @tag = tag
    @entries = entries
    @entries_mutex = Mutex.new
  end

  def on_update(&block)
    @on_update = block
  end

  def <<(new_data)
    # Split lines but keep the newline - https://stackoverflow.com/a/18089658/588314
    lines = new_data.split /(?<=\n)/
    return if lines.empty?

    @entries_mutex.synchronize do
      # Append to the last line if it isn't complete yet
      if @entries.last and not @entries.last.is_complete?
        @entries.last << lines.shift
        @on_update&.call(:replace, @entries.last.to_hash)
      end

      @entries += lines.map do |l| 
        new_entry = LogEntry.new(@tag, l)
        @on_update&.call(:add, new_entry.to_hash)
        new_entry
      end
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
