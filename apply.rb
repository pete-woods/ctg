require 'thread'
require 'set'
require 'tempfile'
require 'optparse'

class Popen4
  @@active = []

  def self.exec(*cmd)
    p cmd
    args = cmd.dup
    args << {:stdin => :null}
    Popen4.new(*args) do |f|
      result = f.stdout.read
      status = f.wait
      if status.exitstatus != 0 then
        raise "#{cmd.join(" ")} failed with #{status}"
      end
      return result
    end
  end

  def initialize(*cmd)
    Popen4.cleanup
    
    if Hash === cmd.last then
      options = cmd.pop
    else
      options = {}
    end
    
    @wait_mutex = Mutex.new
    @stdin = @stdout = @stderr = nil
    @status = nil
    to_close = []
    
    if options.has_key?(:stdin) then
      child_stdin = options[:stdin]
      if child_stdin == :null then
        child_stdin = File.open("/dev/null","r")
	to_close << child_stdin
      end
    else
      child_stdin, @stdin = IO.pipe
      to_close << child_stdin
    end
    
    if options.has_key?(:stdout) then
      child_stdout = options[:stdout]
    else
      @stdout, child_stdout = IO.pipe
      to_close << child_stdout
    end
    
    @pid = fork do
      if child_stdin then
        @stdin.close if @stdin
	STDIN.reopen(child_stdin)
	child_stdin.close
      end
      
      if child_stdout then
        @stdout.close if @stdout
	STDOUT.reopen(child_stdout)
	child_stdout.close
      end
      
      begin
        Kernel.exec(*cmd)
      ensure
        exit!(1)
      end
    end
    
    to_close.each { |fd| fd.close }
    @stdin.sync = true if @stdin
    
    Thread.exclusive { @@active << self }
    if block_given? then
      begin
        yield self
      ensure
        close
      end
    end
  end
  
  def self.cleanup
    active = Thread.exclusive { @@active.dup }
    active.each do |inst|
      inst.poll
    end
  end
  
  attr_reader :stdin, :stdout, :pid
  
  def close
    [@stdin, @stdout].each do |fp|
      begin
        fp.close if fp and not fp.closed?
      rescue
      end
    end
  end
  
  def wait(flags=0)
    @wait_mutex.synchronize do
      wait_no_lock(flags)
    end
  end
  
  def wait_no_lock(flags=0)
    return @status if @status
    while result = Process.waitpid2(@pid, flags)
      if result[0] == @pid and (result[1].exited? or result[1].signaled?) then
        @status = result[1]
        Thread.exclusive { @@active.delete(self) }
        return @status
      end
    end
    nil
  end
  
  private :wait_no_lock
  
  def poll
    if @wait_mutex.try_lock then
      begin
        wait_no_lock(Process::WNOHANG)
      ensure
        @wait_mutex.unlock
      end
    else
      nil
    end
  end
  
  def kill(signal)
    Process.kill(signal, @pid)
  end
end

class String
  def shell_escape
    if self !~ /^[-a-zA-Z0-9_.\/]+$/ then
      "'" + self.gsub("'","'\''") + "'"
    else
      self
    end
  end
end

class GitChange
  def initialize(file)
    @file = file
  end
  attr_reader :file
  
  def apply(cc)
    cmd = ["git", "diff", cc.rev_options, "--", file].flatten
    patch_data = Popen4.exec(*cmd)
    tf = Tempfile.new("patch")
    tf.write(patch_data)
    tf.close
    if not cc.preview then
      Dir.chdir(cc.view_path) do 
        Popen4.exec("git", "apply", tf.path)
      end
    end
    tf.unlink
    
    cc.output "(cd #{Dir.pwd.shell_escape} && git diff #{cc.rev_options} -- #{file.shell_escape}) | git apply"
  end
end

class GitChangeAdd < GitChange
  def calculate_checkouts(cc)
    if File.exists?(File.join(cc.view_path, file)) then
      raise "File already exists that would be added #{file.inspect}"
    end
    cc.checkout_dir File.dirname(file)
    cc.mkelem file, cc.file_message(file)
  end
end

class GitChangeDelete < GitChange
  def calculate_checkouts(cc)
    cc.checkout_dir File.dirname(file)
  end
    
  def apply(cc)
    message = cc.file_message(file)
    cc.cleartool "rmname", "-c", message, file
    cc.cleartool "chevent", "-append", "-c", message, File.dirname(file)
  end
end

class GitChangeModify < GitChange
  def calculate_checkouts(cc)
    cc.checkout file, cc.file_message(file)
  end  
end

class GitToClearcase
  def initialize(view_path)
    @view_path = view_path
    @preview = true
    @dirs_checked_out = Set.new
    @checkouts = Hash.new { |h,k| h[k] = [] }
    @mkelems = []
  end
 
 attr_reader :rev_options, :view_path, :preview
 attr_accessor :preview
 
  def file_message(file)
      cmd = ["git","log","--format=format:%s%n%b",rev_options,"--",file].flatten
      Popen4.exec(*cmd).strip
  end
  
  def mkelem(file, message)
    @mkelems << [file, message]
  end
  
  def checkout(file, message)
    @checkouts[message] << file
  end
  
  def checkin(file)
    @checkins[message] << file
  end
 
  def verify_no_checkouts
    checkouts = Dir.chdir(@view_path) do
      Popen4.exec "cleartool", "lsco", "-recurse"
    end
    if not checkouts.strip.empty? then
      raise "Must not be any checkouts. Try: ct lsco -recurse -fmt %Bn\\n | xargs cleartool unco -rm"
    end
  end
 
  def process(rev_options)
    verify_no_checkouts
  
    @rev_options = rev_options
    if @rev_options.length==1 and @rev_options[0] !~ /\.\./ then
      @rev_options[0] = @rev_options[0] + ".."
    end
    cmd = ["git","diff","--name-status", rev_options].flatten
    text = Popen4.exec(*cmd)
    edits = text.split("\n").map { |line| line.chomp("\n").split("\t") }

    @changes = []

    edits.each do |status, file|
      case status
      when "A"
        @changes << GitChangeAdd.new(file)
      when "M"
        @changes << GitChangeModify.new(file)
      when "D"
        @changes << GitChangeDelete.new(file)
      else
        raise "Unknown status #{status}"
      end
    end
    
    comment "Checking out files/directories"
    @changes.each do |c|
      c.calculate_checkouts(self)
    end

    @checkouts.each do |message,files|
      cleartool "co", "-c", message, *files
    end
    
    @mkelems.each do |file, message|
      cleartool "mkelem", "-c", message, file
      File.unlink(File.join(view_path,file))
    end
    
    do_apply
    #do_checkin
  end

  def do_apply
    comment "Applying changes"
    @changes.each do |c|
      c.apply(self)
    end
  end
  
  def do_checkin
    comment "Checking in files"
    @checkins.values.each do |files|
      cleartool "ci", "-nc", *files
    end
    
    comment "Checking in directories"
    @dirs_checked_out.each do |dir|
      cleartool "ci", "-nc", dir
    end
  end
 
  def comment(line)
    output "# #{line}"
  end
 
  def output(line)
    puts line
  end
 
  def show_command(*args)
    output args.map { |a| a.shell_escape }.join(" ")
  end
 
  def cleartool(*args)
    show_command "cleartool", *args
    if not @preview then
      Dir.chdir(@view_path) do
        cmd = ["cleartool"] + args
        Popen4.exec(*cmd)
      end
    end
  end

  def checkout_dir(dir)
    if not @dirs_checked_out.include?(dir) then
      @dirs_checked_out.add(dir)
      cleartool "co", "-nc", dir
    end
  end
end

if __FILE__ == $0 then
  view_path = nil
  rev_range = nil
  preview = true
  ARGV.options do |opts|
    opts.on("--exec","Actually execute commands") { preview = false }

    opts.banner = "Usage: apply [options] VIEW_PATH REV_RANGE"
    opts.parse!
  end
  
  view_path = ARGV.shift
  rev_range = ARGV
  
  if not view_path or not File.directory?(view_path) or rev_range.empty? then
    puts ARGV.options
    exit 1
  end
  
  gcc = GitToClearcase.new(view_path)
  gcc.preview = preview
  gcc.process(rev_range)

end
