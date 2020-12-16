require "sinatra/base"
require "thin"
require "base64"
require_relative "lib/imapfilter"

class ImapfilterWebUI < Sinatra::Application
  @@imapfilter = nil
  @@imapfilter_mutex = Mutex.new
  @@connections = []

  configure do
    set :app_file, __FILE__
    set :server, :thin
  end

  helpers do
    def h(text)
      Rack::Utils.escape_html(text)
    end
  end

  def log_entries
    @@imapfilter&.log&.to_hash_array || []
  end

  def needs_login?(log_entry)
    !log_entry[:complete] and log_entry[:text].start_with?("Enter password")
  end

  def sse_message(action, log_entry)
    @running = @@imapfilter&.running?

    # some strings are ASCII-8BIT encoded (or are marked as such) and thus can't be JSON encoded.
    # Enforcing UTF-8 encoding fixes that.
    log_entry[:text] = log_entry[:text].force_encoding("utf-8")
    html = erb :log_entry, layout: false, locals: { entry: log_entry }
    data = {
      html: html,
      needs_login: @running && needs_login?(log_entry)
    }
    message = "id: #{log_entry[:id]}\n"
    message << "event: #{action.to_s}\n"
    message << "data: #{ERB::Util.url_encode(JSON.generate(data))}\n"
    message << "\n"
    message
  end

  def broadcast_sse_log_entry(action, entry)
    @@connections.reject!(&:closed?)
    
    @@connections.each { |out| out << sse_message(action, entry) }
  end

  def show_main_page
    @running = @@imapfilter&.running?
    @log = log_entries

    if @running and @log.any? { |e| needs_login? e }
      redirect "/login"
    else
      erb :index
    end
  end

  get "/" do
    show_main_page
  end

  get "/login" do
    entry = log_entries.reverse.find { |e| needs_login? e }
    if entry
      @account = entry[:text].match(/Enter password for (.+?)@/).captures.first
    else
      @account = ""
    end
    erb :login
  end

  post "/login" do
    @@imapfilter << "#{params[:password]}\n" if @@imapfilter
    show_main_page
  end

  post "/start" do
    @@imapfilter_mutex.synchronize do
      return if @@imapfilter&.alive?
      @@imapfilter = Imapfilter.new
      @@imapfilter.on_log_update { |action, entry| broadcast_sse_log_entry(action, entry) }
      @@imapfilter.start
    end
    show_main_page
  end

  post "/stop" do
    @@imapfilter_mutex.synchronize do
      return if @@imapfilter.nil?
      @@imapfilter.stop
    end
    @@connections.each { |out| out.close }
    show_main_page
  end

  post "/input" do
    @@imapfilter << "#{params[:input]}\n"
    show_main_page
  end

  get "/log" do
    content_type "text/event-stream"

    stream(:keep_open) do |out|
      @@connections << out

      # immediately send all log entries with "replace" logic
      # so events which occured _while_ the page was loading
      # are displayed.
      out << log_entries.map { |e| sse_message(:replace, e) }.join

      # purge dead connections
      @@connections.reject!(&:closed?)
    end
  end
end

ImapfilterWebUI.run!
