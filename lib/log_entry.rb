require "securerandom"

class LogEntry
  protected
  attr_writer :text

  public
  attr_reader :id, :tag, :timestamp, :text

  def initialize(tag, text)
    @id = SecureRandom.uuid
    @tag = tag
    @timestamp = DateTime.now.freeze
    @text = ""
    self << text
    complete! if is_complete?
  end

  def <<(additional_text)
    @text << additional_text.dup
    freeze if is_complete?
    self
  end

  def is_complete?
    frozen? or @text.end_with? "\n"
  end

  def complete!
    return if is_complete?
    self << "\n"
  end

  def to_s
    "#{@tag} #{@timestamp} #{@text}"
  end

  def to_hash
    {
      id: id,
      tag: tag,
      timestamp: timestamp,
      complete: is_complete?,
      text: text.force_encoding("utf-8")
    }
  end

  def deep_clone
    result = clone
    result.text = @text.clone unless result.frozen?
    result
  end
end
