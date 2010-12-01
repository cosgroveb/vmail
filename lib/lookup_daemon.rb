require 'drb'
require File.expand_path("../message_formatter", __FILE__)
require 'yaml'
require 'mail'
require 'net/imap'
require 'time'
require 'logger'

class String
  def col(width)
    self[0,width].ljust(width)
  end
end

class GmailServer

  MailboxAliases = { 'sent' => '[Gmail]/Sent Mail',
    'all' => '[Gmail]/All Mail',
    'starred' => '[Gmail]/Starred',
    'important' => '[Gmail]/Important',
    'spam' => '[Gmail]/Spam',
    'trash' => '[Gmail]/Trash'
  }

  def initialize(config)
    @username, @password = config['login'], config['password']
    @mailbox = nil
    @logger = Logger.new("gmail.log")
    @logger.level = Logger::DEBUG
  end

  def open
    @imap = Net::IMAP.new('imap.gmail.com', 993, true, nil, false)
    @imap.login(@username, @password)
  end

  def close
    log "closing connection"
    @imap.close rescue Net::IMAP::BadResponseError
    @imap.disconnect
  end

  def select_mailbox(mailbox)
    if MailboxAliases[mailbox]
      mailbox = MailboxAliases[mailbox]
    end
    if mailbox == @mailbox 
      return
    end
    log "selecting mailbox #{mailbox}"
    @imap.select(mailbox)
    @mailbox = mailbox
    return "OK"
  rescue
    handle_error $!
  end

  def list_mailboxes
    @mailboxes ||= (@imap.list("[Gmail]/", "%") + @imap.list("", "%")).
      select {|struct| struct.attr.none? {|a| a == :Noselect} }.
      map {|struct| struct.name}.
      join("\n")
  rescue
    handle_error $!
  end

  def fetch_headers(uid_set)
    if uid_set.is_a?(String)
      uid_set = uid_set.split(",").map(&:to_i)
    end
    results = @imap.uid_fetch(uid_set, ["FLAGS", "BODY", "ENVELOPE", "RFC822.HEADER"])
    lines = results.map do |res|
      header = res.attr["RFC822.HEADER"]
      mail = Mail.new(header)
      flags = res.attr["FLAGS"]
      uid = res.attr["UID"]
      "#{uid} #{format_time(mail.date.to_s)} #{mail.from[0][0,30].ljust(30)} #{mail.subject.to_s[0,70].ljust(70)} #{flags.inspect.col(30)}"
    end
    log "got data for #{uid_set}"
    return lines.join("\n")
  rescue
    handle_error $!
  end

  def search(limit, *query)
    if @query != query.join(' ')
      @query = query.join(' ')
      log "uid_search #@query"
      @all_uids = @imap.uid_search(@query)
    end
    get_headers(limit)
  rescue
    handle_error $!
  end

  def update
    # i don't know why, but we have to fetch one uid first to be able to get new uids
    fetch_headers(@all_uids[-1])
    uids = @imap.uid_search(@query)
    new_uids = uids - @all_uids
    log "UPDATE: NEW UIDS: #{new_uids.inspect}"
    if !new_uids.empty?
      res = get_headers(1000, new_uids)
      @all_uids = uids
      res
    end
  rescue
    handle_error $!
  end

  def get_headers(limit, uids = @all_uids)
    uids = uids[-([limit.to_i, uids.size].min)..-1] || []
    lines = []
    threads = []
    uids.each do |uid|
      sleep 0.1
      threads << Thread.new(uid) do |thread_uid|
        this_thread = Thread.current
        results = nil
        while results.nil?
          results = @imap.uid_fetch(thread_uid, ["FLAGS", "BODY", "ENVELOPE", "RFC822.HEADER"])
        end
        res = results[0]
        header = res.attr["RFC822.HEADER"]
        log "got data for #{thread_uid}"

        mail = Mail.new(header)
        mail_id = thread_uid
        flags = res.attr["FLAGS"]
        address = @mailbox == '[Gmail]/Sent Mail' ? mail.to : mail.from
        "#{mail_id} #{format_time(mail.date.to_s)} #{address[0][0,30].ljust(30)} #{mail.subject.to_s[0,70].ljust(70)} #{flags.inspect.col(30)}"
      end
    end
    threads.each {|t| lines << t.value}
    lines.join("\n")
  end

  def lookup(uid, raw=false)
    log "fetching #{uid.inspect}"
    res = @imap.uid_fetch(uid.to_i, ["FLAGS", "RFC822"])[0].attr["RFC822"]
    if raw
      return res
    end
    mail = Mail.new(res)
    formatter = MessageFormatter.new(mail)
    part = formatter.find_text_part

    out = formatter.process_body 
    message = <<-END
#{formatter.extract_headers.to_yaml}

#{formatter.list_parts}

-- body --

#{out}
END
    message.gsub("\r", '')
  rescue
    handle_error $!
  end

  def flag(uid_set, action, flg)
    uid_set = uid_set.split(",").map(&:to_i)
    # #<struct Net::IMAP::FetchData seqno=17423, attr={"FLAGS"=>[:Seen, "Flagged"], "UID"=>83113}>
    log "flag #{uid_set} #{flg} #{action}"
    if flg == 'Deleted'
      # for delete, do in a separate thread because deletions are slow
      Thread.new do 
        @imap.uid_copy(uid_set, "[Gmail]/Trash")
        res = @imap.uid_store(uid_set, action, [flg.to_sym])
      end
    elsif flg == '[Gmail]/Spam'
      @imap.uid_copy(uid_set, "[Gmail]/Spam")
      res = @imap.uid_store(uid_set, action, [:Deleted])
      "#{uid} deleted"
    else
      log "Flagging"
      res = @imap.uid_store(uid_set, action, [flg.to_sym])
      # log res.inspect
      fetch_headers(uid_set)
    end
  end

  # TODO copy to a different mailbox

  # TODO mark spam

  def message_template
    headers = {'from' => @username,
      'to' => 'dhchoi@gmail.com',
      'subject' => "test #{rand(90)}"
    }
    headers.to_yaml + "\n\n"
  end

  def deliver(text)
    # parse the text. The headers are yaml. The rest is text body.
    require 'net/smtp'
    require 'smtp_tls'
    require 'mail'
    mail = Mail.new
    raw_headers, body = *text.split(/\n\n/)
    headers = YAML::load(raw_headers)
    log "delivering: #{headers.inspect}"
    mail.from = headers['from']
    mail.to = headers['to'].split(/,\s+/)
    mail.subject = headers['subject']
    mail.delivery_method(*smtp_settings)
    mail.from ||= @username
    mail.body = body
    mail.deliver!
    "SENT"
  end
 
  def smtp_settings
    [:smtp, {:address => "smtp.gmail.com",
    :port => 587,
    :domain => 'gmail.com',
    :user_name => @username,
    :password => @password,
    :authentication => 'plain',
    :enable_starttls_auto => true}]
  end

  def log(string)
    @logger.debug string
  end

  def handle_error(error)
    log error
    if error.is_a?(IOError) && error.message =~ /closed stream/
      log "Trying to reconnect"
      log open
    end
  end

  def format_time(x)
    Time.parse(x.to_s).localtime.strftime "%D %I:%M%P"
  end

  def self.start
    config = YAML::load(File.read(File.expand_path("../../config/gmail.yml", __FILE__)))
    $gmail = GmailServer.new config
    $gmail.open
  end

  def self.daemon
    self.start
    $gmail.select_mailbox "inbox"

    DRb.start_service(nil, $gmail)
    uri = DRb.uri
    puts "starting gmail service at #{uri}"
    uri
    #DRb.thread.join
  end

end

trap("INT") { 
  puts "closing connection"  
  $gmail.close
  exit
}


__END__
GmailServer.start
$gmail.select_mailbox("inbox")

log $gmail.flag(83113, "Flagged")
$gmail.close
